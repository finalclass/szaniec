# Contract: interpretation (Well adapter)

Format identifier (conceptual): `szaniec-interpretation/1`.

The InterpretationEngine binds observed code to architectural boundaries
and interprets interactions. It consumes the observation, the resolved
policy, and evidence it derives from registration calls in the code
itself. It does not read the repository and does not call ProgramAccess.

First delivery contains one framework adapter: `szaniec-well-adapter/1.0.0`
for Well applications, plus the boundary binding that applies the policy.

## Ownership binding

Every in-scope, non-generated unit is classified exactly once:

| Class | Source |
|---|---|
| `contract of service S` | policy `contractModules` |
| `implementation of service S` | policy `implementationModules` |
| `helper of service S` | policy `helperModules` |
| `composition root` | policy `compositionRoots` |
| `external library` | policy `externalLibraries[].unitPrefixes` |
| `unclassified` | everything else |

Prefix rules for external libraries use canonical path prefixes
(`Well.Db` matches `Well`, `Well.Db.Anything`). Ownership ambiguity
declared in the policy produces `GAP-AMBIGUOUS-OWNERSHIP` at
ArchitectureAccess time; here it is carried as a gap finding.

Registration evidence gathered from code, reported but not trusted above
the policy:

- `C.make_spec (module I)` called inside a unit, where `C` is a contract
  module of service `S` per policy → binds the unit as an implementation
  of `S`.
- `Well.Service.register M.spec` in a composition root → registration of
  `M` as an implementation.
A conflict between registration evidence and policy ownership produces
`GAP-AMBIGUOUS-OWNERSHIP`.

## Interaction kinds

Derived from calls and value references, with helper paths:

- `service-request` — caller boundary calls a contract module of another
  service: a request/response interaction via the public contract. The
  caller-side path through private helpers of the same boundary is
  resolved by walking the per-value call graph inside the boundary
  backwards from the contract call to boundary origins (values with no
  in-boundary callers, e.g. route handlers). Paths never cross a service
  boundary: a call into another boundary stops the walk, so legitimate
  `Client -> Manager -> Access` produces two interactions, not a
  transitive `Client -> Access` edge.
- `implementation-access` — call or value reference into another
  service's implementation module outside the registration patterns
  below.
- `resource-access` — call whose resolved callee path has a prefix listed
  in policy `resources[].apiPrefixes`; carries the resource name.
- `registration` — composition-root wiring: `Well.Service.register
  M.spec`, and references to implementation values passed to route
  registration calls (`Well.get`, `Well.post`, `Well.live`) or exposed
  (`Well.Service.expose`). Registrations produce no conformance
  interactions by themselves.
- `external-call` — call into an external library unit. Recorded for
  evidence; library approval does not grant resource access.
- `messaging` — calls to Well messaging APIs
  (`Well.subscribe_keyed`, `Well.publish_keyed`, `Well.request`) are
  recorded as evidence only. Queue and event semantics are declared
  exclusions of this profile.

## Suppression rules (framework-generated mechanics)

- Calls and unresolved calls *inside* a policy-declared contract module
  are framework proxy mechanics (the `_service_ref` dispatch in generated
  code). They produce neither interactions nor `GAP-UNRESOLVED-CALL`.
- Calls from a contract module to other contract modules (generated wire
  conversion) produce no interactions.
- Calls from a service implementation to its own contract module
  (`make_spec`) are binding evidence, not interactions.
- Calls within one boundary (helpers, own contract proxies for
  self-dispatch) produce no cross-boundary interactions; they remain in
  the helper path evidence.

## Gaps

- `GAP-UNRESOLVED-CALL` — application of a locally bound variable, record
  field, or other dynamic callee inside in-scope application code
  (contract modules and external units excluded). Blocks verification of
  rules that need the call's target.
- `GAP-UNSUPPORTED-CONSTRUCT` — constructs the adapter cannot follow
  (e.g. `Texp_send` object method calls) inside in-scope code.

Interpretation output is deterministic: interactions and gaps are sorted
by participants and site locations before evaluation.