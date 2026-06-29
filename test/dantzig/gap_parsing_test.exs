defmodule Dantzig.GapParsingTest do
  use ExUnit.Case, async: true

  alias Dantzig.HiGHS

  require Dantzig.Problem, as: Problem
  require Dantzig.Constraint, as: Constraint
  require Dantzig.Polynomial, as: Polynomial

  describe "extract_mip_gap/1 (canned HiGHS output)" do
    test "parses MIP Gap line with 0%" do
      output = """
      Solving report
        Model             example
        Status            Optimal
        Primal bound      12500
        Dual bound        12500
        Gap               0% (tolerance: 0.01%)
        P-D integral      0
      """

      assert HiGHS.extract_mip_gap(output) == 0.0
    end

    test "parses MIP Gap line with non-zero percentage" do
      output = """
      Solving report
        Status            Optimal
        Gap               2.34% (tolerance: 0.01%)
      """

      assert_in_delta HiGHS.extract_mip_gap(output), 0.0234, 1.0e-9
    end

    test "parses MIP Gap line with whole-number percentage" do
      output = """
      Solving report
        Gap               5% (tolerance: 0.01%)
      """

      assert_in_delta HiGHS.extract_mip_gap(output), 0.05, 1.0e-9
    end

    test "returns :infinity for MIP Gap of inf" do
      output = """
      Solving report
        Model             example
        Status            Infeasible
        Primal bound      inf
        Dual bound        -inf
        Gap               inf
      """

      assert HiGHS.extract_mip_gap(output) == :infinity
    end

    test "parses LP Relative P-D gap" do
      output = """
      Model status        : Optimal
      Simplex   iterations: 17
      Objective value     :  2.5000000000e+02
      Relative P-D gap    :  0.0000000000e+00
      HiGHS run time      :          0.00
      """

      assert HiGHS.extract_mip_gap(output) == 0.0
    end

    test "parses LP Relative P-D gap with non-zero exponential value" do
      output = """
      Relative P-D gap    :  1.2345000000e-05
      """

      assert_in_delta HiGHS.extract_mip_gap(output), 1.2345e-5, 1.0e-12
    end

    test "returns nil when no gap line present" do
      output = """
      Some random output with no gap info
      Status: who knows
      """

      assert HiGHS.extract_mip_gap(output) == nil
    end

    test "MIP Gap takes priority over LP P-D gap when both present" do
      # Some hybrid solves print both; MIP gap is the authoritative one
      output = """
      Relative P-D gap    :  0.0000000000e+00
      Solving report
        Status            Optimal
        Gap               1% (tolerance: 0.01%)
      """

      assert_in_delta HiGHS.extract_mip_gap(output), 0.01, 1.0e-9
    end
  end

  describe "extract_warm_start_status/2 (canned HiGHS output)" do
    test "returns :not_provided when no mip_start was passed" do
      assert HiGHS.extract_warm_start_status("any output", false) == :not_provided
    end

    test "returns :accepted on HiGHS feasible message" do
      output = """
      Assessing feasibility of MIP using primal feasibility and integrality tolerance of 1e-06
      Solution has               num          max          sum
      Col     infeasibilities      0            0            0
      MIP start solution is feasible, objective value is 22
      """

      assert HiGHS.extract_warm_start_status(output, true) == :accepted
    end

    test "returns :rejected on HiGHS 1.13.x discrete-infeasibility message" do
      output = """
      Row     infeasibilities      3           18           35
      Row     residuals            0            0            0
      User-supplied values of discrete variables cannot yield feasible solution
      Presolving model
      """

      assert HiGHS.extract_warm_start_status(output, true) == :rejected
    end

    test "returns :rejected on documented 'MIP start solution is infeasible' wording" do
      output = "MIP start solution is infeasible, objective value is 5\n"
      assert HiGHS.extract_warm_start_status(output, true) == :rejected
    end

    test "returns :accepted via assessment-block fallback when presolve solves the model" do
      # When the model is small enough to be solved entirely at presolve,
      # HiGHS doesn't print the explicit "MIP start solution is feasible" line.
      # The assessment block always appears, though.
      output = """
      Assessing feasibility of MIP using primal feasibility and integrality tolerance of 1e-06
      Solution has               num          max          sum
      Col     infeasibilities      0            0            0
      Integer infeasibilities      0            0            0
      Row     infeasibilities      0            0            0
      Row     residuals            0            0            0
      Presolving model
      Presolve: Optimal
      """

      assert HiGHS.extract_warm_start_status(output, true) == :accepted
    end

    test "rejection signals win over the assessment-block fallback" do
      # If the assessment block AND a rejection signal are both present,
      # rejection wins. (Both can co-occur in HiGHS output.)
      output = """
      Assessing feasibility of MIP using primal feasibility and integrality tolerance of 1e-06
      Row     infeasibilities      3           18           35
      User-supplied values of discrete variables cannot yield feasible solution
      """

      assert HiGHS.extract_warm_start_status(output, true) == :rejected
    end

    test "returns :rejected on nonzero Col infeasibilities without explicit rejection line" do
      # HiGHS 1.13 sometimes runs the repair LP for bound-infeasible starts
      # without emitting "User-supplied values cannot yield...". The
      # assessment summary block is the only signal.
      output = """
      Assessing feasibility of MIP using primal feasibility and integrality tolerance of 1e-06
      Solution has               num          max          sum
      Col     infeasibilities     23          12.5         200
      Integer infeasibilities      0            0            0
      Row     infeasibilities      0            0            0
      Row     residuals            0            0            0
      """

      assert HiGHS.extract_warm_start_status(output, true) == :rejected
    end

    test "returns :rejected on nonzero Row infeasibilities without explicit rejection line" do
      output = """
      Assessing feasibility of MIP using primal feasibility and integrality tolerance of 1e-06
      Solution has               num          max          sum
      Col     infeasibilities      0            0            0
      Integer infeasibilities      0            0            0
      Row     infeasibilities      5           18           35
      Row     residuals            0            0            0
      """

      assert HiGHS.extract_warm_start_status(output, true) == :rejected
    end

    test "returns nil when mip_start was provided but no known status line present" do
      output = "Some unrelated output\nStatus Optimal\n"
      assert HiGHS.extract_warm_start_status(output, true) == nil
    end
  end

  describe "extract_mip_gap/1 (live solve)" do
    test "MIP optimal solve populates mip_gap as a non-nil number" do
      Polynomial.algebra do
        problem = Problem.new(direction: :maximize)
        {problem, x} = Problem.new_variable(problem, "x", type: :integer, min: 0, max: 10)
        {problem, y} = Problem.new_variable(problem, "y", type: :integer, min: 0, max: 10)

        problem =
          problem
          |> Problem.add_constraint(Constraint.new(x + 2 * y <= 15))
          |> Problem.increment_objective(x + y)
      end

      assert {:optimal, solution} = Dantzig.solve(problem)
      assert solution.mip_gap != nil

      assert is_float(solution.mip_gap) or solution.mip_gap == :infinity
      if is_float(solution.mip_gap) do
        assert solution.mip_gap >= 0.0
        # An optimal solve should be at or under the default tolerance
        assert solution.mip_gap < 0.01
      end
    end
  end
end
