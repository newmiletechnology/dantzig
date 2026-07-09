defmodule Dantzig.SolveIodataTest do
  use ExUnit.Case, async: true

  require Dantzig.Problem, as: Problem
  require Dantzig.Constraint, as: Constraint
  require Dantzig.Polynomial, as: Polynomial

  # Maximize x + y subject to x + 2y <= 15, x, y ∈ {0..10}. Optimum objective 12.
  defp small_mip do
    Polynomial.algebra do
      problem = Problem.new(direction: :maximize)
      {problem, x} = Problem.new_variable(problem, "x", type: :integer, min: 0, max: 10)
      {problem, y} = Problem.new_variable(problem, "y", type: :integer, min: 0, max: 10)

      problem =
        problem
        |> Problem.add_constraint(Constraint.new(x + 2 * y <= 15))
        |> Problem.increment_objective(x + y)

      {problem, x, y}
    end
    |> Keyword.get(:do)
  end

  describe "Dantzig.solve_iodata/2" do
    test "matches solve/2 status and objective on a pre-serialized model" do
      {problem, _x, _y} = small_mip()

      {status_p, sol_p} = Dantzig.solve(problem)

      model = Dantzig.to_lp_iodata(problem)
      {status_i, sol_i} = Dantzig.solve_iodata(model, [])

      assert status_i == status_p
      assert status_i == :optimal
      assert sol_i.objective == sol_p.objective
    end

    test "honors memory-lever options without changing the optimum" do
      {problem, _x, _y} = small_mip()

      {:optimal, sol} =
        Dantzig.solve_iodata(Dantzig.to_lp_iodata(problem),
          threads: 1,
          parallel: "off",
          mip_pool_soft_limit: 100,
          presolve: "on"
        )

      assert sol.objective == 12
    end
  end

  describe "Dantzig.solve_iodata/3 (pre-serialized warm start)" do
    test "reproduces solve/2 with :mip_start — status, objective, warm_start_status" do
      {problem, x, y} = small_mip()

      {status_p, sol_p} =
        Dantzig.solve(problem, mip_start: %{x => 10, y => 2}, mip_max_start_nodes: 50)

      model = Dantzig.to_lp_iodata(problem)
      ms = Dantzig.mip_start_to_iodata(problem, %{x => 10, y => 2})
      {status_i, sol_i} = Dantzig.solve_iodata(model, ms, mip_max_start_nodes: 50)

      assert status_i == status_p
      assert status_i == :optimal
      assert sol_i.objective == sol_p.objective
      assert sol_i.warm_start_status == sol_p.warm_start_status
    end

    test "nil mip_start iodata reports :not_provided" do
      {problem, _x, _y} = small_mip()

      {:optimal, sol} = Dantzig.solve_iodata(Dantzig.to_lp_iodata(problem), nil, [])
      assert sol.warm_start_status == :not_provided
    end
  end
end
