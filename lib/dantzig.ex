defmodule Dantzig do
  @moduledoc """
  Documentation for `Dantzig`.
  """

  alias Dantzig.HiGHS
  alias Dantzig.IIS
  alias Dantzig.MipStart
  alias Dantzig.Problem
  alias Dantzig.Solution

  @typedoc "Return type shared by `solve/2` and `solve_iodata/2,3`."
  @type solve_result ::
          {:optimal, Solution.t()}
          | {:time_limit, Solution.t()}
          | {:iteration_limit, Solution.t()}
          | {:objective_bound, Solution.t()}
          | {:objective_target, Solution.t()}
          | {:solution_limit, Solution.t()}
          | {:infeasible, %{optional(:iis) => IIS.t() | nil, output: String.t()}}
          | {:unbounded, %{output: String.t()}}
          | {:error, map()}

  @doc """
  Solves the given linear/mixed-integer problem.

  ## Return Values

  - `{:optimal, solution}` - Proven optimal solution found
  - `{:time_limit, solution}` - Time limit reached, best feasible solution returned
  - `{:iteration_limit, solution}` - Iteration limit reached, best feasible solution returned
  - `{:objective_bound, solution}` - Objective bound reached, feasible solution returned
  - `{:objective_target, solution}` - Objective target reached, feasible solution returned
  - `{:solution_limit, solution}` - Solution limit reached, feasible solution returned
  - `{:infeasible, info}` - Problem is infeasible; `info.iis` contains IIS if `compute_iis: true`
  - `{:unbounded, info}` - Problem is unbounded
  - `{:error, info}` - Solver error with details in `info.reason`

  ## Options

  - `:time_limit` - Maximum solve time in seconds (also used as the timeout for IIS computation)
  - `:compute_iis` - Compute IIS (Irreducible Infeasible Subsystem) when the problem is
    infeasible (default: `false`). When enabled, IIS computation runs in parallel with the
    main solve. If the result is infeasible, `info.iis` will contain a `Dantzig.IIS` struct
    with the conflicting constraints and variables. If the result is feasible, the IIS
    computation is discarded. IIS uses the elastic LP strategy (HiGHS `iis_strategy = 2`).
    Note: IIS currently only supports LP models in HiGHS; for MIP models it operates on
    the LP relaxation.
  - `:mip_rel_gap` - Relative MIP gap tolerance
  - `:mip_abs_gap` - Absolute MIP gap tolerance, in objective units (dollars for us)
  - `:mip_max_stall_nodes` - Max nodes without improvement before stalling
  - `:log_to_console` - Enable solver logging

  ### Tuning options (since 1.2.0)

  - `:mip_heuristic_effort` - Float in `[0.0, 1.0]`, HiGHS default `0.05`. Single highest-
    leverage MIP tuning knob per HiGHS maintainers; controls effort spent on primal
    heuristics during branch-and-bound.
  - `:parallel` - One of `"off" | "choose" | "on"`, HiGHS default `"choose"`. Enables
    parallel solver paths. As of HiGHS 1.13, MIP parallelism is limited to symmetry
    detection, clique tables, and interior-point centre computations; LP/simplex
    parallelism is well established.
  - `:threads` - Integer, HiGHS default `0` (auto). Worker thread count when `parallel`
    is enabled.
  - `:random_seed` - Non-negative integer, HiGHS default `0`. Useful for reproducible
    benchmark runs.

  ### Memory / working-set levers (since 1.2.0)

  HiGHS has no `memory_limit`; these bound its working set instead. All are
  optional and validated against HiGHS 1.12.0. Treat them as knobs to *measure*,
  not automatic wins.

  - `:threads` - see above. `threads: 1` forces serial branch-and-bound; whether
    it lowers native peak RSS depends on the model (larger effect on LP/IPM than
    on MIP in HiGHS 1.12).
  - `:parallel` - `"off"` pairs with `threads: 1` for a fully serial solve.
  - `:mip_pool_soft_limit` - Integer. Soft cap on the cut/clique pool size;
    lower values bound pool memory but may weaken cuts.
  - `:mip_pool_age_limit`, `:mip_lp_age_limit` - Integers. Age-out thresholds for
    pooled cuts / LP rows.
  - `:mip_max_nodes`, `:mip_max_leaves` - Integers. Hard caps on the search tree.
  - `:presolve` - `"off" | "choose" | "on"`, HiGHS default `"choose"`. Exposed
    for completeness; note `"off"` typically *increases* peak memory and time.

  ### Warm start (since 1.2.0)

  - `:mip_start` - Map of `%{var_polynomial_or_name => value}` providing a partial primal
    solution that HiGHS adopts as the incumbent at node 0 if feasible. See
    `Dantzig.MipStart` for details. Recommended to pair with `:mip_max_start_nodes`
    (below) to cap repair effort on infeasible starts.
  - `:mip_max_start_nodes` - Integer, HiGHS default unbounded. Caps the sub-MIP repair
    effort when an infeasible MIP start is provided. A small value (e.g. `50`) is a sane
    default — keeps an unusable start from burning solver time.

  When the solve returns a `%Dantzig.Solution{}`, check `solution.warm_start_status`
  to see whether HiGHS actually adopted the start:

  - `:accepted` — start was feasible; became the incumbent at node 0
  - `:rejected` — start was infeasible / could not yield a feasible solution; discarded
  - `:not_provided` — no `:mip_start` option was passed
  - `nil` — `:mip_start` was provided but HiGHS's status couldn't be determined from the
    log (defensive fallback; should be rare)

  This lets callers detect a silent no-op: a "warm-started" solve that HiGHS quietly
  treated as cold because the start was rejected.

  For time/iteration limited solves, check `solution.mip_gap` for the relative gap. As of
  1.2.0, this is correctly populated; before 1.2.0 it was always `nil` due to a regex
  parsing bug. The type widened from `float() | nil` to `float() | :infinity | nil`; the
  `:infinity` sentinel is returned when HiGHS reports `Gap inf` (no feasible solution
  found within the time limit).

  ## IIS (since v1.1.0)

  When `compute_iis: true` is passed, a parallel HiGHS process computes the IIS alongside the
  main solve. This avoids a bug in HiGHS 1.13.x where proactive IIS options could corrupt the
  solution file for feasible models that hit a time limit. The IIS result is only included in
  the response when the problem is actually infeasible.
  """
  @spec solve(Problem.t(), keyword()) :: solve_result()
  def solve(%Problem{} = problem, opts \\ []) do
    HiGHS.solve(problem, opts)
  end

  @doc """
  Serialize a `Problem` to LP-format iodata (the HiGHS model file contents).

  Pair with `solve_iodata/2,3` to serialize a problem, drop it, and only then
  solve — keeping the (potentially large) `Problem` off the heap during the
  solve. See `solve_iodata/2`.
  """
  @spec to_lp_iodata(Problem.t()) :: iodata()
  def to_lp_iodata(%Problem{} = problem), do: HiGHS.to_lp_iodata(problem)

  @doc """
  Serialize a MIP start (partial primal solution) to iodata for use with
  `solve_iodata/3`. Equivalent to what `solve/2` does internally for the
  `:mip_start` option. See `Dantzig.MipStart`.
  """
  @spec mip_start_to_iodata(Problem.t(), map()) :: iodata()
  def mip_start_to_iodata(%Problem{} = problem, mip_start),
    do: MipStart.to_iodata(problem, mip_start)

  @doc """
  Solve a pre-serialized LP model (from `to_lp_iodata/1`).

  This is the memory-conscious entry point: a caller can serialize the problem,
  release its reference to the `Problem` struct, `:erlang.garbage_collect()`,
  and then call this — so the Problem's constraints/objective are not retained
  on the heap during the (potentially long) solve. Solution decoding is purely
  name-based and never needs the Problem back.

      model = Dantzig.to_lp_iodata(problem)
      problem = nil
      :erlang.garbage_collect()
      Dantzig.solve_iodata(model, opts)

  To warm-start, pass a pre-serialized MIP start (from `mip_start_to_iodata/2`)
  via `solve_iodata/3`. The raw `:mip_start` map is not accepted here — pass it
  to `solve/2` instead if you still hold the `Problem`.

  Returns the same result shape as `solve/2`.
  """
  @spec solve_iodata(iodata(), keyword()) :: solve_result()
  def solve_iodata(model_iodata, opts \\ []) when is_list(opts),
    do: HiGHS.solve_iodata(model_iodata, opts)

  @doc """
  Solve a pre-serialized LP model with a pre-serialized MIP start. See
  `solve_iodata/2` and `mip_start_to_iodata/2`.
  """
  @spec solve_iodata(iodata(), iodata() | nil, keyword()) :: solve_result()
  def solve_iodata(model_iodata, mip_start_iodata, opts),
    do: HiGHS.solve_iodata(model_iodata, mip_start_iodata, opts)

  @doc """
  Solves the problem, raising on infeasibility, unboundedness, or solver errors.

  Returns the solution directly on success. For time/iteration limited solves
  that produce a feasible solution, this function returns successfully.

  For more control over error handling, use `solve/2` instead.
  """
  @spec solve!(Problem.t(), keyword()) :: Solution.t()
  def solve!(%Problem{} = problem, opts \\ []) do
    case solve(problem, opts) do
      {status, %Solution{} = solution}
      when status in [
             :optimal,
             :time_limit,
             :iteration_limit,
             :objective_bound,
             :objective_target,
             :solution_limit
           ] ->
        solution

      {:infeasible, info} ->
        raise Dantzig.InfeasibleError, iis: Map.get(info, :iis)

      {:unbounded, _} ->
        raise Dantzig.UnboundedError

      {:error, details} ->
        raise Dantzig.SolverError, reason: details[:reason], details: details
    end
  end

  def dump_problem_to_file(%Problem{} = problem, path) do
    iodata = HiGHS.to_lp_iodata(problem)
    File.write!(path, iodata)
  end
end
