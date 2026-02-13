defmodule Dantzig.HiGHS do
  @moduledoc false

  require Dantzig.Problem, as: Problem
  alias Dantzig.Config
  alias Dantzig.Constraint
  alias Dantzig.ProblemVariable
  alias Dantzig.Solution
  alias Dantzig.Polynomial
  import Guards

  @max_random_prefix 2 ** 32

  def solve(%Problem{} = problem, opts \\ []) do
    iodata = to_lp_iodata(problem)

    command = Config.get_highs_binary_path()

    with_temporary_files(["model.lp", "solution.lp", "options.txt"], fn [model_path, solution_path, options_path] ->
      File.write!(model_path, iodata)

      args = build_highs_args(model_path, solution_path, options_path, opts)
      {output, _error_code} = System.cmd(command, args)

      solution_contents =
        case File.read(solution_path) do
          {:ok, contents} ->
            contents

          {:error, :enoent} ->
            raise RuntimeError, """
              Couldn't generate a solution for the given problem.

              Input problem/model file:

              #{indent(iodata, 4)}
              Output from the HiGHS solver:

              #{indent(output, 4)}
              """
        end

      Solution.from_file_contents(solution_contents)
    end)
  end

  defp build_highs_args(model_path, solution_path, options_path, opts) do
    options_file_content = build_options_file_content(opts)

    [model_path, "--solution_file", solution_path]
    |> maybe_add_arg("--time_limit", Keyword.get(opts, :time_limit))
    |> maybe_add_options_file(options_file_content, options_path)

  end

  defp maybe_add_arg(args, key, value) when is_present?(value), do: args ++ [key, to_string(value)]
  defp maybe_add_arg(args, _, _), do: args

  defp build_options_file_content(opts) do
    # Options that must be passed via options file (not CLI args)
    file_options = [:mip_rel_gap, :log_to_console, :mip_max_stall_nodes]

    (
      for key <- file_options,
          value = Keyword.get(opts, key),
          is_present?(value) do
        "#{key} = #{value}"
      end
    )
    |> Enum.join("\n")
  end

  defp maybe_add_options_file(args, file_content, options_path) when is_present?(file_content) do
    File.write!(options_path, file_content)
    args ++ ["--options_file", options_path]
  end

  defp maybe_add_options_file(args, _, _), do: args

  defp indent(iodata, indent_level) do
    binary = to_string(iodata)
    spaces = String.duplicate(" ", indent_level)

    binary
    |> String.split("\n")
    |> Enum.map(fn line -> [spaces, line, "\n"] end)
  end

  defp with_temporary_files(basenames, fun) do
    dir = System.tmp_dir!()
    prefix = :rand.uniform(@max_random_prefix) |> Integer.to_string(32)

    paths =
      for basename <- basenames do
        Path.join(dir, "#{prefix}_#{basename}")
      end

    try do
      fun.(paths)
    after
      for path <- paths do
        try do
          File.rm!(path)
        rescue
          _ -> :ok
        end
      end
    end
  end

  defp constraint_to_iodata(constraint = %Constraint{}) do
    [
      "  ",
      constraint.name,
      ": ",
      Polynomial.to_lp_constraint(constraint.left_hand_side),
      " ",
      operator_to_iodata(constraint.operator),
      " ",
      to_string(constraint.right_hand_side),
      "\n"
    ]
  end

  defp operator_to_iodata(operator) do
    case operator do
      :== -> "="
      other -> to_string(other)
    end
  end

  defp direction_to_iodata(:maximize), do: "Maximize"
  defp direction_to_iodata(:minimize), do: "Minimize"

  def to_lp_iodata(%Problem{} = problem) do
    constraints = Enum.sort(problem.constraints)

    constraints_iodata =
      Enum.map(constraints, fn {_id, constraint} ->
        constraint_to_iodata(constraint)
      end)

    bounds = all_variable_bounds(Map.values(problem.variables))
    integers = variables_by_type(problem.variables, :integer)
    binaries = variables_by_type(problem.variables, :binary)

    [
      direction_to_iodata(problem.direction),
      "\n  ",
      Polynomial.to_lp_iodata_objective(problem.objective),
      "\n",
      "Subject To\n",
      constraints_iodata,
      "Bounds\n",
      bounds,
      "General\n",
      list_variables(integers),
      "Binary\n",
      list_variables(binaries),
      "End\n"
    ]
  end

  # Bounds have higher priority than variable type. So we need to exclude the :binary type here.
  defp variable_bounds(%ProblemVariable{type: :binary}), do: ""

  defp variable_bounds(%ProblemVariable{} = v) do
    case {v.min, v.max} do
      {nil, nil} ->
        "  #{v.name} free\n"

      {nil, max} ->
        "  #{v.name} <= #{max}\n"

      {min, nil} ->
        "  #{min} <= #{v.name}\n"

      {min, max} ->
        "  #{min} <= #{v.name}\n  #{v.name} <= #{max}\n"
    end
  end

  defp all_variable_bounds(variables) do
    Enum.map(variables, &variable_bounds/1)
  end

  defp variables_by_type(variables, type) do
    for {name, %{type: ^type}} <- variables, do: name
  end

  defp list_variables([]), do: []

  defp list_variables(variables) do
    for name <- variables, do: "  #{name}\n"
  end
end
