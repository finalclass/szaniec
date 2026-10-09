# Implementation brief

## First delivery

Implement a local CLI that checks OCaml applications using
[Well](https://github.com/finalclass/well). Follow [ARCHITECTURE.md](ARCHITECTURE.md).
The repository currently contains design only; no implementation or passing test
suite should be assumed.

The intended command is `szaniec check`, with text and machine-readable JSON output.
Configuration syntax, options, packaging and exact contracts are still to be designed.
Do not advertise an installation command until it has been verified.

## Start with real evidence

Inspect the public Well source and a small representative Well application before
choosing an extraction approach. Record the Well revision and compiler/toolchain
versions used by the fixture. Validate how direct calls, generated proxies, service
registration and resource access actually work. A sibling Well checkout may be used
for investigation, but it must not become an undocumented build dependency.

Prefer compiler-resolved identities and typed artifacts where available. A native
OCaml helper may be appropriate for compiler integration. Do not replace semantic
resolution with name suffixes or regular expressions while claiming equivalent coverage.

Use TypeScript on Deno for new agent-authored automation and integration scripts.
The product implementation language is not fixed by this instruction: select and
document it based on compiler integration and distribution needs. Do not choose
Python or Node.js merely for convenience.

## Define before implementing

Resolve these details within the accepted architecture and record them in focused
contract documents linked from ARCHITECTURE.md:

- Policy format, approved-policy selection, ownership matching and ambiguous ownership.
- Program snapshot/build identity and normalized observation schema.
- Interpretation schema, adapter capability/version declarations and unresolved facts.
- Inspection request/result, diagnostics, deterministic ordering and profile coverage.
- First rule catalog: identifiers, preconditions, evidence requirements and outcomes.

These are implementation decisions, not permission to change the product scope or
architectural boundaries. Ordinary decisions within the accepted design can proceed;
identify a genuine contradiction before requesting an architectural decision.

## Build one complete slice

Deliver policy resolution, OCaml observation, Well interpretation, deterministic
evaluation, and CLI reporting for the initial supported profile. Preserve evidence
through the whole path. Exercise actual source extraction, not only hand-authored graphs.

The initial profile must cover:

- Direct and supported proxy calls, including calls through local helpers.
- Layer-direction violations such as Client-to-Access and Engine-to-Engine.
- Calls allowed by layer rules but absent from project policy.
- Cross-service implementation access and unapproved shared executable modules.
- Explicit unresolved-call, unsupported-adapter and unclassified-code diagnostics.

Queued-command, event and use-case rules and service-family ownership
are part of `szaniec-rules/3.1.0`.
The acceptance suite is the check that extraction and evaluation agree,
including separate handlers, mutually exclusive branches, and a gap when
a path cannot be built. Do not claim a wider messaging surface than the
interpretation contract lists.
Encountering an unsupported construct relevant to required analysis must not yield
a silent pass. Report declared exclusions and unmet requirements distinctly.

## Acceptance scenarios

Use a small valid application and controlled source mutations. Add fixture cases
for these observable behaviors:

| Scenario | Expected result |
|---|---|
| Client calls Manager, which calls Access | Pass; no transitive Client-to-Access violation |
| Client calls Access directly | Violation with call-site evidence |
| Client calls Access through a helper or supported proxy | Violation with original caller and evidence path |
| Engine calls a different Engine | Structural violation |
| A service bypasses another service's public contract | Boundary violation |
| Two services consume unapproved shared implementation | Violation naming module and consumers |
| A private helper or approved contract is reused as permitted | No false shared-implementation finding |
| A dependency is layer-correct but not approved | Project-policy violation |
| Client uses a library to access a protected resource directly | Resource-boundary violation when supported; explicit gap otherwise |
| A call target cannot be resolved | Incomplete analysis, exit 2 |
| Artifacts are stale or an adapter version is unsupported | Rebuild as configured or report incomplete analysis; never use stale evidence as current |
| The local policy is edited alongside the implementation | Continue checking against the selected approved policy |
| New in-scope code has no declared owner | Explicit diagnostic; no silent exclusion |
| Violations and analysis gaps coexist | Exit 2; retain both in the report |
| Identical inputs and versions are checked repeatedly | Identical ordered machine-readable findings |
| A service call is repeated in `for`, `while`, or a supported iterator callback | Graph context retains the loop site, API and path through local helpers |
| The same helper is called inside and outside a loop | Distinct graph contexts; ordinary paths do not inherit a different caller's loop |
| A module initializer registers recurring work with `Well.every` | Non-RPC entry point with activation context; inner loops remain separate |
| A deferred function or partial iterator is created in a loop | Definition alone does not execute its body or add a looped call |
| Callback semantics or execution traversal cannot be resolved | Explicit unknown graph evidence; existing findings and gaps remain unchanged |

When adding use-case analysis, verify separate handlers and mutually exclusive
branches do not produce false multi-Manager findings. When adding messaging, verify
commands and events remain distinct even when they share a transport library.

Keep evaluation tests independent of compiler syntax. Add adapter tests over actual
source/build fixtures and an end-to-end command test proving the evidence path.
Do not present a manually supplied graph test as proof of language support.

## Delivery requirements

- Document supported versions, capabilities, exclusions, build and check commands.
- Run the appropriate formatter, type checks and acceptance tests for the chosen stack.
- Report actual commands and outcomes; do not invent successful checks.
- Add CI using the same documented verification entry points.
- Keep fixtures minimal and redistributable, with dependencies pinned or reproducible.
- Update README status only as capabilities become executable and verified.
- Leave editor integration, incremental caches, a plugin marketplace,
  servers and databases outside this delivery. Contract-size heuristics,
  coverage targets and CRAP remain separate work. The subsequent performance
  extension accepts the local observation cache and bounded parallel path
  evaluation defined in the observation and inspection contracts; see
  [performance decisions](docs/decisions/full-program-performance.md).
  Local cyclomatic
  complexity is the `szaniec complexity` inventory (`szaniec-cc/1`); it
  is not a conformance gate.
