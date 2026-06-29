# Changelog

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