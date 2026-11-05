# Implementation brief

Follow [ARCHITECTURE.md](ARCHITECTURE.md). The approach and its rationale
are in [dune structural enforcement](docs/decisions/dune-structural-enforcement.md).

## Scope

Two commands:

- `szaniec check` — dune-file conformance for the `well-ocaml` profile.
  Contracts: [check contract](docs/contracts/check-contract.md),
  [rule catalog](docs/contracts/rule-catalog.md).
- `szaniec complexity` — local Cognitive Complexity inventory.
  Contract: [complexity metric](docs/contracts/complexity-metric.md).

Out of scope: call-graph extraction, framework interpretation, approved
policy files, configuration files, coverage, model-based suggestions,
editor integration, servers and databases.

## Rules for changes

- A new rule gets a stable id, an entry in
  `lib/conformance_engine/rule_catalog.ml` with coaching, a section in the
  rule catalog document (the test compares them), and a positive and
  negative fixture case in `test/check/run.ts`.
- A new external library category goes into
  `lib/conformance_engine/profile.ml` only.
- A dune construct that can hide or redirect a dependency must become
  `DUNE-UNSUPPORTED` or a parse error until it is understood; never ignore
  it.
- `check` must not build, read `_build` or require a configuration file,
  and must stay well under a second on DG.
- `complexity` must keep `szaniec-complexity/1` compatible for DG's
  `scripts/check-complexity.ts`: one JSON line starting with
  `{"format":"szaniec-complexity/1"`, `metric`, `status`, `functions[]`
  with `location.path`, `qualname`, `status`, `complexity`, `coverage[]`
  with `path`, `status`, `functions`, and `gaps[]`.

## Acceptance scenarios

| Scenario | Expected result | Test |
|---|---|---|
| Conforming project with every allowed edge | Exit 0, no findings, components classified | `test/check/run.ts` |
| One violating dependency per rule id | Exactly that finding at the atom's `path:line:col` | `test/check/run.ts` |
| `dirs`, `data_only_dirs`, `vendored_dirs`, `_`/`.` dirs | Excluded dune files are not parsed | `test/check/run.ts` |
| `subdir` (also to absent directories), `include`, `select`, `re_export`, comments, block strings | Stanzas and dependencies found at correct positions | `test/check/run.ts` |
| Generated contract libraries absent from the tree | Dependency names still classified and judged | `test/check/run.ts` |
| Several libraries in one directory with `(modules ...)` | Each library is its own component | `test/check/run.ts` |
| Missing, disabled or too-old `implicit_transitive_deps` | `DUNE-TRANSITIVE`, exit 1 | `test/check/run.ts` |
| Unparseable dune file or missing `dune-project` | Exit 2 with `path:line:col`, no report | `test/check/run.ts` |
| `_build` contains dune or `.cyrograf` files | Ignored | `test/check/run.ts` |
| Coaching | Identical in binary and rule catalog document; every rule exercised | `test/check/run.ts` |
| Cognitive and cyclomatic specimens | Hand-derived scores | `test/complexity/run.ts`, `fixture.ts` |
| Cached, uncached and repeated runs | Byte-identical reports | `test/complexity/run.ts`, `fixture.ts` |
| Stale, partial, unmeasurable, externally transformed sources, failing build | Gap, exit 2, never a measured zero | `test/complexity/run.ts`, `fixture.ts` |
| Packaged binary from an unrelated directory | Checks a smoke project | `scripts/release.ts` |

## Verification commands

```sh
make verify   # ocamlformat check, deno fmt/check, all test suites
make build    # well build, bundle, launcher, relocation smoke test
```

The complexity tests build temporary dune projects with the locked
toolchain; the first run needs network access and several minutes.
