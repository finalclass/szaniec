# Complexity inventory performance

The performance target is a complete `complexity --json` invocation below
15 seconds on a previously built application with reusable extraction entries.
Building the application is a separate cost. An empty or disabled extraction
cache must be reported separately; neither implies a cold OS page cache.

## Changes

- Resolve ownership with the same contract binding and classification used by
  full interpretation, without constructing its unused interactions and flows.
- Index per-module ownership, declared RPC members and per-file function counts
  instead of searching the complete lists for each function or source file.
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

Build both revisions with `make build`, and build the application once through
its own build entry point. Run the benchmark outside other CPU-heavy work:

```sh
deno run --allow-read --allow-run test/performance/complexity.ts \
  --baseline /path/to/baseline/_release/szaniec \
  --candidate /path/to/candidate/_release/szaniec \
  --project-root /path/to/application --samples 3 --cache on
```

Repeat with `--cache off` to measure full extraction. The helper alternates
execution order, times the entire CLI invocation including JSON output, and
requires byte-identical reports and identical exit status for every sample.
It prints individual timings, medians, speedup, and whether the candidate median
met the target. No application source, approval, roots or generated-code scope
is changed by the benchmark.

## Regression coverage

Acquisition tests compare cached/uncached and evidence-capability observations.
Import probes exercise first-path corruption, visible/hidden fallback, missing
local interfaces, same-size/same-mtime content replacement, final content
validation, and added/deleted import paths. Generated-contract acceptance cases
compare measurement ownership directly with full interpretation. Existing CC
goldens retain locations, identities, counts, unsupported constructs and stale
source diagnostics.

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
