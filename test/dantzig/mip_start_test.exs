defmodule Dantzig.MipStartTest do
  use ExUnit.Case, async: true

  alias Dantzig.MipStart
  alias Dantzig.Solution

  require Dantzig.Problem, as: Problem
  require Dantzig.Polynomial, as: Polynomial

  setup do
    problem = Problem.new(direction: :maximize)
    {problem, x} = Problem.new_variable(problem, "x", type: :integer, min: 0, max: 10)
    {problem, y} = Problem.new_variable(problem, "y", type: :integer, min: 0, max: 10)
    {:ok, problem: problem, x: x, y: y}
  end

  describe "to_iodata/2" do
    test "round-trips through Dantzig.Solution.Parser", %{problem: problem, x: x, y: y} do
      iodata = MipStart.to_iodata(problem, %{x => 3, y => 1})
      text = IO.iodata_to_binary(iodata)

      assert {:ok, solution} = Solution.from_file_contents(text)
      assert solution.model_status == "Feasible"
      assert solution.feasibility == "Feasible"
      assert solution.variables[Polynomial.variable_name!(x)] == 3
      assert solution.variables[Polynomial.variable_name!(y)] == 1
    end

    test "accepts string keys (mangled internal names)", %{problem: problem, x: x, y: y} do
      x_name = Polynomial.variable_name!(x)
      y_name = Polynomial.variable_name!(y)

      iodata = MipStart.to_iodata(problem, %{x_name => 7, y_name => 2})
      text = IO.iodata_to_binary(iodata)

      assert {:ok, solution} = Solution.from_file_contents(text)
      assert solution.variables[x_name] == 7
      assert solution.variables[y_name] == 2
    end

    test "drops unknown variables silently", %{problem: problem, x: x} do
      x_name = Polynomial.variable_name!(x)

      iodata = MipStart.to_iodata(problem, %{x => 4, "x99999999_ghost" => 99})
      text = IO.iodata_to_binary(iodata)

      assert {:ok, solution} = Solution.from_file_contents(text)
      assert solution.variables[x_name] == 4
      refute Map.has_key?(solution.variables, "x99999999_ghost")
    end

    test "pads every problem variable with its lower bound when mip_start is empty",
         %{problem: problem, x: x, y: y} do
      iodata = MipStart.to_iodata(problem, %{})
      text = IO.iodata_to_binary(iodata)

      assert text =~ "# Columns 2"
      refute text =~ "# Rows"
      assert {:ok, solution} = Solution.from_file_contents(text)
      assert solution.variables[Polynomial.variable_name!(x)] == 0
      assert solution.variables[Polynomial.variable_name!(y)] == 0
    end

    test "raises for multi-variable polynomial key", %{problem: problem, x: x, y: y} do
      sum =
        Polynomial.algebra do
          x + y
        end
        |> Keyword.get(:do)

      assert_raise ArgumentError, fn ->
        MipStart.to_iodata(problem, %{sum => 5})
      end
    end

    test "supports both integer and float values", %{problem: problem, x: x, y: y} do
      x_name = Polynomial.variable_name!(x)
      y_name = Polynomial.variable_name!(y)

      iodata = MipStart.to_iodata(problem, %{x => 3, y => 1.5})
      text = IO.iodata_to_binary(iodata)

      assert {:ok, solution} = Solution.from_file_contents(text)
      assert solution.variables[x_name] == 3
      assert_in_delta solution.variables[y_name], 1.5, 1.0e-9
    end

    test "emits Columns count matching the total number of problem variables",
         %{problem: problem, x: x, y: y} do
      iodata = MipStart.to_iodata(problem, %{x => 3, y => 1, "ghost" => 0})
      text = IO.iodata_to_binary(iodata)

      assert text =~ "# Columns 2"
    end

    test "pads unspecified variables with their lower bound" do
      problem = Problem.new(direction: :maximize)
      {problem, x} = Problem.new_variable(problem, "x", type: :integer, min: 0, max: 10)
      {problem, y} = Problem.new_variable(problem, "y", type: :integer, min: 5, max: 20)

      iodata = MipStart.to_iodata(problem, %{x => 3})
      text = IO.iodata_to_binary(iodata)

      assert {:ok, solution} = Solution.from_file_contents(text)
      assert solution.variables[Polynomial.variable_name!(x)] == 3
      assert solution.variables[Polynomial.variable_name!(y)] == 5
    end
  end
end
