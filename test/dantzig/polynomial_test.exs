defmodule Dantzig.PolynomialTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  require Dantzig.Polynomial, as: Polynomial
  alias Dantzig.Test.PolynomialGenerators, as: Gen

  property "commutative property of addition" do
    check all([p1, p2] <- Gen.polynomials(nr_of_polynomials: 2)) do
      Polynomial.algebra do
        assert Polynomial.equal?(p1 + p2, p2 + p1)
      end
    end
  end

  property "associative property of addition" do
    check all([p1, p2, p3] <- Gen.polynomials(nr_of_polynomials: 3)) do
      Polynomial.algebra do
        assert Polynomial.equal?(p1 + (p2 + p3), p2 + p1 + p3)
      end
    end
  end

  property "zero is identity for addition" do
    check all(p <- Gen.polynomial()) do
      Polynomial.algebra do
        # Add an explicit constant
        assert Polynomial.equal?(p, p + Polynomial.const(0))
        assert Polynomial.equal?(p, p + Polynomial.const(0.0))
        # Add a raw numeric value
        assert Polynomial.equal?(p, p + 0)
        assert Polynomial.equal?(p, p + 0.0)
      end
    end
  end

  property "commutative property of multiplication" do
    # Limit the polynomial degree to make tests faster
    check all([p1, p2] <- Gen.polynomials(nr_of_polynomials: 2, max_degree: 3)) do
      Polynomial.algebra do
        assert Polynomial.equal?(p1 * p2, p2 * p1)
      end
    end
  end

  property "associative property of multiplication" do
    # Limit the polynomial degree to make tests faster
    check all([p1, p2, p3] <- Gen.polynomials(nr_of_polynomials: 3, max_degree: 3)) do
      Polynomial.algebra do
        assert Polynomial.equal?(p1 * (p2 * p3), p1 * p2 * p3)
      end
    end
  end

  property "one is the identity element of multiplication" do
    check all(p <- Gen.polynomial()) do
      Polynomial.algebra do
        # Multiply by an explicit constant
        assert Polynomial.equal?(p, p * Polynomial.const(1))
        # Multiply by a raw integer
        assert Polynomial.equal?(p, p * 1)
        # NOTE: we don't use floats because it can change
        # the type of the polynomial coefficients
      end
    end
  end

  property "distributive property" do
    # Limit the polynomial degree to make tests faster
    check all([p1, p2, q] <- Gen.polynomials(nr_of_polynomials: 3, max_degree: 3)) do
      Polynomial.algebra do
        assert Polynomial.equal?(q * (p1 + p2), q * p1 + q * p2)
      end
    end
  end

  describe "sum_linear/1" do
    test "empty list returns zero constant" do
      result = Polynomial.sum_linear([])
      assert Polynomial.equal?(result, Polynomial.const(0))
    end

    test "single element returns that element unchanged" do
      x = Polynomial.variable(:x)
      result = Polynomial.sum_linear([x])
      assert Polynomial.equal?(result, x)
    end

    test "combines like terms correctly" do
      x = Polynomial.variable(:x)
      y = Polynomial.variable(:y)

      result = Polynomial.sum_linear([x, y, x, x])
      expected = Polynomial.algebra(3 * x + y)

      assert Polynomial.equal?(result, expected)
    end

    test "handles mixed coefficients" do
      x = Polynomial.variable(:x)

      p1 = Polynomial.algebra(2 * x)
      p2 = Polynomial.algebra(-1 * x)
      p3 = Polynomial.algebra(3 * x)

      result = Polynomial.sum_linear([p1, p2, p3])
      expected = Polynomial.algebra(4 * x)

      assert Polynomial.equal?(result, expected)
    end

    test "handles constants" do
      result =
        Polynomial.sum_linear([Polynomial.const(1), Polynomial.const(2), Polynomial.const(3)])

      assert Polynomial.equal?(result, Polynomial.const(6))
    end

    test "handles raw numbers in list" do
      x = Polynomial.variable(:x)
      result = Polynomial.sum_linear([x, 5, x])
      expected = Polynomial.algebra(2 * x + 5)
      assert Polynomial.equal?(result, expected)
    end

    test "cancels terms that sum to zero" do
      x = Polynomial.variable(:x)
      p1 = Polynomial.algebra(3 * x)
      p2 = Polynomial.algebra(-3 * x)

      result = Polynomial.sum_linear([p1, p2])
      # Result should be a zero polynomial (constant with value 0)
      assert Polynomial.constant?(result)
      assert Polynomial.to_number!(result) == 0
    end

    property "sum_linear produces same result as iterative sum" do
      check all(polynomials <- Gen.polynomials(nr_of_polynomials: 5, max_degree: 3)) do
        result_linear = Polynomial.sum_linear(polynomials)
        result_iterative = Enum.reduce(polynomials, Polynomial.const(0), &Polynomial.add/2)

        assert Polynomial.equal?(result_linear, result_iterative)
      end
    end
  end

  describe "collect/1 macro" do
    test "transforms operators and sums results" do
      x = Polynomial.variable(:x)
      y = Polynomial.variable(:y)
      vars = %{1 => x, 2 => y}

      result =
        Polynomial.collect do
          for i <- [1, 2], var = vars[i] do
            2 * var
          end
        end

      expected = Polynomial.algebra(2 * x + 2 * y)
      assert Polynomial.equal?(result, expected)
    end

    test "handles negation" do
      x = Polynomial.variable(:x)
      vars = %{1 => x, 2 => x}
      coefficient = 5

      result =
        Polynomial.collect do
          for i <- [1, 2], var = vars[i] do
            -coefficient * var
          end
        end

      expected = Polynomial.algebra(-10 * x)
      assert Polynomial.equal?(result, expected)
    end

    test "handles nil filtering in comprehension" do
      x = Polynomial.variable(:x)
      vars = %{1 => x, 2 => nil, 3 => x}

      result =
        Polynomial.collect do
          for i <- [1, 2, 3], var = vars[i], var != nil do
            var
          end
        end

      expected = Polynomial.algebra(2 * x)
      assert Polynomial.equal?(result, expected)
    end

    test "handles subtraction in body" do
      x = Polynomial.variable(:x)
      y = Polynomial.variable(:y)
      vars = %{1 => x, 2 => y}

      result =
        Polynomial.collect do
          for i <- [1, 2], var = vars[i] do
            var - 1
          end
        end

      expected = Polynomial.algebra(x + y - 2)
      assert Polynomial.equal?(result, expected)
    end

    test "handles division by constant" do
      x = Polynomial.variable(:x)
      vars = %{1 => x, 2 => x}

      result =
        Polynomial.collect do
          for i <- [1, 2], var = vars[i] do
            var / 2
          end
        end

      # 0.5x + 0.5x = 1x
      expected = Polynomial.algebra(x)
      assert Polynomial.equal?(result, expected)
    end

    test "empty comprehension returns zero" do
      result =
        Polynomial.collect do
          for _i <- [], do: Polynomial.variable(:x)
        end

      assert Polynomial.equal?(result, Polynomial.const(0))
    end
  end
end
