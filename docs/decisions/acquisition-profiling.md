# Acquisition profiling

This follow-up measures the remaining cost after the aggregate performance
implementation and removes eager import-path construction from ProgramAccess.
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
inventory assembly, normalization and profiling bookkeeping; it is not a separately
identified algorithm. Timings include automatic GC within the measured operations.

The buckets distinguish source/artifact scanning, CMT decoding, CMI decoding,
source/interface/import freshness, cache keys, hashes, I/O, payload reuse/publication,
artifact rechecks, compiler-fact/execution extraction and observation normalization.
Inclusive extraction
includes execution extraction, so those inclusive values must not be added together.
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
`--cache-followups` adds two current-checker samples after the uncached comparison:
empty observation cache and reused observation cache. Both must preserve the same
reference artifacts and exit status. They are reported separately and excluded
from the isolated comparison's medians. Existing-application follow-ups require a
snapshot, so the helper cannot clear or initialize the application's own cache.

## Reproduction

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
```

The temporary policy selects `roots = ["lib"]` and
`approved_shared_modules = []`. Both sides use one evaluation domain and identical
GC settings. These settings reproduce the prior large-application investigation;
they do not establish default-runtime latency.
