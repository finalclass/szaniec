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
