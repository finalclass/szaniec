# Architecture

This document records the accepted architectural direction. Concrete file formats,
method signatures, and compiler integration still need implementation-level design.
The first target is OCaml and [Well](https://github.com/finalclass/well).

## Purpose

Check the current implementation against an approved architecture and a declared
profile of structural IDesign rules. Report evidence, violations, and limits of
analysis. Architectural quality and volatility discovery in the inspected project
are outside the product's scope.

Inputs are a program snapshot, a selected approved policy, and an analysis profile.
The output is a deterministic report tied to those inputs and adapter/rule versions.

## Volatility analysis

| Potential change | Reason for change | Risk without a boundary | Owning component |
|---|---|---|---|
| Invocation and presentation | Terminal, CI, editor protocols, output formats | Evaluation depends on a client protocol | CheckClient |
| Inspection workflow | Full checks, additional build targets, later reuse of evidence | Clients and adapters duplicate orchestration | InspectionManager |
| Acquisition of program facts | Language, compiler, build system, generated code, artifact formats | Toolchain details leak into rules | ProgramAccess |
| Architectural meaning of code | Framework proxy, routing, DI, queue and library conventions | Every rule must understand every framework | InterpretationEngine |
| Conformance criteria | New rules, exceptions, evidence requirements | Policy changes force extractor changes | ConformanceEngine |
| Access to approved architecture | Manifest or deterministic projection of an existing specification | Analysis depends on document storage and syntax | ArchitectureAccess |

Service lists, roles, approved edges, and library versions are input variability.
They do not justify a component per service, rule, or library. A new language adds
an adapter within an existing boundary.

The two Engines isolate independent changes: how code expresses an interaction,
and whether that interaction is allowed. A Well proxy change belongs to the former;
a sharing-policy change belongs to the latter.

## Components

These are logical components within one local program, not separately deployed services.

```static-architecture
Szaniec

Who
- [CheckClient]

What
- [InspectionManager] [SuggestionManager]

How
- [InterpretationEngine] [ConformanceEngine]

How-to-access -> Where
- [ProgramAccess]->(AnalyzedProgram)
- [ArchitectureAccess]->(ApprovedArchitecture)
- [ModelAccess]->(JudgmentProvider)
```

| Component | Responsibility | Conceptual operation |
|---|---|---|
| CheckClient | Accept a request, render text/JSON, map the result to an exit status | Run the check or the suggestion review |
| InspectionManager | Coordinate policy resolution, observation, interpretation and evaluation | Check |
| SuggestionManager | Select local candidates, apply judgment templates, compose the suggestion report | Suggest |
| ProgramAccess | Supply program facts and the function catalog while hiding compiler, build and artifact access | Observe, Catalog |
| ArchitectureAccess | Supply a consistent policy with its approved identity, and service ownership | Resolve |
| ModelAccess | Submit bounded typed questions and return typed answers | Judge |
| InterpretationEngine | Bind code to architectural boundaries and interpret interactions | Interpret |
| ConformanceEngine | Evaluate the model and policy, preserving evidence and analysis gaps | Evaluate |

CheckClient calls InspectionManager for a check and SuggestionManager for
suggestions. InspectionManager calls ProgramAccess, ArchitectureAccess, and both
Engines. SuggestionManager calls ProgramAccess, ArchitectureAccess, and
ModelAccess. It does not call either Engine. InspectionManager does not call
ModelAccess or SuggestionManager. The Engines do not call each other. Access
components do not call each other. Rendering belongs to the Client. Conformance
diagnostics stay in the inspection contract; suggestion text stays in the
suggestion contract. A suggestion run does not change check findings or the
check exit status.

## Adapters

Language/toolchain adapters live inside ProgramAccess. They extract symbol identity,
calls, implementation and type dependencies, module relationships, generated-code
provenance, and available control-flow context. They expose common facts rather than
a compiler-specific AST. They do not judge IDesign conformance.

Framework/library adapters live inside InterpretationEngine. They interpret facts
as service calls, proxy targets, DI bindings, resource access, queued commands,
publication, or subscription. They receive configuration and registration evidence
with the observation; they do not read the repository or call ProgramAccess themselves.

Start with an OCaml/toolchain adapter and a Well adapter. Each adapter declares its
version, supported constructs, and evidence capabilities. Profiles select compatible
adapters and their required capabilities. Missing evidence, unsupported versions,
and conflicting interpretations produce explicit gaps, not guessed relationships.
Built-in adapters are sufficient initially; a plugin marketplace is unnecessary.

## Evidence model

Preserve one evidence model with two views: code dependencies and architectural
interactions. The service graph is a projection, not the only retained information.

- Code elements: modules, symbols, operations, libraries, generated proxies and resources.
- Ownership: service boundary, public contract, approved infrastructure, or unclassified code.
- Code dependencies: calls, implementation references, and type/contract-only references.
  An import is not automatically a call.
- Interaction kinds: request/response, queued command, publish, subscribe and resource access.
  Asynchronous syntax alone does not establish queue semantics.
- Context: entry point, operation, known use case, conditions and possible targets where available.
- Provenance: source span, snapshot/build identity, adapter version and interpretation evidence.
  Resolved targets, possible target sets and unresolved targets are distinct.

Follow helper and proxy evidence to reveal `Client -> local helper -> Access`.
Stop collapsing the path at a real approved service boundary: legitimate
`Client -> Manager -> Access` does not imply a prohibited direct Client–Access edge.
Do not treat the transitive closure of all calls as direct architectural calls.

Keep publication, channel and subscription separate; do not turn an event into a
direct call from its publisher to each subscriber. Commands and events can use the
same transport while having different architectural meaning.

## Approved policy and code sharing

Policy defines components and roles, source/symbol ownership, public contracts,
allowed interactions, resources, and library usage. If the architecture already has
an authoritative specification, use a deterministic projection rather than another
independently maintained list. The projection format remains to be designed.

If the architecture has contract files (`.cyrograf`), services are read
from them: a contract declaring `rpc` methods is a service, and its
declared methods are its public surface. Roles are inferred from the
service name suffix (`manager`, `client`, `engine`, `access`; any other
name is a Utility) — see
[the decision record](docs/decisions/donts-based-rules.md).

New in-scope code without ownership produces a diagnostic.
Distinguish:

1. A private helper within one service: inside its boundary.
2. Another service's implementation used outside its public contract: boundary violation.
3. Shared executable code consumed by multiple services without approval: project-policy violation.
4. Approved contracts, generated code, infrastructure and external libraries: evaluate their
   declared permissions. Approving a SQL library does not permit Clients to access the database.

Shared code is not categorically forbidden. The checker enforces approved sharing
boundaries without needing to infer whether arbitrary code contains business logic.

Use an explicitly selected approved policy identity. CI selects this outside the
implementation patch; an architect selects it locally. A modified manifest in the
same patch is not automatically approved. Record the selected identity in the report.
Szaniec does not implement the organization's approval process.

## Evaluation

Evaluate both structural IDesign rules and concrete project constraints. A valid
layer direction can still be an unapproved project dependency. Managers may call
ResourceAccess; do not implement a naive rule allowing only the next numbered layer.

Rules have stable identifiers, rationale and evidence requirements. Findings retain
participants, source locations and helper paths. Potential violations from ambiguous
targets are distinct from confirmed violations.

Use-case rules require use-case boundaries and sufficient path evidence. Multiple
edges aggregated across handlers or mutually exclusive branches do not prove that
both calls execute in one use case. Insufficient evidence marks the rule unverified.

## Check workflow and results

InspectionManager resolves policy and profile, obtains current program observations,
requests interpretation, then requests evaluation. It returns the report and input
identities. The Client renders the result.

Compiler artifacts must match the source and build configuration. Rebuild according
to the selected profile or report incomplete analysis. Never silently analyze stale
artifacts. Inspect the whole declared program, including newly added build inputs;
diff-only inspection can miss changed dependencies in unchanged callers.

| Exit status | Meaning |
|---|---|
| 0 | No violations and all required evidence is available for the declared profile |
| 1 | Violations found with complete required analysis |
| 2 | Incomplete analysis or execution failure, including when violations were also found |

Retain both violations and gaps when both occur. A successful result claims only the
coverage of its declared profile. Tests and build tools have explicit scope; silently
skipping files is not an acceptable coverage strategy.

## Suggestions

`szaniec suggestions` is a separate review for narrow code-quality
judgments. The deterministic checker stays authoritative: a suggestion is
not a violation, a complexity gate, or an input to `szaniec check`.

SuggestionManager reads the function catalog and service ownership, selects
a bounded candidate set, and asks ModelAccess for one typed judgment per
selected criterion. Exact duplicate bodies are recognized locally and are
not sent to the provider. ModelAccess talks to the configured judgment
provider only for this command. Missing credentials, timeouts, and error
responses are an unavailable review, not an empty successful one. Reports
cache by snapshot, rubric, model id, budgets, and question state. The
coding agent records `apply`, `reject`, or `defer` with a rationale; the
tool does not edit the program.

The rubric, retrieval rules, experimental pilot criteria, and report shape
are the [suggestion contract](docs/contracts/suggestion-contract.md). Every
category stays experimental until a live evaluation records cost and
latency. Similar code in different service families is not a license to
introduce a shared business library.

## Contracts

Implementation-level contracts resolved under this architecture:

- [Policy format](docs/contracts/policy-format.md) — `szaniec-policy/2`, approved-policy selection, ownership matching.
- [Observation schema](docs/contracts/observation-schema.md) — program snapshot identity and normalized facts.
- [Interpretation schema](docs/contracts/interpretation-schema.md) — Well adapter evidence, interactions and suppressions.
- [Inspection contract](docs/contracts/inspection-contract.md) — CLI, report JSON, `szaniec.json` call network, determinism and exit statuses.
- [Rule catalog](docs/contracts/rule-catalog.md) — `szaniec-rules/2.0.0`, don'ts-based.
- [Suggestion contract](docs/contracts/suggestion-contract.md) — `szaniec-suggestions/1`, optional and non-blocking.
- [Stack decision](docs/decisions/stack.md) — product language, compiler coupling, investigation evidence.
- [Decision record](docs/decisions/donts-based-rules.md) — don'ts-only rules, suffix roles, cyrograf-discovered services, call network artifact.

## Basis

The approach is inspired by Juval Lowy's *Righting Software*: volatility-based
decomposition in chapter 2, and closed architecture, Utilities and Design Don'ts in
chapter 3. The component design and evidence model above are original project design
decisions. They are not a claim of official IDesign certification.
