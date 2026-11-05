(* The well-ocaml external library profile: which components may depend
   on which Well framework and resource libraries. This is the only place
   that names external libraries. See docs/contracts/rule-catalog.md. *)

open Szaniec_model.Conformance

let name = "well-ocaml"

type category =
  | Framework (* service registry, dispatch by name, process wiring *)
  | Resource (* databases, network, mail, authentication stores *)
  | Publish (* event publication *)
  | Subscribe (* event subscription *)
  | Presentation (* HTTP, HTML and web rendering *)

let category_name = function
  | Framework -> "framework"
  | Resource -> "resource"
  | Publish -> "publish"
  | Subscribe -> "subscribe"
  | Presentation -> "presentation"

let table =
  [ ("well", Framework)
  ; ("well.core", Framework)
  ; ("well.cap", Framework)
  ; ("well.service", Framework)
  ; ("well.cli", Framework)
  ; ("sqlite3", Resource)
  ; ("well.db", Resource)
  ; ("well.net", Resource)
  ; ("well.mail", Resource)
  ; ("well.auth", Resource)
  ; ("well.ppx", Resource)
  ; ("well.publish", Publish)
  ; ("well.subscribe", Subscribe)
  ; ("well.http", Presentation)
  ; ("well.html", Presentation)
  ; ("well.web", Presentation) ]

(* None: allowed for every component. *)
let category (library : string) : category option = List.assoc_opt library table

let rule = function
  | Framework -> "FRAMEWORK-BOUNDARY"
  | Resource -> "RESOURCE-BOUNDARY"
  | Publish -> "EVT-PUBLISH-ROLE"
  | Subscribe -> "EVT-SUBSCRIBE-ROLE"
  | Presentation -> "PRESENTATION-BOUNDARY"

(* Roots and tests are allowed everything; they are handled by the
   caller. [contract_family] marks _contract/_browser/_spec/_wire. *)
let allowed category ~(contract_family : bool) ~(role : role option) : bool =
  match (category, role) with
  | Framework, _ -> contract_family
  | Resource, Some (Access | Utility) -> true
  | Publish, Some (Manager | Utility) -> true
  | Subscribe, Some (Manager | Client | Utility) -> true
  | Presentation, Some (Client | Utility) -> true
  | _ -> false
