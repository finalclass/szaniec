# Complexity inventory performance

The performance target is a complete `complexity --json` invocation below
15 seconds on a previously built application with reusable extraction entries.
Building the application is a separate cost. An empty or disabled extraction
cache must be reported separately; neither implies a cold OS page cache.

## Changes

- Index per-file function counts instead of searching the complete lists for
  each source file. (Service ownership, which this change also indexed, is no
  longer part of the report.)
- Create default transformation provenance only when no caller supplied it.
  `Option.value` eagerly evaluated the expensive default even when unused.
- Hash a repeated generator/dependency once while assembling its provenance
  snapshot. Source and compiler-artifact freshness checks remain active.
- Share decoded CMI CRC tables and import-path existence lookups within one
  observation. Keep visible-before-hidden and first-match rejection semantics.

Import lookup memoization is not timestamp-based proof. Metadata changes cause
an immediate CMI reread, and every reused CMI's content digest is checked again
before returning the observation. Every memoized existence result, including a
missing higher-priority import path, is also rechecked. A concurrent change
aborts acquisition explicitly, like an artifact changing during observation.
These tables are recreated for every invocation and do not cache a final report.

## Reproduce

The paired benchmark helper used for the measurement below was removed with
the other performance suites in the
[dune structural enforcement](dune-structural-enforcement.md) rewrite. To
compare two builds, build the application once, then time
`szaniec complexity --json` for each binary alternately (with
`SZANIEC_OBSERVATION_CACHE=off` for full extraction) and require
byte-identical reports and identical exit status.

## Regression coverage

`test/complexity/run.ts` compares cached and uncached reports byte for byte;
`test/complexity/fixture.ts` retains locations, identities, counts,
unsupported constructs and stale source diagnostics. The import-probe and
acquisition suites described in earlier revisions of this record were removed
with the call-graph pipeline.

## Recorded application results

On 2026-10-15, a paired CLI run against the same previously built application
and reusable extraction entries measured **116.42 s** for `0ce33ae9` and
**9.79 s** for this change: **11.89x** faster. This is one paired sample, not
a cross-machine guarantee. A separate candidate run with extraction caching
disabled took **36.37 s**; full extraction does not meet the 15-second target.

All reports were byte-identical, including the uncached run. The inventory
contained 104,649 functions, 104,639 measured bodies, 10 unmeasurable bodies,
and the same 10 measurement gaps. Exit status remained 2. The comparison did
not filter generated sources or convert incomplete measurement into success.
The full `make verify` suite passed, and the instrumented profiling helper
compiled and reproduced the same application report.
