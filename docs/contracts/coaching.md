# Contract: diagnostic coaching

Catalog identifier: `szaniec-coaching/1`.

`check` findings and `suggestions` include local, deterministic repair guidance.
The existing diagnostic is the trigger. Coaching does not discover a finding,
judge a repair, edit code, call a provider, or approve architecture. The
complexity inventory remains a measurement without a threshold; complexity
coaching is triggered by the existing `complicated-construct` suggestion.

## Rationale

A numeric target can reward moving complexity rather than making an operation
easier to understand. Pairing the concrete diagnostic with repair intent and
misleading examples gives the coding agent relevant guidance at the point of
action. This follows the approach demonstrated in
[Emily Bache's Habit Hooks interview](https://coding-is-like-cooking.info/2026/08/how-to-stop-ai-from-ruining-your-codebase/).

The catalog is compiled into the existing CheckClient rather than adding a
provider call or a new architectural component. Guide changes are presentation
changes independent of compiler acquisition, conformance criteria and model
judgments. Ownership-specific reuse guides protect the project's approved
service boundaries. The [published prompt evaluation](https://github.com/LiinaSuoniemi/prompt-vs-metric-eval)
is motivation for evaluating this approach locally, not evidence that it
improves refactoring in OCaml or in Szaniec consumers.

## Ownership and presentation

CheckClient owns the catalog, selection, and text/JSON presentation.
SuggestionManager returns judgments and suggestions without presentation logic.
The inspection and suggestion contracts retain diagnostic meaning. No additional
component or permitted call is introduced.

Every finding, suggestion, and suggestion-catalog gap has an additive `coaching`
JSON field: a guide object, or `null` for an unknown identifier. Unknown
diagnostics remain visible with their original severity and evidence. Uncertain
judgments, categories not run, unavailable-provider details, and clean reports
do not acquire repair suggestions.

```json
{
  "catalog": "szaniec-coaching/1",
  "id": "client-business-entry",
  "intent": "Keep presentation separate from business workflow and resource access.",
  "steps": [
    "Trace the reported call and helper path to the Client entry point.",
    "Route the use case through the appropriate existing Manager contract; keep workflow and resource access behind their approved boundaries."
  ],
  "avoid": [
    "A Client-local wrapper around the same forbidden call, a renamed service, or a new pass-through Manager only to silence the rule."
  ],
  "example": {
    "before": "Client -> helper -> Access",
    "after": "Client -> existing Manager use case -> Access"
  },
  "verification": [
    "Run the affected behavior tests and szaniec check --rebuild; inspect the original call path and retain every remaining gap."
  ]
}
```

Arrays are ordered and non-empty. Examples illustrate a transformation; they
are not executable patches or claims about the inspected program. All text is
English. Content or selection changes require a new catalog identifier.
Report formats remain `szaniec-report/1` and `szaniec-suggestions/1` with existing
fields unchanged. Text places the guide after its first trigger and prints each
guide id once per report; every repeated diagnostic, location, evidence path,
and decision remains present. JSON includes the full guide on every item.
`check --summary` remains one line with its existing counts and status.

## Inspection catalog

The [rule catalog](rule-catalog.md) defines allowed interactions. Guide wording
must explain the intent, concrete repair steps, misleading fixes to avoid, an
illustrative before/after transformation, and verification within that policy.

| Diagnostic identifiers | Guide id | Required repair guidance |
|---|---|---|
| `ID-CLIENT-ACCESS`, `ID-CLIENT-ENGINE` | `client-business-entry` | Route the use case through its existing Manager; avoid wrappers, renaming roles, and pass-through services |
| `ID-ENGINE-ENGINE` | `engine-isolation` | Let the owning Manager compose independent activities; avoid hiding the call in a helper or Utility |
| `ID-ACCESS-ACCESS` | `atomic-access` | Keep the atomic resource operation in its owning Access; avoid shared resource implementation helpers |
| `ID-ACCESS-OUTBOUND` | `access-direction` | Move workflow/rule decisions above Access; avoid callbacks retaining the upward dependency |
| `ID-MANAGER-CLIENT`, `ID-ENGINE-CLIENT`, `ID-ACCESS-CLIENT` | `client-boundary` | Return data through the contract and render in Client; avoid aliases to Client implementation |
| `ID-MANAGER-MANAGER` | `manager-delegation` | Review the synchronous result requirement before approved queued delegation; do not change request semantics to silence the rule |
| `UC-CLIENT-MULTI-MANAGER` | `single-use-case` | Put the use-case sequence in its owning Manager; preserve independent alternatives and avoid Client helper orchestration |
| `Q-TARGET-ROLE` | `queue-target` | Direct the command to its owning Manager; avoid renaming an Engine or substituting an event for a command |
| `Q-MULTI-MANAGER` | `queue-fanout` | Give a command one resolved Manager target; preserve required consumers and distinguish events |
| `EVT-PUBLISH-ROLE` | `event-publication` | Publish from the owning Manager; avoid Utility wrappers disguising publication |
| `EVT-SUBSCRIBE-ROLE` | `event-subscription` | Receive in Client or Manager and delegate permitted work; move the actual subscriber responsibility |
| `IMPL-ACCESS-CROSS-SERVICE` | `public-contract` | Use the appropriate approved public contract; avoid aliases or whitelisting business implementation |
| `SHARED-UNAPPROVED` | `owned-sharing` | Establish responsibility and ownership before private reuse or separately reviewed infrastructure; duplication does not authorize `Common`, `Shared`, or `Utils` |
| `RESOURCE-BOUNDARY` | `resource-access` | Put the operation behind an authorized Access contract; library approval is not resource permission |
| `POLICY-UNCLASSIFIED` | `implementation-ownership` | Place code in its correct existing family or obtain a deliberate ownership decision; avoid excluding sources or blanket sharing approval |
| `SPEC-UNDECLARED-METHOD` | `declared-method` | Use the declared contract or request a genuine contract change; avoid adding RPC declarations just to pass |
| `SPEC-UNREGISTERED-SERVICE` | `service-registration` | Bind and mount the service in the composition root; avoid deleting its contract to conceal missing registration |
| `GAP-BUILD`, `GAP-UNOBSERVED-SOURCE`, `GAP-STALE-ARTIFACT`, `GAP-MISSING-INPUT`, `GAP-UNVERIFIABLE-TRANSFORMATION`, `GAP-INCOMPLETE-ARTIFACT`, `GAP-ARTIFACT-READ` | `fresh-artifacts` | Diagnose the named failure and acquire complete fresh artifacts through `check --rebuild`; avoid touching files, forging receipts, stale reuse, or source exclusions |
| `GAP-SOURCE-MAPPING` | `source-mapping` | Restore authored mappings in the supported transformation; never guess locations |
| `GAP-UNSUPPORTED-COMPILER`, `GAP-PROFILE-UNSUPPORTED`, `GAP-UNSUPPORTED-CONSTRUCT`, `GAP-UNRESOLVED-CALL`, `GAP-CALLBACK-SEMANTICS`, `GAP-RETURNED-CLOSURE`, `GAP-AMBIGUOUS-PATH`, `GAP-UNRESOLVED-TARGET`, `GAP-UNMEASURABLE` | `supported-evidence` | Identify the missing capability or target and acquire supported evidence or retain the limitation; never invent targets/order or turn unknown evidence into success |
| `GAP-POLICY-NOT-APPROVED` | `approved-policy` | Compare against the selected approved architecture and use deliberate review; never approve automatically on every check |
| `GAP-AMBIGUOUS-OWNERSHIP`, `GAP-LOCAL-SERVICE`, `GAP-PUBLIC-CONTRACT` | `ownership-evidence` | Resolve conflicting/missing bindings and review declaration changes; never choose a convenient owner or treat a directory name as approval |

Inspection verification requires affected behavior tests and a fresh full check.
Gap verification requires acquisition of the missing evidence and a full rerun;
unsuccessful acquisition retains the incomplete result. Approval guidance never
contains an unconditional `approve` command.

## Suggestion catalog

Guides retain the experimental status and decision workflow of the
[suggestion contract](suggestion-contract.md). `apply`, `reject`, and `defer`
record decisions rather than prove successful refactoring.

| Criterion / ownership relation | Guide id | Required repair guidance |
|---|---|---|
| `name-quality` | `meaningful-name` | Name observed intent and update uses; avoid longer meaningless names or invented intent |
| `exact-duplicate`, `semantic-reuse` / `same-service` | `reuse-within-service` | Compare behavior and callers, then reuse a coherent private operation inside the service; avoid merging distinct behaviors through mode flags |
| `exact-duplicate`, `semantic-reuse` / `distinct-services` | `reuse-across-services` | Compare responsibilities and reasons for change; retain separate implementations unless an approved contract owns the behavior; avoid a shared business library just to remove duplication |
| `exact-duplicate`, `semantic-reuse` / any other relation | `reuse-needs-ownership` | Resolve ownership first; unknown ownership or one observed caller cannot authorize reuse |
| `responsibility-mix` | `cohesive-responsibility` | Explain intent in one sentence, separate unrelated concerns within the owner, preserve the contract; avoid arbitrary cuts and crossing service boundaries |
| `complicated-construct` | `readable-control-flow` | Simplify redundant decisions/nesting and extract meaningful operations; avoid identical branches moved into `function2`, compressed syntax, or using a lower score as proof |
| `vocabulary-consistency` | `consistent-vocabulary` | Align names for the same local concept after examining uses; avoid imposing global vocabulary without context |
| `predicate-clarity` | `clear-predicate` | Align predicate and branches with a clear boolean meaning while preserving truth conditions |
| `unexpected-effects` | `explicit-effects` | Expose the actual effect in the name/contract or separate it within the owner; avoid harmless-looking wrappers |
| `mode-flags` | `coherent-operations` | Separate unrelated operations and retain legitimate options; avoid opaque parameter bags |
| `comment-mismatch` | `accurate-comment` | Remove redundant comments or reconcile explanations with approved behavior; do not change behavior to match a stale comment |
| `unnecessary-indirection` | `useful-abstraction` | Remove forwarding only when no approved boundary or adaptation is lost; retain public contracts |
| `idiomatic-alternative` | `suitable-idiom` | Verify the supplied API's semantics; avoid invented APIs or cleverness at the expense of clarity |
| catalog gap `GAP-SUGGESTION-NO-SOURCE` | `available-source` | Restore the fresh catalog's source slice; never synthesize bodies or interpret skipped review as no issue |

Suggestion verification uses affected behavior tests, a full architecture check
after edits, and another suggestion review when available. Semantic equivalence
remains a hypothesis until verified. Guides add no model questions and do not
alter cache identity or provider accounting.

## Acceptance coverage

- Every catalog rule/category selects a complete guide; unknown identifiers
  select `null` without deleting diagnostics. Reuse selects the ownership variant,
  including ambiguous and missing ownership.
- Text deduplicates guides while retaining every diagnostic, location, path and
  decision. JSON attaches the matching full guide to each item. Uncertain,
  unavailable and empty reviews gain no fabricated suggestions.
- A compiled Client-to-Access fixture gets the guide and retains exit 1. Mixed
  violation/gap results retain exit 2; clean results retain exit 0. Summary output
  remains one line. Repeated identical runs produce identical reports.
- Suggestion fixture goldens retain judgments, decisions, ownership, provider,
  cache and check behavior with the additive guides.
- A relocated Linux bundle renders a guide without repository files, Deno,
  provider credentials, or external guide assets.

Run `make verify` for formatting and acceptance, including coaching renderer
and CLI checks, and `make build` for packaging. These verify delivery behavior;
improved agent refactoring quality requires a separate behavioral evaluation.

## Recorded delivery verification

The following commands completed successfully for this delivery:

- `dune build @test/coaching/runtest bin/szaniec.exe` — complete guides,
  ownership variants, unknown identifiers, retained decisions, uncertain
  judgments, text deduplication and deterministic JSON.
- `deno check scripts/release.ts test/coaching/run.ts` — packaging and CLI
  acceptance script type checks.
- `make verify` — formatting, unit tests and the complete source, contract,
  complexity, suggestion, performance and coverage acceptance suites.
- `make build` — Well packaging, bundled libraries, launcher, archive/checksum
  and the relocated bundle's approval-gap guide in JSON.

All 55 existing golden reports were compared with the parent revision after
removing only the additive `coaching` fields; their original facts were identical.
Every one of the 38 diagnostics documented in the rule catalog selected a guide.
No live provider or agent-refactoring quality evaluation was performed.
