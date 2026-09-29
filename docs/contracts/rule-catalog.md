# Contract: rule catalog

Catalog version: `szaniec-rules/1.0.0`.

Every rule has a stable identifier, a precondition, an evidence
requirement, and an outcome. Rules evaluate the interpretation model
against the resolved policy. Rules never look at source code; they use
interactions, ownership and gaps. A rule that cannot get its required
evidence stays silent (the gap diagnostics cover the failure), except
where stated.

## Structural rules

### `ID-CLIENT-ACCESS`
- Precondition: `service-request` interaction from an owner whose role is
  `client` to an owner whose role is `access`.
- Evidence: resolved contract module of the target, call sites, helper
  path from the boundary origin to the call.
- Outcome: violation. The helper path is reported; the direct caller and
  the original boundary origin are both participants' evidence.

### `ID-ENGINE-ENGINE`
- Precondition: `service-request` interaction between two owners whose
  role is `engine` (either direction).
- Evidence: resolved target contract and call site.
- Outcome: violation.

### `ID-ACCESS-OUTBOUND`
- Precondition: `service-request` interaction from an owner whose role is
  `access` to any other service (self excluded).
- Evidence: resolved target contract and call site.
- Outcome: violation.

## Project-policy rules

### `POLICY-UNAPPROVED-CALL`
- Precondition: `service-request` interaction from owner A to owner B,
  A ≠ B, and edge (A, B) is absent from `approvedCalls`.
- Evidence: call sites with helper paths.
- Outcome: violation. A layer-correct dependency can still be unapproved;
  layer rules and this rule are independent and may both fire.

### `IMPL-ACCESS-CROSS-SERVICE`
- Precondition: `implementation-access` interaction (call or value
  reference into another service's implementation module outside
  registration patterns).
- Evidence: call/reference sites, target module, both owners.
- Outcome: violation.

### `SHARED-UNAPPROVED`
- Precondition: an executable module is consumed by calls from more than
  one boundary and is not a contract of any service, not declared in
  `approvedSharedModules`, and not external.
- Evidence: consumer list with call sites, module canonical path.
- Outcome: violation naming the module and all consumers.

### `RESOURCE-BOUNDARY`
- Precondition: `resource-access` interaction from an owner not listed in
  the resource's `accessors`.
- Evidence: resource name, API path, call site.
- Outcome: violation. Approving a library (e.g. SQL/SQLite) does not
  permit non-accessors to use its resource APIs.

### `POLICY-UNCLASSIFIED`
- Precondition: an in-scope, non-generated unit has no ownership class.
- Evidence: unit canonical path and source path.
- Outcome: violation. No silent exclusion of unowned code.

## Gap diagnostics

| Identifier | Condition | Effect |
|---|---|---|
| `GAP-UNOBSERVED-SOURCE` | in-scope source file without artifact | exit 2 |
| `GAP-STALE-ARTIFACT` | artifact digest ≠ source digest | exit 2 |
| `GAP-UNSUPPORTED-COMPILER` | artifact compiler series outside adapter support | exit 2 |
| `GAP-ARTIFACT-READ` | artifact unreadable | exit 2 |
| `GAP-UNRESOLVED-CALL` | dynamic callee in in-scope application code | exit 2 |
| `GAP-UNSUPPORTED-CONSTRUCT` | construct the adapter cannot follow | exit 2 |
| `GAP-AMBIGUOUS-OWNERSHIP` | declared module name matches several units | exit 2 |
| `GAP-POLICY-NOT-APPROVED` | policy content ≠ approved digest | exit 2 |
| `GAP-PROFILE-UNSUPPORTED` | policy requests an unknown profile | exit 2 |

Gap rules require no policy approval: they report limits of analysis.
Violations and gaps coexist in one report; gaps force exit 2.

## Deliberately absent from this catalog

- Queued-command, publish/subscribe and use-case rules (adapter
  capabilities not verified in this profile).
- Any role or ownership inference from file/class names.
- Volatility/decomposition quality judgments.