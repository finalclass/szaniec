# Contract: interpretation (Well adapter)

Format identifier (conceptual): `szaniec-interpretation/1`.

The InterpretationEngine binds observed code to architectural boundaries
and interprets interactions. It consumes the observation, the resolved
policy, and evidence it derives from registration calls in the code
itself. It does not read the repository and does not call ProgramAccess.

First delivery contains one framework adapter: `szaniec-well-adapter/2.0.0`
for Well applications, plus the boundary binding.

## Ownership binding

Services come from cyrograf contract files (ArchitectureAccess). Every
in-scope, non-generated unit is classified exactly once:

| Class | Source |
|---|---|
| `contract of service S` | unit whose canonical path lies on S's contract surface: a segment equals the service stem (case-insensitive) or ends with `_` + stem, and the unit is not under the application library prefix (`App.`) |
| `implementation of service S` | unit under the application library whose canonical path carries S's stem segment, or which calls `make_spec` on S's contract module |
| `composition root` | unit calling `Well.Service.register`/`register_drut`/`expose` |
| `external library` | `Well.*` (framework knowledge) and any target not observed in the build tree |
| `unclassified` | everything else |

Client families: a canonical segment ending with `client`
(case-insensitive) makes the unit part of an implicit Client boundary
named by that segment. Units are never classified by their own file
names beyond these rules; code without ownership is a
`POLICY-UNCLASSIFIED` finding.

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
  service: a request/response interaction via the public contract,
  carrying the called method name (the final member of the callee path)
  validated against the service's declared rpc methods. The caller-side
  path through private helpers of the same boundary is resolved by
  walking the per-value call graph inside the boundary from boundary
  origins (values with no in-boundary callers, e.g. route handlers).
  Paths never cross a service boundary: a call into another boundary
  stops the walk, so legitimate `Client -> Manager -> Access` produces
  two interactions, not a transitive `Client -> Access` edge.
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
- Generated-code mechanic members of contract units (wire codecs, `make`,
  `spec`, `_service_ref` and friends — see the rule catalog) produce no
  interactions; calls to any other contract member are checked against
  the declared rpc methods.
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