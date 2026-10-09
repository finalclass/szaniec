# Full-program performance

The optimization program covers issues #14–#21 together. The approved component
boundaries, current `/3` callgraph, helper traversal, ownership, diagnostics,
analysis gaps and exit statuses remain binding. No service is checked in isolation.
The exploratory 5–10 second application target is not a product guarantee.

## Ownership and evidence

ConformanceEngine indexes first-match unit, ownership and execution-path records.
Recursive expansion retains its visiting/depth context and is not memoized.
Canonical supplies longest-prefix membership indexes and caches hits and misses.
An immutable index belongs to each observation; each domain memoizes only its
most recently used resolver. Switching resolver identities clears the memo, so
old inventories cannot supply results and repeated observations do not allocate
an unbounded sequence of domain-local keys.

InspectionManager indexes owning prefixes and declared RPCs, including unmapped
origin results. It accumulates edges, sites, contexts and reverse callers in
tables, then sorts once. Initial-site behavior and first-match ownership are
preserved; resource/external targets remain absent from `calledBy`. Non-RPC
entry points keep their existing execution contexts and ordered flows.

ProgramAccess selects Architecture, Measurement or All evidence as specified in
the [observation contract](../contracts/observation-schema.md). Measurement keeps
the compiler facts needed for current ownership attribution; removing those facts
would change inventories for compiler-bound implementations. It skips the separate
execution-context/ordered-flow walker. Architecture skips complexity measurement.
Suggestions retain their dependency catalog and source extraction.

Acquisition retains tree-free CMT metadata, validates the full current inventory,
and processes selected trees individually. Stripping preserves the original
annotation kind so
an incomplete interface identity cannot gain a partial-implementation exemption.
The compiler fixture checks all five annotation kinds and absent interface digests.
Metadata caching uses format `/3` to invalidate earlier stripped representations.
Metadata cold misses require reading the compiler's serialized record; its format
does not expose independent scope
metadata before the tree. Selected cold artifacts are read again after inventory
and freshness validation. This deliberately trades some I/O for lower retained
memory instead of guessing exclusion from filenames. Persistent metadata hits
avoid typed-tree unmarshalling for duplicates and excluded units. Artifact
selection keeps the existing first-match behavior, including duplicate unit names.

ProgramAccess owns the versioned local cache and atomic publication. Cache entry
identity and payload integrity are checked separately. Freshness checks always
precede fact reuse; source/artifact changes during selected acquisition fail
explicitly. Cached raw facts undergo current cross-unit alias normalization,
interpretation and evaluation. Cache disabling, concurrency and cleanup follow
the observation contract. Unknown evidence retains its meaning; a cache hit does
not grant ownership, policy approval or a successful check.

ConformanceEngine parallelizes root-path evaluation only. Global rules run once
with complete evidence. Lookup tables are read-only, memoization is domain-local,
and each root owns its findings and temporary traversal tables. An atomic work
cursor balances roots; joining all workers precedes deterministic merging.
Worker failures propagate after cleanup. Workloads below 256 path records and
the default single-domain setting use sequential evaluation. Parallel execution
is opt-in because domain startup and GC can outweigh benefits on simple inputs.

CLI graph rendering creates lazy JSON collections and writes through a scoped
formatter/channel. It preserves Yojson's existing pretty layout, escaping, field
order and final newline. This avoids a second complete JSON tree plus final
buffer/string copies; one collection's shallow nodes are produced at a time.
The complete Callgraph model and every flow, site, context and unknown remain
present. Rendering stays owned by CLI and does not enter either Engine. Channel
cleanup runs on write failure. This follows the large application's rendering
failure described below.

## Verification

The reproducible entry points are:

```sh
make build
make verify
deno check test/performance/conformance.ts test/performance/acquisition.ts
dune exec test/performance/resolver.exe
```

The unit suites cover overlapping/unknown canonical prefixes, changed inventories,
duplicate metadata/ownership/path keys, recursion, depth and alternative bounds,
request/queue fan-out and gaps. Small semantic fixtures are repeated over 1, 2,
4 and 8 domains, including enough records to use workers. Worker tests cover skew,
exceptions, joining and tiny workloads. A 40,000-path/40,000-unit regression guards
indexed evaluation. A 4,000-target projection fixture checks repeated sites,
overlapping owner prefixes, unmapped/private origins, same RPC names in different
services, resources and reverse callers.

The acquisition compiler fixture compares cached and uncached packaged checks
at 1/2/4/8 domains, concurrent invocations, corruption/interrupted writes, stale
and rebuilt sources, added/deleted sources, corrupt and duplicate CMTs, scope,
policy and contract changes. A native probe compares requested facts against All
evidence and checks the generated-function inventory. Cache unit tests also check
entry identity, content/capability changes and private permissions. Existing
compiled acceptance covers interface freshness, preprocessing, missing artifacts,
generated wrappers, native/browser serializers, private/resource access and
unsupported evidence. The #31 serializer/runtime shape is already implemented
by PR #29; its packaged acceptance is retained rather than duplicated.
The renderer compares 1,000 varied JSON layouts, escaping, integer limits and
100-level nesting against Yojson, then compiled graphs against the former
renderer. The corruption fixture replaces a deliberately read-only CMT instead
of modifying Dune's potentially hard-linked output in place; this fixes the
first CI run's test-environment permission failure.

The final `make build` and full `make verify` completed successfully, including
unit, acquisition, configuration, loop/flow, public/application-generated
contract, architecture, complexity, suggestion and coverage acceptance. The
packaged CLI also retained the write-error diagnostic when writing to `/dev/full`.
The metadata-kind correction additionally received targeted compiled reruns:

```sh
dune build @test/unit/runtest test/performance/acquisition.exe
deno test --allow-read --allow-write --allow-run --allow-env \
  test/performance/acquisition.ts test/acceptance/public_contracts.ts
```

Tracked OCaml formatting, both Deno helpers' formatting/type checks, and the final
cache comparison also passed. Source/interface changes, original annotation kinds,
current compiler import identities and complete report/graph equivalence are
covered by the final compiled reruns.

## Benchmark method

`test/performance/conformance.ts` builds temporary comparison copies and one
compiled public application. Adapters, toolchain and input artifacts match on
both sides. `--component` selects an isolated rollback: `conformance`, `resolver`,
`attribution`, `aggregation`, `selection`, `capabilities`, or the full `all`
rollback to `baf52b9c`. The full rollback also receives the two small Well
interpretation safety guards described below; all adapter identities match.
`cache` compares off/on using current code; `parallel`
compares 1 against `--domains` using current code. Extraction caches are disabled
in all other modes. Samples alternate comparison order and require identical
reports, complete graphs and exit statuses, including nonzero conformance results.
Full graphs are validated with `jq --stream empty`, compared byte-for-byte with
`cmp`, and fingerprinted with `sha256sum`. These existing command-line tools are
required for full-graph benchmarks. The Deno helper retains only the report and a
graph path, so multi-gigabyte graphs do not become JavaScript strings or objects.
`rendering` replaces only the CLI with the former eager renderer. The `all`
rollback also includes the former CLI. Observation, interpretation, evaluation,
projection and rendering have separate timings in the temporary copies.

The small native Linux `measure.c` helper uses `wait4` for actual child peak RSS
and total CPU time across domains. Deno remains the automation runtime; C is
limited to the OS resource-measurement interface absent from Deno. `cc` builds it
in the temporary directory. `--time-command` can select GNU time instead (CPU
totals then are unavailable). Each invocation has a 300-second default budget,
selected by `--timeout-seconds`; timeout/OOM samples fail and are never accepted
as completed checks. Temporary builds, fixtures and reports are removed.
On timeout the native helper forwards termination to its child and records the
child's resource usage before exiting; the timeout remains a failed sample.

The helper also supports `--projection-only`, `--complexity`, and
`--shape branching` (48 alternatives). Component projection measurements use
normalized fixtures rather than compiler fixtures; ordinary check/complexity
comparisons still exercise the compiler and complete CLI. Allocation around
evaluation counts the main domain only, so it must not be presented as total
parallel allocation. Full-process RSS and CPU include all domains.

`--filesystem-cache cold` applies unprivileged `POSIX_FADV_DONTNEED` to artifacts
before each invocation. This is advised eviction, not proof that every page left
the kernel cache. Default runs reuse the warm filesystem cache. Selection tests
are independent of the persistent extraction cache.

Example commands, run from the repository root:

```sh
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component all --runs 3 --size 2000
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component aggregation --projection-only --runs 3 --size 4000
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component capabilities --complexity --runs 3 --size 2000
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component capabilities --runs 3 --size 2000
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component selection --filesystem-cache cold --runs 3 --size 2000
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component cache --runs 3 --size 2000
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component parallel --shape branching --domains 4 --runs 3 --size 400
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component parallel --shape branching --domains 2 --runs 3 --size 400
```

The cache mode additionally rebuilds one artifact, then broadly changed sources.
Its first sample for each state records invalidation; subsequent samples record
warm reuse. Temporary copies discard the source checkout's observation cache:
project-root identity prevents reuse and inherited entries would distort disk costs.
Disk costs can be inspected under the temporary application's cache.
Use `--project-root <application> --config <toml>` for an existing application;
this does not rebuild it or approve its policy. Raw application facts are local.

## Measurements

Local Linux x86_64 measurements on 2026-10-09 used OCaml 5.4.1, the locked Dune
toolchain and three alternating samples. These are observations on a shared host,
not statistically established speedup guarantees. Full-check comparisons retained
22 units, 8,080 paths and 8,137 calls with byte-identical reports and `/3` graphs.

| Comparison | Baseline | Optimized |
|---|---:|---:|
| All changes, full-check median | 1.825 s | 1.145 s |
| All changes, process peak RSS median | 135.4 MiB | 90.1 MiB |
| All changes, evaluation median | 0.533 s | 0.015 s |
| All changes, observation median | 0.798 s | 0.901 s |
| Resolver rollback, full-check median | 1.445 s | 1.216 s |
| Resolver rollback, interpretation median | 0.346 s | 0.117 s |
| Isolated resolver, 12,000 lookups CPU median | 0.786 s | 0.004 s |
| Isolated resolver, allocation median | 12,095,312 bytes | 2,400,088 bytes |
| Attribution only, 4,000-target projection CPU median | 0.580 s | 0.007 s |
| Attribution only, projection allocation | 778,112,912 bytes | 5,312,400 bytes |
| Aggregation only, projection CPU median | 4.116 s | 0.008 s |
| Aggregation only, projection allocation | 7,612,378,608 bytes | 5,312,400 bytes |
| Tree retention rollback, warm-filesystem peak RSS median | 148.1 MiB | 100.4 MiB |
| Tree retention rollback, advised-cold peak RSS median | 141.8 MiB | 100.9 MiB |
| Tree retention rollback, advised-cold observation median | 1.010 s | 0.979 s |
| Capability selection, full complexity median over lib roots | 1.133 s | 0.974 s |
| Capability selection, complexity observation median | 0.938 s | 0.864 s |
| Rendering only, compiled fixture rendering median | 0.118 s | 0.064 s |
| Rendering only, repository graph rendering median | 9.362 s | 4.585 s |
| Rendering only, repository process peak RSS median | 2,111.5 MiB | 182.6 MiB |

Attribution and aggregation do not materially improve the small full-check
fixture: it has few exported edges. The large projection fixture isolates their
list-scan/allocation costs. Selection reduces memory but increases cold selected
reads (58 versus 84 typed reads, with 58 scanned and 26 selected artifacts);
advised-cold full-check medians were 1.292 and 1.262 s. These final runs include
hidden Dune object directories in advised eviction. Earlier exploratory eviction
runs that missed those directories are excluded. Capability-selection
check medians (1.210/1.187 s, observation 0.923/0.920 s) do not establish an
independent check-time gain on the straight-line fixture; complexity exercises
all lib definitions separately. The complete uncached extension increases
acquisition time because selected CMTs are reread and cache identities are hashed;
its interpretation/evaluation gains and lower retained memory improve the full
check despite that cost.

Cache measurements before the CLI streaming change retained identical full
outputs; their full-check timings include the former renderer:

| State | Cache off | Cache on first sample | Cache on subsequent samples |
|---|---:|---:|---:|
| Unchanged fixture, full check | 1.176 s median | 1.194 s | 0.675 / 0.688 s |
| One source rebuilt, full check | 1.262 s median | 1.254 s | 0.683 / 0.745 s |
| Broad source changes rebuilt, full check | 1.206 s median | 1.302 s | 0.753 / 0.839 s |

Initial extraction records 84 misses/typed reads and 0 hits; unchanged repeats
record 84 hits and no reads. The one-source rebuild records 3 misses/reads and
55 hits, then 58 hits and no reads; rebuilding changes the byte/native artifact
inventory from 58 to 32 while retaining all 22 units. Broad invalidation records
66 misses/reads and 13 hits, then 79 hits and no reads (53 scanned artifacts).
Warm unchanged RSS is approximately 63.9 MiB versus 102.9 MiB uncached. Cache
payloads occupy 1,724,624 bytes/84 entries initially, 3,325,713 bytes/87 entries
after the one-source rebuild and 5,031,649 bytes/153 entries after broad changes.
Old content-addressed entries accumulate until explicit cleanup. First runs and
invalidation can cost more than uncached checks; warm savings do not describe
every edit.

The isolated resolver comparison is `dune exec test/performance/resolver.exe`,
with 2,001 overlapping unit prefixes, known/unknown paths and repeated queries.
Index construction is outside its timed lookup section; full-check measurements
include preparation. All three runs assert baseline/indexed result equivalence.

Parallel measurements use 400 roots sharing a 48-alternative helper (481 observed
paths and 585 calls). An initial three-pair comparison measured full-check medians
2.632/1.799 s at 1/4 domains, total CPU 2.587/3.205 s and RSS 168.2/166.9 MiB.
One four-domain sample took 5.035 s. A later repeat while acceptance fixtures were
compiling measured medians 2.878/4.982 s, CPU 2.652/5.827 s and RSS 160.0/166.6 MiB.
Both comparisons retained identical reports and graphs. This variability and GC/
host contention prevent claiming reliable four-domain speedup on this host.
A subsequent three-pair two-domain comparison improved every full-check sample:
medians 2.553/1.929 s (24% elapsed reduction), evaluation 1.428/0.806 s, total CPU
2.517/2.677 s and RSS 160.3/162.6 MiB. Its reports and graphs were identical.
Two domains are therefore the measured useful setting for this branching workload;
adding domains does not guarantee further improvement.
The simple straight-line fixture also slows slightly with four domains. The
single-domain default, opt-in domain selection and sequential comparison remain
available. Main-domain allocation is not total worker allocation.

An existing-application comparison used this repository's compiled `lib` scope,
with 36 observed units, 427 paths and 6,475 calls. One full pair completed in
15.972/11.346 s, evaluation 0.059/0.034 s, CPU 15.045/10.942 s and RSS
1,983.2/1,991.0 MiB. Reports and complete `/3` graphs were byte-identical. Both
returned exit 2 under the same deliberately unapproved temporary policy; this is
a completed comparison preserving incomplete analysis, not an approved application.
The original baseline crashed on an empty execution symbol before producing a
report. Both comparison copies therefore receive guards for empty entry symbols
and bare `spec` references; the product fixes have targeted regression coverage
and change Well adapter identity to 3.4.1. Nonempty dotted-name normalization is
preserved. These public-repository measurements precede the CLI streaming change.

An isolated `--component conformance` full comparison on the same public
repository preserved both artifacts and exit 2 with all other optimizations held
constant. Evaluation was 0.057/0.034 s and allocated 55,187,304/43,287,816 bytes;
full checks took 10.058/10.431 s at 1,991.0/1,991.8 MiB peak RSS. Evaluation is a
small part of this application's full pipeline, so this pair does not establish
an independent end-to-end gain from #14. The corresponding 2,000-entry compiled
fixture measured evaluation 0.504/0.015 s and full checks 1.717/1.097 s with
identical artifacts and exit 0.

The existing-application command actually run was:

```sh
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component all --runs 1 --size 2000 \
  --project-root . --config <temporary-unapproved-lib-policy> --timeout-seconds 120
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component conformance --runs 1 --size 2000 \
  --project-root . --config <temporary-unapproved-lib-policy> --timeout-seconds 120
deno run --allow-read --allow-write --allow-run test/performance/conformance.ts \
  --baseline baf52b9c --component rendering --runs 3 --size 2000 \
  --project-root . --config <temporary-unapproved-lib-policy> --timeout-seconds 120
```

## Large application follow-up

The 451-unit application from the original #14 investigation was retested with
24,072 paths and 155,591 calls. The isolated ConformanceEngine rollback used the
current acquisition, interpretation, projection and streaming CLI on both sides.
Both complete checks returned exit 2 under the same unapproved temporary lib
policy. Reports and all 3,321,235,829 callgraph bytes were identical; freshness,
unknown evidence and violations remained present. No application source, build
or approval was changed. This completes the previously missing full comparison
recorded in [conformance indexes](conformance-indexes.md).

One pair, with extraction caching disabled and one evaluation domain, measured:

| Metric | Baseline evaluator | Indexed evaluator |
|---|---:|---:|
| Evaluation | 15.311 s | 5.465 s |
| Full native check | 137.471 s | 129.251 s |
| Total CPU | 128.349 s | 120.186 s |
| Process peak RSS | 4,588.8 MiB | 4,585.0 MiB |
| Evaluation allocation | 4,407,538,984 bytes | 4,062,976,584 bytes |
| Observation | 67.448 s | 69.219 s |
| Interpretation | 7.860 s | 8.094 s |
| Projection | 0.316 s | 0.350 s |
| Rendering | 21.253 s | 20.584 s |

Both runs scanned 561 artifacts, selected 485 and performed 994 counted typed
reads. They used `OCAMLRUNPARAM=o=20` and `--collect-between-stages` equally.
Full-check timings include those collections; they do not describe default GC.
JSON validation, file comparison and hashing run afterward and are outside native
check timings. This is one completed comparison, not a latency guarantee or a
claim that the exploratory 5–10-second target has been reached. Acquisition and
the complete retained flow model still dominate this application's costs.

Before streaming, an instrumented full attempt timed out after 180 seconds during
rendering, at 6,634,644 KiB peak RSS, after observation 40.233 s, interpretation
5.704 s, evaluation 12.923 s and projection 0.339 s. Another 180-second streaming
attempt under concurrent compiler/renderer memory pressure did not finish
evaluation. A tuned attempt then exposed the benchmark helper's eager
multi-gigabyte graph read and ended with exit 137. None of these attempts counts
as a completed comparison. Streaming rendering plus file-based validation made
the final full comparison possible without reducing graph scope.

The completed command was:

```sh
OCAMLRUNPARAM=o=20 deno run --allow-read --allow-write --allow-run \
  test/performance/conformance.ts --baseline baf52b9c --component conformance \
  --runs 1 --size 2000 --project-root <application> \
  --config <temporary-unapproved-lib-policy> --timeout-seconds 300 \
  --collect-between-stages
```

The temporary policy selects `roots = ["lib"]` and
`approved_shared_modules = []`. No policy approval is created for that application.

The [acquisition profiling follow-up](acquisition-profiling.md) separates remaining
freshness, compiler, cache and normalization costs, measures first/warm cache use
on a temporary application snapshot, and validates on-demand compiler import-path
construction and inventory-scoped alias memoization against this implementation.
