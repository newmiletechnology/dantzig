defmodule Dantzig.ProblemTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Dantzig.Problem
  alias Dantzig.Constraint
  require Dantzig.Polynomial, as: Polynomial

  test "creating a problem requires specifying the optimization direction" do
    assert_raise RuntimeError, fn ->
      Problem.new([])
    end
  end

  test "can create a linear maximization problem" do
    _problem = Problem.new(direction: :maximize)
  end

  test "can create a linear minimization problem" do
    _problem = Problem.new(direction: :minimize)
  end

  property "can create a variable with the given suffix" do
    check all(
            suffix <- StreamData.string([?a..?z, ?A..?Z, ?0..?9, ?_], min_length: 1),
            direction <- StreamData.one_of([:minimize, :maximize])
          ) do
      problem = Problem.new(direction: direction)
      {problem, variable} = Problem.new_variable(problem, suffix)

      assert Enum.any?(problem.variables, fn {variable_name, _variable} ->
               String.ends_with?(variable_name, suffix)
             end)

      assert Enum.any?(Polynomial.variables(variable), fn variable_name ->
               String.ends_with?(variable_name, suffix)
             end)

      assert %Problem{} = problem
    end
  end

  test "variables are monomials (i.e. have a single term) of degree 1 and with no constant term" do
    check all(
            suffix <- StreamData.string([?a..?z, ?A..?Z, ?0..?9, ?_], min_length: 1),
            direction <- StreamData.one_of([:minimize, :maximize])
          ) do
      problem = Problem.new(direction: direction)
      {_problem, variable} = Problem.new_variable(problem, suffix)

      assert Polynomial.degree(variable) == 1
      assert Polynomial.number_of_terms(variable) == 1
      assert Polynomial.has_constant_term?(variable) == false
    end
  end

  test "the right hand side of a constraint is a number (and not a polynomial)" do
    check all(
            terms1 <-
              StreamData.list_of(
                StreamData.tuple({
                  StreamData.float(),
                  StreamData.string([?a..?z, ?A..?Z, ?0..?9, ?_], min_length: 1)
                }),
                min_length: 1
              ),
            terms2 <-
              StreamData.list_of(
                StreamData.tuple({
                  StreamData.float(),
                  StreamData.string([?a..?z, ?A..?Z, ?0..?9, ?_], min_length: 1)
                }),
                min_length: 1
              ),
            const1 <- StreamData.float(),
            const2 <- StreamData.float(),
            direction <- StreamData.one_of([:minimize, :maximize]),
            operator <- StreamData.one_of([:==, :<=, :>=])
          ) do
      variable_suffixes_left = Enum.map(terms1, fn {_coeff, var} -> var end)
      variable_suffixes_right = Enum.map(terms2, fn {_coeff, var} -> var end)

      problem = Problem.new(direction: direction)
      # Add variables top the problem based on the suffixes we've generated
      {problem, variables_left} = Problem.new_variables(problem, variable_suffixes_left)
      {problem, variables_right} = Problem.new_variables(problem, variable_suffixes_right)

      p_left = Polynomial.sum(variables_left) |> Polynomial.add(const1)
      p_right = Polynomial.sum(variables_right) |> Polynomial.add(const2)

      problem = Problem.add_constraint(problem, Constraint.new(p_left, operator, p_right))

      [constraint] = Map.values(problem.constraints)

      assert map_size(problem.constraints) == 1
      assert is_number(constraint.right_hand_side)
      assert constraint.right_hand_side == const2 - const1
    end
  end

  describe "lookup_variable/2" do
    test "returns the ProblemVariable when given the polynomial monomial" do
      problem = Problem.new(direction: :maximize)
      {problem, x} = Problem.new_variable(problem, "myvar", type: :integer, min: 0, max: 7)

      variable = Problem.lookup_variable(problem, x)

      assert variable.type == :integer
      assert variable.min == 0
      assert variable.max == 7
      assert String.ends_with?(variable.name, "_myvar")
    end

    test "returns the ProblemVariable when given the mangled string name" do
      problem = Problem.new(direction: :maximize)
      {problem, x} = Problem.new_variable(problem, "myvar")
      name = Polynomial.variable_name!(x)

      variable = Problem.lookup_variable(problem, name)

      assert variable.name == name
    end

    test "returns nil for an unknown name" do
      problem = Problem.new(direction: :maximize)
      {problem, _x} = Problem.new_variable(problem, "x")

      assert Problem.lookup_variable(problem, "does_not_exist") == nil
    end

    test "returns nil for a constant polynomial" do
      problem = Problem.new(direction: :maximize)
      {problem, _x} = Problem.new_variable(problem, "x")

      assert Problem.lookup_variable(problem, Polynomial.const(5)) == nil
    end

    test "returns nil for a multi-variable polynomial" do
      Polynomial.algebra do
        problem = Problem.new(direction: :maximize)
        {problem, x} = Problem.new_variable(problem, "x")
        {problem, y} = Problem.new_variable(problem, "y")

        assert Problem.lookup_variable(problem, x + y) == nil
      end
    end

    test "looks up a variable whose polynomial has a non-1 coefficient" do
      # Lenient: variable_name! doesn't check the coefficient, so neither does this
      Polynomial.algebra do
        problem = Problem.new(direction: :maximize)
        {problem, x} = Problem.new_variable(problem, "x")

        variable = Problem.lookup_variable(problem, x * 3)
        refute variable == nil
        assert String.ends_with?(variable.name, "_x")
      end
    end
  end
end
