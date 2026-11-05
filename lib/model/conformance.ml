(* Check report. Mirrors docs/contracts/check-contract.md. Produced by
   ConformanceEngine, rendered by the CheckClient. *)

type role =
  | Client
  | Manager
  | Engine
  | Access
  | Utility

let role_name = function
  | Client -> "client"
  | Manager -> "manager"
  | Engine -> "engine"
  | Access -> "access"
  | Utility -> "utility"

(* How a stanza participates in the architecture. *)
type component_class =
  | Service (* implementation library of a service *)
  | Contract (* <svc>_contract: callable contract *)
  | Browser (* <svc>_browser: browser-side callable contract *)
  | Spec (* <svc>_spec: server surface *)
  | Wire (* <svc>_wire: transport adapter *)
  | Facet (* <svc>_<anything>: in-process surface of a service *)
  | Local (* any other project library *)
  | Root (* executable or <name>_root library: composition root *)
  | Test

let class_name = function
  | Service -> "service"
  | Contract -> "contract"
  | Browser -> "browser-contract"
  | Spec -> "spec"
  | Wire -> "wire"
  | Facet -> "facet"
  | Local -> "local"
  | Root -> "root"
  | Test -> "test"

type component =
  { component_name: string
  ; component_kind: Structure.stanza_kind
  ; component_class: component_class
  ; component_role: role option (* None for roots and tests *)
  ; component_service: string option (* owning service name *)
  ; component_at: Structure.position }

(* One side of a finding. [endpoint_class] is a component class name,
   "external", "external:<category>", "project" or a dune construct. *)
type endpoint =
  { endpoint_name: string
  ; endpoint_kind: string (* stanza kind, "dune-project" or "dependency" *)
  ; endpoint_class: string
  ; endpoint_role: role option }

type finding =
  { rule: string
  ; from_: endpoint
  ; to_: endpoint
  ; at: Structure.position
  ; message: string
  ; coaching: string }

type report =
  { project: string
  ; profile: string
  ; services: Structure.service list
  ; components: component list
  ; findings: finding list (* sorted by location, then rule *) }
