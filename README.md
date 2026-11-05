# Szaniec

**Protect an IDesign architecture expressed as dune libraries, and measure
OCaml Cognitive Complexity.**

Szaniec is a local CLI for people and coding agents working on the DG
project. Architecture is enforced by structure: every service is its own
dune library, `(implicit_transitive_deps false)` makes the compiler reject
any reference to a library that is not a direct dependency, and
`szaniec check` verifies that the `dune` files declare only dependencies
allowed by IDesign rules. Findings come with coaching from Juval Löwy's
*Righting Software* that tells the implementing agent how to fix the design.

The name is Polish for a defensive earthwork. This is not an official
IDesign product.

## Commands and status

| Command | Status | Purpose |
|---|---|---|
| `szaniec check` | works | Check dune dependencies against IDesign rules; no build, no config |
| `szaniec complexity` | works | Inventory functions and their Cognitive Complexity from compiler artifacts |

`init`, `approve`, `coverage`, `suggestions`, `szaniec.toml` and the
call-graph checker (`szaniec.json`) were removed; see
[the decision record](docs/decisions/dune-structural-enforcement.md).
Passing them now prints a usage error (exit 2).

What works:

- The `well-ocaml` rule set: 23 rule ids covering the IDesign role matrix,
  cross-service implementation access, contract leaks, composition-root
  leaks, Well framework/resource/event/presentation libraries, `re_export`,
  unsupported dune constructs and the `implicit_transitive_deps` setting.
- Dune's directory rules (`dirs`, `data_only_dirs`, `vendored_dirs`, `_`/`.`
  directories), `subdir`, `include`, `select`, `re_export`, `pps`,
  `ppx_runtime_libraries`, `public_name` resolution, and every comment form.
- Classification of dependency names by convention even when the library is
  generated and absent from the tree.
- `szaniec check` on the migrated DG (22 services, 145 stanzas) takes about
  30 ms.
- `szaniec complexity` with `szaniec-cognitive/1` and `szaniec-cc/1` for
  OCaml 5.4 artifacts, including Dune PPX and MLX freshness evidence.

What does not:

- `check` judges declared dependencies only. It relies on
  `(implicit_transitive_deps false)` for the guarantee that code uses
  nothing else; without it the check reports `DUNE-TRANSITIVE` and the
  remaining findings are incomplete by definition.
- Use-case rules (one Client path calling two Managers, queued fan-out) and
  method-level contract checks of the old call-graph checker are gone; dune
  edges cannot express them.
- Libraries in vendored directories are not read; dependencies on them are
  judged by their names alone.
- OCaml-syntax dune files (`(* -*- tuareg -*- *)`) are rejected (exit 2).
- `complexity` needs compiler artifacts of OCaml 5.4.x. The PPX-trust and
  MLX-receipt behaviours are kept but their dedicated acceptance suites were
  removed with the call-graph pipeline; only the action-preprocessor case is
  still covered by tests.

## Check architecture

```sh
szaniec check            # current directory
szaniec check path/to/project --json
```

Exit status: `0` conforming, `1` violations, `2` usage error, unreadable or
unparseable input (nothing on stdout; `szaniec: path:line:col: message` on
stderr).

Example text output:

```text
szaniec check (well-ocaml): violations
  5 services, 14 service libraries, 3 local libraries, 1 root, 1 test

ID-MANAGER-MANAGER (1)
  lib/billing/dune:3:13: Manager billing_manager depends on contract order_manager_contract of Manager OrderManager
  How to fix:
    Managers never call each other synchronously: a sideways call couples
    use cases and signals functional decomposition. …

1 finding(s) in ID-MANAGER-MANAGER 1
```

How names map to components (first match wins):

| Library name | Component | Role |
|---|---|---|
| `*_root` | composition root (exempt) | — |
| `<svc>` (e.g. `ai_access` for `AIAccess.cyrograf`) | service implementation | service's |
| `<svc>_contract`, `<svc>_browser` | callable contract | service's |
| `<svc>_spec`, `<svc>_wire` | server surface, transport adapter | service's |
| `<svc>_<anything>` (e.g. `security_api`) | facet of the service | service's |
| anything else | local component | from its suffix |
| `executable`, `test` stanzas | root, test (exempt) | — |

A service is a `.cyrograf` file declaring `rpc` methods. Roles come from the
name suffix: `manager`, `client`, `engine`, `access`, otherwise Utility.
Clients call Managers; Managers call Engines and ResourceAccess; Engines call
ResourceAccess; everyone may use Utilities; nobody calls sideways or up.
Other services are reached only through `_contract`, `_browser` or a facet.

The [rule catalog](docs/contracts/rule-catalog.md) lists every rule, the
library profile and the coaching. The JSON report (`szaniec-check/2`) is
specified in the [check contract](docs/contracts/check-contract.md).

## Inspect function complexity

```sh
szaniec complexity --rebuild                     # dune build, then measure lib/
szaniec complexity --rebuild --build "make build" --root lib \
  --metric cognitive --json --sort complexity    # what DG runs
szaniec complexity --root lib --root test --sort complexity
```

Options: `--project-root <dir>` (default: current directory), `--rebuild`
(run the build first), `--build <command>` (shell command, default
`dune build`), `--root <dir>` (repeatable, default `lib`), `--json`,
`--sort location|complexity`, `--metric cognitive|cyclomatic`. There is no
configuration file.

```ocaml
let increment x = x + 1                         (* complexity 0 *)
let absolute x = if x < 0 then -x else x         (* complexity 2 *)
let sign x =                                     (* complexity 3 *)
  if x < 0 then -1 else if x = 0 then 0 else 1
```

Exit status: `0` when every in-scope file was measured, `2` when anything is
stale, missing, unreadable, unmeasurable or the build failed. There is no
threshold; DG enforces its own limit on the JSON. The report no longer
carries `service`, `ownership`, `binding` or policy fields. See the
[metric specification](docs/contracts/complexity-metric.md).

## Build and run

On Linux with `well`, Dune, Deno 2, `make` and `patchelf`:

```sh
make build                # well build + bundle + launcher in _release/
make install              # link ~/.local/bin/szaniec to _release/szaniec
dune exec szaniec -- check test/fixtures/check/conforming
```

`make build` calls `well build` (Dune compilation, shared-library
discovery, bundling, `patchelf`), adds a POSIX launcher, verifies the
relocated bundle against a smoke project and writes a development archive
with a SHA-256 checksum to `dist/`. Dune resolves OCaml 5.4.1 and the
dependencies through the checked-in `dune.lock`; the first build needs
network access. The build host needs glibc 2.33 or newer for the bundled
loader's `--argv0` option.

```text
_release/
  szaniec           # launcher; preserves the current directory
  README.md
  bin/szaniec       # Well-packaged ELF executable
  bin/lib/          # bundled loader and shared libraries, including glibc
```

Use `_release/szaniec` (or the installed link) rather than `bin/szaniec`
from arbitrary directories. Keep the checkout and its `_release` directory
in place after `make install`.

## Linux releases

Publishing a GitHub Release runs [Linux release](.github/workflows/release.yml)
on native x86_64 and aarch64 runners and uploads
`szaniec-<tag>-linux-<arch>.tar.gz` with a `.sha256` file. To package
locally without publishing: `make release VERSION=v0.1.0`.

```sh
release_tag=v0.1.0  # replace with an available release tag
release_arch=x86_64 # aarch64 on ARM64 Linux
archive="szaniec-${release_tag}-linux-${release_arch}.tar.gz"
gh release download "$release_tag" --repo finalclass/szaniec \
  --pattern "$archive" --pattern "$archive.sha256"
sha256sum --check "$archive.sha256"
mkdir -p "$HOME/.local/share/szaniec/$release_tag" "$HOME/.local/bin"
tar xzf "$archive" -C "$HOME/.local/share/szaniec/$release_tag"
ln -sfn "$HOME/.local/share/szaniec/$release_tag/szaniec" "$HOME/.local/bin/szaniec"
```

## Verification and reference documents

```sh
make verify
```

runs the ocamlformat check, `deno fmt`/`deno check`, the check suite
(`test/check/run.ts`, fixture projects in `test/fixtures/check`) and the
complexity suites (`test/complexity/run.ts`, `test/complexity/fixture.ts`
over `test/fixtures/complexity-app`). The complexity suites build temporary
dune projects and take several minutes.

- [ARCHITECTURE.md](ARCHITECTURE.md) — components and permitted calls.
- [IMPLEMENTATION.md](IMPLEMENTATION.md) — scope and acceptance scenarios.
- [Check contract](docs/contracts/check-contract.md),
  [rule catalog](docs/contracts/rule-catalog.md),
  [complexity metric](docs/contracts/complexity-metric.md).
- Decisions: [dune structural enforcement](docs/decisions/dune-structural-enforcement.md),
  [stack](docs/decisions/stack.md),
  [Cognitive Complexity](docs/decisions/cognitive-complexity.md),
  [complexity performance](docs/decisions/complexity-performance.md),
  [PPX rewriter trust](docs/decisions/ppx-rewriter-trust.md),
  [transformation receipt scope](docs/decisions/transformation-receipt-scope.md).
