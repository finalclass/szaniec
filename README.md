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
by dune. See [ARCHITECTURE.md](ARCHITECTURE.md), the contract documents
under [docs/contracts](docs/contracts) and the stack decision in
[docs/decisions/stack.md](docs/decisions/stack.md).

## Intended use

In a configured project:

```sh
szaniec approve --policy szaniec/policy.json --approval szaniec/approval.json
szaniec check   --policy szaniec/policy.json --approval szaniec/approval.json \
                --project-root . [--rebuild] [--json]
```

- `approve` records the approved policy identity (name + SHA-256) in the
  approval file; CI selects the policy outside the implementation patch.
- `check` reports violations, their source locations, analysis gaps, and
  the input identities (policy digest, snapshot digest, adapter and rule
  versions). Unresolved calls and stale or missing artifacts never
  produce a passing result.
- Exit status: `0` no violations and no gaps; `1` violations with
  complete analysis; `2` incomplete analysis or execution failure.

Findings examples: a Client calling an Access service (also through
helpers or supported proxies), a Client calling an Engine, an Engine
calling another Engine, a service bypassing another service's public
contract, an unapproved shared module, direct access to a protected
resource by a non-accessor, a contract call that is not a declared
`rpc` method, and unclassified code. A layer-correct call is not a
violation merely because no edge list names it: allowed calls come
from the IDesign don'ts, not from a specification of permitted edges.

Every check writes `szaniec.json` in the project root: for each service
and each declared method, the outgoing and incoming calls observed in
that run.

The checker preserves legitimate boundaries: `Client -> Manager -> Access`
is never misreported as a direct `Client -> Access` call; helpers are
followed only inside one service boundary.

Services are discovered from `.cyrograf` contract files that declare
`rpc` methods. The role of a service is the suffix of its name
(`manager`, `client`, `engine`, `access`; any other name is a utility).

Szaniec checks implementation conformance. It does not judge whether the
approved architecture was correctly decomposed around volatility.

## Build and verification

From the repository root (dune resolves the OCaml 5.4 toolchain and
package lock through `dune pkg`; first run needs network access):

```sh
dune pkg lock                       # resolve/verify dune.lock
dune build @all                     # build everything
dune exec ocamlformat -- --check $(git ls-files '*.ml')   # formatter check
dune build @runtest                 # unit gate test + acceptance suite (13 scenarios)
test/acceptance/run.sh              # same suite, standalone entry point
```

The acceptance suite copies `test/fixtures/tasks-app` (a minimal
Well-shaped application), applies controlled source mutations per
scenario, rebuilds the fixture inside the scenario work directory, runs
`szaniec check --json` and compares the report with golden files in
`test/acceptance/expected/`. The fixture uses a documented stub of the
Well API surface (`lib/well_stub/`) instead of the real framework
dependency; see the fixture README.

CI (`.github/workflows/ci.yml`) runs the same commands.

## Profile exclusions

Declared exclusions of the `well-ocaml-core` profile (reported in every
check, never silently dropped): `.mlx` view files, `.mli` interfaces,
dune wrapper units, queued-command/publish/subscribe and use-case rules,
resource access beyond policy-declared API prefixes, and calls through
locally bound functions (reported as `GAP-UNRESOLVED-CALL`, exit 2).

## Design

- [Architecture](ARCHITECTURE.md): volatility analysis, components, adapters, evidence,
  policy, and the check workflow.
- [Implementation brief](IMPLEMENTATION.md): first delivery, acceptance scenarios,
  unresolved implementation decisions, and verification expectations.
- [Contract documents](docs/contracts): policy format, observation schema,
  interpretation schema, inspection contract, rule catalog.
- [Agent instructions](AGENTS.md): repository rules for an implementing agent.

The checker is a local command-line program. It needs no server or
database. IDesign-inspired checks and project-specific policy checks
remain distinguishable in diagnostics. This project is not an official
IDesign product.