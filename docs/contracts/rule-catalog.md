# Contract: rule catalog

Catalog version: `szaniec-rules/3.0.0`.

Rules evaluate the interpretation model against the service roles and
the policy. There is no permitted-calls list: conformance follows the
structural IDesign rules (the don'ts) and closed-architecture layering.
See [the decision record](../decisions/donts-based-rules.md).

## Layer model

Roles: Client, Manager, Engine, Access, Utility (inferred from name
suffixes). Ownership classes: contract of service, implementation of
service, composition root, external library, unclassified.

Allowed synchronous request/response edges between boundaries:

- Client → Manager, Client → Utility, Client → Client.
- Manager → Engine, Manager → Access, Manager → Utility.
- Engine → Access, Engine → Utility, Engine → Manager (activity
  delegation stays within the business layer's direction).
- Utility → any (the utilities bar is cross-cutting infrastructure).
- Access → Utility, Access → resource APIs.

A synchronous Manager → Manager call is not in this list. Manager →
Manager delegation is a queued command, defined with the queue rules
below. Everything else between service boundaries is a violation by
one of the rules below. The evaluator matches every role pair; it has
no silent default.

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

### `ID-MANAGER-CLIENT`
- Don't: closed architecture. A Manager does not call back into a Client.
- Precondition: `service-request` from a Manager-role owner to a
  Client-role service, including a call reached through a same-boundary
  helper or a supported proxy.
- Evidence: call sites and the helper path from the boundary origin.
- Outcome: violation.

### `ID-ENGINE-CLIENT`
- Don't: closed architecture. An Engine does not call a Client.
- Precondition: `service-request` from an Engine-role owner to a
  Client-role service, including helpers and supported proxies.
- Outcome: violation.

### `ID-ACCESS-CLIENT`
- Don't: closed architecture. An Access service does not call a Client.
- Precondition: `service-request` from an Access-role owner to a
  Client-role service, including helpers and supported proxies.
- Outcome: violation.

### `ID-MANAGER-MANAGER`
- Don't: Managers do not call each other synchronously. Delegation to
  another Manager is a queued command.
- Precondition: `service-request` from a Manager-role owner to a
  different Manager-role service.
- Outcome: violation. A `queued-command` whose resolved target is a
  single Manager is not this rule.

## Use-case rules

Path evidence is the executable alternatives of one boundary entry.
`if` and `match` arms are different alternatives. A call sequenced
after a branch sits on every alternative that reaches it. Resolved
helpers inside the same boundary are inlined; a call into another
boundary stops the walk. `Client -> Manager -> Access` stays two
interactions and is not a Client use-case that called Access.

An entry is a value with no caller in the same boundary. When a
function's alternatives cannot be built (more than 48 alternatives,
a `try`/`with` whose body and handler both call, or recursive helper
inlining), the function contributes `GAP-AMBIGUOUS-PATH` and these
rules do not fire for it.

### `UC-CLIENT-MULTI-MANAGER`
- Don't: a Client performs one use case through one Manager.
- Precondition: one executable alternative of a Client entry reaches
  two or more distinct Manager services by `service-request`.
- Evidence: both call sites and the helper path.
- Outcome: violation. Separate entries and mutually exclusive arms do
  not combine.

## Queue rules

A queued command is a call to `Well.request` only. Its targets are the
services that subscribe to the same topic. See the interpretation
contract for the topic identity. The command is not a publication and
not a synchronous service request.

### `Q-MULTI-MANAGER`
- Don't: one executable path does not fan out queued commands to
  several Managers.
- Precondition: one alternative targets two or more distinct Manager
  services, either by several `Well.request` calls or by one request
  whose topic has several Manager subscribers.
- Outcome: violation. Mutually exclusive arms stay distinct. The same
  path cap and gap as `UC-CLIENT-MULTI-MANAGER` apply.

### `Q-TARGET-ROLE`
- Don't: a queued command is addressed to a Manager, not to an Engine
  or an Access service.
- Precondition: a resolved queued-command target whose role is Engine
  or Access.
- Evidence: the request site and the subscriber.
- Outcome: violation.

## Event rules

A publication is `Well.publish`, `Well.publish_keyed` or
`Well.MessageBus.publish`. A subscription is `Well.subscribe`,
`Well.subscribe_keyed`, `Well.MessageBus.subscribe` or
`Well.MessageBus.once`. Neither becomes a `service-request` from the
publisher to a subscriber.

### `EVT-PUBLISH-ROLE`
- Don't: only Managers publish.
- Precondition: a publication whose performing owner is not a Manager.
  Engines, Access services (the resource layer), Clients, Utilities
  and every other owner are included.
- Outcome: violation.

### `EVT-SUBSCRIBE-ROLE`
- Don't: only Clients and Managers subscribe. Engines, Access
  services, Utilities and resources do not.
- Precondition: a subscription whose performing owner is not a Client
  and not a Manager.
- Outcome: violation.

## Project-policy rules

### `IMPL-ACCESS-CROSS-SERVICE`
- Precondition: `implementation-access` interaction (call or value
  reference into another service's implementation module outside
  registration patterns).
- Outcome: violation.

### `SHARED-UNAPPROVED`
- Precondition: an in-scope unit is consumed by calls from more than one
  boundary, is not a contract of any service, not declared in
  `approvedSharedModules`, and not role-Unclassified-owned by a single
  boundary.
- Evidence: consumer list with call sites, module canonical path.
- Outcome: violation naming the module and all consumers.

### `RESOURCE-BOUNDARY`
- Precondition: `resource-access` interaction whose performing unit is
  not an Access-role service, not a Utility-role service, and not an
  approved shared module.
- Evidence: resource name, API path, call site.
- Outcome: violation. Framework library approval never grants resource
  access.

### `POLICY-UNCLASSIFIED`
- Precondition: an in-scope, non-generated unit has no ownership class
  and is not listed in `approvedSharedModules`. A unit whose artifact
  was not read (stale, missing or unsupported) is not judged here:
  missing evidence is not an unowned unit.
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
| `GAP-AMBIGUOUS-OWNERSHIP` | declared module name matches several units | exit 2 |
| `GAP-POLICY-NOT-APPROVED` | policy content ≠ approved digest | exit 2 |
| `GAP-PROFILE-UNSUPPORTED` | policy requests an unknown profile | exit 2 |
| `GAP-AMBIGUOUS-PATH` | executable alternatives for a function cannot be built (width cap, mixed `try`/`with`, or recursive inlining) | exit 2 |
| `GAP-UNRESOLVED-TARGET` | `Well.request` topic is not a resolved value or string literal, or no subscriber of that topic was observed | exit 2 |

Gap rules require no policy approval: they report limits of analysis.
Violations and gaps coexist in one report; gaps force exit 2.
`GAP-UNRESOLVED-CALL` still covers a callee that is itself unresolved;
it is not used to guess a queue or event kind.

## Deliberately absent from this catalog

- Any role or ownership inference beyond the accepted name-suffix rule.
- Volatility/decomposition quality judgments.
- Treating `Well.Service.cast`, `Well.replay` or a shared transport
  library as a queued command, a publication or a subscription. Those
  calls stay external calls.