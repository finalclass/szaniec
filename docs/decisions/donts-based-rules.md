# Decision: rules come from IDesign don'ts, roles from name suffixes

Status: accepted (supersedes parts of the original policy contract and the
first rule catalog).

## What changed

1. **Allowed calls are not a specification list anymore.** The
   `approvedCalls` list is removed from the policy. A layer-correct call
   that is absent from any list is not a violation. Conformance is judged
   solely by structural IDesign rules (the don'ts of
   `lib/contract/idesign/DESIGN-DONTS.MD` in projects that keep them,
   plus closed-architecture layering). Rationale: a permitted-edges list
   is itself a specification, and errors can creep into specifications —
   the checker must detect them, not enforce them. Rules evaluate the
   code as it is; nothing the developer writes can turn a don't into a
   don't-not.
2. **Roles are inferred from service names.** A service whose name ends
   (case-insensitively) with `manager` is a Manager; `client` → Client;
   `engine` → Engine; `access` → Access; any other name → Utility.
   Rationale: the naming convention is an explicit team contract (see the
   classification guidelines in the project's IDesign notes); the checker
   enforcing it keeps names and architecture from drifting apart. Known
   trade-off, accepted: a badly named service gets the wrong role and the
   rules will judge it under that role — which is exactly the drift the
   checker is supposed to surface.
3. **Services are discovered from cyrograf contract files.** A
   `.cyrograf` file whose stem declares `rpc` methods is a service. The
   policy no longer lists services. Implementation units bind through
   compiler-resolved evidence (`make_spec` calls on the service's
   contract module, registration calls in the composition root), not
   through lists. Composition roots are auto-detected as the units that
   call service registration.
4. **Specification errors are findings.** Calling a contract member that
   is not a declared `rpc` method and not a known generated-code mechanic
   is a `SPEC-UNDECLARED-METHOD` violation. A service declaring `rpc`
   methods that is never registered in the composition root is a
   `SPEC-UNREGISTERED-SERVICE` violation.
5. **Call network artifact.** Szaniec writes `szaniec.json`
   (`szaniec-callgraph/1`) into the checked project: per service and per
   method, the outgoing and incoming call edges with sites, resource and
   external accesses, unresolved calls and unclassified units. It is a
   deterministic projection of one check run, intended as a base for
   future diagram tooling.

## Consequences

- The policy shrinks to: program roots, approved shared modules,
  protected resources (name + API prefixes), and the policy identity.
- The "layer-correct but unapproved" acceptance scenario of the first
  brief is superseded: such a dependency produces no finding.
- Utilities (role by name or the default role for services without a
  suffix) may be called by any layer and may reach resources; they are
  the infrastructure bar.
- Resource access is attributed to the unit that performs the call. When
  a boundary reaches a resource through another boundary's helper, the
  finding names the direct caller; the helper path stays in the evidence
  chain. Attributing resource access along the whole call path is future
  work.

## Closed architecture, use cases, queues and events

Status: accepted. This section supersedes the earlier permission for
ordinary Manager → Manager calls. The rest of the suffix-role and
cyrograf-discovery decisions above stay in force.

1. **Every service-to-service direction is an explicit matrix entry.**
   A Client, Manager, Engine or Access calling a Client is a
   closed-architecture violation (`ID-MANAGER-CLIENT`,
   `ID-ENGINE-CLIENT`, `ID-ACCESS-CLIENT`), including a call that
   reaches the Client through a same-boundary helper or a supported
   proxy. Client → Client stays allowed. Utility → anyone stays
   allowed. No forbidden pair is left to a silent default match.
2. **Synchronous Manager → Manager calls are prohibited**
   (`ID-MANAGER-MANAGER`). A Manager delegates to another Manager only
   by a queued command. The previous catalog permitted the synchronous
   call; implementations must not keep that reading.
3. **One Client use-case path calls at most one Manager**
   (`UC-CLIENT-MULTI-MANAGER`). A path is one executable alternative
   from a boundary entry (a value with no same-boundary caller),
   following resolved helpers inside that boundary and stopping at the
   next service boundary. Separate handlers, and separate branches of
   `if` / `match`, are different paths. A call after a branch is on
   every path that reaches it.
4. **Queue and event kinds come only from the verified Well surface**
   named in the interpretation contract (`Well.publish`,
   `Well.publish_keyed`, `Well.MessageBus.publish`, `Well.subscribe`,
   `Well.subscribe_keyed`, `Well.MessageBus.subscribe`,
   `Well.MessageBus.once`, `Well.request`). A call merely being
   "messaging" establishes none of these kinds. `Well.request` is a
   queued command and is not a publication. Publish and subscribe are
   not service requests, and a publication is not an edge from the
   publisher to each subscriber.
5. **Queued-command targets are the services that subscribe to the
   same topic.** The topic is the canonical value passed to `~cmd`, or
   the string literal passed to `Well.MessageBus`. A missing topic or
   a topic with no observed subscriber is `GAP-UNRESOLVED-TARGET`, not
   a pass. On one executable path, queued commands may target only one
   Manager (`Q-MULTI-MANAGER`). A queued command must not target an
   Engine or an Access service (`Q-TARGET-ROLE`).
6. **Events.** Only a Manager publishes (`EVT-PUBLISH-ROLE`). Only a
   Client or a Manager subscribes (`EVT-SUBSCRIBE-ROLE`). Engines,
   Access services (the resource layer), Utilities and every other
   owner do neither. External resource APIs are not application
   publishers; the rule judges the application unit that calls the
   messaging API.
