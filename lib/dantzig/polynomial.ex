defmodule Dantzig.Polynomial do
  @moduledoc """
  Polynomials for linear and quadratic programming.

  This module provides polynomial construction and manipulation for use with
  LP/QP solvers. Polynomials can represent objective functions, constraint
  left-hand sides, and intermediate expressions.

  ## Building Polynomials

  There are several ways to construct polynomials:

  ### Direct Construction

      x = Polynomial.variable(:x)
      y = Polynomial.variable(:y)
      c = Polynomial.const(5)

  ### Using `algebra/1` for Inline Expressions

  The `algebra/1` macro transforms arithmetic operators to polynomial operations:

      # Inline syntax (recommended for simple expressions)
      objective = Polynomial.algebra(2 * x + 3 * y - 5)

  ### Using `collect/1` for Efficient Comprehensions

  For building polynomials from many terms (e.g., in optimization problems with
  thousands of variables), use `collect/1` which runs in O(n) time:

      # Efficient for large-scale problems
      objective = Polynomial.collect do
        for i <- 1..10_000, var = vars[i], var != nil do
          coefficients[i] * var
        end
      end

  ## Performance Considerations

  When building polynomials from many terms:

  - **O(n²) approach** (avoid for large n): Using `Enum.reduce` with `add/2`
    causes repeated map merges, leading to quadratic time complexity.

  - **O(n) approach** (recommended): Use `collect/1` or `sum_linear/1` which
    flattens all terms and combines them in a single pass.

  For problems with 1,000+ terms, the difference is significant. For 42,000 terms,
  the O(n) approach completes in under 1 second vs. several minutes for O(n²).

  ## Examples

      # Simple objective function
      require Dantzig.Polynomial, as: Polynomial

      x = Polynomial.variable(:x)
      y = Polynomial.variable(:y)

      # Using algebra for simple expressions
      objective = Polynomial.algebra(3 * x + 2 * y + 10)

      # Using collect for comprehensions (efficient for many terms)
      switching_penalty = Polynomial.collect do
        for {id, var} <- decision_vars do
          -penalty * var
        end
      end

  """

  defstruct simplified: %{}

  @type t :: %__MODULE__{simplified: %{optional([term()]) => number()}}

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(p, _opts) do
      concat([
        "#Polynomial<",
        Dantzig.Polynomial.to_iodata(p) |> to_string(),
        ">"
      ])
    end
  end

  @doc """
  Transforms arithmetic operators to polynomial operations.

  This macro rewrites `+`, `-`, `*`, and `/` operators within the given
  expression to their polynomial equivalents (`add/2`, `subtract/2`,
  `multiply/2`, `divide/2`).

  ## Syntax

  Use inline syntax for simple expressions:

      Polynomial.algebra(2 * x + 3 * y - 5)

  When using `do/end` block syntax, the macro returns a keyword list
  `[do: result]` which must be pattern-matched:

      [do: objective] = Polynomial.algebra do
        Enum.reduce(vars, Polynomial.const(0), fn var, acc ->
          acc + coeff * var
        end)
      end

  ## Examples

      require Dantzig.Polynomial, as: Polynomial

      x = Polynomial.variable(:x)
      y = Polynomial.variable(:y)

      # Inline syntax (returns the polynomial directly)
      p = Polynomial.algebra(2 * x + 3 * y)

      # With negation
      p = Polynomial.algebra(-5 * x)

      # Division by constant
      p = Polynomial.algebra(x / 2)

  ## Notes

  - For building polynomials from comprehensions, prefer `collect/1` which
    provides both operator transformation and efficient O(n) summation.
  - The `/` operator only supports division by constants (numbers or constant
    polynomials). Division by variable polynomials is not supported.
  """
  defmacro algebra(ast) do
    replace_operators(ast)
  end

  @doc """
  Efficiently collects polynomial terms from a comprehension.

  This macro transforms arithmetic operators (+, -, *, /) within the block
  to their polynomial equivalents (like `algebra/1`), then wraps the result
  in `sum_linear/1` for O(n) performance.

  ## Examples

      # Collect terms from a comprehension
      Polynomial.collect do
        for i <- 1..1000, var = vars[i], var != nil do
          coefficient * var
        end
      end

      # Equivalent to but faster than:
      Polynomial.sum(for i <- 1..1000, var = vars[i], var != nil do
        Polynomial.algebra(coefficient * var)
      end)

  ## Notes

  - The block should return an enumerable of polynomials
  - Operator transformation applies to the entire block, including the body
  - Use this for building objectives or constraint LHS from many terms
  """
  defmacro collect(ast) do
    # ast is [do: block] when called with do/end syntax
    transformed = replace_operators(ast)
    # Extract the transformed block from the keyword list
    block = Keyword.fetch!(transformed, :do)

    quote do
      Dantzig.Polynomial.sum_linear(unquote(block))
    end
  end

  @doc """
  Replace operators by their polynomial versions inside a code block.
  """
  def replace_operators(ast) do
    Macro.prewalk(ast, fn
      {:+, _meta, [x, y]} ->
        quote do
          Dantzig.Polynomial.add(unquote(x), unquote(y))
        end

      {:-, _meta, [x, y]} ->
        quote do
          Dantzig.Polynomial.subtract(unquote(x), unquote(y))
        end

      {:*, _meta, [x, y]} ->
        quote do
          Dantzig.Polynomial.multiply(unquote(x), unquote(y))
        end

      {:/, _meta, [x, y]} ->
        quote do
          Dantzig.Polynomial.divide(unquote(x), unquote(y))
        end

      {:-, _meta, [x]} ->
        quote do
          Dantzig.Polynomial.subtract(0, unquote(x))
        end

      other ->
        other
    end)
  end

  def monomial(coefficient, variable) do
    %__MODULE__{simplified: %{[variable] => coefficient}}
  end

  def coefficients(%__MODULE__{} = p) do
    Map.values(p.simplified)
  end

  def coefficient_for(%__MODULE__{} = p, term) do
    Map.get(p.simplified, term)
  end

  def to_number!(number) when is_number(number) do
    number
  end

  def to_number!(%__MODULE__{} = p) do
    if constant?(p) do
      {_, const} = split_constant(p)
      const
    else
      raise "Can't convert polynomial to number (the polynomial contains free variables)"
    end
  end

  def to_number_if_possible(number) when is_number(number) do
    number
  end

  def to_number_if_possible(%__MODULE__{} = p) do
    if constant?(p) do
      {_, const} = split_constant(p)
      const
    else
      p
    end
  end

  @doc false
  def to_lp_iodata_objective(p) do
    # Raise an error if the polynomial is cubic or higher
    unless degree(p) in [0, 1, 2] do
      raise RuntimeError, """
      Polynomials of degree > 2 are not supported by the LP solver.
          Please try to convert your constraints and objective function \
      into polynomials of degree 0, 1 or 2.
      """
    end

    # The degree of all terms will be at maximum two from now on
    by_degree = Enum.group_by(p.simplified, fn {vars, _coeff} -> length(vars) end)
    true = Enum.all?(Map.keys(by_degree), fn degree -> degree < 3 end)

    terms_of_degree_0 = Map.get(by_degree, 0, [])
    terms_of_degree_1 = Map.get(by_degree, 1, [])
    terms_of_degree_2 = Map.get(by_degree, 2, [])

    doubled_terms_of_degree_2 =
      for {vars, coeff} <- terms_of_degree_2 do
        {vars, 2 * coeff}
      end

    linear_terms = terms_of_degree_0 ++ terms_of_degree_1
    linear_terms_iodata = terms_to_iodata(linear_terms)

    terms_of_degree_2_iodata =
      case terms_of_degree_2 do
        [] ->
          ""

        _other ->
          [
            " + [ ",
            terms_to_iodata(doubled_terms_of_degree_2),
            " ] / 2"
          ]
      end

    [linear_terms_iodata, terms_of_degree_2_iodata]
  end

  def to_lp_constraint(p) do
    # Raise an error if the polynomial is cubic or higher
    unless degree(p) in [0, 1, 2] do
      raise RuntimeError, """
      Polynomials of degree > 2 are not supported by the LP solver.
          Please try to convert your constraints and objective function \
      into polynomials of degree 0, 1 or 2.
      """
    end

    # The degree of all terms will be at maximum two from now on
    by_degree = Enum.group_by(p.simplified, fn {vars, _coeff} -> length(vars) end)
    true = Enum.all?(Map.keys(by_degree), fn degree -> degree < 3 end)

    terms_of_degree_0 = Map.get(by_degree, 0, [])
    terms_of_degree_1 = Map.get(by_degree, 1, [])
    terms_of_degree_2 = Map.get(by_degree, 2, [])

    linear_terms = terms_of_degree_0 ++ terms_of_degree_1
    linear_terms_iodata = terms_to_iodata(linear_terms)

    terms_of_degree_2_iodata =
      case terms_of_degree_2 do
        [] ->
          ""

        _other ->
          [
            " + [ ",
            terms_to_iodata(terms_of_degree_2),
            " ] / 2"
          ]
      end

    [linear_terms_iodata, terms_of_degree_2_iodata]
  end

  def to_iodata(p) do
    terms_to_iodata(p.simplified)
  end

  defp terms_to_iodata([]), do: "0"

  defp terms_to_iodata(map) when map == %{}, do: "0"

  defp terms_to_iodata(terms) do
    # Ensure deterministic order if terms are in a dictionary
    terms = Enum.sort(terms)

    signed_terms =
      for {vars, coeff} <- terms do
        case coeff > 0 do
          true ->
            {"+ ", to_string(coeff), vars_to_iodata(vars)}

          false ->
            {"- ", to_string(abs(coeff)), vars_to_iodata(vars)}
        end
      end

    case signed_terms do
      [{"+ ", coeff1, vars1}] ->
        [coeff1, " ", vars1]

      [{"- ", coeff1, vars1}] ->
        ["- ", coeff1, " ", vars1]

      [{"+ ", coeff1, vars1} | rest] ->
        [coeff1, " ", vars1, " " | rest_of_coeffs_to_iodata(rest)]

      [{"- ", coeff1, vars1} | rest] ->
        ["- ", coeff1, " ", vars1, " " | rest_of_coeffs_to_iodata(rest)]
    end
  end

  defp vars_to_iodata([]), do: ""

  defp vars_to_iodata(vars) do
    counts =
      vars
      |> Enum.frequencies()
      |> Enum.sort()

    grouped_vars =
      Enum.map(counts, fn {var, count} ->
        case count == 1 do
          true ->
            var

          false ->
            "#{var}^#{count}"
        end
      end)

    grouped_vars
    |> Enum.map(&to_string/1)
    |> Enum.intersperse(" * ")
  end

  def serialize(p) do
    p
    |> to_iodata()
    |> IO.iodata_to_binary()
  end

  defp rest_of_coeffs_to_iodata(rest) do
    parts =
      Enum.map(rest, fn {sign, coeff, vars} ->
        [sign, coeff, " ", vars]
      end)

    Enum.intersperse(parts, " ")
  end

  @doc """
  Returns true if the polynomial has no variables (degree 0).
  """
  @spec constant?(t()) :: boolean()
  def constant?(p) do
    degree(p) == 0
  end

  @doc """
  Splits a polynomial into its constant term and remaining terms.

  Returns `{non_constant_polynomial, constant_value}`.
  """
  @spec split_constant(t()) :: {t(), number()}
  def split_constant(p) do
    case Map.fetch(p.simplified, []) do
      {:ok, value} ->
        {subtract(p, const(value)), value}

      :error ->
        {p, 0}
    end
  end

  @doc """
  Returns true if two polynomials are structurally equal.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(p1, p2) do
    p1.simplified == p2.simplified
  end

  def has_constant_term?(p) do
    case Map.fetch(p, []) do
      {:ok, _coeff} -> true
      :error -> false
    end
  end

  def depends_on?(number, _variable) when is_number(number) do
    nil
  end

  def depends_on?(%__MODULE__{} = p, variable) do
    result =
      Enum.find(p.simplified, fn {vars, _coeff} ->
        Enum.find(vars, fn var -> var == variable end)
      end)

    if result == nil do
      false
    else
      true
    end
  end

  def number_of_terms(p) do
    map_size(p.simplified)
  end

  def separate_constant(p) do
    case p.simplified do
      # The polynomial contains a constant term
      %{[] => constant_value} ->
        # Subtract the constant so that the subtraction of the constant
        # is added to the operastions
        new_p = subtract(p, constant_value)
        new_simplified = Map.delete(p.simplified, [])

        # Return the pair
        {constant_value, %{new_p | simplified: new_simplified}}

      # The polynomial doesn't contain a constant term
      _ ->
        {0, p}
    end
  end

  @doc """
  Creates a constant polynomial from a numeric value.

  ## Examples

      iex> Polynomial.const(5)
      #Polynomial<5 >

  """
  @spec const(number()) :: t()
  def const(value) when is_number(value) do
    %__MODULE__{simplified: %{[] => value}}
  end

  @doc """
  Creates a polynomial representing a single variable with coefficient 1.

  The variable name can be any term except a number.

  ## Examples

      iex> Polynomial.variable(:x)
      #Polynomial<1 x>

      iex> Polynomial.variable("my_var")
      #Polynomial<1 my_var>

  """
  @spec variable(term()) :: t()
  def variable(name) when not is_number(name) do
    # NOTE: the variable name can't be a number, otherwise it would be too confusing!
    %__MODULE__{simplified: %{[name] => 1}}
  end

  def term(variables, coefficient) do
    Enum.reduce(variables, const(coefficient), fn name, p ->
      multiply(p, variable(name))
    end)
  end

  def find_variables_by(%__MODULE__{} = p, fun) do
    p.simplified
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(fun)
  end

  def find_variables_by(_number, _fun), do: nil

  def get_variables_by(%__MODULE__{} = p, fun) do
    p.simplified
    |> Map.keys()
    |> List.flatten()
    |> Enum.filter(fun)
  end

  def get_variables_by(_number, _fun), do: []

  def substitute(%__MODULE__{} = p, substitutions) when is_map(substitutions) do
    products =
      for {vars, coeff} <- p.simplified do
        substituted_vars = Enum.map(vars, fn v -> Map.get(substitutions, v, v) end)

        substituted_vars_as_polynomials =
          Enum.map(substituted_vars, fn var ->
            case var do
              # The variable is already a polynomial; we can multiply it directly
              %__MODULE__{} ->
                var

              # The variable is something other than a polynomial
              # We must convert it into a polynomial, multiply it and simplify it later
              other ->
                if is_number(other) do
                  const(other)
                else
                  variable(other)
                end
            end
          end)

        multiply(product(substituted_vars_as_polynomials), coeff)
      end

    simplified = sum(products).simplified

    %__MODULE__{simplified: simplified}
  end

  def substitute(constant, _substitutions) do
    %__MODULE__{simplified: %{[] => constant}}
  end

  def replace(%__MODULE__{} = p, fun) do
    products =
      for {vars, coeff} <- p.simplified do
        substituted_vars = Enum.map(vars, fn v -> fun.(v) end)

        substituted_vars_as_polynomials =
          Enum.map(substituted_vars, fn var ->
            case var do
              # The variable is already a polynomial; we can multiply it directly
              %__MODULE__{} ->
                var

              # The variable is something other than a polynomial
              # We must convert it into a polynomial, multiply it and simplify it later
              other ->
                if is_number(other) do
                  const(other)
                else
                  variable(other)
                end
            end
          end)

        multiply(product(substituted_vars_as_polynomials), coeff)
      end

    sum(products)
  end

  def evaluate(p, substitutions) when is_map(substitutions) do
    case substitute(p, substitutions) do
      %__MODULE__{simplified: %{[] => constant} = simplified} when map_size(simplified) == 1 ->
        {:ok, constant}

      result ->
        free_variables = variables(result)
        {:error, {:free_variables, free_variables}}
    end
  end

  def evaluate!(p, substitutions) when is_map(substitutions) do
    {:ok, constant} = evaluate(p, substitutions)
    constant
  end

  @doc """
  Returns the degree of the polynomial (highest power of any term).

  A constant polynomial has degree 0.
  """
  @spec degree(t()) :: non_neg_integer()
  def degree(%{simplified: simplified} = _p) when simplified == %{} do
    0
  end

  def degree(p) do
    # Count all variables
    p.simplified
    |> Enum.map(fn {vars, _coeff} -> Enum.count(vars) end)
    |> Enum.max()
  end

  def degree_on(p, var) do
    # Count only the times the variable is multiplied
    p.simplified
    |> Enum.map(fn {vars, _coeff} -> Enum.count(vars, fn v -> v == var end) end)
    |> Enum.max()
  end

  # A number is turned into a constant
  def to_polynomial(p) when is_number(p), do: const(p)
  # A polynomial is returned unchanged
  def to_polynomial(p) when is_struct(p, __MODULE__), do: p
  # Everything else is returned as a variable
  def to_polynomial(p), do: %__MODULE__{simplified: %{[p] => 1}}

  def variables(p) do
    p.simplified
    |> Enum.flat_map(fn {vars, _coeff} -> vars end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def power(_p, 0), do: const(1)
  def power(p, exponent) when exponent > 0, do: multiply(p, power(p, exponent - 1))

  @doc """
  Adds two polynomials (or numbers) together.

  Arguments can be polynomials or numbers; numbers are converted to constants.
  """
  @spec add(t() | number(), t() | number()) :: t()
  def add(p1, p2) do
    p1 = to_polynomial(p1)
    p2 = to_polynomial(p2)

    terms =
      Map.merge(p1.simplified, p2.simplified, fn _var, coeff1, coeff2 ->
        coeff1 + coeff2
      end)

    simplified = cancel_terms(terms)

    %__MODULE__{simplified: simplified}
  end

  @doc """
  DEPRECATED: Prefer `sum_linear/1` instead.
  Sums a list of polynomials.

  This is implemented using `sum_linear/1` which runs in O(n) time.
  """
  @spec sum([t()]) :: t()
  def sum(polynomials), do: sum_linear(polynomials)

  @doc """
  Efficiently sums a list of polynomials in O(n) time.

  This function collects all terms from all polynomials and groups them
  by variable combination, summing coefficients for like terms. Unlike
  iterative addition which has O(n²) map merge cost, this approach processes
  all terms in a single pass.

  ## Examples

      iex> x = Polynomial.variable(:x)
      iex> y = Polynomial.variable(:y)
      iex> Polynomial.sum_linear([x, y, x])
      #Polynomial<2 x + 1 y>

  """
  @spec sum_linear([t()]) :: t()
  def sum_linear([]), do: const(0)
  def sum_linear([single]), do: single

  def sum_linear(polynomials) when is_list(polynomials) do
    simplified =
      polynomials
      |> Enum.flat_map(fn
        %__MODULE__{simplified: s} -> Map.to_list(s)
        n when is_number(n) -> [{[], n}]
      end)
      |> Enum.group_by(fn {vars, _coeff} -> vars end, fn {_vars, coeff} -> coeff end)
      |> Enum.map(fn {vars, coeffs} -> {vars, Enum.sum(coeffs)} end)
      |> cancel_terms()

    %__MODULE__{simplified: simplified}
  end

  @doc """
  Subtracts the second polynomial from the first.

  Arguments can be polynomials or numbers; numbers are converted to constants.
  """
  @spec subtract(t() | number(), t() | number()) :: t()
  def subtract(p1, p2) do
    p1 = to_polynomial(p1)
    p2 = multiply(to_polynomial(p2), -1)

    terms =
      Map.merge(p1.simplified, p2.simplified, fn _var, coeff1, coeff2 ->
        coeff1 + coeff2
      end)

    simplified = cancel_terms(terms)

    %__MODULE__{simplified: simplified}
  end

  def scale(%__MODULE__{} = _p, m) when m in [0, 0.0] do
    const(m)
  end

  def scale(%__MODULE__{} = p, m) when is_number(m) do
    terms =
      for {vars, coeff} <- p.simplified, into: %{} do
        {vars, m * coeff}
      end

    simplified_terms = merge_and_simplify_terms(terms)

    %{p | simplified: simplified_terms}
  end

  @doc """
  Divides a polynomial by a constant.

  Only division by constants (numbers or constant polynomials) is supported.
  Raises `ArgumentError` if the divisor contains variables.
  """
  @spec divide(t() | number(), t() | number()) :: t()
  def divide(p, c) do
    c_as_number = to_number_if_possible(c)

    case c_as_number do
      constant when is_number(constant) ->
        multiply(p, 1 / c)

      %__MODULE__{} ->
        raise ArgumentError,
              "Polynomial #{c} is not a constant and can't be used for division"
    end
  end

  @doc """
  Multiplies two polynomials (or numbers) together.

  Arguments can be polynomials or numbers; numbers are converted to constants.
  """
  @spec multiply(t() | number(), t() | number()) :: t()
  def multiply(p1, p2) do
    p1 = to_polynomial(p1)
    p2 = to_polynomial(p2)

    terms =
      for {vars1, coeff1} <- p1.simplified, {vars2, coeff2} <- p2.simplified do
        vars = Enum.sort(vars1 ++ vars2)
        coeff = coeff1 * coeff2

        {vars, coeff}
      end

    simplified = merge_and_simplify_terms(terms)

    %__MODULE__{simplified: simplified}
  end

  def product(polynomials) do
    Enum.reduce(polynomials, const(1), fn p, current_total ->
      multiply(current_total, p)
    end)
  end

  defp cancel_terms(terms) do
    terms
    |> Enum.reject(fn {_vars, coeff} -> coeff == 0 or coeff == 0.0 end)
    |> Enum.into(%{})
  end

  def merge_and_simplify_terms_in_polynomial(p) do
    %{p | simplified: merge_and_simplify_terms(p.simplified)}
  end

  defp merge_and_simplify_terms(terms) do
    terms
    |> Enum.group_by(fn {vars, _coeff} -> vars end, fn {_vars, coeff} -> coeff end)
    |> Enum.map(fn {vars, coeffs} -> {vars, Enum.sum(coeffs)} end)
    |> cancel_terms()
  end
end
