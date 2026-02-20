defmodule Dantzig.ErrorHandlingTest do
  use ExUnit.Case, async: true

  require Dantzig.Problem, as: Problem
  require Dantzig.Constraint, as: Constraint
  require Dantzig.Polynomial, as: Polynomial

  alias Dantzig.Solution

  describe "infeasible problems" do
    test "returns {:infeasible, info}" do
      Polynomial.algebra do
        problem = Problem.new(direction: :minimize)
        {problem, x} = Problem.new_variable(problem, "x")

        problem =
          problem
          |> Problem.add_constraint(Constraint.new(x >= 10))
          |> Problem.add_constraint(Constraint.new(x <= 5))
          |> Problem.increment_objective(x)
      end

      assert {:infeasible, info} = Dantzig.solve(problem)
      assert is_map(info)
      assert Map.has_key?(info, :output)
    end

    test "returns IIS when compute_iis: true" do
      Polynomial.algebra do
        problem = Problem.new(direction: :minimize)
        {problem, x} = Problem.new_variable(problem, "x")

        problem =
          problem
          |> Problem.add_constraint(Constraint.new(x >= 10))
          |> Problem.add_constraint(Constraint.new(x <= 5))
          |> Problem.increment_objective(x)
      end

      assert {:infeasible, info} = Dantzig.solve(problem, compute_iis: true)
      assert Map.has_key?(info, :iis)

      if info.iis != nil do
        assert is_list(info.iis.constraints)
        assert is_binary(info.iis.raw_content)
      end
    end

    test "solve! raises InfeasibleError" do
      Polynomial.algebra do
        problem = Problem.new(direction: :minimize)
        {problem, x} = Problem.new_variable(problem, "x")

        problem =
          problem
          |> Problem.add_constraint(Constraint.new(x >= 10))
          |> Problem.add_constraint(Constraint.new(x <= 5))
          |> Problem.increment_objective(x)
      end

      assert_raise Dantzig.InfeasibleError, fn ->
        Dantzig.solve!(problem)
      end
    end
  end

  describe "infeasible with unbounded variable" do
    test "handles infeasible problem with free variables as {:infeasible, _}" do
      Polynomial.algebra do
        problem = Problem.new(direction: :maximize)
        {problem, x} = Problem.new_variable(problem, "x")

        problem =
          problem
          |> Problem.add_constraint(Constraint.new(x >= 10))
          |> Problem.add_constraint(Constraint.new(x <= 5))
          |> Problem.increment_objective(x)
      end

      assert {:infeasible, info} = Dantzig.solve(problem)
      assert is_map(info)
    end
  end

  describe "unbounded problems" do
    test "returns {:unbounded, info}" do
      Polynomial.algebra do
        problem = Problem.new(direction: :maximize)
        {problem, x} = Problem.new_variable(problem, "x", min: 0.0)

        problem = Problem.increment_objective(problem, x)
      end

      assert {:unbounded, info} = Dantzig.solve(problem)
      assert is_map(info)
      assert Map.has_key?(info, :output)
    end

    test "solve! raises UnboundedError" do
      Polynomial.algebra do
        problem = Problem.new(direction: :maximize)
        {problem, x} = Problem.new_variable(problem, "x", min: 0.0)

        problem = Problem.increment_objective(problem, x)
      end

      assert_raise Dantzig.UnboundedError, fn ->
        Dantzig.solve!(problem)
      end
    end
  end

  describe "optimal solutions" do
    test "returns {:optimal, solution}" do
      Polynomial.algebra do
        problem = Problem.new(direction: :maximize)
        {problem, x} = Problem.new_variable(problem, "x", min: 0.0, max: 10.0)

        problem = Problem.increment_objective(problem, x)
      end

      assert {:optimal, solution} = Dantzig.solve(problem)
      assert solution.status == :optimal
      assert solution.model_status == "Optimal"
      assert solution.objective == 10.0
    end

    test "solution has mip_gap field" do
      Polynomial.algebra do
        problem = Problem.new(direction: :maximize)
        {problem, x} = Problem.new_variable(problem, "x", min: 0.0, max: 10.0)

        problem = Problem.increment_objective(problem, x)
      end

      {:optimal, solution} = Dantzig.solve(problem)
      assert Map.has_key?(solution, :mip_gap)
    end
  end

  describe "solve!/2" do
    test "returns solution directly for optimal" do
      Polynomial.algebra do
        problem = Problem.new(direction: :maximize)
        {problem, x} = Problem.new_variable(problem, "x", min: 0.0, max: 10.0)

        problem = Problem.increment_objective(problem, x)
      end

      solution = Dantzig.solve!(problem)
      assert %Solution{} = solution
      assert solution.objective == 10.0
    end

    test "works with multi-variable problem" do
      Polynomial.algebra do
        total_width = 300.0

        problem = Problem.new(direction: :maximize)
        {problem, left_margin} = Problem.new_variable(problem, "left_margin", min: 0.0)
        {problem, center} = Problem.new_variable(problem, "center", min: 0.0)
        {problem, right_margin} = Problem.new_variable(problem, "right_margin", min: 0.0)

        problem =
          problem
          |> Problem.add_constraint(
            Constraint.new(left_margin + center + right_margin == total_width)
          )
          |> Problem.increment_objective(center - left_margin - right_margin)
      end

      solution = Dantzig.solve!(problem)
      assert solution.model_status == "Optimal"
      assert Solution.nr_of_constraints(solution) == 1
      assert Solution.nr_of_variables(solution) == 3
    end
  end
end
