defmodule Dantzig.HiGHS do
  @moduledoc false

  require Dantzig.Problem, as: Problem
  require Logger
  alias Dantzig.Config
  alias Dantzig.Constraint
  alias Dantzig.IIS
  alias Dantzig.MipStart
  alias Dantzig.ProblemVariable
  alias Dantzig.Solution
  alias Dantzig.Polynomial
  import Guards

  @max_random_prefix 2 ** 32

  @model_statuses %{
    # Success statuses — have a feasible solution to parse
    "Optimal" => :optimal,
    "Bound on objective reached" => :objective_bound,
    "Target for objective reached" => :objective_target,

    # Early termination — have a feasible solution if one was found
    "Time limit reached" => :time_limit,
    "Iteration limit reached" => :iteration_limit,
    "Solution limit reached" => :solution_limit,

    # Infeasible/unbounded — no solution
    "Infeasible" => :infeasible,
    "Unbounded" => :unbounded,
    "Primal infeasible or unbounded" => :infeasible
  }

  @output_status_patterns [
    {~r/^\s*Status\s+Infeasible$/m, :infeasible},
    {~r/^\s*Status\s+Primal infeasible or unbounded$/m, :infeasible},
    {~r/^\s*Status\s+Unbounded$/m, :unbounded}
  ]

  # --- Public API ---

  @spec solve(Dantzig.Problem.t()) ::
          {:optimal
           | :time_limit
           | :iteration_limit
           | :objective_bound
           | :objective_target
           | :solution_limit, map()}
          | {:infeasible | :unbounded | :error, map()}
  def solve(%Problem{} = problem, opts \\ []) do
    model_iodata = to_lp_iodata(problem)
    mip_start = Keyword.get(opts, :mip_start)
    mip_start_iodata = if mip_start, do: MipStart.to_iodata(problem, mip_start)

    # Never thread the raw :mip_start map past here — solve_iodata works off
    # pre-serialized iodata so a memory-critical caller can drop the Problem.
    solve_iodata(model_iodata, mip_start_iodata, Keyword.delete(opts, :mip_start))
  end

  @doc """
  Solve a model that has already been serialized to LP iodata via
  `to_lp_iodata/1`. Lets a caller serialize, drop the `Problem`, GC, and only
  then solve — the decoder is name-based and never needs the Problem back.

  Pass a pre-serialized MIP start (from `MipStart.to_iodata/2`) as the second
  argument to warm-start; the raw `:mip_start` map is *not* accepted here.
  """
  def solve_iodata(model_iodata, opts \\ []) when is_list(opts) do
    solve_iodata(model_iodata, nil, opts)
  end

  def solve_iodata(model_iodata, mip_start_iodata, opts) do
    compute_iis? = Keyword.get(opts, :compute_iis, false)
    mip_start_provided? = mip_start_iodata != nil

    solve_opts =
      opts
      |> Keyword.delete(:compute_iis)
      |> Keyword.delete(:mip_start)

    timeout_ms = Keyword.get(opts, :time_limit, 120) * 1_000

    with_temporary_files(temp_file_names(mip_start_iodata), fn paths ->
      {model_path, solution_path, options_path, mip_start_path} = assign_paths(paths)
      File.write!(model_path, model_iodata)

      if mip_start_path do
        File.write!(mip_start_path, mip_start_iodata)
      end

      # The serialized model(s) are garbage from here on. Collect them before
      # the (potentially minutes-long) System.cmd wait — a process blocked in
      # System.cmd never GCs on its own, so this garbage would otherwise sit on
      # the heap for the whole solve.
      :erlang.garbage_collect()

      # Spawn IIS computation in parallel if requested — it reads the same model file
      iis_task = if compute_iis?, do: Task.async(fn -> compute_iis_pass(model_path, opts) end)

      args = build_args(model_path, solution_path, options_path, mip_start_path, solve_opts)
      {output, exit_code} = run_solver(args)

      result =
        process_result(exit_code, output, solution_path, model_path)
        |> add_warm_start_status(output, mip_start_provided?)

      case result do
        {:infeasible, info} when compute_iis? ->
          iis_result = Task.await(iis_task, timeout_ms)
          maybe_warn_infeasible_with_mip_start(mip_start_iodata)
          {:infeasible, Map.merge(info, iis_result)}

        {:infeasible, _info} ->
          if iis_task, do: Task.shutdown(iis_task, :brutal_kill)
          maybe_warn_infeasible_with_mip_start(mip_start_iodata)
          result

        _ ->
          if iis_task, do: Task.shutdown(iis_task, :brutal_kill)
          result
      end
    end)
  end

  defp add_warm_start_status({status, %Solution{} = sol}, output, mip_start_provided?) do
    {status,
     %{sol | warm_start_status: extract_warm_start_status(output, mip_start_provided?)}}
  end

  defp add_warm_start_status(other, _output, _mip_start_provided?), do: other

  defp maybe_warn_infeasible_with_mip_start(nil), do: :ok

  defp maybe_warn_infeasible_with_mip_start(_mip_start) do
    Logger.warning(
      "HiGHS reported :infeasible while a mip_start was provided. " <>
        "Due to HiGHS issue #902, status reporting can be incorrect when a start is rejected. " <>
        "Recommend a re-solve without mip_start to confirm the model itself is infeasible."
    )
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

  defp process_result(exit_code, output, solution_path, model_path)
       when exit_code in [0, 1] do
    case read_solution_file(solution_path) do
      {:ok, contents} ->
        contents
        |> extract_model_status()
        |> build_response(contents, output)

      :error ->
        {:error, %{reason: :no_solution, output: output, model: read_model_for_error(model_path)}}
    end
  end

  defp process_result(exit_code, output, _solution_path, model_path) do
    {:error,
     %{
       reason: :solver_error,
       exit_code: exit_code,
       output: output,
       model: read_model_for_error(model_path)
     }}
  end

  # The model file still exists here — cleanup runs `after` the solve closure
  # returns — so re-read it lazily for error reporting instead of keeping the
  # serialized model on the heap for the whole solve.
  defp read_model_for_error(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      _ -> nil
    end
  end

  defp build_response(:infeasible, _contents, output) do
    {:infeasible, %{output: output}}
  end

  defp build_response(:unbounded, _contents, output) do
    {:unbounded, %{output: output}}
  end

  defp build_response(status, contents, output)
       when status in [
              :optimal,
              :time_limit,
              :iteration_limit,
              :objective_bound,
              :objective_target,
              :solution_limit
            ] do
    case Solution.from_file_contents(contents) do
      {:ok, solution} ->
        {status, %{solution | status: status, mip_gap: extract_mip_gap(output)}}

      :error ->
        {:error, %{reason: :parse_error, raw: contents, output: output}}
    end
  end

  defp build_response(nil, contents, output) do
    case extract_status_from_output(output) do
      :infeasible ->
        {:infeasible, %{output: output}}

      :unbounded ->
        {:unbounded, %{output: output}}

      nil ->
        {:error, %{reason: :unknown_status, raw: contents, output: output}}
    end
  end

  defp extract_status_from_output(output) do
    Enum.find_value(@output_status_patterns, fn {pattern, status} ->
      if Regex.match?(pattern, output), do: status
    end)
  end

  # --- Solver Execution ---

  defp run_solver(args) do
    System.cmd(Config.get_highs_binary_path(), args, stderr_to_stdout: true)
  end

  defp compute_iis_pass(model_path, opts) do
    with_temporary_files(["iis_options.txt", "iis.lp"], fn [options_path, iis_path] ->
      File.write!(options_path, build_iis_options_content(iis_path))

      # Use the same time limit as the main solve — IIS runs in parallel so it
      # has the full duration available, and will be killed/ignored if not needed
      time_limit = Keyword.get(opts, :time_limit)

      args =
        [model_path, "--options_file", options_path]
        |> maybe_add_arg("--time_limit", time_limit)

      {_output, _exit_code} = run_solver(args)
      %{iis: IIS.from_file(iis_path)}
    end)
  end

  defp build_iis_options_content(iis_path) do
    "write_iis_model_file = #{iis_path}\niis_strategy = 2\npresolve = off"
  end

  defp temp_file_names(nil), do: ["model.lp", "solution.lp", "options.txt"]

  defp temp_file_names(_mip_start),
    do: ["model.lp", "solution.lp", "options.txt", "mip_start.sol"]

  defp assign_paths([model_path, solution_path, options_path]) do
    {model_path, solution_path, options_path, nil}
  end

  defp assign_paths([model_path, solution_path, options_path, mip_start_path]) do
    {model_path, solution_path, options_path, mip_start_path}
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

  @doc false
  def extract_warm_start_status(_output, false = _mip_start_provided?), do: :not_provided

  def extract_warm_start_status(output, true = _mip_start_provided?) do
    cond do
      # Explicit rejection signals — check first, they're the most specific.
      Regex.match?(
        ~r/User-supplied values of discrete variables cannot yield feasible solution/,
        output
      ) ->
        :rejected

      # Defensive: documented "MIP start solution is infeasible" wording.
      Regex.match?(~r/MIP start solution is infeasible/, output) ->
        :rejected

      # HiGHS 1.13 emits this when the start has bound/constraint
      # infeasibilities but the repair LP still runs (instead of bailing out
      # with the "User-supplied values cannot yield feasible solution" line).
      # Match the assessment summary block — `Col infeasibilities <N>` or
      # `Row infeasibilities <N>` with N > 0 (any nonzero leading digit).
      Regex.match?(~r/Col\s+infeasibilities\s+[1-9]/, output) ->
        :rejected

      Regex.match?(~r/Row\s+infeasibilities\s+[1-9]/, output) ->
        :rejected

      # Explicit acceptance signal (HiGHS 1.13.x, appears when MIP solving runs).
      Regex.match?(~r/MIP start solution is feasible/, output) ->
        :accepted

      # Fallback acceptance signal: HiGHS read and assessed the start. When the
      # model is solved entirely at presolve, the explicit "MIP start solution
      # is feasible" line isn't printed, but the assessment block always
      # appears. If no rejection signal fired above, the start was accepted.
      Regex.match?(~r/Assessing feasibility of MIP/, output) ->
        :accepted

      true ->
        nil
    end
  end

  @doc false
  def extract_mip_gap(output) do
    cond do
      match = Regex.run(~r/^\s*Gap\s+(\d+\.?\d*)%/m, output) ->
        {gap, _} = Float.parse(Enum.at(match, 1))
        gap / 100.0

      Regex.match?(~r/^\s*Gap\s+inf\b/m, output) ->
        :infinity

      match = Regex.run(~r/Relative P-D gap\s*:\s*([\d.eE+\-]+)/, output) ->
        {gap, _} = Float.parse(Enum.at(match, 1))
        gap

      true ->
        nil
    end
  end

  # --- CLI Argument Building ---

  defp build_args(model_path, solution_path, options_path, mip_start_path, opts) do
    options_content = build_options_content(opts)

    [model_path, "--solution_file", solution_path]
    |> maybe_add_arg("--time_limit", Keyword.get(opts, :time_limit))
    |> maybe_add_options_file(options_content, options_path)
    |> maybe_add_mip_start(mip_start_path)
  end

  defp maybe_add_mip_start(args, nil), do: args
  defp maybe_add_mip_start(args, path), do: args ++ ["--read_solution_file", path]

  @doc false
  def build_options_content(opts) do
    file_options = [
      :mip_rel_gap,
      :mip_abs_gap,
      :log_to_console,
      :mip_max_stall_nodes,
      :mip_heuristic_effort,
      :mip_max_start_nodes,
      :parallel,
      :threads,
      :random_seed,
      # Memory levers. HiGHS has NO memory_limit option; these bound the
      # solver's working set. All verified valid in HiGHS 1.12.0. NB: `presolve`
      # is exposed as a knob but `presolve = off` typically *increases* peak
      # memory — do not set it off expecting a memory win.
      :mip_pool_soft_limit,
      :mip_pool_age_limit,
      :mip_lp_age_limit,
      :mip_max_nodes,
      :mip_max_leaves,
      :presolve
    ]

    for key <- file_options,
        value = Keyword.get(opts, key),
        is_present?(value) do
      "#{key} = #{value}"
    end
    |> Enum.join("\n")
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
