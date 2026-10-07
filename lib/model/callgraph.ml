(* Call network model: per service and per method, the observed call
   edges. CheckClient renders it as szaniec-callgraph/1 JSON. *)

type target =
  | Service_method of string (* service *) * string (* method *)
  | Resource_target of string
  | External_target of string
  | Unresolved_target of string (* detail *)

type edge =
  { target: target
  ; sites: Observation.site list }

type method_info =
  { mi_name: string
  ; mi_request: string
  ; mi_response: string
  ; mi_calls: edge list (* sorted, deduplicated *)
  ; mi_called_by: (string * string) list (* (service, method) sorted *) }

type service_info =
  { si_name: string
  ; si_role: string
  ; si_methods: method_info list }

type t =
  { services: service_info list
  ; unresolved: (string * string * Observation.site) list
  ; (* unit, caller, site *)
    unclassified_units: string list }

let compare_target (a : target) (b : target) = compare a b

let compare_edge (a : edge) (b : edge) =
  let c = compare_target a.target b.target in
  if c <> 0
  then c
  else
    compare
      (List.map
         (fun s ->
           (s.Observation.site_path, s.Observation.line, s.Observation.col) )
         a.sites )
      (List.map
         (fun s ->
           (s.Observation.site_path, s.Observation.line, s.Observation.col) )
         b.sites )
