# Acquisition profiling

This follow-up measures the remaining cost after the aggregate performance
implementation, removes eager import-path construction from ProgramAccess and
memoizes canonical alias resolution within an immutable alias inventory.
Diagnostic instrumentation is added only to temporary benchmark builds. The
original policy, observation contract, full-graph scope, freshness gaps, diagnostics
and exit status are retained.

## Import lookup

For every imported compiler unit, the former acquisition code constructed paths
for every visible and hidden load-path directory, then searched that list for the
first existing interface. Path construction itself probes absolute compiler paths,
so candidates after the first match caused unnecessary filesystem work.

ProgramAccess now constructs candidates on demand in the same compiler-directory
order and stops at the first existing interface. It validates that interface's CRC;
a corrupt or mismatched first interface must still fail, even if a later directory
contains a valid one. Missing earlier candidates may fall back to later visible or
hidden directories. A missing local import remains a freshness failure. Compiler
validation is not replaced by policy approval, cached interpretations or file-time
guesses. No successful raw-fact semantics or adapter identity changes.

The compiled acquisition probe checks first-match rejection, valid first-match
precedence, visible/hidden fallback and missing-local rejection. Existing cached
acquisition and public-contract scenarios check current sources, interfaces, import
identities, artifact corruption and concurrent checks.

## Alias resolution

Observation normalization repeatedly resolves the same canonical symbols while
rewriting calls, references, arguments and flow steps. Canonical retains the
existing longest-prefix index and first-match duplicate behavior, and memoizes
only complete resolutions started with an empty visiting context. Successful
results and cyclic failures may both be reused. Intermediate recursive results
are not memoized across visiting contexts. A cached cyclic result still lets each
caller record its existing unsupported evidence; it is not a successful target.

Each domain owns its memo. A fixed domain-local key retains only the most recently
used resolver identity and clears entries when that identity changes. The captured
alias index is immutable. Changing inventories cannot reuse old successes or
cyclic failures, domains do not mutate a shared memo, and constructing new resolvers
does not allocate an unbounded sequence of domain-local keys. The primitive remains
owned by Model and carries no framework or policy interpretation.

The unit fixture checks longest-prefix selection, duplicate aliases, unchanged
unknown paths, self/mutual cycles, changed inventories, long chains and concurrent
domains. Compiled comparisons retain all normalization and global interpretation.

## Method

`test/performance/conformance.ts --profile-acquisition` wraps acquisition operations
in the temporary OCaml build. The compiler integration remains OCaml; Deno owns
build copying, invocation, validation, comparison and cleanup. No profiling module
is added to the distributable application.

Each named operation records a call count, inclusive elapsed time and exclusive
elapsed time. Nested operations charge their inclusive duration to their parent;
the parent's exclusive duration excludes that charge. Exclusive buckets partition
the complete observation timer. The helper rejects missing or overlapping timing
summaries. The `observation` exclusive bucket contains unwrapped work, including
inventory assembly and profiling bookkeeping; it is not a separately
identified algorithm. Timings include automatic GC within the measured operations.

The buckets distinguish source/artifact scanning, CMT decoding, CMI decoding,
source/interface/import freshness, cache keys, hashes, I/O, payload reuse/publication,
artifact rechecks, compiler-fact/execution extraction and observation normalization.
Inclusive extraction includes execution extraction, so those inclusive values must
not be added together.
`--collect-between-stages` also reports the total elapsed time of explicit major
collections separately. That counter does not measure all automatic GC.

`--snapshot-roots lib --project-root <application>` copies the selected source roots
and the complete `_build` tree into a temporary application, preserving file times.
It copies the selected configuration and discards only the temporary copy's
observation cache. Copying the complete build tree preserves discovery cost,
including directories whose CMTs are later excluded by the existing default-build
filter. The application checkout, approval and existing cache are untouched.
Recorded compiler paths that point to existing external inputs remain subject to
the adapter's ordinary freshness checks.

Cache comparisons use the current checker on both sides: cache off versus cache
on, alternating order over three pairs. The first cache-on sample starts with no
observation entries; later samples reuse them. These are extraction-cache states,
not claims of a cold OS page cache. The separate one-source and broad-invalidation
scenarios mutate and rebuild only the public synthetic fixture.

Every sample must finish within its native-process budget, parse as a complete
report and graph, and preserve report bytes, every graph byte and exit status.
Graph validation uses `jq --stream`, comparison uses `cmp` and hashing uses
`sha256sum`, after the native check's measured time. Copying, compilation and graph
validation are outside native-process timings. Raw logs and private application
facts remain temporary; published results contain only aggregate counts and costs.

`--component imports` rolls back only the import-validation function in the
baseline comparison copy. Every other implementation and adapter identity matches.
`--component acquisition` rolls back that function and canonical alias memoization
together, preserving the other aggregate optimizations.
`--cache-followups` adds two current-checker samples after the uncached comparison:
empty observation cache and reused observation cache. Both must preserve the same
reference artifacts and exit status. They are reported separately and excluded
from the isolated comparison's medians. Existing-application follow-ups require a
snapshot, so the helper cannot clear or initialize the application's own cache.

## Commands used

The cache matrix was recorded while production code still matched `e0581ff4`.
The imports-only comparison followed the import change, before alias memoization.
The acquisition comparison followed both changes. `--component cache` always
profiles the current production code on both sides; rerunning it after this
follow-up measures the newer implementation. The combined acquisition mode
restores both original algorithms in its baseline copy.

```sh
OCAMLRUNPARAM=o=20 deno run --allow-read --allow-write --allow-run \
  test/performance/conformance.ts --baseline origin/main --component cache \
  --runs 3 --size 50 --project-root <application> --snapshot-roots lib \
  --config <temporary-unapproved-lib-policy> --timeout-seconds 300 \
  --profile-acquisition --collect-between-stages
OCAMLRUNPARAM=o=20 deno run --allow-read --allow-write --allow-run \
  test/performance/conformance.ts --baseline e0581ff4 --component imports \
  --runs 1 --size 50 --project-root <application> --snapshot-roots lib \
  --config <temporary-unapproved-lib-policy> --timeout-seconds 300 \
  --profile-acquisition --collect-between-stages --cache-followups
OCAMLRUNPARAM=o=20 deno run --allow-read --allow-write --allow-run \
  test/performance/conformance.ts --baseline e0581ff4 --component acquisition \
  --runs 1 --size 50 --project-root <application> --snapshot-roots lib \
  --config <temporary-unapproved-lib-policy> --timeout-seconds 300 \
  --profile-acquisition --collect-between-stages --cache-followups
```

The temporary policy selects `roots = ["lib"]` and
`approved_shared_modules = []`. Both sides use one evaluation domain and identical
GC settings. These settings reproduce the prior large-application investigation;
they do not establish default-runtime latency.

## Measurements

The application contains 451 units, 24,072 paths and 155,591 calls. Every compared
check retains the complete 3,321,235,829-byte graph, identical report bytes and exit
status 2. That status reflects the temporary unapproved policy, not a benchmark
failure. All measurements below use the same application revision, one domain,
`OCAMLRUNPARAM=o=20` and explicit collections between stages, on a shared host.

### Existing extraction cache

Before either optimization, three cache-off samples took 121.499, 126.767 and
131.508 seconds (median 126.767). The first cache-on check took 126.303 seconds;
subsequent warm checks took 112.753 and 115.804 seconds. A warm extraction cache
saved approximately 10% against the cache-off median, while initially populating
it added cost. This is not evidence that the OS page cache was cold.

An uncached check counted 994 typed reads. The cache stored 993 entries totaling
35,252,437 bytes; warm checks reused 993 entries and performed one typed read.
Unsupported evidence remains uncached. Warm acquisition still decoded 44 interface
annotations and checked 63,228 imported compiler interfaces. Its peak memory stayed
near 4.48 GiB, similar to uncached execution.

The first uncached acquisition took 62.310 seconds. Import freshness accounted for
25.811 seconds inclusive, including 4.805 seconds of CMI decoding. CMT decoding took
2.279 seconds and compiler-fact extraction took 4.601 seconds inclusive. Cache-file
I/O and hashes took 7.043 and 2.700 seconds respectively. These measurements reject
the assumption that typed-tree extraction alone dominates this workload. A later,
more detailed profile isolated roughly 17–18 seconds of observation normalization.

### Import lookup alone

One comparison with the same alias implementation on both sides reduced the full
uncached check from 120.139 to 118.365 seconds. Import freshness fell from 25.926 to
24.263 seconds; normalization remained approximately 17.5 seconds. The optimized
check took 120.317 seconds with an empty extraction cache and 107.856 seconds with
a warm cache. This single pair supports a modest improvement, not a large or
guaranteed speedup. It motivated profiling repeated alias resolution next.

### Both optimizations

The final isolated comparison and current-checker cache follow-ups all completed:

| Implementation and extraction cache | Full check | Observation | Total CPU |
| --- | ---: | ---: | ---: |
| Original import and alias algorithms, cache off | 121.378 s | 62.288 s | 116.536 s |
| On-demand imports and alias memo, cache off | 120.706 s | 64.077 s | 115.361 s |
| Both optimizations, initially empty cache | 117.464 s | 59.878 s | 115.040 s |
| Both optimizations, warm cache | 105.591 s | 48.863 s | 103.470 s |

In the uncached pair, import freshness fell from 25.955 to 24.816 seconds and
normalization from 18.134 to 16.593 seconds. Artifact scanning and file I/O varied
in the opposite direction; the overall difference is small enough that one pair
does not establish a reliable uncached latency improvement. Cache follow-ups do
not form an isolated alias-only experiment. The 105.591-second warm result is a
completed sample, not a promised latency or proof that alias memoization alone
caused the difference from earlier warm samples.

All four samples kept identical report bytes, every graph byte and exit status.
The warm sample still reused 993 entries, read one unsupported artifact and
validated imported interfaces. Peak RSS was 4.47–4.48 GiB across these samples;
the alias memo did not materially reduce peak memory.

Warm execution still spent 24.112 seconds on import freshness, 15.512 seconds on
normalization, 19.492 seconds rendering the complete graph and 17.566 seconds in
explicit major collections. Those collections are outside the stage timers;
automatic GC is included within stages. Reducing typed reads alone cannot remove
these costs. Further large reductions require examining the retained flow model,
normalization, imported-interface validation and full-graph export while preserving
freshness and unsupported evidence. A 5–10-second full check has not been achieved.

## Verification performed

The following local commands passed after both production changes:

```sh
make build
dune build @test/unit/runtest
deno test --allow-read --allow-write --allow-run --allow-env \
  test/performance/acquisition.ts test/acceptance/public_contracts.ts
dune exec ocamlformat -- --check lib/model/canonical.ml \
  lib/program_access/ocaml_adapter.ml test/performance/acquisition.ml \
  test/unit/alias_memo.ml
deno fmt --check test/performance/conformance.ts
deno check test/performance/conformance.ts
git diff --check
```

Compiled synthetic cache comparisons covered unchanged, one-source invalidation
and broad invalidation. An unprofiled synthetic control produced the same report
and graph digests as the profiled checker. Separate import and combined-acquisition
comparisons covered uncached, initially populated and reused cache states. The
large application checks kept their entire output and compared it after streaming
validation. No result is inferred from a partial graph or a timed-out process.

Full `make verify` is also configured in GitHub CI; it was not repeated locally
for this follow-up. The focused local checks above cover the changed resolver,
compiled acquisition and public-contract freshness behavior.
