defmodule Dantzig.WarmStartTest do
  use ExUnit.Case, async: true

  require Dantzig.Problem, as: Problem
  require Dantzig.Constraint, as: Constraint
  require Dantzig.Polynomial, as: Polynomial

  # Build a small MIP whose optimum is reachable by warm-starting.
  # Maximize x + y subject to x + 2y <= 15, x, y ∈ {0..10}.
  # Optimal is x=10, y=2 with objective 12 (or x=9,y=3 — both objective 12).
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

  describe "Dantzig.solve/2 with :mip_start" do
    test "cold and warm solves return the same optimal objective" do
      {problem, x, y} = small_mip()

      {:optimal, sol_cold} = Dantzig.solve(problem)

      {:optimal, sol_warm} =
        Dantzig.solve(problem,
          mip_start: %{x => 10, y => 2},
          mip_max_start_nodes: 50
        )

      assert sol_cold.objective == sol_warm.objective
    end

    test "non-optimal feasible warm start still finds the optimum" do
      {problem, x, y} = small_mip()

      {:optimal, sol_cold} = Dantzig.solve(problem)

      {:optimal, sol_warm} =
        Dantzig.solve(problem,
          mip_start: %{x => 5, y => 5},
          mip_max_start_nodes: 50
        )

      assert sol_cold.objective == sol_warm.objective
    end

    test "infeasible warm start does not break the solve" do
      {problem, x, y} = small_mip()

      {:optimal, sol_cold} = Dantzig.solve(problem)

      # x=10, y=10 violates x + 2y <= 15
      {:optimal, sol_warm} =
        Dantzig.solve(problem,
          mip_start: %{x => 10, y => 10},
          mip_max_start_nodes: 50
        )

      assert sol_cold.objective == sol_warm.objective
    end

    test "mip_start with no useful entries still solves correctly" do
      {problem, _x, _y} = small_mip()

      {:optimal, sol_cold} = Dantzig.solve(problem)

      {:optimal, sol_warm} =
        Dantzig.solve(problem,
          mip_start: %{"x99999999_ghost" => 99},
          mip_max_start_nodes: 50
        )

      assert sol_cold.objective == sol_warm.objective
    end

    test "string-name keys work for warm start" do
      {problem, x, y} = small_mip()
      x_name = Polynomial.variable_name!(x)
      y_name = Polynomial.variable_name!(y)

      {:optimal, sol_warm} =
        Dantzig.solve(problem,
          mip_start: %{x_name => 10, y_name => 2},
          mip_max_start_nodes: 50
        )

      assert sol_warm.objective == 12
    end
  end

  describe "warm_start_status" do
    test "cold solve reports :not_provided" do
      {problem, _x, _y} = small_mip()

      {:optimal, sol} = Dantzig.solve(problem)

      assert sol.warm_start_status == :not_provided
    end

    test "feasible warm start reports :accepted" do
      {problem, x, y} = small_mip()

      {:optimal, sol} =
        Dantzig.solve(problem,
          mip_start: %{x => 10, y => 2},
          mip_max_start_nodes: 50
        )

      assert sol.warm_start_status == :accepted
    end

    test "feasible suboptimal warm start reports :accepted" do
      {problem, x, y} = small_mip()

      {:optimal, sol} =
        Dantzig.solve(problem,
          mip_start: %{x => 1, y => 1},
          mip_max_start_nodes: 50
        )

      assert sol.warm_start_status == :accepted
    end

    test "infeasible warm start reports :rejected" do
      {problem, x, y} = small_mip()

      # x=10, y=10 violates x + 2y <= 15
      {:optimal, sol} =
        Dantzig.solve(problem,
          mip_start: %{x => 10, y => 10},
          mip_max_start_nodes: 50
        )

      assert sol.warm_start_status == :rejected
    end
  end
end
