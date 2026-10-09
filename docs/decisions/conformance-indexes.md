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
For memory-constrained investigations, `--collect-between-stages` performs a full
major collection after observation, interpretation, evaluation and callgraph
construction in both copies. This is benchmark instrumentation, not a product GC
change. Its cost is included in full-check time, while the evaluation timer excludes
collections outside `evaluate`. Record this option and any `OCAMLRUNPARAM` settings
alongside results; those full-check times do not describe the default runtime.

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

`--evaluation-only` runs the native OCaml measurement executable instead of the
CLI. It observes the same complete source scope and prepares ownership, bindings,
interactions and gaps. In these temporary copies only, the two graph-only context
and ordered-flow projections receive empty execution input; ConformanceEngine
does not consume those projections. It evaluates the complete observed call/path
inventories and compares fingerprints of its inputs and the ordered JSON of every
finding field. Input fingerprints omit the unused execution/measurement projections
and retain physical sharing in the OCaml serialization. This mode reports
`processSeconds` for preparation, evaluation and fingerprinting, not full-check
time. It produces no callgraph. The ordinary full-check mode retains both graph
projections and compares the complete CLI artifacts.

## Recorded comparison

Local Linux x86_64 measurements on 2026-10-09 used the locked toolchain and GNU
Time 1.9. The synthetic fixture had 22 units, 8,080 execution-path entries and
8,137 calls. Three alternating runs against `baf52b9c` produced these medians:

| Measurement | Baseline | Indexed |
|---|---:|---:|
| Evaluation elapsed time | 0.709 s | 0.026 s |
| Full check elapsed time | 2.449 s | 2.341 s |
| Evaluation allocation | 34.21 MiB | 25.11 MiB |
| Full-check peak RSS | 135.38 MiB | 136.20 MiB |

Reports and `/3` callgraphs were byte-identical in all six runs, with exit 0.
The report SHA-256 was
`dba6cb4d6e314e9bb856e64770dc4bbcc5f8fbc7001f403b510b1d0e77f31ed2`;
the graph SHA-256 was
`92fab609e439a997570fe46385f655e98bff07876d4da1b830f14c60e629f968`.
The evaluation reduction isolates the changed lookups; the remaining full-check
stages are unchanged. These short runs shared the host with other work, so the
full-check medians are observations rather than a statistically established speedup.

The same three-run synthetic comparison using the issue's `2cb177e` evaluator and
current adapters also preserved both artifacts and exit status. Its evaluation
median was 0.576 s versus 0.027 s; full-check medians were 2.884 s versus 1.507 s.
One full-check sample took 100 s under memory pressure, reinforcing the limitation
of full-check timing on this shared host.

The 40,000-path/40,000-unit regression took 0.061 CPU seconds and allocated
98,920,064 bytes with indexes. Running its evaluator-independent fixtures against
the prior evaluator preserved their semantic assertions, then failed the five-second
performance guard at 16.715 CPU seconds. The prior module was supplied the new
standalone index helpers only so the direct prefix-equivalence assertions could
compile; its `evaluate` implementation retained the original list scans.

An initial existing-application attempt evaluated 451 units, 24,072 path entries and
155,591 calls. Its baseline evaluation took 15.507 s, but the full process exited
137 after 531 s at 5,750,660 KiB peak RSS. This is a failed analysis, excluded from
successful full-check comparisons. The helper rejects exit codes above 2 and parses
both output documents before accepting a sample.

Two further full-check attempts with `OCAMLRUNPARAM=o=20`, then `o=5` plus
`--collect-between-stages`, also exited 137. Their baseline evaluations took
16.006 s and 24.477 s, with process peaks of 6,509,432 KiB and 4,967,672 KiB.
The complete current application callgraph could not be compared in this environment.
This validation remains outstanding; neither a full-check speedup nor byte identity
of that application's complete CLI artifacts is claimed.

A one-pair `--evaluation-only` comparison with `OCAMLRUNPARAM=o=20` completed on
the same 451-unit application, retaining all 24,072 paths and 155,591 calls:

| Component measurement | Baseline | Indexed |
|---|---:|---:|
| Evaluation elapsed time | 15.810 s | 6.142 s |
| Evaluation allocation | 4,407,538,984 bytes | 4,247,730,416 bytes |
| Preparation/evaluation/fingerprint process | 114.609 s | 104.166 s |
| Component process peak RSS | 4,111,332 KiB | 4,110,872 KiB |

Input and diagnostic fingerprints were identical. This isolates the lookup change
on the application without claiming a complete CLI comparison. The native driver
uses the product's OCaml contracts; Deno remains the orchestration runtime. The
application, its configuration and raw facts remain local.

The sanitized command shape for this completed component comparison was:

```sh
TMPDIR=<disk-temporary-directory> OCAMLRUNPARAM=o=20 \
  deno run --allow-read --allow-write --allow-run \
  test/performance/conformance.ts --baseline baf52b9c --runs 1 --size 2000 \
  --project-root <application> --config <temporary-toml> \
  --time-command <gnu-time-1.9> --evaluation-only
```

Verification commands completed successfully:

```sh
make build
dune build @test/unit/runtest
dune build test/performance/evaluation.exe
deno fmt --check test/performance/conformance.ts
deno check test/performance/conformance.ts
make verify
```

`make verify` was rerun with `TMPDIR` on disk after a temporary-filesystem quota
failure. It passed formatting, unit tests, configuration, repetition and ordered
flow integration, public/generated contracts, architecture and complexity
acceptance, recorded suggestions, and coverage acceptance. The benchmark helper's
subsequent GC instrumentation passed formatting, type checking and a synthetic
full-check comparison with identical artifacts.

## Follow-up failure diagnosis

Read-only kernel journal inspection confirmed that all three exit-137 processes
were killed by the global Linux OOM killer. This was an execution failure, not
the checker's violation exit status. The earlier failures occurred with the
baseline evaluator, so they do not establish a regression introduced by #14.

Temporary stage instrumentation on the indexed evaluator measured observation at
67.251 seconds, with a 3,075.7 MiB OCaml heap and 17,944.4 MiB cumulative allocation
on return. The implementation reads and retains all scanned CMT typed trees in
`read_infos` before deduplication, source-scope filtering and MLX exclusion. This
is a concrete memory contributor covered by #19; these stage measurements do not
attribute the complete later OOM peak to artifact retention alone.

The execution-context projection took another 44.838 seconds. The ordered-flow
projection had not completed when the diagnostic monitor stopped this separate
run after 300.681 seconds, at 3,622,904 KiB sampled peak RSS. That stop was an
explicit diagnostic time budget (SIGTERM, exit 143), not a new OOM event or a
successful full-check comparison. It occurred before conformance evaluation and
callgraph assembly in that run. The original OOM runs had completed evaluation;
their exact later failing operation has not been isolated.

The benchmark's temporary policy was deliberately unapproved, with `roots =
["lib"]` and no sharing or application-generated binding declarations. No
project-owned `szaniec.toml` was found. The completed component inspection retained
52 stale-artifact gaps, 47 unobserved-source gaps and four unsupported-construct
gaps. It also retained unresolved-call/target and ambiguous-path evidence. Its
measurement-driver exit 0 means the measurement completed; it is not an
architectural approval or an exit-0 conformance result.

The engine emitted 1,980 provisional violation findings before final report
composition. Their count is not a verified count of application defects. Some
refer to unmarked application-generated proxies without approved binding evidence;
others depend on sharing/ownership declarations absent from the minimal policy.
Source inspection nevertheless confirmed authored Manager calls into another
service's private Store/lock implementation. The service contract keeps storage
mechanics private. Such a bypass requires a boundary-preserving implementation
repair rather than approval of private storage internals as shared code.

The appropriate current conformance outcome is incomplete analysis, with confirmed
violations retained. A complete verdict requires a deliberately selected policy,
current artifacts for the declared executable scope, supported interpretation and
completion of the full pipeline. Positive conformance must not be presumed, and
an invalid application must still produce diagnostics rather than an OOM crash.
No application source, approval or shared-module policy was changed during this
investigation.

The follow-up used `journalctl -k --since '2026-10-09 00:00:00' --no-pager -g
'Killed process|Out of memory|oom-kill'`, a temporary native diagnostic executable
built with `dune build test/performance/diagnosis.exe bin/szaniec.exe`, and a Deno
process monitor. The component driver preserved the engine input scope while
disabling only the two unused graph projections, as in `--evaluation-only` above;
the separate timed-out run retained both projections. Temporary diagnostic sources
and raw application findings were removed after inspection. This documentation
update does not change the product implementation or its previous verification.
