# Contract: interpretation (Well adapter)

## Owned public surfaces

The Well adapter distinguishes service contracts from data contracts. Source
pairs, recognized generator provenance, and the approved declarations in
[the policy contract](policy-format.md#public-contracts) bind generated units.
`contract data` ownership carries the source contract identity without
inventing a Utility service. Pure compiler-observed alias
aggregators of public contracts inherit contract-data ownership. An aggregator
with executable values does not receive this exemption.

Calls to declared message `make`/codec members are data use, including nested
messages, nested `Storage` conversions, and server/browser projections. Fresh
generator-marked units also expose their generated message modules without
requiring a separate policy declaration. RPC calls (including `Proxy.method`)
are service requests; unknown members of generator-marked service contracts
remain checked against their RPC declarations. Other members of contract units
remain implementation access across families, and their bodies are inspected.
Generated RPC dispatch is excluded from application call analysis. Message
conversion bodies, including private `encode_value`/`decode_value` helpers,
retain inspection for private calls, callbacks and protected resources.
Application extraction gaps and stale evidence are preserved.

The generated serialization runtime has private contract-data ownership when a
fresh bound message's serializer references the observed `Drut_runtime` in the
same compilation library and source directory, and the runtime defines the
supported primitive and Syntax surface. This combines compiler identity,
contract provenance and shape evidence; a runtime filename or helper spelling
alone is insufficient. Supported runtime dependencies from those serializer
bodies are mechanical data operations. Their calls and module references remain
in ProgramAccess. Direct application access to runtime members or private
serializer helpers remains implementation access. Runtime bodies retain checks
for foreign private dependencies and resources. No shared whitelist entry is
required or inferred.
Data-contract and runtime ownership does not declare a Utility service or grant
its resource permission. Resource performers must be declared Access/Utility
services or explicitly approved infrastructure under the existing structural rule.
Locally bound callback/recursion targets inside the supported runtime primitives
remain raw unresolved compiler facts without becoming unknown application calls.
Other unresolved calls, including unsupported expressions inside serializers,
retain their gaps.

An unavailable contract target or alias aggregator records an unresolved-target
gap for calls and callbacks; it does not establish foreign implementation access.
Missing bindings for unmarked prefixed projections explain the required approved
`policy.contract_bindings` declaration. Names alone never approve their members.

An approved in-process facet grants access only to exact declared values and
consumers. Its implementation body is still analyzed in the owning service;
public declarations cannot hide private dependencies or resource access.
Foreign consumers or undeclared members produce implementation access.

Acceptance uses a redistributable, compiled fixture with several service
families, a data-only Common contract, native/browser bindings, nested aliases,
prefixed modules and an owned server API with an `.mli`. With an empty shared
whitelist, valid data/codec/API use passes and repeated reports are identical.
Controlled private Store and lock access (including aliases/callbacks), generic
helper sharing, extra executable aggregator values, an undeclared API member,
an unlisted consumer, unrelated initialization references beside registration,
edited policy, stale artifacts, missing members and
ambiguous ownership retain violations or gaps. Browser RPC calls retain layer
checks. Data-only contracts are absent from the service graph.

Format identifier (conceptual): `szaniec-interpretation/4`.

The InterpretationEngine binds observed code to architectural boundaries
and interprets interactions. It consumes the observation, the resolved
policy, and evidence it derives from registration calls in the code
itself. It does not read the repository and does not call ProgramAccess.

First delivery contains one framework adapter: `szaniec-well-adapter/3.4.0`
for Well applications, plus the boundary binding. The recognized
messaging surface is the public Well API recorded by the tasks-app
fixture (Well revision `5c573753367f10d7226f5eaedf1adbeacab2c09d`).

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
| Generated binding | a fresh source header is `(* Generated by Well. Do not edit. *)` or `(* Generated by Cyrograf. Do not edit. *)`, and its compilation-unit name matches a declared service, optionally prefixed with `App_service_`. The unit is that service's contract surface, including server/browser variants. Conflicting family evidence remains a gap; a prefixed wrapper without recognized provenance or independent ownership evidence records `GAP-AMBIGUOUS-OWNERSHIP`. |

Nested modules inside one compilation unit share that unit's family.
They are not separate owners.

When these sources name different families, or one directory name
matches several services, the unit is not classified and the
interpretation records `GAP-AMBIGUOUS-OWNERSHIP`. Missing or stale
artifacts are not read as an empty consumer set.
An ambiguously owned unit retains its code facts and gap; its own calls do
not establish service interactions. Calls into it retain an unresolved-target
gap instead of guessing a contract or implementation boundary.

## Ownership binding

Services come from cyrograf contract files (ArchitectureAccess). Every
in-scope, non-generated unit is classified exactly once:

| Class | Source |
|---|---|
| `contract of service S` | a fresh source pair or approved generated binding connects the unit to S's `.cyrograf` contract |
| `contract data` | a data-only contract binding or a pure alias aggregator of contract modules |
| `contract data` (private serialization runtime) | fresh sibling runtime with the supported primitive/Syntax surface and compiler-observed use by a proven message serializer; direct application access remains private |
| `implementation of service S` | source layout, compiler evidence or the canonical path binds the unit to S, and it is not S's contract surface. Private helpers in that directory tree use this class |
| `composition root` | unit calling `Well.Service.register`/`register_drut`/`expose` |
| `external library` | `Well.*` (framework knowledge) and any target not observed in the build tree |
| `helper of M` | an unclassified compilation unit whose only observed callers are that same unit. A single foreign caller does not create this class and does not adopt the unit |
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
  validated against the service's declared rpc methods or exact approved
  in-process facet. The caller-side
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
  in policy `policy.resources[].api_prefixes`; carries the resource name.
- `registration` — composition-root wiring: `Well.Service.register
  M.spec`, and references to implementation values passed to route
  registration calls (`Well.get`, `Well.post`, `Well.live`) or exposed
  (`Well.Service.expose`). Registrations produce no conformance
  interactions by themselves. Only the values actually passed as resolved
  arguments to those APIs receive the wiring exception; other references in
  the same initialization function remain ordinary implementation access.
- `external-call` — call into an external library unit. Recorded for
  evidence; library approval does not grant resource access.
- `queued-command` — a call to `Well.request`. The topic is the
  canonical path of the `~cmd` argument (`path:<canonical>`), or a
  string literal when the argument is a literal. Targets are the
  owners of observed `subscription` interactions on that same topic,
  one interaction per target service. `Well.request` is not a
  publication. A topic that is not a resolved path or literal, or a
  topic with no subscriber, is `GAP-UNRESOLVED-TARGET` and carries no
  target.
- `publication` — a call to `Well.publish`, `Well.publish_keyed` or
  `Well.MessageBus.publish`. The topic is recorded. Subscribers of
  that topic are not request targets and are not command targets.
- `subscription` — a call to `Well.subscribe`, `Well.subscribe_keyed`,
  `Well.MessageBus.subscribe` or `Well.MessageBus.once`. The topic is
  the first unlabeled topic value or channel literal.

No other call is given queue or event meaning. `Well.Service.cast`,
`Well.replay`, `Well.MessageBus.replay` and `Well.topic` stay
`external-call`. A locally bound function that happens to be one of
the APIs above is `GAP-UNRESOLVED-CALL`, not a guessed kind.

## Repetition projection

`executionInteractions` projects the observation's separate invocation graph.
Each interaction retains its originating definition, owner and execution
context: terminal call site, helper evidence path, `loops`, `activations`, and
`unknownReasons`. The conformance interaction list and executable alternatives
remain unchanged. InspectionManager combines the projection with existing
edges in [the graph contract](inspection-contract.md#call-network-artifact-szaniecjson).

The adapter follows compiler-resolved functions inside one boundary and stops
at service, resource or external calls. Declared RPCs are independent origins
even when another local function calls them. Module initializers and functions
with no local callers are additional possible origins; this is static evidence,
not proof that every origin runs. Recursion cycles retain `recursion` loop
context. Traversal is bounded at depth 64 and 4096 visited states per origin;
a truncated path produces an unresolved edge with an explicit unknown reason.

Compiler-observed `for`/`while` regions are loops. Eager callback APIs recognized
under the exact resolved `Stdlib.List` and `Stdlib.Array` paths add `iterator`
regions: iteration, maps, folds, filters, partitions, searches, predicates,
sorting, merging and `init`. Callback positions are API-specific (`init` uses
position 1; these other APIs use position 0). User modules named `List` or
`Array` do not receive these semantics. Known partial applications of local
functions defer execution until invoked; unknown execution phases stay explicit.
The resolved `Stdlib.@@` and `Stdlib.|>` operators invoke their function argument
once; composing an iterator through them preserves its callback loop context.

`Well.every` adds `periodic` activation context. `Well.subscribe`,
`Well.subscribe_keyed`, and `Well.MessageBus.subscribe` add `subscription`
activation context; `Well.get`, `Well.post`, and `Well.live` add handler activation
context. `Well.MessageBus.once` invokes its callback without a repetition
annotation. `Stdlib.ignore` does not invoke function arguments. Other callback
APIs retain possible callback paths with unknown invocation semantics. Activation
context stops at the next service boundary, whose methods are separate origins.
Starting an independent activation resets loops around its registration; loops
inside the callback are retained. The registration call itself keeps its original
loop evidence.

Only function-valued arguments are callback candidates. Dynamic targets and
unsupported callback expressions retain unknown evidence. Neither this projection
nor an empty loop list changes a conformance finding or proves a runtime count.
Policy rules and TOML exemptions for repetition are outside this delivery.

## Ordered flow projection

InterpretationEngine projects ordered execution evidence using the existing
ownership, interaction, suppression, and callback rules. It expands private
helpers at their invocation positions and stops at real service boundaries.
Each service method and non-RPC entry point retains its own flow; calls
reference target methods instead of flattening their bodies into the caller.
Branch, loop, exit, and unknown structure survives projection. Repeated
occurrences are not deduplicated. Framework mechanics may be suppressed,
but relevant application execution and unknown evidence remain visible.
InspectionManager assembles these flows with the call network;
CheckClient serializes them according to the
[inspection contract](inspection-contract.md#ordered-execution-flow).

## Suppression rules (framework-generated mechanics)

- Calls and unresolved calls inside recognized generated members are
  framework mechanics, as defined under Owned public surfaces above.
- Calls from a service implementation to its own contract module
  (`make_spec`) are binding evidence, not interactions.
- Contract module aliases and message-module references are public data
  dependencies. A private nested Store module is not a message module.
  Contract targets come from the resolved compilation-unit owner, including
  nested message and storage modules and aliases. An application implementation
  helper named `to_drut` retains ordinary implementation-access semantics.
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
  (recognized generated members and external units excluded). Blocks verification of
  rules that need the call's target.
- `GAP-UNSUPPORTED-CONSTRUCT` — constructs the adapter cannot follow
  inside in-scope code: object method calls (`Texp_send`), first-class
  module unpacks, and functor applications. The construct is a gap, not
  a resolved dependency.
- `GAP-AMBIGUOUS-OWNERSHIP` — source layout and compiler evidence name
  different families, or one directory name matches several services.
- `GAP-PUBLIC-CONTRACT` — an approved generated binding or owned public
  facet lacks a consistent source, owner, member or fresh compiler evidence.

Interpretation output is deterministic: interactions and gaps are sorted
by participants and site locations before evaluation.
