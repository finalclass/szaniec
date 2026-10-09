# Conformance evaluation indexes

ConformanceEngine prepares three lookup tables for each evaluation: execution
paths by `(canonical unit, caller)`, ownership by canonical unit, and unit metadata
by canonical unit. Each table retains the first input entry for a duplicate key,
matching the former list searches. The input lists still determine traversal and
finding order; hash-table enumeration does not replace them.

The unit table also supplies membership for ConformanceEngine's longest unit-prefix
lookup. It normalizes dotted paths through the existing Canonical functions and
checks successively shorter prefixes. This resolver stays inside ConformanceEngine;
other components retain their existing resolvers. No results or indexes survive
an evaluation.

Recursive expansion retains its visiting set, depth limit of eight, alternative
limit of 48, and ambiguity failures. Expansion results are not memoized: a helper
that succeeds under one entry can exceed the depth limit or revisit a symbol under
another. Missing paths and missing ownership/metadata retain their existing defaults.

## Regression coverage

`test/unit/conformance_indexes.ml` checks nested helpers, separate entries and
mutually exclusive alternatives, request and queue fan-out, missing/ambiguous paths,
recursion, shallow/deep reuse, width limits, duplicate paths, duplicate ownership,
duplicate metadata, missing metadata and longest-prefix equivalence.

The same test evaluates 40,000 distinct paths and 40,000 stale unclassified units.
It requires unchanged empty findings, bounded allocation and less than five CPU
seconds. The generous CPU budget detects the former repeated list scans; wall-clock
scheduling delays do not count toward it. Small fixtures establish semantics
independently of this performance guard. Architecture acceptance continues to
exercise actual compiler artifacts and source-to-diagnostic integration.

## Reproducible full-check comparison

Run from the repository root on Linux with GNU `time`:

```sh
deno run --allow-read --allow-write --allow-run \
  test/performance/conformance.ts --baseline baf52b9c --runs 3 --size 2000
```

The helper builds temporary copies of the working tree, replacing only the baseline
copy's ConformanceEngine with the selected Git revision. All remaining code, adapter
versions, compiler dependencies and input artifacts are identical. Temporary timing
instrumentation around `evaluate` records its elapsed time and allocated bytes;
the executable still runs the full `check` pipeline, including call-network
construction and rendering. Full-check wall time and process peak RSS are measured
separately. Compilation is outside the measurement.

When the checkout has an `_build` tree, its artifacts seed the temporary builds;
Dune still verifies and rebuilds changed inputs. Set `TMPDIR` to a disk-backed
directory if the default temporary filesystem cannot hold these builds. GNU `time`
must be on `PATH`, or selected with `--time-command <executable>`.

The synthetic fixture extends the public tasks application with `--size` independent
entries, each invoking three private helper levels and one Manager request. It is
built once and reused by both evaluators. Baseline/indexed order alternates between
runs. Every run must preserve report bytes, callgraph bytes and exit status, both
against the other evaluator and against earlier runs. The output includes each
sample, medians and artifact digests. Temporary sources, builds and reports are
removed on completion.

For an existing application with fresh OCaml artifacts, add
`--project-root <application>` and optionally `--config <absolute-toml-path>`.
The helper reads that application and writes graph output only inside its temporary
directory; it does not rebuild the application or change its approval. Keep its
sources and artifacts unchanged during measurement. An incomplete application
remains incomplete; the benchmark does not bypass freshness or missing evidence.

`baf52b9c` is the implementation baseline immediately before #14. The original
approximately 63-second invocation cited by the issue used `2cb177e` and older
adapters and callgraph projection. It is not a same-input performance comparison
with current versions. Select `--baseline 2cb177e` to investigate that evaluator
with current adapters; a diagnostic mismatch must still fail the comparison.
