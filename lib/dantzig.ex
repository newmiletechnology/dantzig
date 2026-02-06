defmodule Dantzig do
  @moduledoc """
  Documentation for `Dantzig`.
  """

  alias Dantzig.HiGHS
  alias Dantzig.Problem

  def solve(%Problem{} = problem, opts \\ []) do
    HiGHS.solve(problem, opts)
  end

  def solve!(%Problem{} = problem, opts \\ []) do
    {:ok, solution} = HiGHS.solve(problem, opts)
    solution
  end

  def dump_problem_to_file(%Problem{} = problem, path) do
    iodata = HiGHS.to_lp_iodata(problem)
    File.write!(path, iodata)
  end
end
