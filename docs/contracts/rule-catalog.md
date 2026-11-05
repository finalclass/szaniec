# Rule catalog: szaniec-check/2, profile well-ocaml

The rules judge declared dune dependencies (see the
[check contract](check-contract.md)). They follow the closed architecture
and design don'ts of Juval Löwy's *Righting Software* (chapter 3). This is
not an official IDesign product. The OCaml source of truth is
`lib/conformance_engine/rule_catalog.ml` (ids and coaching) and
`lib/conformance_engine/profile.ml` (external library table);
`test/check/run.ts` fails when the coaching below differs from the binary's.

## Components and roles

Classification (first match wins) of a library name, whether or not its
stanza is in the scanned tree:

1. ends with `_root` → composition root (exempt, like executables and tests);
2. key equals a service key → service implementation;
3. `<svc>_contract`, `<svc>_browser` → callable contract; `<svc>_spec`,
   `<svc>_wire` → server surface and transport adapter (together: the
   contract family);
4. `<svc>_<anything>`, longest service prefix on `_` boundaries → facet;
5. otherwise a local component.

Service-owned libraries take the service's role; local components take the
role of their own name suffix (`manager`, `client`, `engine`, `access`,
otherwise Utility). A key is the name lowercased with non-alphanumerics
removed. A service is a `.cyrograf` file with `rpc` methods.

A **facet** is an in-process surface of a service (for example
`security_api` of `Security`). Architecture rules apply to it by the owning
service's role: other components reach it like `<svc>_contract`, and its
own dependencies are judged as that role's.

## Edge evaluation

For each dependency of a stanza:

- Roots (executables, `_root` libraries) and tests are exempt from role and
  profile rules; `DUNE-*` rules still apply.
- A dependency on a `_root` library from anything else is `ROOT-LEAK`.
- A contract-family library may depend only on its own family, local
  Utilities and external libraries (`CONTRACT-LEAK`), and may use the
  framework libraries.
- Otherwise, edges within one component (an implementation, its facets and
  its family) are allowed. An edge to another service's implementation,
  `_spec` or `_wire` is `IMPL-CROSS-SERVICE`. An edge to another service's
  `_contract`, `_browser` or facet, or to a local component, is judged by
  the role matrix:

| from \ to | Client | Manager | Engine | ResourceAccess | Utility |
|---|---|---|---|---|---|
| Client | ID-CLIENT-CLIENT | ok | ID-CLIENT-ENGINE | ID-CLIENT-ACCESS | ok |
| Manager | ID-MANAGER-CLIENT | ID-MANAGER-MANAGER | ok | ok | ok |
| Engine | ID-ENGINE-CLIENT | ID-ENGINE-MANAGER | ID-ENGINE-ENGINE | ok | ok |
| ResourceAccess | ID-ACCESS-CLIENT | ID-ACCESS-OUTBOUND | ID-ACCESS-OUTBOUND | ID-ACCESS-ACCESS | ok |
| Utility | ID-UTILITY-BUSINESS | ID-UTILITY-BUSINESS | ID-UTILITY-BUSINESS | ID-UTILITY-BUSINESS | ok |

External libraries (names in the profile table, dotted names, and names
that classify as a plain Utility) are judged by the well-ocaml profile:

| Category | Libraries | Allowed for (besides roots and tests) | Rule |
|---|---|---|---|
| framework | `well`, `well.core`, `well.cap`, `well.service`, `well.cli` | contract-family libraries | FRAMEWORK-BOUNDARY |
| resource | `sqlite3`, `well.db`, `well.net`, `well.mail`, `well.auth`, `well.ppx` | ResourceAccess, Utility | RESOURCE-BOUNDARY |
| publish | `well.publish` | Manager, Utility | EVT-PUBLISH-ROLE |
| subscribe | `well.subscribe` | Manager, Client, Utility | EVT-SUBSCRIBE-ROLE |
| presentation | `well.http`, `well.html`, `well.web` | Client, Utility | PRESENTATION-BOUNDARY |
| other | everything else (`well.rpc`, `well.runtime`, `yojson`, `eio`, …) | everyone | — |

## Rules

Each finding carries the rule id, `from` and `to` endpoints, the location
of the offending atom, a one-line message and the coaching below. Coaching
instructs the implementing agent how to change the design; it never
suggests editing dune files to silence the finding.

### DUNE-TRANSITIVE

Dune-project must disable implicit transitive dependencies.

When: Any `dune-project` in the tree lacks `(implicit_transitive_deps false)`, sets it to another value, or declares `(lang dune X)` with X < 3.17. Location: the setting's value, else the `lang` version, else 1:1.

Coaching:

> Szaniec enforces the architecture through dune: every component is its own library and the compiler may only see direct dependencies. Declare (lang dune 3.17) or newer and (implicit_transitive_deps false) in dune-project. Without it a component can reach any library its dependencies use, so every other rule is void. Then add each library a component really uses to its (libraries ...) field and let the remaining findings show where the design is wrong.

### DUNE-REEXPORT

Re_export widens a component's surface.

When: `(re_export X)` in a stanza that is not a contract-family library, or a contract-family library re-exporting anything other than its own family, a local Utility, or an external library outside the profile table.

Coaching:

> (re_export X) makes X visible to every consumer, which turns a private dependency into part of the public contract and lets callers bypass the closed architecture. Only a contract-family library may re-export, and only its own family, a Utility data library or a framework-neutral external library. Remove the re_export and let each consumer declare what it really uses; if the consumer is not allowed to depend on X, its design must change, not the export.

### DUNE-UNSUPPORTED

Construct hides or redirects dependencies.

When: `copy_files`/`copy_files#` whose source is absolute, contains `..` or a `%{...}` variable; a library with `virtual_modules`, `implements` or `default_implementation`; a `%{...}` variable in a dependency position.

Coaching:

> This dune construct compiles code or selects an implementation outside the declared (libraries ...) of a stanza, so the dependency structure Szaniec checks is no longer the one the compiler sees. Copy only files from the stanza's own directory, and replace virtual libraries (virtual_modules, implements, default_implementation) with an explicit contract library and a composition root that chooses the implementation.

### IMPL-CROSS-SERVICE

Another service is reached outside its contract.

When: A service implementation, facet or local component depends on another service's implementation library, `_spec` or `_wire`.

Coaching:

> A service is reached only through its contract library (<service>_contract, or <service>_browser from browser code). Depending on its implementation, server surface (_spec) or transport adapter (_wire) couples you to how it works instead of what it promises, and defeats encapsulation of its volatility. Depend on the service's _contract library and call the operation it declares; if the operation you need is missing, add it to the .cyrograf contract as a coarse-grained business operation, not as a pass-through of the internal function. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### CONTRACT-LEAK

Contract family depends on implementation.

When: A contract-family library (`_contract`, `_browser`, `_spec`, `_wire`) depends on a project library that is neither in its own family nor a local Utility (including its own implementation and facets).

Coaching:

> A contract describes what a service does, never how. A contract, browser, spec or wire library may depend only on its own family, Utility data libraries and external libraries. A dependency on an implementation, on another service or on a business component leaks that component into every caller. Move the shared data types into a Utility data library (or into the contract itself) and keep behaviour in the implementation library. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-CLIENT-CLIENT

Client calls another Client.

When: Client → Client.

Coaching:

> Clients never call each other. Each Client is an entry point for its own audience and volatility; a Client calling a Client chains presentation concerns and hides a use case. Put the shared use case behind a Manager contract that both Clients call, and share pure presentation helpers only through a Utility. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-CLIENT-ENGINE

Client calls an Engine.

When: Client → Engine.

Coaching:

> Clients enter the business layer only through a Manager. Calling an Engine directly moves use-case orchestration into the Client and bypasses the Manager that owns the workflow. Add the operation to a Manager contract; the Manager calls the Engine. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-CLIENT-ACCESS

Client calls ResourceAccess.

When: Client → ResourceAccess.

Coaching:

> Clients enter the business layer only through a Manager. Calling ResourceAccess directly skips the use case and couples the Client to atomic business verbs and resources. Add the operation to a Manager contract; the Manager composes the ResourceAccess calls. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-MANAGER-MANAGER

Manager calls another Manager synchronously.

When: Manager → Manager.

Coaching:

> Managers never call each other synchronously: a sideways call couples use cases and signals functional decomposition. If the other Manager must act as a consequence, queue a command to it through the queue Utility or publish an event; if both need the same activity, that activity is an Engine or ResourceAccess shared by both - extract it. Never move it into a Utility to dodge the rule. Do not edit dune files to silence this.

### ID-MANAGER-CLIENT

Manager calls a Client.

When: Manager → Client.

Coaching:

> Don't call up. A Manager serves Clients and must not know them; a call up into the Client layer indicates the need for queuing or pub/sub. Return data to the caller, or publish an event the Client subscribes to. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-ENGINE-ENGINE

Engine calls another Engine.

When: Engine → Engine.

Coaching:

> Engines never call each other; the Manager orchestrates them. An Engine encapsulates one volatile activity; chaining Engines hard-codes a workflow inside the business logic. Return the result to the Manager and let the Manager call the next Engine. If two Engines share an algorithm, that is either one Engine or a Utility with no business knowledge. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-ENGINE-MANAGER

Engine calls a Manager.

When: Engine → Manager.

Coaching:

> Don't call up. An Engine serves its Manager; a call up indicates the need for queuing or pub/sub. Return data to the caller, or publish an event through the Manager's workflow. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-ENGINE-CLIENT

Engine calls a Client.

When: Engine → Client.

Coaching:

> Don't call up. Engines never depend on presentation; a call up indicates the need for queuing or pub/sub. Return data to the Manager, which returns it to the Client. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-ACCESS-ACCESS

ResourceAccess calls another ResourceAccess.

When: ResourceAccess → ResourceAccess.

Coaching:

> ResourceAccess services never call each other; atomic business verbs are composed by the Manager. Return the data to the Manager and let it call the other ResourceAccess. If both need the same resource helper, put it in a Utility with no business knowledge. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-ACCESS-OUTBOUND

ResourceAccess calls a Manager or Engine.

When: ResourceAccess → Manager or Engine.

Coaching:

> Don't call up. ResourceAccess exposes atomic business verbs over a resource and is called by Managers and Engines; a call up indicates the need for queuing or pub/sub. Return data to the caller instead. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-ACCESS-CLIENT

ResourceAccess calls a Client.

When: ResourceAccess → Client.

Coaching:

> Don't call up. ResourceAccess never depends on presentation; a call up indicates the need for queuing or pub/sub. Return data to the caller instead. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ID-UTILITY-BUSINESS

Utility depends on a business component.

When: Utility → Manager, Engine, ResourceAccess or Client.

Coaching:

> Utilities are infrastructure any layer may use - the 'cappuccino machine' test: it could serve any system - and must not depend on business components (Managers, Engines, ResourceAccess, Clients). Invert the dependency: the business component calls the Utility and passes the data it needs. If the code really encodes business rules, it is not a Utility; make it an Engine or ResourceAccess and name it accordingly. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### ROOT-LEAK

Component depends on the composition root.

When: A library that is not a composition root depends on a `_root` library. Executables, tests and other `_root` libraries may.

Coaching:

> The composition root wires services: it links implementations, specs and wires and chooses which implementation serves each contract. Components must never reach back into it - that would make every component depend on the whole system. Only executables, tests and other _root libraries may depend on a _root library. Depend on the contract of the service you need instead, and let the root pass it in. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### FRAMEWORK-BOUNDARY

Component uses the full framework.

When: A framework library (`well`, `well.core`, `well.cap`, `well.service`, `well.cli`) used by anything other than a root, test or contract-family library.

Coaching:

> Only the composition root wires services and may use the full framework (registry, dispatch by name, process wiring); contract libraries may use the framework surface generated code needs. A service implementation receives its collaborators through their contracts and implements its own spec; it never looks services up by name. Move the wiring into the executable that composes the system. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### RESOURCE-BOUNDARY

Component touches a resource directly.

When: A resource library (`sqlite3`, `well.db`, `well.net`, `well.mail`, `well.auth`, pps `well.ppx`) used by anything other than ResourceAccess, a Utility, a root or a test.

Coaching:

> Only ResourceAccess (and infrastructure Utilities) touch resources such as the database, network, mail or authentication store. Get the data through a ResourceAccess contract that exposes atomic business verbs, not CRUD over the resource. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### EVT-PUBLISH-ROLE

Event published outside a Manager.

When: `well.publish` used by anything other than a Manager, a Utility, a root or a test.

Coaching:

> Only Managers publish events: an event is a fact about a use case. Return the data to the Manager that runs the use case and let it publish. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### EVT-SUBSCRIBE-ROLE

Event subscription outside a Manager or Client.

When: `well.subscribe` used by anything other than a Manager, a Client, a Utility, a root or a test.

Coaching:

> Only Managers and Clients subscribe to events. Engines and ResourceAccess are called by Managers; if they must react to an event, the subscribing Manager calls them. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.

### PRESENTATION-BOUNDARY

Presentation outside a Client.

When: `well.http`, `well.html` or `well.web` used by anything other than a Client, a Utility, a root or a test.

Coaching:

> HTTP, HTML and web rendering belong to Clients. Business components return data; the Client presents it. Move the rendering into the Client and return structured data from the Manager. Do not edit dune files, rename libraries or move code into a Utility just to silence this finding; change the design.
