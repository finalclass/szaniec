# Contract: interpretation (Well adapter)

Format identifier (conceptual): `szaniec-interpretation/1`.

The InterpretationEngine binds observed code to architectural boundaries
and interprets interactions. It consumes the observation, the resolved
policy, and evidence it derives from registration calls in the code
itself. It does not read the repository and does not call ProgramAccess.

First delivery contains one framework adapter: `szaniec-well-adapter/2.1.0`
for Well applications, plus the boundary binding.

## Service family

A service family is one service's contract surface together with the
implementation units that belong to that service. Private helpers,
nested directories and nested OCaml modules are inside the family only
when the compilation unit that contains them is.

Membership is decided from the source layout and from compiler-resolved
evidence. A unit is never adopted into a family because exactly one
boundary calls it. A directory or module named `Shared`, `Common`,
`Utils` or any other name without a role suffix is not approved
infrastructure and is not a member of every family.

| Evidence | Binding |
|---|---|
| Source layout | the nearest directory of the source path whose name matches one service stem (case-insensitive, underscores ignored), including nested directories. A directory whose name ends with `client` and matches no service stem is an implicit client family; the family name is that directory spelled as an OCaml module (`web_client` → `Web_client`). |
| Compiler evidence | the unit calls `make_spec` on a service contract, or its `spec` value is what a composition root registers |
| Canonical path | a path segment matches a service stem, an `impl` suffix of that stem, or an implicit client segment |

Nested modules inside one compilation unit share that unit's family.
They are not separate owners.

When these sources name different families, or one directory name
matches several services, the unit is not classified and the
interpretation records `GAP-AMBIGUOUS-OWNERSHIP`. Missing or stale
artifacts are not read as an empty consumer set.

## Ownership binding

Services come from cyrograf contract files (ArchitectureAccess). Every
in-scope, non-generated unit is classified exactly once:

| Class | Source |
|---|---|
| `contract of service S` | the canonical path lies on S's contract surface (a segment matches S's stem) and the source path is not inside S's implementation directory |
| `implementation of service S` | source layout, compiler evidence or the canonical path binds the unit to S, and it is not S's contract surface. Private helpers in that directory tree use this class |
| `composition root` | unit calling `Well.Service.register`/`register_drut`/`expose` |
| `external library` | `Well.*` (framework knowledge) and any target not observed in the build tree |
| `unclassified` | everything else, including a repository-local module that no family evidence binds |

A separate Dune library under a program root is observed. It is not an
external library merely because it is a different compilation unit or
because its public name changed. Targets absent from the build tree
(the standard library and other packages) stay external.

Code without a family is a `POLICY-UNCLASSIFIED` finding, except a unit
whose artifact was not read and a unit already reported as
`GAP-AMBIGUOUS-OWNERSHIP`. An approved shared module (see the policy
contract) is the ownership exception for infrastructure the architect
selected.

Registration evidence gathered from code, reported but not trusted above
the policy:

- `C.make_spec (module I)` called inside a unit, where `C` is a contract
  module of service `S` per policy → binds the unit as an implementation
  of `S`.
- `Well.Service.register M.spec` in a composition root → registration of
  `M` as an implementation.
When this evidence names a different family from the source layout or
the canonical path, the unit stays unclassified and
`GAP-AMBIGUOUS-OWNERSHIP` is recorded. The evidence is not ranked above
the source layout by guessing.

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
- `implementation-access` — call, resolved alias, or value reference
  (including a function value passed as a callback) into another
  family's implementation, or into an unclassified repository-local
  module. Registration patterns below are not implementation access.
  One consumer is enough: the access leaves the caller's family.
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
- Calls within one family (helpers, nested modules, own contract
  proxies for self-dispatch) produce no cross-boundary interactions;
  they remain in the helper path evidence.
- A structure-level module alias (`module Alias = Path`) is resolved to
  `Path` before the interaction is recorded. The finding names the
  resolved owners. A first-class module unpack or a functor application
  is not followed.

## Gaps

- `GAP-UNRESOLVED-CALL` — application of a locally bound variable, record
  field, or other dynamic callee inside in-scope application code
  (contract modules and external units excluded). Blocks verification of
  rules that need the call's target.
- `GAP-UNSUPPORTED-CONSTRUCT` — constructs the adapter cannot follow
  inside in-scope code: object method calls (`Texp_send`), first-class
  module unpacks, and functor applications. The construct is a gap, not
  a resolved dependency.
- `GAP-AMBIGUOUS-OWNERSHIP` — source layout and compiler evidence name
  different families, or one directory name matches several services.

Interpretation output is deterministic: interactions and gaps are sorted
by participants and site locations before evaluation.