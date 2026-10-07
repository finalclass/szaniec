# Szaniec

**Check that an implementation respects its approved architecture.**

Szaniec is an architecture conformance checker for code written by people
and coding agents. Given a codebase and an approved architecture, it
extracts code dependencies and service interactions from compiler-typed
artifacts, then checks them against structural IDesign rules and
project-specific boundaries.

The name is Polish for a defensive earthwork: Szaniec protects established
boundaries.

## Status

**First delivery works end to end**: `szaniec check` runs against OCaml
applications built with [Well](https://github.com/finalclass/well),
extracts facts from real compiler artifacts (`.cmt`), interprets Well
service mechanics (contracts, proxies, registrations, database access),
evaluates the rule catalog, and reports deterministic text/JSON findings.

Supported profile: `well-ocaml-core` — OCaml **5.4.x** artifacts produced
by dune. `szaniec complexity` inventories every function in the declared
program roots and reports local cyclomatic complexity (`szaniec-cc/1`).
It does not apply a threshold and it does not write `szaniec.json`. See
[ARCHITECTURE.md](ARCHITECTURE.md), the contract documents under
[docs/contracts](docs/contracts) and the stack decision in
[docs/decisions/stack.md](docs/decisions/stack.md).

## Intended use

In a configured project:

```sh
szaniec approve --policy szaniec/policy.json --approval szaniec/approval.json
szaniec check   --policy szaniec/policy.json --approval szaniec/approval.json \
                --project-root . [--rebuild] [--json]
szaniec complexity --policy szaniec/policy.json \
                   [--approval szaniec/approval.json] [--project-root .] \
                   [--rebuild] [--json] [--sort location|complexity]
```

- `approve` records the approved policy identity (name + SHA-256) in the
  approval file; CI selects the policy outside the implementation patch.
- `check` reports violations, their source locations, analysis gaps, and
  the input identities (policy digest, snapshot digest, adapter and rule
  versions). Unresolved calls and stale or missing artifacts never
  produce a passing result.
- Exit status of `check`: `0` no violations and no gaps; `1` violations
  with complete analysis; `2` incomplete analysis or execution failure.
- `complexity` lists every syntactic function with its `szaniec-cc/1`
  complexity, source span, provenance, and ownership when interpretation
  has one. `--sort location` (the default) is source order; `--sort
  complexity` is descending complexity, then `id`, with unmeasurable
  definitions last. Exit status: `0` when coverage is complete, `2` when
  a file or construct could not be measured. The command never exits
  `1`. A recorded policy approval does not by itself change that status.

## Coverage

`szaniec coverage` measures an existing application scenario. It does not
change conformance rules and it does not apply a coverage threshold.

The consumer hook is one Dune backend on every in-scope library and
executable:

```lisp
(instrumentation (backend szaniec.instrumentation))
```

Ordinary `dune build` does not instrument. `szaniec coverage` adds
`--instrument-with szaniec.instrumentation` to the configured build.
An application PPX rewriter stays in its own `(preprocess (pps ...))`
stanza. A second measurement engine is composed inside this same
backend; consumers do not add another instrumentation line.

```sh
szaniec coverage --project-root . --config szaniec/coverage.json --json
```

The configuration format is `szaniec-coverage-config/1`. The machine
report is `szaniec-coverage/1`: point coverage over instrumented points,
not branch or path coverage. A function with no points is uninstrumented.
A function with points that did not run is measured and unexecuted.
CRAP is available only when a `szaniec-complexity/1` inventory
(`szaniec-cc/1`, from `szaniec complexity --json`) supplies complexity
for that function; otherwise the score is unavailable. There
is no CRAP gate. The command, the `supervise` runner, sanitized
environments, and the gap codes are specified in
[the coverage contract](docs/contracts/coverage.md).

The public fixture is `test/fixtures/coverage-app`: two application
libraries, a local ppxlib rewriter, nested and unused functions, an MLX
file, and a Deno HTTP scenario. The scenario assertions stay as they
are. `test/coverage/run.sh` checks that a normal build is not
instrumented, then that one `szaniec coverage` command builds the
instrumented server, runs those assertions, and writes the report.
It also exercises a sanitized environment, a restart, concurrent
servers, `SIGTERM` flush, `SIGKILL`, a library missing the hook, and a
source change during the run.

Verified with the locked toolchain: OCaml 5.4.1 (the compiler reports
`5.4.1+relocatable`), dune 3.24.2, and ppxlib 0.38.0. The internal
points engine is `bisect_ppx_ng` 3.0.0, because released `bisect_ppx`
2.8.3 requires ppxlib older than 0.36. That package is not part of the
consumer hook or the report. MLX is excluded unless the dune project
declares an `mlx` dialect, in which case an in-scope `.mlx` file is a
gap. Raw point files and reports stay in a temporary directory and are
not committed.

Findings examples: a Client calling an Access service (also through
helpers or supported proxies), a Client calling an Engine, an Engine
calling another Engine, a Manager, Engine or Access calling a Client,
a synchronous Manager-to-Manager call, a Client calling two Managers
on one executable path, a queued command fanning out to several
Managers or aimed at an Engine or Access service, a publication or
subscription from a role that may not use it, a service bypassing
another service's public contract, an unapproved shared module, direct
access to a protected resource by a non-accessor, a contract call that
is not a declared `rpc` method, and unclassified code. A layer-correct
call is not a violation merely because no edge list names it: allowed
calls come from the IDesign don'ts, not from a specification of
permitted edges. A queued Manager-to-Manager command is allowed.
Separate handlers and mutually exclusive branches are not one path.

Every check writes `szaniec.json` in the project root: for each service
and each declared method, the outgoing and incoming calls observed in
that run.

The checker preserves legitimate boundaries: `Client -> Manager -> Access`
is never misreported as a direct `Client -> Access` call; helpers are
followed only inside one service boundary.

Services are discovered from `.cyrograf` contract files that declare
`rpc` methods. The role of a service is the suffix of its name
(`manager`, `client`, `engine`, `access`; any other name is a utility).
A private helper belongs to a service only when its source path sits in
that service's directory tree or compiler evidence binds the unit.
One caller does not adopt an outside module. `approvedSharedModules`
is an exception only while the policy digest matches the approval.

Szaniec checks implementation conformance. It does not judge whether the
approved architecture was correctly decomposed around volatility.

## Build and verification

From the repository root (dune resolves the OCaml 5.4 toolchain and
package lock through `dune pkg`; first run needs network access):

```sh
dune pkg lock                       # resolve/verify dune.lock
dune build @all                     # build everything
dune exec ocamlformat -- --check $(git ls-files '*.ml')   # formatter check
dune build @runtest                 # unit tests, acceptance suite, complexity suite, coverage suite
test/acceptance/run.sh              # architecture and complexity acceptance, standalone
test/coverage/run.sh                # coverage fixture, standalone
```

The acceptance suite copies `test/fixtures/tasks-app` (a minimal
Well-shaped application), applies controlled source mutations per
scenario, rebuilds the fixture inside the scenario work directory, runs
`szaniec check --json` and compares the report with golden files in
`test/acceptance/expected/`. The same entry point then runs `szaniec
complexity` against the `metric/` and `test/` specimens (straight-line
code, matches, loops, recursion, exceptions, nested and anonymous
functions, an rpc method, a test-provenance definition, a stale
artifact, a source that does not type-check, and object constructs).
Expected complexities are listed in the fixture README. The fixture
uses a documented stub of the Well API surface (`lib/well_stub/`)
instead of the real framework dependency; see the fixture README.

CI (`.github/workflows/ci.yml`) runs the same commands.

## Profile exclusions

Declared exclusions of the `well-ocaml-core` profile (reported in every
check, never silently dropped): `.mlx` view files, `.mli` interfaces,
dune wrapper units, resource access beyond policy-declared API prefixes,
and calls through locally bound functions (reported as `GAP-UNRESOLVED-CALL`,
exit 2). Queued commands (`Well.request`), publications and subscriptions
are checked. A topic that cannot be resolved, or a function whose
executable paths cannot be built, is an analysis gap (exit 2), not a pass.

## Design

- [Architecture](ARCHITECTURE.md): volatility analysis, components, adapters, evidence,
  policy, and the check workflow.
- [Implementation brief](IMPLEMENTATION.md): first delivery, acceptance scenarios,
  unresolved implementation decisions, and verification expectations.
- [Contract documents](docs/contracts): policy format, observation schema,
  interpretation schema, inspection contract, rule catalog, the
  [complexity metric](docs/contracts/complexity-metric.md), and coverage.
- [Agent instructions](AGENTS.md): repository rules for an implementing agent.

The checker is a local command-line program. It needs no server or
database. IDesign-inspired checks and project-specific policy checks
remain distinguishable in diagnostics. This project is not an official
IDesign product.