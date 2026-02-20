defmodule Dantzig.PerformanceTest do
  @moduledoc """
  Performance tests to verify O(n) behavior of sum_linear and collect.
  """
  use ExUnit.Case, async: true

  alias Dantzig.Problem

  require Dantzig.Polynomial, as: Polynomial

  describe "performance" do
    @describetag :performance

    test "sum_linear handles 42,000 terms in under 1 second" do
      problem = Problem.new(direction: :maximize)

      n = 42_000

      # Create variables
      {_problem, vars} =
        Enum.reduce(1..n, {problem, %{}}, fn i, {p, v} ->
          {new_p, var} = Problem.new_variable(p, "x#{i}")
          {new_p, Map.put(v, i, var)}
        end)

      # Generate coefficients
      coefficients = for i <- 1..n, into: %{}, do: {i, :math.sin(i) * 100}

      # Measure time for collect
      start_time = System.monotonic_time(:millisecond)

      _result =
        Polynomial.collect do
          for i <- 1..n do
            coefficients[i] * vars[i]
          end
        end

      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      # Should complete in under 1 second (was 5+ minutes with old sum/1)
      assert elapsed_ms < 1000,
             "Expected 42,000 terms to construct in < 1s, took #{elapsed_ms}ms"
    end

    test "sum_linear is significantly faster than iterative for large inputs" do
      problem = Problem.new(direction: :maximize)

      # Smaller for comparison test
      n = 1000

      {_problem, vars} =
        Enum.reduce(1..n, {problem, %{}}, fn i, {p, v} ->
          {new_p, var} = Problem.new_variable(p, "x#{i}")
          {new_p, Map.put(v, i, var)}
        end)

      coefficients = for i <- 1..n, into: %{}, do: {i, i * 1.0}

      # Prepare polynomial list
      polynomials =
        for i <- 1..n do
          Polynomial.algebra(coefficients[i] * vars[i])
        end

      # Measure sum_linear
      start_linear = System.monotonic_time(:microsecond)
      _result_linear = Polynomial.sum_linear(polynomials)
      time_linear = System.monotonic_time(:microsecond) - start_linear

      # Measure iterative (old behavior simulation)
      start_iterative = System.monotonic_time(:microsecond)
      _result_iterative = Enum.reduce(polynomials, Polynomial.const(0), &Polynomial.add/2)
      time_iterative = System.monotonic_time(:microsecond) - start_iterative

      # sum_linear should be at least 5x faster for 1000 terms
      speedup = time_iterative / max(time_linear, 1)

      assert speedup > 5,
             "Expected sum_linear to be >5x faster, got #{Float.round(speedup, 1)}x " <>
               "(linear: #{time_linear}us, iterative: #{time_iterative}us)"
    end
  end
end
