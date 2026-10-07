# Contract: rule catalog

Catalog version: `szaniec-rules/2.1.0`.

Rules evaluate the interpretation model against the service roles and
the policy. There is no permitted-calls list: conformance follows the
structural IDesign rules (the don'ts) and closed-architecture layering.
See [the decision record](../decisions/donts-based-rules.md).

## Layer model

Roles: Client, Manager, Engine, Access, Utility (inferred from name
suffixes). Ownership classes: contract of service, implementation of
service, composition root, external library, unclassified.

Allowed request/response edges between boundaries:

- Client → Manager, Client → Utility, Client → Client.
- Manager → Manager, Manager → Engine, Manager → Access, Manager →
  Utility.
- Engine → Access, Engine → Utility, Engine → Manager (activity
  delegation stays within the business layer's direction).
- Utility → any (the utilities bar is cross-cutting infrastructure).
- Access → Utility, Access → resource APIs.

Everything else between service boundaries is a violation by one of the
rules below.

## Structural rules

### `ID-CLIENT-ACCESS`
- Don't: clients reach the business layer only through Managers
  (closed architecture; a Client calling an Access pulls the resource
  layer into presentation).
- Precondition: `service-request` interaction from a Client-role owner
  to an Access-role service.
- Evidence: call sites with the helper path from the boundary origin.
- Outcome: violation.

### `ID-CLIENT-ENGINE`
- Don't: clients must not call Engines (the only entry points to the
  business layer are Managers).
- Precondition: `service-request` interaction from a Client-role owner
  to an Engine-role service.
- Outcome: violation.

### `ID-ENGINE-ENGINE`
- Don't: engines never call each other.
- Precondition: `service-request` interaction between two Engine-role
  services.
- Outcome: violation.

### `ID-ACCESS-ACCESS`
- Don't: ResourceAccess services never call each other (an atomic
  business verb cannot require another; the join belongs in one
  service).
- Precondition: `service-request` interaction between two Access-role
  services.
- Outcome: violation.

### `ID-ACCESS-OUTBOUND`
- Don't: Access services work for the layers above them; calls from an
  Access service to a Manager or an Engine are upward calls.
- Precondition: `service-request` interaction from an Access-role
  service to a Manager- or Engine-role service.
- Outcome: violation.

## Project-policy rules

### `IMPL-ACCESS-CROSS-SERVICE`
- Precondition: `implementation-access` interaction. The target is
  another family's implementation, or an unclassified repository-local
  module. Calls, resolved aliases, value references and callbacks all
  count. A single consumer is enough. The target is not an approved
  shared module of the approved policy, and the reference is not a
  registration pattern.
- Evidence: both owners (the caller's family and the target service or
  module), source sites, and the helper or alias path.
- Outcome: violation.

### `SHARED-UNAPPROVED`
- Precondition: an unclassified in-scope unit is reached by executable
  dependencies from more than one family. Executable dependencies are
  calls, resolved aliases, value references and callbacks. Type-only
  references do not count. The unit is not a contract, not an external
  library, and not an approved shared module of the approved policy.
  A module owned by one family is that family's implementation; another
  family's use of it is `IMPL-ACCESS-CROSS-SERVICE`, not this rule.
- Evidence: the shared module, the distinct consumer families, the
  source sites, and the reference paths.
- Outcome: violation naming the module and all consumers.
- An unread artifact is not an empty consumer set. Confirmed accesses
  from units that were read stay in the report; the observation gap
  keeps the result at exit 2.

### `RESOURCE-BOUNDARY`
- Precondition: `resource-access` interaction whose performing boundary
  is not an Access-role service, not a Utility-role service, and not an
  approved shared module of the approved policy.
- Evidence: resource name, API path, call site.
- Outcome: violation. Framework library approval never grants resource
  access.

### `POLICY-UNCLASSIFIED`
- Precondition: an in-scope, non-generated unit has no ownership class
  and is not an approved shared module of the approved policy. A unit
  whose artifact was not read (stale, missing or unsupported) is not
  judged here. A unit already reported as `GAP-AMBIGUOUS-OWNERSHIP` is
  not judged here either: ambiguous evidence is not "no owner".
- Outcome: violation. No silent exclusion of unowned code.

## Specification rules

### `SPEC-UNDECLARED-METHOD`
- Precondition: a call resolves into a service's contract surface, the
  final member name is not a known generated-code mechanic, and the name
  is not among the `rpc` methods declared in the service's cyrograf
  contract.
- Outcome: violation — the code disagrees with the specification.
  (Mechanic allowlist: `make_spec`, `spec`, `_service_ref`, `make`,
  `to_wire`, `of_wire`, `to_data`, `from_data`, `to_drut`, `from_drut`,
  `wire_of_storage`, `storage_of_wire`, `to_storage_value`,
  `from_storage_value`.)

### `SPEC-UNREGISTERED-SERVICE`
- Precondition: a cyrograf service declares `rpc` methods but no unit
  binds its implementation (no `make_spec` call on its contract) or the
  bound spec is never registered in a composition root. Not reported
  when an artifact was stale, missing or unreadable: the registration
  may sit in a unit that was not read.
- Outcome: violation — the specification declares a service the program
  does not mount.

## Gap diagnostics

| Identifier | Condition | Effect |
|---|---|---|
| `GAP-UNOBSERVED-SOURCE` | in-scope source file without artifact | exit 2 |
| `GAP-STALE-ARTIFACT` | artifact older than its source and no verified rebuild | exit 2 |
| `GAP-UNSUPPORTED-COMPILER` | artifact compiler series outside adapter support | exit 2 |
| `GAP-ARTIFACT-READ` | artifact unreadable | exit 2 |
| `GAP-UNRESOLVED-CALL` | dynamic callee in in-scope application code | exit 2 |
| `GAP-UNSUPPORTED-CONSTRUCT` | construct the adapter cannot follow | exit 2 |
| `GAP-AMBIGUOUS-OWNERSHIP` | family evidence disagrees, or one directory name matches several services | exit 2 |
| `GAP-POLICY-NOT-APPROVED` | policy content ≠ approved digest | exit 2 |
| `GAP-PROFILE-UNSUPPORTED` | policy requests an unknown profile | exit 2 |

Gap rules require no policy approval: they report limits of analysis.
Violations and gaps coexist in one report; gaps force exit 2.

## Deliberately absent from this catalog

- Client-calls-multiple-managers-per-use-case, queue/event rules
  (require use-case and messaging adapter capabilities; exclusions are
  declared).
- Any role or ownership inference beyond the accepted name-suffix rule.
- Volatility/decomposition quality judgments.