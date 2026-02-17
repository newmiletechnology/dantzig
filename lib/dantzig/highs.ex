defmodule Dantzig.HiGHS do
  @moduledoc false

  require Dantzig.Problem, as: Problem
  alias Dantzig.Config
  alias Dantzig.Constraint
  alias Dantzig.IIS
  alias Dantzig.ProblemVariable
  alias Dantzig.Solution
  alias Dantzig.Polynomial
  import Guards

  @max_random_prefix 2 ** 32

  @model_statuses %{
    "Optimal" => :optimal,
    "Infeasible" => :infeasible,
    "Unbounded" => :unbounded,
    "Time limit reached" => :time_limit,
    "Iteration limit reached" => :iteration_limit
  }

  # --- Public API ---

  @spec solve(Dantzig.Problem.t()) ::
          {:error | :infeasible | :iteration_limit | :optimal | :time_limit | :unbounded, map()}
  def solve(%Problem{} = problem, opts \\ []) do
    iodata = to_lp_iodata(problem)

    with_temporary_files(temp_file_names(opts), fn paths ->
      {model_path, solution_path, options_path, iis_path} = assign_paths(paths)
      File.write!(model_path, iodata)

      args = build_args(model_path, solution_path, options_path, iis_path, opts)
      {output, exit_code} = run_solver(args)

      process_result(exit_code, output, solution_path, iis_path, iodata)
    end)
  end

  def to_lp_iodata(%Problem{} = problem) do
    constraints = Enum.sort(problem.constraints)

    constraints_iodata =
      Enum.map(constraints, fn {_id, constraint} ->
        constraint_to_iodata(constraint)
      end)

    bounds = Enum.map(Map.values(problem.variables), &variable_bounds/1)
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

  # --- Result Processing ---

  defp process_result(exit_code, output, solution_path, iis_path, model_iodata)
       when exit_code in [0, 1] do
    case read_solution_file(solution_path) do
      {:ok, contents} ->
        contents
        |> extract_model_status()
        |> build_response(contents, output, iis_path)

      :error ->
        {:error,
         %{reason: :no_solution, output: output, model: IO.iodata_to_binary(model_iodata)}}
    end
  end

  defp process_result(exit_code, output, _solution_path, _iis_path, model_iodata) do
    {:error,
     %{
       reason: :solver_error,
       exit_code: exit_code,
       output: output,
       model: IO.iodata_to_binary(model_iodata)
     }}
  end

  defp build_response(:infeasible, _contents, output, iis_path) do
    {:infeasible, %{iis: IIS.from_file(iis_path), output: output}}
  end

  defp build_response(:unbounded, _contents, output, _iis_path) do
    {:unbounded, %{output: output}}
  end

  defp build_response(status, contents, output, _iis_path)
       when status in [:optimal, :time_limit, :iteration_limit] do
    case Solution.from_file_contents(contents) do
      {:ok, solution} ->
        {status, %{solution | status: status, mip_gap: extract_mip_gap(output)}}

      :error ->
        {:error, %{reason: :parse_error, raw: contents, output: output}}
    end
  end

  defp build_response(nil, contents, output, _iis_path) do
    {:error, %{reason: :unknown_status, raw: contents, output: output}}
  end

  # --- Solver Execution ---

  defp run_solver(args) do
    System.cmd(Config.get_highs_binary_path(), args, stderr_to_stdout: true)
  end

  defp temp_file_names(opts) do
    base = ["model.lp", "solution.lp", "options.txt"]
    if Keyword.get(opts, :compute_iis, false), do: base ++ ["iis.lp"], else: base
  end

  defp assign_paths(paths) do
    [model_path, solution_path, options_path | rest] = paths
    {model_path, solution_path, options_path, List.first(rest)}
  end

  # --- Solution Parsing ---

  defp extract_model_status(contents) do
    case String.split(contents, "\n", parts: 3) do
      ["Model status", status | _] -> Map.get(@model_statuses, String.trim(status))
      _ -> nil
    end
  end

  defp read_solution_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      _ -> :error
    end
  end

  defp extract_mip_gap(output) do
    cond do
      match = Regex.run(~r/Relative gap:\s*([\d.]+)/, output) ->
        {gap, ""} = Float.parse(Enum.at(match, 1))
        gap

      match = Regex.run(~r/Gap:\s*([\d.]+)%/, output) ->
        {gap, ""} = Float.parse(Enum.at(match, 1))
        gap / 100.0

      true ->
        nil
    end
  end

  # --- CLI Argument Building ---

  defp build_args(model_path, solution_path, options_path, iis_path, opts) do
    options_content = build_options_content(opts, iis_path)

    [model_path, "--solution_file", solution_path]
    |> maybe_add_arg("--time_limit", Keyword.get(opts, :time_limit))
    |> maybe_add_options_file(options_content, options_path)
  end

  defp build_options_content(opts, iis_path) do
    file_options = [:mip_rel_gap, :log_to_console, :mip_max_stall_nodes]

    base =
      for key <- file_options,
          value = Keyword.get(opts, key),
          is_present?(value) do
        "#{key} = #{value}"
      end

    iis =
      if Keyword.get(opts, :compute_iis, false) && is_binary(iis_path) do
        [
          "write_iis_model_file = #{iis_path}",
          # iis_strategy 8 = find true IIS via elastic filter
          "iis_strategy = 8"
        ]
      else
        []
      end

    Enum.join(base ++ iis, "\n")
  end

  defp maybe_add_arg(args, key, value) when is_present?(value),
    do: args ++ [key, to_string(value)]

  defp maybe_add_arg(args, _, _), do: args

  defp maybe_add_options_file(args, content, path) when is_present?(content) do
    File.write!(path, content)
    args ++ ["--options_file", path]
  end

  defp maybe_add_options_file(args, _, _), do: args

  # --- Temporary Files ---

  defp with_temporary_files(basenames, fun) do
    dir = System.tmp_dir!()
    prefix = :rand.uniform(@max_random_prefix) |> Integer.to_string(32)
    paths = Enum.map(basenames, &Path.join(dir, "#{prefix}_#{&1}"))

    try do
      fun.(paths)
    after
      Enum.each(paths, fn path ->
        try do
          File.rm!(path)
        rescue
          _ -> :ok
        end
      end)
    end
  end

  # --- LP Format Generation ---

  defp constraint_to_iodata(%Constraint{} = constraint) do
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

  defp operator_to_iodata(:==), do: "="
  defp operator_to_iodata(other), do: to_string(other)

  defp direction_to_iodata(:maximize), do: "Maximize"
  defp direction_to_iodata(:minimize), do: "Minimize"

  defp variable_bounds(%ProblemVariable{type: :binary}), do: ""

  defp variable_bounds(%ProblemVariable{} = v) do
    case {v.min, v.max} do
      {nil, nil} -> "  #{v.name} free\n"
      {nil, max} -> "  #{v.name} <= #{max}\n"
      {min, nil} -> "  #{min} <= #{v.name}\n"
      {min, max} -> "  #{min} <= #{v.name}\n  #{v.name} <= #{max}\n"
    end
  end

  defp variables_by_type(variables, type) do
    for {name, %{type: ^type}} <- variables, do: name
  end

  defp list_variables([]), do: []
  defp list_variables(variables), do: Enum.map(variables, &"  #{&1}\n")
end
