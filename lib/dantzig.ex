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
  - `{:infeasible, info}` - Problem is infeasible; `info.iis` contains IIS if `compute_iis: true`
  - `{:unbounded, info}` - Problem is unbounded
  - `{:error, info}` - Solver error with details in `info.reason`

  ## Options

  - `:time_limit` - Maximum solve time in seconds
  - `:compute_iis` - Extract IIS on infeasibility (default: false)
  - `:mip_rel_gap` - Relative MIP gap tolerance
  - `:mip_max_stall_nodes` - Max nodes without improvement before stalling
  - `:log_to_console` - Enable solver logging

  For time/iteration limited solves, check `solution.mip_gap` for the relative gap.
  """
  @spec solve(Problem.t(), keyword()) ::
          {:optimal, Solution.t()}
          | {:time_limit, Solution.t()}
          | {:iteration_limit, Solution.t()}
          | {:infeasible, %{iis: IIS.t() | nil, output: String.t()}}
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
      {status, %Solution{} = solution} when status in [:optimal, :time_limit, :iteration_limit] ->
        solution

      {:infeasible, %{iis: iis}} ->
        raise Dantzig.InfeasibleError, iis: iis

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
