defmodule Dantzig.MipStart do
  @moduledoc """
  Serialize a partial primal solution into the HiGHS solution-file format for
  use as a MIP start (incumbent hint).

  HiGHS reads this via `--read_solution_file`. If the start is integer- and
  constraint-feasible, it is adopted as the incumbent at node 0. If it is
  mildly infeasible, HiGHS attempts a sub-MIP repair (bounded by
  `mip_max_start_nodes`); on failure the start is silently discarded and a
  normal search continues. Variables omitted from the start are filled in via
  HiGHS's heuristic completion.

  ## Input shape

      %{
        polynomial_or_name => integer_or_float,
        ...
      }

  Keys may be:
  - A `%Dantzig.Polynomial{}` for a single variable — type-checked via
    `Dantzig.Polynomial.variable_name!/1`. Any single-variable monomial is
    accepted regardless of coefficient.
  - A string with the mangled internal name (e.g. `"x00000000_x"`). Useful for
    advanced callers that already have the names in hand.

  Keys that don't correspond to a variable in the problem are dropped silently.
  Keys that are multi-variable polynomials raise `ArgumentError` via
  `variable_name!/1`.

  ## Recommended pairing

  When passing `mip_start`, also pass `mip_max_start_nodes:` (a small int like
  `50`) so an unusable start can't burn arbitrary solver time on the repair
  sub-MIP. See `Dantzig.solve/2`.
  """

  alias Dantzig.Polynomial
  alias Dantzig.Problem

  @type key :: Polynomial.t() | String.t()
  @type t :: %{key() => number()}

  @doc """
  Serializes a partial primal solution into iodata in HiGHS's solution-file
  format. The output round-trips through `Dantzig.Solution.Parser`.

  HiGHS requires the `# Columns N` section to list a value for every variable
  in the model — its `readSolutionFile` fails with "Solution file is for N
  columns, not M" when the count differs. We pad variables that aren't in
  `mip_start` with the variable's lower bound when it's strictly positive, and
  with `0` otherwise (including negative lower bounds and unbounded-below
  variables). This keeps the file model-complete; the user-provided entries
  seed the variables the caller actually cares about, and any padded value
  that's infeasible (e.g. a variable bounded `[-5, -1]`) is just discarded by
  HiGHS along with the rest of the start.
  """
  @spec to_iodata(Problem.t(), t()) :: iodata()
  def to_iodata(%Problem{} = problem, mip_start) when is_map(mip_start) do
    user_values =
      for {key, value} <- mip_start,
          name = resolve_name(key),
          Map.has_key?(problem.variables, name),
          into: %{} do
        {name, value}
      end

    column_lines =
      Enum.map(problem.variables, fn {name, variable} ->
        value = Map.get(user_values, name, default_value(variable))
        [to_string(name), " ", format_value(value), "\n"]
      end)

    # We deliberately omit the `# Rows <N>` section. HiGHS's reader treats it as
    # the dual-value section and warns when the count doesn't match the model's
    # row count. For a primal-only MIP start we don't have dual values to
    # provide, and HiGHS happily proceeds without the section.
    [
      "Model status\n",
      "Feasible\n",
      "\n",
      "# Primal solution values\n",
      "Feasible\n",
      "Objective 0\n",
      "# Columns ",
      Integer.to_string(map_size(problem.variables)),
      "\n",
      column_lines
    ]
  end

  defp resolve_name(name) when is_binary(name), do: name
  defp resolve_name(%Polynomial{} = poly), do: Polynomial.variable_name!(poly)

  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)

  defp default_value(%{min: min}) when is_number(min) and min > 0, do: min
  defp default_value(_variable), do: 0
end
