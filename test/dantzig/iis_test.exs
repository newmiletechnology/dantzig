defmodule Dantzig.IISTest do
  use ExUnit.Case, async: true

  alias Dantzig.IIS

  describe "parse/1" do
    test "extracts constraints from LP format" do
      lp = """
      \\ File written by HiGHS .lp file handler
      min
       obj: 1 x0 + 1 x1
      st
       c0: 1 x0 + 1 x1 >= 20
       c1: 1 x0 <= 5
       c2: 1 x1 <= 10
      bounds
       0 <= x0 <= 5
       0 <= x1 <= 10
      end
      """

      iis = IIS.parse(lp)

      assert "c0" in iis.constraints
      assert "c1" in iis.constraints
      assert "c2" in iis.constraints
      assert "obj" in iis.constraints
    end

    test "extracts variables from bounds section" do
      lp = """
      \\ File written by HiGHS .lp file handler
      min
       obj: 1 x0 + 1 x1
      st
       c0: 1 x0 + 1 x1 >= 20
      bounds
       0 <= x0 <= 5
       0 <= x1 <= 10
      end
      """

      iis = IIS.parse(lp)

      assert "x0" in iis.variables
      assert "x1" in iis.variables
    end

    test "deduplicates variables that appear in multiple bound lines" do
      lp = """
      \\ comment
      min
       obj:
      st
      bounds
       0 <= x0
       x0 <= 10
      end
      """

      iis = IIS.parse(lp)

      assert iis.variables == ["x0"]
    end

    test "ignores LP comments starting with backslash" do
      lp = """
      \\ This is: a comment
      \\ Another: comment line
      min
       obj: 1 x0
      st
       c0: 1 x0 >= 10
      bounds
      end
      """

      iis = IIS.parse(lp)

      refute Enum.any?(iis.constraints, &String.contains?(&1, "comment"))
    end

    test "preserves raw_content" do
      lp = "min\n obj:\nst\nbounds\nend\n"

      iis = IIS.parse(lp)

      assert iis.raw_content == lp
    end

    test "handles minimal/empty IIS file" do
      lp = """
      \\ File written by HiGHS .lp file handler
      min
       obj:
      st
      bounds
      end
      """

      iis = IIS.parse(lp)

      assert "obj" in iis.constraints
      assert iis.variables == []
    end

    test "handles constraint names with underscores and numbers" do
      lp = """
      \\ IIS
      min
       obj:
      st
       supply_constraint_42: 1 x_warehouse_1 + 1 x_warehouse_2 >= 100
       demand_limit_7: 1 x_warehouse_1 <= 30
      bounds
       0 <= x_warehouse_1 <= 30
       0 <= x_warehouse_2 <= 50
      end
      """

      iis = IIS.parse(lp)

      assert "supply_constraint_42" in iis.constraints
      assert "demand_limit_7" in iis.constraints
      assert "x_warehouse_1" in iis.variables
      assert "x_warehouse_2" in iis.variables
    end
  end

  describe "from_file/1" do
    test "returns nil for nil path" do
      assert IIS.from_file(nil) == nil
    end

    test "returns nil for nonexistent file" do
      assert IIS.from_file("/tmp/nonexistent_iis_#{System.unique_integer()}.lp") == nil
    end

    test "returns nil for empty file" do
      path = Path.join(System.tmp_dir!(), "empty_iis_#{System.unique_integer()}.lp")
      File.write!(path, "")

      assert IIS.from_file(path) == nil
    after
      # cleanup handled by test isolation
    end

    test "parses a valid IIS file from disk" do
      path = Path.join(System.tmp_dir!(), "test_iis_#{System.unique_integer()}.lp")

      File.write!(path, """
      \\ IIS model
      min
       obj: 1 x0
      st
       c0: 1 x0 >= 10
      bounds
       0 <= x0 <= 5
      end
      """)

      iis = IIS.from_file(path)

      assert %IIS{} = iis
      assert "c0" in iis.constraints
      assert "x0" in iis.variables
    after
      # cleanup
    end
  end

  describe "end-to-end IIS extraction" do
    require Dantzig.Problem, as: Problem
    require Dantzig.Constraint, as: Constraint
    require Dantzig.Polynomial, as: Polynomial

    test "infeasible problem without compute_iis returns nil iis" do
      Polynomial.algebra do
        problem = Problem.new(direction: :minimize)
        {problem, x} = Problem.new_variable(problem, "x")

        problem =
          problem
          |> Problem.add_constraint(Constraint.new(x >= 10))
          |> Problem.add_constraint(Constraint.new(x <= 5))
          |> Problem.increment_objective(x)
      end

      assert {:infeasible, %{iis: nil}} = Dantzig.solve(problem)
    end

    test "infeasible problem with compute_iis returns IIS with conflicting constraints" do
      Polynomial.algebra do
        problem = Problem.new(direction: :minimize)
        {problem, x} = Problem.new_variable(problem, "x")

        problem =
          problem
          |> Problem.add_constraint(Constraint.new(x >= 10))
          |> Problem.add_constraint(Constraint.new(x <= 5))
          |> Problem.increment_objective(x)
      end

      assert {:infeasible, %{iis: iis}} = Dantzig.solve(problem, compute_iis: true)
      assert %IIS{} = iis
      # IIS should identify both conflicting constraints
      assert length(iis.constraints) >= 2
      # IIS should identify the variable involved in the conflict
      assert length(iis.variables) >= 1
      assert is_binary(iis.raw_content)
      assert byte_size(iis.raw_content) > 0
    end

    test "IIS identifies all conflicting constraints in multi-variable problem" do
      Polynomial.algebra do
        problem = Problem.new(direction: :minimize)
        {problem, x} = Problem.new_variable(problem, "x")
        {problem, y} = Problem.new_variable(problem, "y")

        problem =
          problem
          |> Problem.add_constraint(Constraint.new(x + y >= 20))
          |> Problem.add_constraint(Constraint.new(x <= 5))
          |> Problem.add_constraint(Constraint.new(y <= 10))
          |> Problem.increment_objective(x + y)
      end

      assert {:infeasible, %{iis: iis}} = Dantzig.solve(problem, compute_iis: true)
      assert %IIS{} = iis
      # All three constraints form the IIS (x+y>=20, x<=5, y<=10) and objective constraint
      assert length(iis.constraints) == 4
      # Both variables should appear in bounds
      assert length(iis.variables) == 2
      assert is_binary(iis.raw_content)
      assert byte_size(iis.raw_content) > 0
    end
  end
end
