defmodule Dantzig.LPEquivalenceTest do
  @moduledoc """
  Tests that verify the LP output is identical regardless of which
  polynomial construction method is used.

  This is critical for ensuring the solver receives the same problem
  whether using:
  - Old iterative approach (algebra + sum)
  - New efficient approach (collect + sum_linear)
  - Direct map construction (workaround)
  """
  use ExUnit.Case, async: true

  alias Dantzig.Problem
  alias Dantzig.Constraint
  alias Dantzig.HiGHS

  require Dantzig.Polynomial, as: Polynomial
  require Dantzig.Constraint

  describe "LP output equivalence" do
    test "objective built with algebra+reduce matches collect" do
      problem = Problem.new(direction: :maximize)

      # Create some variables
      {problem, vars} =
        Enum.reduce(1..10, {problem, %{}}, fn i, {p, v} ->
          {new_p, var} = Problem.new_variable(p, "v#{i}")
          {new_p, Map.put(v, i, var)}
        end)

      coefficients = %{1 => 2.0, 2 => -3.0, 3 => 1.5, 4 => -0.5, 5 => 4.0,
                       6 => -1.0, 7 => 2.5, 8 => -2.0, 9 => 3.0, 10 => -1.5}

      # Method 1: Old iterative approach
      [do: objective_old] = Polynomial.algebra do
        Enum.reduce(1..10, Polynomial.const(0), fn i, acc ->
          acc + coefficients[i] * vars[i]
        end)
      end

      # Method 2: New collect approach
      objective_new = Polynomial.collect do
        for i <- 1..10 do
          coefficients[i] * vars[i]
        end
      end

      # Verify polynomials are equal
      assert Polynomial.equal?(objective_old, objective_new)

      # Build problems with each objective
      problem_old = %{problem | objective: objective_old}
      problem_new = %{problem | objective: objective_new}

      # Verify LP output is identical
      lp_old = HiGHS.to_lp_iodata(problem_old) |> IO.iodata_to_binary()
      lp_new = HiGHS.to_lp_iodata(problem_new) |> IO.iodata_to_binary()

      assert lp_old == lp_new
    end

    test "constraint LHS built with different methods produces identical LP" do
      problem = Problem.new(direction: :minimize)

      # Create variables for a truck/route style problem
      truck_ids = [:t1, :t2, :t3]
      route_ids = [:r1, :r2, :r3, :r4]

      {problem, x_vars} =
        Enum.reduce(truck_ids, {problem, %{}}, fn truck_id, {p, vars} ->
          Enum.reduce(route_ids, {p, vars}, fn route_id, {p2, vars2} ->
            {new_p, var} = Problem.new_variable(p2, "x_#{truck_id}_#{route_id}")
            {new_p, Map.put(vars2, {truck_id, route_id}, var)}
          end)
        end)

      hours_by_route = %{r1: 2.0, r2: 3.0, r3: 1.5, r4: 4.0}
      max_hours = 8.0

      # Build constraint LHS using old method
      [do: lhs_old] = Polynomial.algebra do
        Enum.reduce(route_ids, Polynomial.const(0), fn route_id, acc ->
          x_var = x_vars[{:t1, route_id}]
          hours = hours_by_route[route_id]
          acc + hours * x_var
        end)
      end

      # Build constraint LHS using collect
      lhs_new = Polynomial.collect do
        for route_id <- route_ids do
          x_var = x_vars[{:t1, route_id}]
          hours = hours_by_route[route_id]
          hours * x_var
        end
      end

      # Verify polynomials are equal
      assert Polynomial.equal?(lhs_old, lhs_new)

      # Add constraints to separate problems
      problem_old = Problem.add_constraint(problem, Constraint.new(lhs_old, :<=, max_hours))
      problem_new = Problem.add_constraint(problem, Constraint.new(lhs_new, :<=, max_hours))

      # Verify LP output is identical
      lp_old = HiGHS.to_lp_iodata(problem_old) |> IO.iodata_to_binary()
      lp_new = HiGHS.to_lp_iodata(problem_new) |> IO.iodata_to_binary()

      assert lp_old == lp_new
    end

    test "direct map construction matches collect output" do
      problem = Problem.new(direction: :maximize)

      # Create variables
      {problem, vars} =
        Enum.reduce(1..5, {problem, %{}}, fn i, {p, v} ->
          {new_p, var} = Problem.new_variable(p, "y#{i}")
          {new_p, Map.put(v, i, var)}
        end)

      penalty = 10.0

      # Method 1: Direct map construction (workaround pattern)
      terms_map =
        for i <- 1..5,
            var = vars[i],
            [{var_key, _coeff}] = Map.to_list(var.simplified),
            into: %{} do
          {var_key, -penalty}
        end
      objective_direct = %Polynomial{simplified: terms_map}

      # Method 2: Using collect
      objective_collect = Polynomial.collect do
        for i <- 1..5, var = vars[i] do
          -penalty * var
        end
      end

      # Verify polynomials are equal
      assert Polynomial.equal?(objective_direct, objective_collect)

      # Build problems
      problem_direct = %{problem | objective: objective_direct}
      problem_collect = %{problem | objective: objective_collect}

      # Verify LP output is identical
      lp_direct = HiGHS.to_lp_iodata(problem_direct) |> IO.iodata_to_binary()
      lp_collect = HiGHS.to_lp_iodata(problem_collect) |> IO.iodata_to_binary()

      assert lp_direct == lp_collect
    end

    test "large scale equivalence (1000 terms)" do
      problem = Problem.new(direction: :minimize)

      n = 1000

      {problem, vars} =
        Enum.reduce(1..n, {problem, %{}}, fn i, {p, v} ->
          {new_p, var} = Problem.new_variable(p, "x#{i}")
          {new_p, Map.put(v, i, var)}
        end)

      # Generate deterministic coefficients
      coefficients = for i <- 1..n, into: %{}, do: {i, :math.sin(i) * 100}

      # Old method
      [do: objective_old] = Polynomial.algebra do
        Enum.reduce(1..n, Polynomial.const(0), fn i, acc ->
          acc + coefficients[i] * vars[i]
        end)
      end

      # New method
      objective_new = Polynomial.collect do
        for i <- 1..n do
          coefficients[i] * vars[i]
        end
      end

      assert Polynomial.equal?(objective_old, objective_new)

      problem_old = %{problem | objective: objective_old}
      problem_new = %{problem | objective: objective_new}

      lp_old = HiGHS.to_lp_iodata(problem_old) |> IO.iodata_to_binary()
      lp_new = HiGHS.to_lp_iodata(problem_new) |> IO.iodata_to_binary()

      assert lp_old == lp_new
    end

    test "mixed positive and negative coefficients" do
      problem = Problem.new(direction: :maximize)

      {problem, x} = Problem.new_variable(problem, "x")
      {problem, y} = Problem.new_variable(problem, "y")
      {_problem, z} = Problem.new_variable(problem, "z")

      vars = [x, y, z]
      coeffs = [3.0, -2.0, 1.5]

      # Old
      [do: objective_old] = Polynomial.algebra do
        Enum.zip(vars, coeffs)
        |> Enum.reduce(Polynomial.const(0), fn {var, coeff}, acc ->
          acc + coeff * var
        end)
      end

      # New
      objective_new = Polynomial.collect do
        for {var, coeff} <- Enum.zip(vars, coeffs) do
          coeff * var
        end
      end

      assert Polynomial.equal?(objective_old, objective_new)
    end

    test "with constant terms" do
      problem = Problem.new(direction: :minimize)

      {_problem, x} = Problem.new_variable(problem, "x")
      {_problem, y} = Problem.new_variable(problem, "y")

      # Old method with explicit constant
      [do: objective_old] = Polynomial.algebra do
        2 * x + 3 * y + 5
      end

      # New method - collect with constant added
      objective_new = Polynomial.collect do
        [2 * x, 3 * y, Polynomial.const(5)]
      end

      assert Polynomial.equal?(objective_old, objective_new)
    end
  end

  describe "complex multi-constraint problem" do
    @doc """
    Models a production planning problem with:
    - Multiple factories and products
    - Capacity constraints per factory
    - Demand fulfillment constraints per product
    - Resource usage constraints
    - Multi-component objective (revenue, costs, penalties)
    """
    test "production planning problem with multiple constraint types" do
      problem = Problem.new(direction: :maximize)

      # Problem dimensions
      factories = [:f1, :f2, :f3]
      products = [:p1, :p2, :p3, :p4]
      resources = [:raw_material, :labor_hours, :machine_time]

      # Create production quantity variables: x[factory][product]
      {problem, x_vars} =
        Enum.reduce(factories, {problem, %{}}, fn factory, {p, vars} ->
          Enum.reduce(products, {p, vars}, fn product, {p2, vars2} ->
            {new_p, var} = Problem.new_variable(p2, "x_#{factory}_#{product}")
            {new_p, Map.put(vars2, {factory, product}, var)}
          end)
        end)

      # Create binary indicator variables: y[factory] (is factory active?)
      {problem, y_vars} =
        Enum.reduce(factories, {problem, %{}}, fn factory, {p, vars} ->
          {new_p, var} = Problem.new_variable(p, "y_#{factory}")
          {new_p, Map.put(vars, factory, var)}
        end)

      # Problem data
      revenue = %{p1: 100.0, p2: 150.0, p3: 80.0, p4: 200.0}
      production_cost = %{
        {:f1, :p1} => 20.0, {:f1, :p2} => 30.0, {:f1, :p3} => 15.0, {:f1, :p4} => 40.0,
        {:f2, :p1} => 25.0, {:f2, :p2} => 25.0, {:f2, :p3} => 18.0, {:f2, :p4} => 35.0,
        {:f3, :p1} => 22.0, {:f3, :p2} => 28.0, {:f3, :p3} => 12.0, {:f3, :p4} => 45.0
      }
      factory_capacity = %{f1: 500.0, f2: 400.0, f3: 600.0}
      product_demand = %{p1: 200.0, p2: 150.0, p3: 300.0, p4: 100.0}
      resource_usage = %{
        {:p1, :raw_material} => 2.0, {:p1, :labor_hours} => 1.0, {:p1, :machine_time} => 0.5,
        {:p2, :raw_material} => 3.0, {:p2, :labor_hours} => 2.0, {:p2, :machine_time} => 1.0,
        {:p3, :raw_material} => 1.0, {:p3, :labor_hours} => 0.5, {:p3, :machine_time} => 0.3,
        {:p4, :raw_material} => 4.0, {:p4, :labor_hours} => 3.0, {:p4, :machine_time} => 2.0
      }
      resource_limits = %{raw_material: 2000.0, labor_hours: 1000.0, machine_time: 800.0}
      fixed_cost = %{f1: 1000.0, f2: 800.0, f3: 1200.0}

      # ========== OBJECTIVE FUNCTION ==========
      # Maximize: total_revenue - production_costs - fixed_costs

      # Revenue component (old method)
      [do: revenue_old] = Polynomial.algebra do
        Enum.reduce(factories, Polynomial.const(0), fn factory, acc ->
          Enum.reduce(products, acc, fn product, acc2 ->
            acc2 + revenue[product] * x_vars[{factory, product}]
          end)
        end)
      end

      # Revenue component (new method)
      revenue_new = Polynomial.collect do
        for factory <- factories,
            product <- products do
          revenue[product] * x_vars[{factory, product}]
        end
      end

      assert Polynomial.equal?(revenue_old, revenue_new)

      # Production cost component (old method)
      [do: prod_cost_old] = Polynomial.algebra do
        Enum.reduce(factories, Polynomial.const(0), fn factory, acc ->
          Enum.reduce(products, acc, fn product, acc2 ->
            acc2 + production_cost[{factory, product}] * x_vars[{factory, product}]
          end)
        end)
      end

      # Production cost component (new method)
      prod_cost_new = Polynomial.collect do
        for factory <- factories,
            product <- products do
          production_cost[{factory, product}] * x_vars[{factory, product}]
        end
      end

      assert Polynomial.equal?(prod_cost_old, prod_cost_new)

      # Fixed cost component (old method)
      [do: fixed_cost_old] = Polynomial.algebra do
        Enum.reduce(factories, Polynomial.const(0), fn factory, acc ->
          acc + fixed_cost[factory] * y_vars[factory]
        end)
      end

      # Fixed cost component (new method)
      fixed_cost_new = Polynomial.collect do
        for factory <- factories do
          fixed_cost[factory] * y_vars[factory]
        end
      end

      assert Polynomial.equal?(fixed_cost_old, fixed_cost_new)

      # Complete objective (old method)
      objective_old = Polynomial.algebra(revenue_old - prod_cost_old - fixed_cost_old)

      # Complete objective (new method)
      objective_new = Polynomial.algebra(revenue_new - prod_cost_new - fixed_cost_new)

      assert Polynomial.equal?(objective_old, objective_new)

      # ========== CONSTRAINTS ==========

      # 1. Capacity constraints: sum of production at each factory <= capacity
      {problem_old, problem_new} =
        Enum.reduce(factories, {problem, problem}, fn factory, {p_old, p_new} ->
          # Old method
          [do: capacity_lhs_old] = Polynomial.algebra do
            Enum.reduce(products, Polynomial.const(0), fn product, acc ->
              acc + x_vars[{factory, product}]
            end)
          end

          # New method
          capacity_lhs_new = Polynomial.collect do
            for product <- products do
              x_vars[{factory, product}]
            end
          end

          assert Polynomial.equal?(capacity_lhs_old, capacity_lhs_new)

          constraint_old = Constraint.new(capacity_lhs_old, :<=, factory_capacity[factory])
          constraint_new = Constraint.new(capacity_lhs_new, :<=, factory_capacity[factory])

          {Problem.add_constraint(p_old, constraint_old),
           Problem.add_constraint(p_new, constraint_new)}
        end)

      # 2. Demand constraints: sum of production across factories >= demand
      {problem_old, problem_new} =
        Enum.reduce(products, {problem_old, problem_new}, fn product, {p_old, p_new} ->
          # Old method
          [do: demand_lhs_old] = Polynomial.algebra do
            Enum.reduce(factories, Polynomial.const(0), fn factory, acc ->
              acc + x_vars[{factory, product}]
            end)
          end

          # New method
          demand_lhs_new = Polynomial.collect do
            for factory <- factories do
              x_vars[{factory, product}]
            end
          end

          assert Polynomial.equal?(demand_lhs_old, demand_lhs_new)

          constraint_old = Constraint.new(demand_lhs_old, :>=, product_demand[product])
          constraint_new = Constraint.new(demand_lhs_new, :>=, product_demand[product])

          {Problem.add_constraint(p_old, constraint_old),
           Problem.add_constraint(p_new, constraint_new)}
        end)

      # 3. Resource constraints: total resource usage <= limit
      {problem_old, problem_new} =
        Enum.reduce(resources, {problem_old, problem_new}, fn resource, {p_old, p_new} ->
          # Old method
          [do: resource_lhs_old] = Polynomial.algebra do
            Enum.reduce(factories, Polynomial.const(0), fn factory, acc ->
              Enum.reduce(products, acc, fn product, acc2 ->
                usage = resource_usage[{product, resource}]
                acc2 + usage * x_vars[{factory, product}]
              end)
            end)
          end

          # New method
          resource_lhs_new = Polynomial.collect do
            for factory <- factories,
                product <- products do
              usage = resource_usage[{product, resource}]
              usage * x_vars[{factory, product}]
            end
          end

          assert Polynomial.equal?(resource_lhs_old, resource_lhs_new)

          constraint_old = Constraint.new(resource_lhs_old, :<=, resource_limits[resource])
          constraint_new = Constraint.new(resource_lhs_new, :<=, resource_limits[resource])

          {Problem.add_constraint(p_old, constraint_old),
           Problem.add_constraint(p_new, constraint_new)}
        end)

      # Set objectives
      problem_old = %{problem_old | objective: objective_old}
      problem_new = %{problem_new | objective: objective_new}

      # Verify complete LP output is identical
      lp_old = HiGHS.to_lp_iodata(problem_old) |> IO.iodata_to_binary()
      lp_new = HiGHS.to_lp_iodata(problem_new) |> IO.iodata_to_binary()

      assert lp_old == lp_new

      # Verify constraint counts match
      assert map_size(problem_old.constraints) == map_size(problem_new.constraints)
      # 3 capacity + 4 demand + 3 resource = 10 constraints
      assert map_size(problem_old.constraints) == 10
    end

    test "assignment problem with quadratic-like structure" do
      # Models: assign workers to tasks, minimize cost + penalty for unassigned
      problem = Problem.new(direction: :minimize)

      workers = [:w1, :w2, :w3, :w4, :w5]
      tasks = [:t1, :t2, :t3, :t4]

      # Assignment variables: a[worker][task] = 1 if worker assigned to task
      {problem, a_vars} =
        Enum.reduce(workers, {problem, %{}}, fn worker, {p, vars} ->
          Enum.reduce(tasks, {p, vars}, fn task, {p2, vars2} ->
            {new_p, var} = Problem.new_variable(p2, "a_#{worker}_#{task}")
            {new_p, Map.put(vars2, {worker, task}, var)}
          end)
        end)

      # Slack variables for unassigned tasks
      {problem, slack_vars} =
        Enum.reduce(tasks, {problem, %{}}, fn task, {p, vars} ->
          {new_p, var} = Problem.new_variable(p, "slack_#{task}")
          {new_p, Map.put(vars, task, var)}
        end)

      # Cost matrix
      cost = %{
        {:w1, :t1} => 10.0, {:w1, :t2} => 15.0, {:w1, :t3} => 9.0, {:w1, :t4} => 12.0,
        {:w2, :t1} => 8.0,  {:w2, :t2} => 11.0, {:w2, :t3} => 14.0, {:w2, :t4} => 7.0,
        {:w3, :t1} => 12.0, {:w3, :t2} => 9.0,  {:w3, :t3} => 10.0, {:w3, :t4} => 11.0,
        {:w4, :t1} => 11.0, {:w4, :t2} => 13.0, {:w4, :t3} => 8.0, {:w4, :t4} => 9.0,
        {:w5, :t1} => 9.0,  {:w5, :t2} => 10.0, {:w5, :t3} => 11.0, {:w5, :t4} => 13.0
      }
      penalty = 100.0

      # Objective: minimize assignment cost + penalty for slack
      [do: cost_old] = Polynomial.algebra do
        Enum.reduce(workers, Polynomial.const(0), fn worker, acc ->
          Enum.reduce(tasks, acc, fn task, acc2 ->
            acc2 + cost[{worker, task}] * a_vars[{worker, task}]
          end)
        end)
      end

      cost_new = Polynomial.collect do
        for worker <- workers, task <- tasks do
          cost[{worker, task}] * a_vars[{worker, task}]
        end
      end

      assert Polynomial.equal?(cost_old, cost_new)

      [do: penalty_old] = Polynomial.algebra do
        Enum.reduce(tasks, Polynomial.const(0), fn task, acc ->
          acc + penalty * slack_vars[task]
        end)
      end

      penalty_new = Polynomial.collect do
        for task <- tasks do
          penalty * slack_vars[task]
        end
      end

      assert Polynomial.equal?(penalty_old, penalty_new)

      objective_old = Polynomial.algebra(cost_old + penalty_old)
      objective_new = Polynomial.algebra(cost_new + penalty_new)

      assert Polynomial.equal?(objective_old, objective_new)

      # Constraint 1: Each worker assigned to at most one task
      {problem_old, problem_new} =
        Enum.reduce(workers, {problem, problem}, fn worker, {p_old, p_new} ->
          [do: lhs_old] = Polynomial.algebra do
            Enum.reduce(tasks, Polynomial.const(0), fn task, acc ->
              acc + a_vars[{worker, task}]
            end)
          end

          lhs_new = Polynomial.collect do
            for task <- tasks, do: a_vars[{worker, task}]
          end

          assert Polynomial.equal?(lhs_old, lhs_new)

          {Problem.add_constraint(p_old, Constraint.new(lhs_old, :<=, 1.0)),
           Problem.add_constraint(p_new, Constraint.new(lhs_new, :<=, 1.0))}
        end)

      # Constraint 2: Each task has assignment + slack = 1
      {problem_old, problem_new} =
        Enum.reduce(tasks, {problem_old, problem_new}, fn task, {p_old, p_new} ->
          [do: lhs_old] = Polynomial.algebra do
            worker_sum = Enum.reduce(workers, Polynomial.const(0), fn worker, acc ->
              acc + a_vars[{worker, task}]
            end)
            worker_sum + slack_vars[task]
          end

          lhs_new = Polynomial.collect do
            worker_terms = for worker <- workers, do: a_vars[{worker, task}]
            worker_terms ++ [slack_vars[task]]
          end

          assert Polynomial.equal?(lhs_old, lhs_new)

          {Problem.add_constraint(p_old, Constraint.new(lhs_old, :==, 1.0)),
           Problem.add_constraint(p_new, Constraint.new(lhs_new, :==, 1.0))}
        end)

      problem_old = %{problem_old | objective: objective_old}
      problem_new = %{problem_new | objective: objective_new}

      lp_old = HiGHS.to_lp_iodata(problem_old) |> IO.iodata_to_binary()
      lp_new = HiGHS.to_lp_iodata(problem_new) |> IO.iodata_to_binary()

      assert lp_old == lp_new

      # 5 worker constraints + 4 task constraints = 9
      assert map_size(problem_old.constraints) == 9
    end

    test "transportation problem with shipping costs and capacity" do
      # Ship goods from warehouses to customers minimizing cost
      problem = Problem.new(direction: :minimize)

      warehouses = [:wh1, :wh2]
      customers = [:c1, :c2, :c3, :c4, :c5]

      # Shipping quantity variables
      {problem, ship_vars} =
        Enum.reduce(warehouses, {problem, %{}}, fn wh, {p, vars} ->
          Enum.reduce(customers, {p, vars}, fn cust, {p2, vars2} ->
            {new_p, var} = Problem.new_variable(p2, "ship_#{wh}_#{cust}")
            {new_p, Map.put(vars2, {wh, cust}, var)}
          end)
        end)

      # Data
      shipping_cost = %{
        {:wh1, :c1} => 4.0, {:wh1, :c2} => 6.0, {:wh1, :c3} => 9.0, {:wh1, :c4} => 5.0, {:wh1, :c5} => 7.0,
        {:wh2, :c1} => 5.0, {:wh2, :c2} => 3.0, {:wh2, :c3} => 7.0, {:wh2, :c4} => 8.0, {:wh2, :c5} => 4.0
      }
      warehouse_supply = %{wh1: 150.0, wh2: 200.0}
      customer_demand = %{c1: 50.0, c2: 70.0, c3: 60.0, c4: 80.0, c5: 90.0}

      # Objective: minimize total shipping cost
      [do: objective_old] = Polynomial.algebra do
        Enum.reduce(warehouses, Polynomial.const(0), fn wh, acc ->
          Enum.reduce(customers, acc, fn cust, acc2 ->
            acc2 + shipping_cost[{wh, cust}] * ship_vars[{wh, cust}]
          end)
        end)
      end

      objective_new = Polynomial.collect do
        for wh <- warehouses, cust <- customers do
          shipping_cost[{wh, cust}] * ship_vars[{wh, cust}]
        end
      end

      assert Polynomial.equal?(objective_old, objective_new)

      # Supply constraints: total shipped from warehouse <= supply
      {problem_old, problem_new} =
        Enum.reduce(warehouses, {problem, problem}, fn wh, {p_old, p_new} ->
          [do: lhs_old] = Polynomial.algebra do
            Enum.reduce(customers, Polynomial.const(0), fn cust, acc ->
              acc + ship_vars[{wh, cust}]
            end)
          end

          lhs_new = Polynomial.collect do
            for cust <- customers, do: ship_vars[{wh, cust}]
          end

          assert Polynomial.equal?(lhs_old, lhs_new)

          {Problem.add_constraint(p_old, Constraint.new(lhs_old, :<=, warehouse_supply[wh])),
           Problem.add_constraint(p_new, Constraint.new(lhs_new, :<=, warehouse_supply[wh]))}
        end)

      # Demand constraints: total received by customer >= demand
      {problem_old, problem_new} =
        Enum.reduce(customers, {problem_old, problem_new}, fn cust, {p_old, p_new} ->
          [do: lhs_old] = Polynomial.algebra do
            Enum.reduce(warehouses, Polynomial.const(0), fn wh, acc ->
              acc + ship_vars[{wh, cust}]
            end)
          end

          lhs_new = Polynomial.collect do
            for wh <- warehouses, do: ship_vars[{wh, cust}]
          end

          assert Polynomial.equal?(lhs_old, lhs_new)

          {Problem.add_constraint(p_old, Constraint.new(lhs_old, :>=, customer_demand[cust])),
           Problem.add_constraint(p_new, Constraint.new(lhs_new, :>=, customer_demand[cust]))}
        end)

      problem_old = %{problem_old | objective: objective_old}
      problem_new = %{problem_new | objective: objective_new}

      lp_old = HiGHS.to_lp_iodata(problem_old) |> IO.iodata_to_binary()
      lp_new = HiGHS.to_lp_iodata(problem_new) |> IO.iodata_to_binary()

      assert lp_old == lp_new

      # 2 supply + 5 demand = 7 constraints
      assert map_size(problem_old.constraints) == 7
    end
  end

  describe "edge cases" do
    test "all terms cancel to zero" do
      problem = Problem.new(direction: :maximize)

      {_problem, x} = Problem.new_variable(problem, "x")

      result = Polynomial.collect do
        [3 * x, -3 * x]
      end

      # Should produce a zero polynomial
      assert Polynomial.constant?(result)
      assert Polynomial.to_number!(result) == 0
    end

    test "single term in collect" do
      problem = Problem.new(direction: :maximize)

      {_problem, x} = Problem.new_variable(problem, "x")

      result = Polynomial.collect do
        [5 * x]
      end

      expected = Polynomial.algebra(5 * x)
      assert Polynomial.equal?(result, expected)
    end

    test "nested arithmetic expressions" do
      problem = Problem.new(direction: :maximize)

      {_problem, x} = Problem.new_variable(problem, "x")
      {_problem, y} = Problem.new_variable(problem, "y")

      vars = [x, y]

      result = Polynomial.collect do
        for var <- vars do
          (2 + 3) * var - 1
        end
      end

      # (5*x - 1) + (5*y - 1) = 5x + 5y - 2
      expected = Polynomial.algebra(5 * x + 5 * y - 2)
      assert Polynomial.equal?(result, expected)
    end
  end
end
