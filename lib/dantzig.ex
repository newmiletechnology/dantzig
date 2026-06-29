defmodule Dantzig do
  @moduledoc """
  Documentation for `Dantzig`.
  """

  alias Dantzig.HiGHS
  alias Dantzig.IIS
  alias Dantzig.Problem
  alias Dantzig.Solution

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
  @spec solve(Problem.t(), keyword()) ::
          {:optimal, Solution.t()}
          | {:time_limit, Solution.t()}
          | {:iteration_limit, Solution.t()}
          | {:objective_bound, Solution.t()}
          | {:objective_target, Solution.t()}
          | {:solution_limit, Solution.t()}
          | {:infeasible, %{optional(:iis) => IIS.t() | nil, output: String.t()}}
          | {:unbounded, %{output: String.t()}}
          | {:error, map()}
  def solve(%Problem{} = problem, opts \\ []) do
    HiGHS.solve(problem, opts)
  end

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
