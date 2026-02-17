# Dantzig API Guide

Dantzig is an Elixir library for building and solving linear programming (LP) and
quadratic programming (QP) optimization problems using the HiGHS solver.

## Table of Contents

- [Quick Start](#quick-start)
- [Creating a Problem](#creating-a-problem)
- [Creating Variables](#creating-variables)
- [Building Polynomials](#building-polynomials)
  - [Direct Construction](#direct-construction)
  - [Using `algebra/1`](#using-algebra1)
  - [Using `collect/1` (Recommended for Large Problems)](#using-collect1-recommended-for-large-problems)
- [Setting the Objective](#setting-the-objective)
- [Adding Constraints](#adding-constraints)
- [Solving the Problem](#solving-the-problem)
- [Working with Solutions](#working-with-solutions)
- [Error Handling](#error-handling)
- [Performance Best Practices](#performance-best-practices)
- [Complete Examples](#complete-examples)

---

## Quick Start

```elixir
require Dantzig.Polynomial, as: Polynomial
alias Dantzig.{Problem, Constraint}

# Create a maximization problem
problem = Problem.new(direction: :maximize)

# Create decision variables
{problem, x} = Problem.new_variable(problem, "x", min: 0)
{problem, y} = Problem.new_variable(problem, "y", min: 0)

# Set the objective: maximize 3x + 2y
objective = Polynomial.algebra(3 * x + 2 * y)
problem = %{problem | objective: objective}

# Add constraints
problem = Problem.add_constraint(problem, Constraint.new(x + y <= 10))
problem = Problem.add_constraint(problem, Constraint.new(x <= 6))
problem = Problem.add_constraint(problem, Constraint.new(y <= 8))

# Solve
{:optimal, solution} = Dantzig.solve(problem)

# Access results
IO.puts("Optimal value: #{solution.objective}")
IO.puts("x = #{solution.variables["x00000000_x"]}")
IO.puts("y = #{solution.variables["x00000001_y"]}")
```

---

## Creating a Problem

Use `Problem.new/1` to create a new optimization problem:

```elixir
# Maximization problem
problem = Problem.new(direction: :maximize)

# Minimization problem
problem = Problem.new(direction: :minimize)
```

The `:direction` option is required and must be either `:maximize` or `:minimize`.

---

## Creating Variables

### Basic Variables

```elixir
# Create a single variable
{problem, x} = Problem.new_variable(problem, "x")
```

The variable `x` is a polynomial that can be used in expressions. The actual
variable name in the solver will be mangled (e.g., `x00000000_x`).

### Variable Options

```elixir
# Variable with bounds
{problem, x} = Problem.new_variable(problem, "x", min: 0, max: 100)

# Non-negative variable
{problem, y} = Problem.new_variable(problem, "y", min: 0)

# Integer variable (for MIP problems)
{problem, z} = Problem.new_variable(problem, "z", type: :integer, min: 0)

# Binary variable (0 or 1)
{problem, b} = Problem.new_variable(problem, "b", type: :integer, min: 0, max: 1)
```

### Creating Multiple Variables

For problems with many variables, create them in a loop:

```elixir
# Create variables for each item
items = [:a, :b, :c, :d]

{problem, vars} =
  Enum.reduce(items, {problem, %{}}, fn item, {p, v} ->
    {new_p, var} = Problem.new_variable(p, "x_#{item}", min: 0)
    {new_p, Map.put(v, item, var)}
  end)

# Access: vars[:a], vars[:b], etc.
```

### Multi-dimensional Variables

For assignment or transportation problems with multiple indices:

```elixir
workers = [:w1, :w2, :w3]
tasks = [:t1, :t2, :t3, :t4]

{problem, assign_vars} =
  Enum.reduce(workers, {problem, %{}}, fn worker, {p, vars} ->
    Enum.reduce(tasks, {p, vars}, fn task, {p2, vars2} ->
      {new_p, var} = Problem.new_variable(p2, "assign_#{worker}_#{task}", min: 0, max: 1)
      {new_p, Map.put(vars2, {worker, task}, var)}
    end)
  end)

# Access: assign_vars[{:w1, :t2}]
```

---

## Building Polynomials

Polynomials represent objective functions and constraint expressions. There are
three ways to build them.

### Direct Construction

For simple cases, use the basic constructors:

```elixir
require Dantzig.Polynomial, as: Polynomial

# Constant
c = Polynomial.const(5)

# Variable (standalone, not tied to a problem)
x = Polynomial.variable(:x)

# Operations
sum = Polynomial.add(x, c)           # x + 5
diff = Polynomial.subtract(x, c)     # x - 5
prod = Polynomial.multiply(x, 2)     # 2x
quot = Polynomial.divide(x, 2)       # x/2 = 0.5x
```

### Using `algebra/1`

The `algebra/1` macro transforms arithmetic operators to polynomial operations:

```elixir
require Dantzig.Polynomial, as: Polynomial

x = Polynomial.variable(:x)
y = Polynomial.variable(:y)

# Inline syntax (returns polynomial directly)
p = Polynomial.algebra(3 * x + 2 * y - 5)

# With negation
p = Polynomial.algebra(-10 * x)

# Division by constant
p = Polynomial.algebra(x / 2 + y / 3)
```

**Block syntax** requires pattern matching on the result:

```elixir
# When using do/end blocks, pattern match on [do: result]
[do: objective] = Polynomial.algebra do
  Enum.reduce(vars, Polynomial.const(0), fn {_key, var}, acc ->
    acc + coefficient * var
  end)
end
```

### Using `collect/1` (Recommended for Large Problems)

For problems with many terms (100+ variables), use `collect/1` which provides
**O(n) performance** instead of O(n²):

```elixir
require Dantzig.Polynomial, as: Polynomial

# Efficient collection from a comprehension
objective = Polynomial.collect do
  for item <- items, var = vars[item] do
    profit[item] * var
  end
end

# With filtering
penalty_sum = Polynomial.collect do
  for {id, var} <- decision_vars,
      var != nil,
      penalty = penalties[id],
      penalty > 0 do
    -penalty * var
  end
end

# Nested comprehensions
total_cost = Polynomial.collect do
  for source <- sources,
      dest <- destinations do
    cost[{source, dest}] * ship_vars[{source, dest}]
  end
end
```

**Why use `collect/1`?**

| Approach | Time Complexity | 1,000 terms | 42,000 terms |
|----------|-----------------|-------------|--------------|
| `Enum.reduce` + `add/2` | O(n²) | ~100ms | 5+ minutes |
| `collect/1` | O(n) | ~5ms | < 1 second |

---

## Setting the Objective

### Direct Assignment

```elixir
objective = Polynomial.algebra(3 * x + 2 * y)
problem = %{problem | objective: objective}
```

### Incremental Building

```elixir
# Add to objective
problem = Problem.maximize(problem, revenue_polynomial)
problem = Problem.minimize(problem, cost_polynomial)

# Or use increment/decrement
problem = Problem.increment_objective(problem, some_polynomial)
problem = Problem.decrement_objective(problem, some_polynomial)
```

### Multi-Component Objectives

```elixir
# Build components separately, then combine
revenue = Polynomial.collect do
  for p <- products, do: price[p] * quantity_vars[p]
end

cost = Polynomial.collect do
  for p <- products, do: unit_cost[p] * quantity_vars[p]
end

penalty = Polynomial.collect do
  for p <- products, do: -shortage_penalty * slack_vars[p]
end

# Combine with algebra
objective = Polynomial.algebra(revenue - cost + penalty)
problem = %{problem | objective: objective}
```

---

## Adding Constraints

### Using the Macro Syntax

The `Constraint.new/1` macro allows natural comparison syntax:

```elixir
require Dantzig.Constraint

# Less than or equal
problem = Problem.add_constraint(problem, Constraint.new(x + y <= 100))

# Greater than or equal
problem = Problem.add_constraint(problem, Constraint.new(x >= 10))

# Equality
problem = Problem.add_constraint(problem, Constraint.new(x + y == 50))

# With polynomial expressions
problem = Problem.add_constraint(problem, Constraint.new(2 * x + 3 * y <= 120))
```

### Using the Function Syntax

For programmatic constraint building:

```elixir
# Constraint.new(left_hand_side, operator, right_hand_side)
lhs = Polynomial.algebra(2 * x + 3 * y)
constraint = Constraint.new(lhs, :<=, 100)
problem = Problem.add_constraint(problem, constraint)
```

### Named Constraints

```elixir
constraint = Constraint.new(x + y <= 100, name: "capacity")
problem = Problem.add_constraint(problem, constraint)
```

### Adding Multiple Constraints

```elixir
# Capacity constraints for each factory
problem =
  Enum.reduce(factories, problem, fn factory, p ->
    lhs = Polynomial.collect do
      for product <- products do
        production_vars[{factory, product}]
      end
    end

    constraint = Constraint.new(lhs, :<=, capacity[factory])
    Problem.add_constraint(p, constraint)
  end)
```

---

## Solving the Problem

### Basic Solving

```elixir
case Dantzig.solve(problem) do
  {:optimal, solution} ->
    IO.puts("Optimal objective: #{solution.objective}")

  {:infeasible, info} ->
    IO.puts("Problem is infeasible")

  {:unbounded, info} ->
    IO.puts("Problem is unbounded")

  {:error, details} ->
    IO.puts("Solver error: #{details[:reason]}")
end
```

### Return Values

| Status | Return Value | Description |
|--------|-------------|-------------|
| `:optimal` | `{:optimal, %Solution{}}` | Proven optimal solution |
| `:time_limit` | `{:time_limit, %Solution{}}` | Time limit reached, best feasible solution returned |
| `:iteration_limit` | `{:iteration_limit, %Solution{}}` | Iteration limit reached, best feasible solution returned |
| `:infeasible` | `{:infeasible, %{iis: IIS.t() \| nil, output: String.t()}}` | Problem is infeasible |
| `:unbounded` | `{:unbounded, %{output: String.t()}}` | Problem is unbounded |
| `:error` | `{:error, %{reason: atom(), ...}}` | Solver error |

### Solver Options

```elixir
# With time limit (seconds)
{:optimal, solution} = Dantzig.solve(problem, time_limit: 60)

# With MIP gap tolerance
{:optimal, solution} = Dantzig.solve(problem, mip_rel_gap: 0.01)

# Maximum stall nodes for MIP
{:optimal, solution} = Dantzig.solve(problem, mip_max_stall_nodes: 100)

# Suppress solver output
{:optimal, solution} = Dantzig.solve(problem, log_to_console: false)

# Extract IIS on infeasibility (see Error Handling section)
result = Dantzig.solve(problem, compute_iis: true)
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:time_limit` | `number` | none | Maximum solve time in seconds |
| `:mip_rel_gap` | `float` | none | Relative MIP gap tolerance |
| `:mip_max_stall_nodes` | `integer` | none | Max nodes without improvement before stalling |
| `:log_to_console` | `boolean` | `false` | Enable solver logging to console |
| `:compute_iis` | `boolean` | `false` | Extract IIS when problem is infeasible |

### Using `solve!/2`

For a simpler API when you expect success, use `solve!/2`. It returns the solution directly and raises on failure:

```elixir
# Returns Solution directly - raises on infeasibility/unboundedness/error
solution = Dantzig.solve!(problem)
IO.puts("Objective: #{solution.objective}")

# Also works with options
solution = Dantzig.solve!(problem, time_limit: 60)
```

Exceptions raised by `solve!/2`:

| Exception | When |
|-----------|------|
| `Dantzig.InfeasibleError` | Problem is infeasible (includes IIS data if available) |
| `Dantzig.UnboundedError` | Problem is unbounded |
| `Dantzig.SolverError` | Solver error (includes reason and details) |

---

## Working with Solutions

### Accessing Variable Values

```elixir
{:optimal, solution} = Dantzig.solve(problem)

# Direct access (need to know mangled name)
x_value = solution.variables["x00000000_x"]

# Using evaluate with the polynomial
x_value = Dantzig.Solution.evaluate(solution, x)
```

### Evaluating Expressions

```elixir
# Evaluate any polynomial expression
profit = Dantzig.Solution.evaluate(solution, revenue - cost)

# Check constraint slack
slack = Dantzig.Solution.evaluate(solution, capacity - used_capacity)
```

### Solution Properties

```elixir
solution.objective      # Optimal objective value
solution.model_status   # "Optimal", "Time limit reached", etc.
solution.status         # :optimal, :time_limit, or :iteration_limit
solution.feasibility    # true/false
solution.variables      # Map of variable name => value
solution.constraints    # Map of constraint name => info
solution.mip_gap        # Relative MIP gap at termination (nil if not MIP or optimal)
```

### Handling Time/Iteration Limits

When a solve hits a time or iteration limit but has a feasible solution, the result
is returned with the corresponding status atom. The solution is still usable:

```elixir
case Dantzig.solve(problem, time_limit: 30) do
  {:optimal, solution} ->
    IO.puts("Proven optimal: #{solution.objective}")

  {:time_limit, solution} ->
    IO.puts("Best found: #{solution.objective} (gap: #{solution.mip_gap})")

  {:iteration_limit, solution} ->
    IO.puts("Best found: #{solution.objective} (gap: #{solution.mip_gap})")

  {:infeasible, _} ->
    IO.puts("Infeasible")
end
```

---

## Error Handling

### Infeasibility and IIS

When a problem is infeasible, you can extract the **Irreducible Infeasible Set (IIS)** —
the minimal set of constraints and variable bounds that together cause infeasibility.
This helps diagnose *why* a model is infeasible.

```elixir
case Dantzig.solve(problem, compute_iis: true) do
  {:infeasible, %{iis: iis}} when not is_nil(iis) ->
    IO.puts("Infeasible! Conflicting constraints:")
    for name <- iis.constraints, do: IO.puts("  - #{name}")

    IO.puts("Variables involved:")
    for var <- iis.variables, do: IO.puts("  - #{var}")

  {:infeasible, %{iis: nil}} ->
    IO.puts("Infeasible, but IIS could not be extracted")

  {:optimal, solution} ->
    IO.puts("Solved: #{solution.objective}")
end
```

The IIS struct (`Dantzig.IIS`) contains:

| Field | Type | Description |
|-------|------|-------------|
| `constraints` | `[String.t()]` | Names of conflicting constraints |
| `variables` | `[String.t()]` | Variables involved in conflicting bounds |
| `raw_content` | `String.t()` | Raw LP-format IIS model from HiGHS |

IIS computation is **opt-in** via `compute_iis: true` because it adds overhead.
When not requested, `iis` will be `nil` in the infeasible result.

### Using `solve!/2` with Exceptions

`solve!/2` raises typed exceptions for programmatic error handling:

```elixir
try do
  solution = Dantzig.solve!(problem, compute_iis: true)
  IO.puts("Objective: #{solution.objective}")
rescue
  e in Dantzig.InfeasibleError ->
    # e.iis contains the IIS struct (or nil)
    IO.puts("Infeasible: #{Exception.message(e)}")

  e in Dantzig.UnboundedError ->
    IO.puts("Unbounded: #{Exception.message(e)}")

  e in Dantzig.SolverError ->
    IO.puts("Solver error: #{e.reason}")
end
```

---

## Performance Best Practices

### 1. Use `collect/1` for Large Problems

```elixir
# BAD: O(n²) for large n
[do: objective] = Polynomial.algebra do
  Enum.reduce(items, Polynomial.const(0), fn item, acc ->
    acc + price[item] * vars[item]
  end)
end

# GOOD: O(n)
objective = Polynomial.collect do
  for item <- items do
    price[item] * vars[item]
  end
end
```

### 2. Pre-compute Coefficients

```elixir
# Compute coefficients once, outside the polynomial construction
coefficients = for item <- items, into: %{} do
  {item, compute_coefficient(item)}
end

objective = Polynomial.collect do
  for item <- items do
    coefficients[item] * vars[item]
  end
end
```

### 3. Batch Variable Creation

```elixir
# Create all variables in one pass
{problem, vars} =
  Enum.reduce(all_indices, {problem, %{}}, fn idx, {p, v} ->
    {new_p, var} = Problem.new_variable(p, "x_#{idx}", min: 0)
    {new_p, Map.put(v, idx, var)}
  end)
```

### 4. Use `sum_linear/1` for Lists of Polynomials

```elixir
# If you already have a list of polynomials
polynomials = for item <- items, do: Polynomial.algebra(price[item] * vars[item])

# Efficient summation
total = Polynomial.sum_linear(polynomials)
```

---

## Complete Examples

### Production Planning

```elixir
defmodule ProductionPlanning do
  require Dantzig.Polynomial, as: Polynomial
  require Dantzig.Constraint
  alias Dantzig.{Problem, Constraint}

  def solve do
    products = [:widgets, :gadgets, :gizmos]
    resources = [:labor, :materials, :machine_time]

    revenue = %{widgets: 100, gadgets: 150, gizmos: 80}
    cost = %{widgets: 30, gadgets: 50, gizmos: 25}

    usage = %{
      {:widgets, :labor} => 2, {:widgets, :materials} => 3, {:widgets, :machine_time} => 1,
      {:gadgets, :labor} => 3, {:gadgets, :materials} => 2, {:gadgets, :machine_time} => 2,
      {:gizmos, :labor} => 1, {:gizmos, :materials} => 4, {:gizmos, :machine_time} => 1
    }

    limits = %{labor: 100, materials: 150, machine_time: 80}

    # Create problem
    problem = Problem.new(direction: :maximize)

    # Create variables
    {problem, vars} =
      Enum.reduce(products, {problem, %{}}, fn product, {p, v} ->
        {new_p, var} = Problem.new_variable(p, "produce_#{product}", min: 0)
        {new_p, Map.put(v, product, var)}
      end)

    # Objective: maximize profit
    objective = Polynomial.collect do
      for product <- products do
        (revenue[product] - cost[product]) * vars[product]
      end
    end
    problem = %{problem | objective: objective}

    # Resource constraints
    problem =
      Enum.reduce(resources, problem, fn resource, p ->
        lhs = Polynomial.collect do
          for product <- products do
            usage[{product, resource}] * vars[product]
          end
        end
        Problem.add_constraint(p, Constraint.new(lhs, :<=, limits[resource]))
      end)

    # Solve
    {:optimal, solution} = Dantzig.solve(problem)

    # Report results
    IO.puts("Optimal profit: $#{solution.objective}")
    for product <- products do
      qty = Dantzig.Solution.evaluate(solution, vars[product])
      IO.puts("  #{product}: #{qty} units")
    end
  end
end
```

### Transportation Problem

```elixir
defmodule Transportation do
  require Dantzig.Polynomial, as: Polynomial
  require Dantzig.Constraint
  alias Dantzig.{Problem, Constraint}

  def solve do
    warehouses = [:seattle, :denver]
    customers = [:chicago, :dallas, :boston]

    supply = %{seattle: 350, denver: 300}
    demand = %{chicago: 200, dallas: 150, boston: 250}

    cost = %{
      {:seattle, :chicago} => 2.5, {:seattle, :dallas} => 3.5, {:seattle, :boston} => 4.0,
      {:denver, :chicago} => 2.0,  {:denver, :dallas} => 2.5,  {:denver, :boston} => 3.5
    }

    problem = Problem.new(direction: :minimize)

    # Shipping variables
    {problem, ship} =
      Enum.reduce(warehouses, {problem, %{}}, fn wh, {p, vars} ->
        Enum.reduce(customers, {p, vars}, fn cust, {p2, vars2} ->
          {new_p, var} = Problem.new_variable(p2, "ship_#{wh}_#{cust}", min: 0)
          {new_p, Map.put(vars2, {wh, cust}, var)}
        end)
      end)

    # Minimize total shipping cost
    objective = Polynomial.collect do
      for wh <- warehouses, cust <- customers do
        cost[{wh, cust}] * ship[{wh, cust}]
      end
    end
    problem = %{problem | objective: objective}

    # Supply constraints
    problem =
      Enum.reduce(warehouses, problem, fn wh, p ->
        lhs = Polynomial.collect do
          for cust <- customers, do: ship[{wh, cust}]
        end
        Problem.add_constraint(p, Constraint.new(lhs, :<=, supply[wh]))
      end)

    # Demand constraints
    problem =
      Enum.reduce(customers, problem, fn cust, p ->
        lhs = Polynomial.collect do
          for wh <- warehouses, do: ship[{wh, cust}]
        end
        Problem.add_constraint(p, Constraint.new(lhs, :>=, demand[cust]))
      end)

    {:optimal, solution} = Dantzig.solve(problem)

    IO.puts("Minimum shipping cost: $#{solution.objective}")
    for wh <- warehouses, cust <- customers do
      qty = Dantzig.Solution.evaluate(solution, ship[{wh, cust}])
      if qty > 0 do
        IO.puts("  #{wh} -> #{cust}: #{qty} units")
      end
    end
  end
end
```

---

## API Reference

### `Dantzig`

| Function | Description |
|----------|-------------|
| `solve(problem, opts)` | Solve problem, returns `{status, result}` tuple |
| `solve!(problem, opts)` | Solve problem, returns solution or raises |
| `dump_problem_to_file(problem, path)` | Write problem in LP format to disk |

### `Dantzig.Polynomial`

| Function | Description |
|----------|-------------|
| `const(n)` | Create constant polynomial |
| `variable(name)` | Create variable polynomial |
| `algebra(expr)` | Transform arithmetic to polynomial ops |
| `collect(do: block)` | Efficiently sum terms from comprehension |
| `add(p1, p2)` | Add polynomials |
| `subtract(p1, p2)` | Subtract polynomials |
| `multiply(p1, p2)` | Multiply polynomials |
| `divide(p, c)` | Divide by constant |
| `sum_linear(list)` | O(n) summation of polynomial list |
| `equal?(p1, p2)` | Test structural equality |
| `degree(p)` | Get polynomial degree |
| `constant?(p)` | Check if polynomial is constant |

### `Dantzig.Problem`

| Function | Description |
|----------|-------------|
| `new(direction: dir)` | Create new problem |
| `new_variable(p, name, opts)` | Add decision variable |
| `add_constraint(p, c)` | Add constraint |
| `maximize(p, poly)` | Add to objective (maximize) |
| `minimize(p, poly)` | Add to objective (minimize) |

### `Dantzig.Constraint`

| Function | Description |
|----------|-------------|
| `new(comparison)` | Create from comparison expression |
| `new(lhs, op, rhs)` | Create from components |
| `new_linear(...)` | Create with linearity check |

### `Dantzig.Solution`

| Field/Function | Description |
|----------|-------------|
| `.objective` | Optimal objective value |
| `.model_status` | HiGHS status string ("Optimal", etc.) |
| `.status` | Status atom: `:optimal`, `:time_limit`, `:iteration_limit` |
| `.mip_gap` | Relative MIP gap at termination (`nil` if N/A) |
| `.feasibility` | `true`/`false` |
| `.variables` | Map of variable name to value |
| `.constraints` | Map of constraint name to info |
| `evaluate(sol, poly)` | Evaluate polynomial with solution |
| `nr_of_variables(sol)` | Count variables |
| `nr_of_constraints(sol)` | Count constraints |

### `Dantzig.IIS`

| Field/Function | Description |
|----------|-------------|
| `.constraints` | List of conflicting constraint names |
| `.variables` | List of variables involved in conflicting bounds |
| `.raw_content` | Raw LP-format IIS model content |
| `parse(contents)` | Parse LP-format IIS string into struct |
| `from_file(path)` | Read and parse IIS file from disk (returns `nil` if missing/empty) |

### Exceptions

| Exception | Fields | Description |
|-----------|--------|-------------|
| `Dantzig.InfeasibleError` | `iis` | Problem is infeasible; `iis` contains `%IIS{}` or `nil` |
| `Dantzig.UnboundedError` | — | Problem is unbounded |
| `Dantzig.SolverError` | `reason`, `details` | Solver error with diagnostic info |
