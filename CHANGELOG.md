# Changelog

## v1.3 - HiGHS solver memory upgrades

Reduces both BEAM- and native-side memory on the solve path.

- New `Dantzig.solve_iodata/2` and `solve_iodata/3` — solve a pre-serialized LP
  model (from `to_lp_iodata/1`) instead of a `%Problem{}`. This lets a caller
  serialize, drop its reference to the `Problem`, `:erlang.garbage_collect()`,
  and only then solve — so the Problem's constraints/objective aren't retained
  on the heap during the (potentially long) solve. Solution decoding is
  name-based and never needs the Problem back. `solve_iodata/3` takes a
  pre-serialized MIP start (from `mip_start_to_iodata/2`) for warm starts.
- New public serializers `Dantzig.to_lp_iodata/1` and
  `Dantzig.mip_start_to_iodata/2` so callers can pre-serialize through the
  public API (previously only reachable via the internal `HiGHS` module).
- `solve/2` now serializes the model inside the temp-file closure and runs
  `:erlang.garbage_collect()` before launching HiGHS. A process blocked in
  `System.cmd` never GCs on its own, so the ~100+ MB of LP-serialization
  garbage (sorted constraint list, per-polynomial fragments) previously sat on
  the heap for the entire solve. On large models this was the single biggest
  BEAM-side spike. Error reporting re-reads the model file lazily instead of
  holding it in memory. No behavior change for callers; warm start unaffected.
- New `solve/2` memory levers, all passed through to HiGHS via the options file:
  `:mip_pool_soft_limit`, `:mip_pool_age_limit`, `:mip_lp_age_limit`,
  `:mip_max_nodes`, `:mip_max_leaves`, `:presolve`. HiGHS has no `memory_limit`;
  these bound its working set instead. They default to HiGHS's own defaults, so
  existing behavior is unchanged. Note: `presolve: "off"` typically *increases*
  peak memory — it's exposed as a knob, not a memory win.

## v1.2 - HiGHS solver upgrades

- New `solve/2` tuning options: `:mip_heuristic_effort`, `:mip_max_start_nodes`,
  `:parallel`, `:threads`, `:random_seed`. All pass through to HiGHS via the
  options file and default to HiGHS's own defaults, so existing behavior is
  unchanged.
- New `:mip_start` option for warm-starting MIPs with a partial primal solution.
  Accepts a map of `%{polynomial_or_name => value}` and writes a HiGHS solution
  file that's loaded via `--read_solution_file`. See `Dantzig.MipStart`.
  Variables not supplied by the caller are padded with their lower bound (or
  `0` if unbounded below) so the file lists a value for every model variable —
  HiGHS's reader aborts otherwise.
- New `Solution.warm_start_status` field
  (`:accepted | :rejected | :not_provided | nil`) so callers can detect whether
  HiGHS actually adopted a provided MIP start or silently discarded it. Parsed
  from HiGHS's stdout log.
- Fixed MIP gap parsing. `Solution.mip_gap` was previously always `nil` because
  the regex matched neither the LP `Relative P-D gap` line nor the MIP
  `Gap   <n>%` line. The type widened from `float() | nil` to
  `float() | :infinity | nil`; `:infinity` is returned when HiGHS reports
  `Gap inf` (no feasible solution found within the time limit).
- New `Polynomial.variable_name!/1` returns the variable name of a
  single-variable monomial polynomial. Lenient on coefficient.
- New `Problem.lookup_variable/2` returns the `%ProblemVariable{}` for a given
  polynomial monomial or mangled string name.

Note: prior tagged releases (v1.0.0, v1.1.0) did not update `mix.exs`, so the
in-repo `@version` was stale at `0.2.0`. This release re-aligns `mix.exs` with
the tagged version line.

## v0.2 - First version that downloads the HiGHS binary at compile-time

We now download the HiGHS binary at compile time.
Not all architectures are supported yet.
Documentation is still lacking, especially regarding configuration options.

## v0.1 - First public version

Most of the functionality is already implemented.
When dependent packages become stable, the version will be upgraded to 1.0.
