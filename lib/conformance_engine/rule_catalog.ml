(* Rule catalog: stable rule identifiers, titles and the coaching given to
   the implementing agent. Coaching follows Juval Löwy's "Righting
   Software" (IDesign closed architecture and design don'ts). Mirrors
   docs/contracts/rule-catalog.md; keep both in sync. *)

type rule =
  { id: string
  ; title: string
  ; coaching: string }

let no_silencing =
  " Do not edit dune files, rename libraries or move code into a Utility just \
   to silence this finding; change the design."

let rules =
  [ { id= "DUNE-TRANSITIVE"
    ; title= "dune-project must disable implicit transitive dependencies"
    ; coaching=
        "Szaniec enforces the architecture through dune: every component is \
         its own library and the compiler may only see direct dependencies. \
         Declare (lang dune 3.17) or newer and (implicit_transitive_deps \
         false) in dune-project. Without it a component can reach any library \
         its dependencies use, so every other rule is void. Then add each \
         library a component really uses to its (libraries ...) field and let \
         the remaining findings show where the design is wrong." }
  ; { id= "DUNE-REEXPORT"
    ; title= "re_export widens a component's surface"
    ; coaching=
        "(re_export X) makes X visible to every consumer, which turns a \
         private dependency into part of the public contract and lets callers \
         bypass the closed architecture. Only a contract-family library may \
         re-export, and only its own family, a Utility data library or a \
         framework-neutral external library. Remove the re_export and let each \
         consumer declare what it really uses; if the consumer is not allowed \
         to depend on X, its design must change, not the export." }
  ; { id= "DUNE-UNSUPPORTED"
    ; title= "construct hides or redirects dependencies"
    ; coaching=
        "This dune construct compiles code or selects an implementation \
         outside the declared (libraries ...) of a stanza, so the dependency \
         structure Szaniec checks is no longer the one the compiler sees. Copy \
         only files from the stanza's own directory, and replace virtual \
         libraries (virtual_modules, implements, default_implementation) with \
         an explicit contract library and a composition root that chooses the \
         implementation." }
  ; { id= "IMPL-CROSS-SERVICE"
    ; title= "another service is reached outside its contract"
    ; coaching=
        "A service is reached only through its contract library \
         (<service>_contract, or <service>_browser from browser code). \
         Depending on its implementation, server surface (_spec) or transport \
         adapter (_wire) couples you to how it works instead of what it \
         promises, and defeats encapsulation of its volatility. Depend on the \
         service's _contract library and call the operation it declares; if \
         the operation you need is missing, add it to the .cyrograf contract \
         as a coarse-grained business operation, not as a pass-through of the \
         internal function."
        ^ no_silencing }
  ; { id= "CONTRACT-LEAK"
    ; title= "contract family depends on implementation"
    ; coaching=
        "A contract describes what a service does, never how. A contract, \
         browser, spec or wire library may depend only on its own family, \
         Utility data libraries and external libraries. A dependency on an \
         implementation, on another service or on a business component leaks \
         that component into every caller. Move the shared data types into a \
         Utility data library (or into the contract itself) and keep behaviour \
         in the implementation library."
        ^ no_silencing }
  ; { id= "ID-CLIENT-CLIENT"
    ; title= "Client calls another Client"
    ; coaching=
        "Clients never call each other. Each Client is an entry point for its \
         own audience and volatility; a Client calling a Client chains \
         presentation concerns and hides a use case. Put the shared use case \
         behind a Manager contract that both Clients call, and share pure \
         presentation helpers only through a Utility."
        ^ no_silencing }
  ; { id= "ID-CLIENT-ENGINE"
    ; title= "Client calls an Engine"
    ; coaching=
        "Clients enter the business layer only through a Manager. Calling an \
         Engine directly moves use-case orchestration into the Client and \
         bypasses the Manager that owns the workflow. Add the operation to a \
         Manager contract; the Manager calls the Engine."
        ^ no_silencing }
  ; { id= "ID-CLIENT-ACCESS"
    ; title= "Client calls ResourceAccess"
    ; coaching=
        "Clients enter the business layer only through a Manager. Calling \
         ResourceAccess directly skips the use case and couples the Client to \
         atomic business verbs and resources. Add the operation to a Manager \
         contract; the Manager composes the ResourceAccess calls."
        ^ no_silencing }
  ; { id= "ID-MANAGER-MANAGER"
    ; title= "Manager calls another Manager synchronously"
    ; coaching=
        "Managers never call each other synchronously: a sideways call couples \
         use cases and signals functional decomposition. If the other Manager \
         must act as a consequence, queue a command to it through the queue \
         Utility or publish an event; if both need the same activity, that \
         activity is an Engine or ResourceAccess shared by both - extract it. \
         Never move it into a Utility to dodge the rule. Do not edit dune \
         files to silence this." }
  ; { id= "ID-MANAGER-CLIENT"
    ; title= "Manager calls a Client"
    ; coaching=
        "Don't call up. A Manager serves Clients and must not know them; a \
         call up into the Client layer indicates the need for queuing or \
         pub/sub. Return data to the caller, or publish an event the Client \
         subscribes to."
        ^ no_silencing }
  ; { id= "ID-ENGINE-ENGINE"
    ; title= "Engine calls another Engine"
    ; coaching=
        "Engines never call each other; the Manager orchestrates them. An \
         Engine encapsulates one volatile activity; chaining Engines \
         hard-codes a workflow inside the business logic. Return the result to \
         the Manager and let the Manager call the next Engine. If two Engines \
         share an algorithm, that is either one Engine or a Utility with no \
         business knowledge."
        ^ no_silencing }
  ; { id= "ID-ENGINE-MANAGER"
    ; title= "Engine calls a Manager"
    ; coaching=
        "Don't call up. An Engine serves its Manager; a call up indicates the \
         need for queuing or pub/sub. Return data to the caller, or publish an \
         event through the Manager's workflow."
        ^ no_silencing }
  ; { id= "ID-ENGINE-CLIENT"
    ; title= "Engine calls a Client"
    ; coaching=
        "Don't call up. Engines never depend on presentation; a call up \
         indicates the need for queuing or pub/sub. Return data to the \
         Manager, which returns it to the Client."
        ^ no_silencing }
  ; { id= "ID-ACCESS-ACCESS"
    ; title= "ResourceAccess calls another ResourceAccess"
    ; coaching=
        "ResourceAccess services never call each other; atomic business verbs \
         are composed by the Manager. Return the data to the Manager and let \
         it call the other ResourceAccess. If both need the same resource \
         helper, put it in a Utility with no business knowledge."
        ^ no_silencing }
  ; { id= "ID-ACCESS-OUTBOUND"
    ; title= "ResourceAccess calls a Manager or Engine"
    ; coaching=
        "Don't call up. ResourceAccess exposes atomic business verbs over a \
         resource and is called by Managers and Engines; a call up indicates \
         the need for queuing or pub/sub. Return data to the caller instead."
        ^ no_silencing }
  ; { id= "ID-ACCESS-CLIENT"
    ; title= "ResourceAccess calls a Client"
    ; coaching=
        "Don't call up. ResourceAccess never depends on presentation; a call \
         up indicates the need for queuing or pub/sub. Return data to the \
         caller instead."
        ^ no_silencing }
  ; { id= "ID-UTILITY-BUSINESS"
    ; title= "Utility depends on a business component"
    ; coaching=
        "Utilities are infrastructure any layer may use - the 'cappuccino \
         machine' test: it could serve any system - and must not depend on \
         business components (Managers, Engines, ResourceAccess, Clients). \
         Invert the dependency: the business component calls the Utility and \
         passes the data it needs. If the code really encodes business rules, \
         it is not a Utility; make it an Engine or ResourceAccess and name it \
         accordingly."
        ^ no_silencing }
  ; { id= "ROOT-LEAK"
    ; title= "component depends on the composition root"
    ; coaching=
        "The composition root wires services: it links implementations, specs \
         and wires and chooses which implementation serves each contract. \
         Components must never reach back into it - that would make every \
         component depend on the whole system. Only executables, tests and \
         other _root libraries may depend on a _root library. Depend on the \
         contract of the service you need instead, and let the root pass it \
         in."
        ^ no_silencing }
  ; { id= "FRAMEWORK-BOUNDARY"
    ; title= "component uses the full framework"
    ; coaching=
        "Only the composition root wires services and may use the full \
         framework (registry, dispatch by name, process wiring); contract \
         libraries may use the framework surface generated code needs. A \
         service implementation receives its collaborators through their \
         contracts and implements its own spec; it never looks services up by \
         name. Move the wiring into the executable that composes the system."
        ^ no_silencing }
  ; { id= "RESOURCE-BOUNDARY"
    ; title= "component touches a resource directly"
    ; coaching=
        "Only ResourceAccess (and infrastructure Utilities) touch resources \
         such as the database, network, mail or authentication store. Get the \
         data through a ResourceAccess contract that exposes atomic business \
         verbs, not CRUD over the resource."
        ^ no_silencing }
  ; { id= "EVT-PUBLISH-ROLE"
    ; title= "event published outside a Manager"
    ; coaching=
        "Only Managers publish events: an event is a fact about a use case. \
         Return the data to the Manager that runs the use case and let it \
         publish."
        ^ no_silencing }
  ; { id= "EVT-SUBSCRIBE-ROLE"
    ; title= "event subscription outside a Manager or Client"
    ; coaching=
        "Only Managers and Clients subscribe to events. Engines and \
         ResourceAccess are called by Managers; if they must react to an \
         event, the subscribing Manager calls them."
        ^ no_silencing }
  ; { id= "PRESENTATION-BOUNDARY"
    ; title= "presentation outside a Client"
    ; coaching=
        "HTTP, HTML and web rendering belong to Clients. Business components \
         return data; the Client presents it. Move the rendering into the \
         Client and return structured data from the Manager."
        ^ no_silencing } ]

let find (id : string) : rule =
  match List.find_opt (fun r -> r.id = id) rules with
  | Some r -> r
  | None -> invalid_arg ("unknown rule " ^ id)
