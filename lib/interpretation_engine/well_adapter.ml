(* InterpretationEngine: binds observed code to architectural boundaries
   and interprets interactions for Well applications.
   See docs/contracts/interpretation-schema.md and
   docs/decisions/donts-based-rules.md. *)

open Szaniec_model

let exclusions =
  [ ".mlx view files (MLX preprocessor not in this profile)"
  ; ".mli bodies (interface freshness recorded)"
  ; "dune wrapper execution (.ml-gen aliases observed)"
  ; "resource access beyond framework-known APIs (recorded as external calls)"
  ]

(* Well framework APIs interpreted as registration/wiring: implementation
   references passed through them are framework mechanics. *)
let registration_apis =
  ["Well.Service.register"; "Well.Service.register_drut"; "Well.Service.expose"]

let route_apis = ["Well.get"; "Well.post"; "Well.live"]

(* Verified Well surface (fixture revision
   5c573753367f10d7226f5eaedf1adbeacab2c09d). Nothing else is a queue or
   an event. *)
let publish_apis =
  ["Well.publish"; "Well.publish_keyed"; "Well.MessageBus.publish"]

let subscribe_apis =
  [ "Well.subscribe"
  ; "Well.subscribe_keyed"
  ; "Well.MessageBus.subscribe"
  ; "Well.MessageBus.once" ]

let request_apis = ["Well.request"]

let messaging_apis = publish_apis @ subscribe_apis @ request_apis

let topic_key (args : Observation.call_arg list) ~(labeled : string) :
    string option =
  let matching =
    List.filter
      (fun (a : Observation.call_arg) ->
        if labeled = ""
        then a.Observation.arg_label = ""
        else String.equal a.Observation.arg_label labeled )
      args
  in
  match matching with
  | [] -> None
  | a :: _ ->
      if a.Observation.arg_target <> ""
      then Some ("path:" ^ a.Observation.arg_target)
      else if a.Observation.arg_literal <> ""
      then Some ("lit:" ^ a.Observation.arg_literal)
      else None

(* Resource APIs are framework knowledge, not project policy. *)
let framework_resources : (string * string) list =
  [("Well.Db.", "database"); ("Sqlite3.", "database")]

(* Generated-code mechanic members of contract units (wire codecs,
   binding and dispatch). Calls to any other contract member are checked
   against the declared rpc methods. *)
(* ── ownership ────────────────────────────────────────────────────── *)

(* Role of a service name: suffix rule (decision record). *)
let role_of_name = Szaniec_architecture_access.Cyrograf.role_of_suffix

(* Last dot-separated member of a canonical path. *)
let last_segment (path : string) : string =
  match String.rindex_opt path '.' with
  | Some i -> String.sub path (i + 1) (String.length path - i - 1)
  | None -> path

let generated_contract = Public_contracts.generated_contract

let wrapper_segment = Public_contracts.wrapper_segment

type ownership_map = (string, Interpretation.ownership) Hashtbl.t

(* A canonical path segment equals the service stem (case-insensitive) or
   ends with "_" + stem. *)
let family_segment_matches (segs : string list) (svc : string) : bool =
  List.exists
    (fun seg ->
      Szaniec_architecture_access.Cyrograf.segment_matches_service
        ~service:svc
        seg )
    segs

let dir_segments (source_path : string) : string list =
  match List.rev (String.split_on_char '/' source_path) with
  | [] -> []
  | _file :: rev_dirs -> List.rev rev_dirs

let module_ident_of_dir (seg : string) : string = String.capitalize_ascii seg

let services_matching_segment
    (cy : Szaniec_architecture_access.Cyrograf.t)
    (seg : string) =
  List.filter
    (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
      Szaniec_architecture_access.Cyrograf.segment_matches_service
        ~service:s.Szaniec_architecture_access.Cyrograf.svc_name
        seg )
    cy.Szaniec_architecture_access.Cyrograf.services

(* Nearest directory to the file. [`Conflict] when that directory names
   more than one service. A `client` directory that names no service is
   an implicit client family. *)
let source_layout_family
    (cy : Szaniec_architecture_access.Cyrograf.t)
    (source_path : string) =
  let ends_client (seg : string) : bool =
    let l = String.lowercase_ascii seg in
    let n = String.length l in
    n >= 6 && String.sub l (n - 6) 6 = "client"
  in
  let rec walk = function
    | [] -> None
    | seg :: rest -> (
      match services_matching_segment cy seg with
      | _ :: _ :: _ -> Some (`Conflict seg)
      | [s] -> Some (`Family s.Szaniec_architecture_access.Cyrograf.svc_name)
      | [] ->
          if ends_client seg
          then Some (`Family (module_ident_of_dir seg))
          else walk rest )
  in
  walk (List.rev (dir_segments source_path))

let impl_suffix_matches (segs : string list) (svc : string) : bool =
  List.exists
    (fun seg ->
      String.equal
        (Szaniec_architecture_access.Cyrograf.normalize_stem seg)
        (Szaniec_architecture_access.Cyrograf.normalize_stem svc ^ "impl") )
    segs

(* Implicit client boundary: any segment ending with "client". *)
let client_segment (segs : string list) : string option =
  List.find_opt
    (fun seg ->
      let l = String.lowercase_ascii seg in
      let n = String.length l in
      n >= 6 && String.sub l (n - 6) 6 = "client" )
    segs

let canonical_family
    (cy : Szaniec_architecture_access.Cyrograf.t)
    (segs : string list) : string option =
  match
    List.find_opt
      (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
        family_segment_matches
          segs
          s.Szaniec_architecture_access.Cyrograf.svc_name )
      cy.Szaniec_architecture_access.Cyrograf.services
  with
  | Some s -> Some s.Szaniec_architecture_access.Cyrograf.svc_name
  | None -> (
    match
      List.find_opt
        (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
          impl_suffix_matches
            segs
            s.Szaniec_architecture_access.Cyrograf.svc_name )
        cy.Szaniec_architecture_access.Cyrograf.services
    with
    | Some s -> Some s.Szaniec_architecture_access.Cyrograf.svc_name
    | None -> client_segment segs )

let classify_ownership
    ~contracts
    (cy : Szaniec_architecture_access.Cyrograf.t)
    (obs : Observation.t) :
    ownership_map * Observation.gap list * (string, string) Hashtbl.t =
  let map : ownership_map = Hashtbl.create 64 in
  let gaps = ref [] in
  (* implementation binding from compiler evidence: a unit calling
     <Contract>.make_spec implements that service, even when its own
     module name does not carry the service stem *)
  let impl_of : (string, string) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (c : Observation.call) ->
      match List.rev (Canonical.split_dots c.Observation.callee) with
      | "make_spec" :: prev :: _ -> (
          let bound_contract =
            Option.bind
              (Canonical.unit_prefix
                 (List.map
                    (fun (u : Observation.unit_info) -> u.canonical)
                    obs.units )
                 c.callee )
              (Hashtbl.find_opt contracts)
          in
          let svc =
            List.find_opt
              (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
                match bound_contract with
                | Some contract ->
                    contract.Szaniec_architecture_access.Cyrograf.contract_name
                    = s.svc_name
                | None -> family_segment_matches [prev] s.svc_name )
              cy.Szaniec_architecture_access.Cyrograf.services
          in
          match svc with
          | Some s ->
              Hashtbl.replace
                impl_of
                c.Observation.call_unit
                s.Szaniec_architecture_access.Cyrograf.svc_name
          | None -> () )
      | _ -> () )
    obs.Observation.calls ;
  (* registration evidence: X.spec passed to a registration API binds X's
     unit to that service *)
  List.iter
    (fun (v : Observation.value_ref) ->
      match List.rev (Canonical.split_dots v.Observation.ref_target) with
      | "spec" :: mod_segs_rev -> (
          let unit_root = List.hd mod_segs_rev in
          let stem_candidates =
            [unit_root]
            @
            if
              String.length unit_root > 5
              && String.sub
                   (String.lowercase_ascii unit_root)
                   (String.length unit_root - 5)
                   5
                 = "_impl"
            then [String.sub unit_root 0 (String.length unit_root - 5)]
            else []
          in
          let svc =
            List.find_opt
              (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
                List.exists
                  (fun seg ->
                    Szaniec_architecture_access.Cyrograf.segment_matches_service
                      ~service:s.Szaniec_architecture_access.Cyrograf.svc_name
                      seg )
                  stem_candidates )
              cy.Szaniec_architecture_access.Cyrograf.services
          in
          match svc with
          | Some s ->
              let target_unit =
                match
                  Canonical.unit_prefix
                    (List.map
                       (fun (u : Observation.unit_info) ->
                         u.Observation.canonical )
                       obs.Observation.units )
                    v.Observation.ref_target
                with
                | Some u -> u
                | None ->
                    List.hd (Canonical.split_dots v.Observation.ref_target)
              in
              Hashtbl.replace
                impl_of
                target_unit
                s.Szaniec_architecture_access.Cyrograf.svc_name
          | None -> () )
      | _ -> () )
    obs.Observation.value_refs ;
  let push_name (acc : string list) (name : string option) : string list =
    match name with
    | None -> acc
    | Some n -> if List.mem n acc then acc else n :: acc
  in
  let owner_of_family canonical family =
    let cls = Interpretation.Implementation_of family in
    { Interpretation.owner_module= canonical
    ; owner_class= cls
    ; owner_service= family }
  in
  List.iter
    (fun (u : Observation.unit_info) ->
      let canonical = u.Observation.canonical in
      let segs = Canonical.split_dots canonical in
      let generated = generated_contract u in
      let wrapper = wrapper_segment (last_segment canonical) in
      let generated_families =
        if generated
        then
          services_matching_segment cy wrapper
          |> List.map (fun s -> s.Szaniec_architecture_access.Cyrograf.svc_name)
        else []
      in
      let is_framework =
        List.exists
          (fun seg ->
            String.equal (String.lowercase_ascii seg) "well"
            || String.equal (String.lowercase_ascii seg) "well_stub" )
          segs
      in
      let owner =
        if is_framework
        then
          { Interpretation.owner_module= canonical
          ; owner_class= Interpretation.ExternalLibrary "well"
          ; owner_service= "" }
        else
          let source = source_layout_family cy u.Observation.source_path in
          match source with
          | Some (`Conflict seg) ->
              gaps :=
                { Observation.gap_code= "GAP-AMBIGUOUS-OWNERSHIP"
                ; gap_path= u.Observation.source_path
                ; gap_detail=
                    Printf.sprintf
                      "directory %s matches more than one service family"
                      seg }
                :: !gaps ;
              { Interpretation.owner_module= canonical
              ; owner_class= Interpretation.Unclassified
              ; owner_service= "" }
          | _ -> (
              let source_name =
                match source with
                | Some (`Family n) -> Some n
                | _ -> None
              in
              let names =
                generated_families |> fun acc ->
                push_name acc source_name |> fun acc ->
                push_name acc (canonical_family cy segs) |> fun acc ->
                push_name acc (Hashtbl.find_opt impl_of canonical)
                |> List.sort_uniq compare
              in
              match names with
              | [] ->
                  if
                    (not generated)
                    && (not (Hashtbl.mem contracts canonical))
                    && wrapper <> last_segment canonical
                    && services_matching_segment cy wrapper <> []
                  then
                    gaps :=
                      { Observation.gap_code= "GAP-AMBIGUOUS-OWNERSHIP"
                      ; gap_path= u.Observation.source_path
                      ; gap_detail=
                          Printf.sprintf
                            "generated contract provenance cannot be \
                             established for %s"
                            canonical }
                      :: !gaps ;
                  { Interpretation.owner_module= canonical
                  ; owner_class= Interpretation.Unclassified
                  ; owner_service= "" }
              | [family] -> owner_of_family canonical family
              | many ->
                  gaps :=
                    { Observation.gap_code= "GAP-AMBIGUOUS-OWNERSHIP"
                    ; gap_path= u.Observation.source_path
                    ; gap_detail=
                        Printf.sprintf
                          "unit %s matches families %s"
                          canonical
                          (String.concat " and " many) }
                    :: !gaps ;
                  { Interpretation.owner_module= canonical
                  ; owner_class= Interpretation.Unclassified
                  ; owner_service= "" } )
      in
      Hashtbl.replace map canonical owner )
    obs.Observation.units ;
  let ambiguous_units = Hashtbl.create 16 in
  List.iter
    (fun (u : Observation.unit_info) ->
      if
        List.exists
          (fun (g : Observation.gap) ->
            g.gap_code = "GAP-AMBIGUOUS-OWNERSHIP" && g.gap_path = u.source_path )
          !gaps
      then Hashtbl.replace ambiguous_units u.canonical () )
    obs.units ;
  Hashtbl.iter
    (fun unit (contract : Szaniec_architecture_access.Cyrograf.contract) ->
      let previous = Hashtbl.find map unit in
      let service =
        List.find_opt
          (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
            s.svc_name = contract.contract_name )
          cy.services
      in
      let family =
        match service with
        | Some s -> s.svc_name
        | None -> ""
      in
      if Hashtbl.mem ambiguous_units unit
      then ()
      else if previous.owner_service <> "" && previous.owner_service <> family
      then (
        Hashtbl.replace
          map
          unit
          { previous with
            owner_class= Interpretation.Unclassified
          ; owner_service= "" } ;
        let source =
          List.find
            (fun (u : Observation.unit_info) -> u.canonical = unit)
            obs.units
        in
        gaps :=
          { Observation.gap_code= "GAP-AMBIGUOUS-OWNERSHIP"
          ; gap_path= source.source_path
          ; gap_detail=
              "generated contract conflicts with service-family ownership" }
          :: !gaps )
      else
        Hashtbl.replace
          map
          unit
          { Interpretation.owner_module= unit
          ; owner_service= family
          ; owner_class=
              ( match service with
              | Some s -> Interpretation.Contract_of s.svc_name
              | None -> Interpretation.Contract_data contract.contract_name ) } )
    contracts ;
  let rec classify_aggregators () =
    let changed = ref false in
    List.iter
      (fun unit ->
        match Hashtbl.find_opt map unit with
        | Some o
          when o.owner_class = Interpretation.Unclassified
               && not (Hashtbl.mem ambiguous_units unit) ->
            let aliases =
              List.filter
                (fun (path, _) ->
                  Canonical.starts_with ~prefix:(unit ^ ".") path )
                obs.module_aliases
            in
            let contract_target (_, target) =
              match Canonical.resolve_alias obs.module_aliases target with
              | None -> false
              | Some target -> (
                match
                  Canonical.unit_prefix
                    (List.map
                       (fun (u : Observation.unit_info) -> u.canonical)
                       obs.units )
                    target
                with
                | Some target -> (
                  match (Hashtbl.find map target).owner_class with
                  | Interpretation.Contract_of _
                   |Interpretation.Contract_data _ ->
                      true
                  | _ -> false )
                | None -> false )
            in
            if aliases <> [] && List.for_all contract_target aliases
            then (
              changed := true ;
              Hashtbl.replace
                map
                unit
                {o with owner_class= Interpretation.Contract_data "aggregator"}
              )
        | _ -> () )
      obs.alias_only_units ;
    if !changed then classify_aggregators ()
  in
  classify_aggregators () ;
  (* composition roots: units calling registration APIs (auto-detected) *)
  let is_registration (callee : string) : bool =
    List.exists (fun a -> String.equal a callee) registration_apis
  in
  List.iter
    (fun (c : Observation.call) ->
      if is_registration c.Observation.callee
      then
        match Hashtbl.find_opt map c.Observation.call_unit with
        | Some o
          when o.Interpretation.owner_class = Interpretation.CompositionRoot ->
            ()
        | Some o ->
            Hashtbl.replace
              map
              c.Observation.call_unit
              { o with
                owner_class= Interpretation.CompositionRoot
              ; owner_service= "" }
        | None -> () )
    obs.Observation.calls ;
  (* An unclassified unit reached only by its own calls is a helper of
     itself. The complexity inventory reports that class. One foreign
     caller does not adopt the unit into the caller's family. *)
  let self_helpers : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let foreign_callers : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (c : Observation.call) ->
      if String.length c.Observation.callee > 0
      then
        match
          ( Canonical.unit_prefix
              (List.map
                 (fun (u : Observation.unit_info) -> u.Observation.canonical)
                 obs.Observation.units )
              c.Observation.callee
          , Hashtbl.find_opt map c.Observation.call_unit )
        with
        | Some target_unit, Some caller -> (
          match Hashtbl.find_opt map target_unit with
          | Some {owner_class= Interpretation.Unclassified; _} ->
              if String.equal caller.Interpretation.owner_module target_unit
              then Hashtbl.replace self_helpers target_unit ()
              else Hashtbl.replace foreign_callers target_unit ()
          | Some _
           |None ->
              () )
        | _ -> () )
    obs.Observation.calls ;
  Hashtbl.iter
    (fun target () ->
      if
        (not (Hashtbl.mem foreign_callers target))
        && not (Hashtbl.mem ambiguous_units target)
      then
        Hashtbl.replace
          map
          target
          { Interpretation.owner_module= target
          ; owner_class= Interpretation.Helper_of target
          ; owner_service= target } )
    self_helpers ;
  (map, List.sort_uniq compare !gaps, impl_of)

type node =
  { n_unit: string
  ; n_symbol: string }

let node_id (n : node) = n.n_unit ^ "@" ^ n.n_symbol

let same_boundary (a : Interpretation.ownership) (b : Interpretation.ownership)
    : bool =
  a.Interpretation.owner_service <> ""
  && String.equal a.Interpretation.owner_service b.Interpretation.owner_service
  || String.equal a.Interpretation.owner_module b.Interpretation.owner_module

let interaction_key (i : Interpretation.interaction) =
  ( Interpretation.kind_name i.kind
  , i.from_owner
  , i.to_service
  , i.to_method
  , i.target_module
  , i.api
  , String.concat ">" i.evidence_path )

(* Group once by identity, retaining every call site for path rules. Sorting
   only the completed groups keeps large observations out of a quadratic
   scan and makes the result independent of hash-table iteration order. *)
let merge_interactions (interactions : Interpretation.interaction list) :
    Interpretation.interaction list =
  let groups = Hashtbl.create 128 in
  List.iter
    (fun (i : Interpretation.interaction) ->
      let key = interaction_key i in
      match Hashtbl.find_opt groups key with
      | None -> Hashtbl.add groups key i
      | Some prev ->
          Hashtbl.replace
            groups
            key
            {prev with Interpretation.sites= List.rev_append i.sites prev.sites} )
    interactions ;
  Hashtbl.fold (fun key i acc -> (key, i) :: acc) groups []
  |> List.sort (fun (a, _) (b, _) -> compare a b)
  |> List.map (fun (_, (i : Interpretation.interaction)) ->
      {i with Interpretation.sites= List.sort_uniq compare i.sites} )

let interpret
    ?(approved = false)
    ~(policy : Policy.t)
    ~(cy : Szaniec_architecture_access.Cyrograf.t)
    (obs : Observation.t) : Interpretation.t =
  let contracts, contract_gaps =
    Public_contracts.bind ~approved ~policy ~cy obs
  in
  let ownership_map, ownership_gaps, impl_of =
    classify_ownership ~contracts cy obs
  in
  let surfaces, surface_gaps =
    Public_contracts.validate_surfaces ~approved ~policy ~cy obs ownership_map
  in
  let unit_paths =
    List.map
      (fun (u : Observation.unit_info) -> u.Observation.canonical)
      obs.Observation.units
  in
  let ambiguous_units = Hashtbl.create 16 in
  let ambiguous_paths = Hashtbl.create 16 in
  List.iter
    (fun (gap : Observation.gap) ->
      if gap.gap_code = "GAP-AMBIGUOUS-OWNERSHIP"
      then Hashtbl.replace ambiguous_paths gap.gap_path () )
    (ownership_gaps @ contract_gaps) ;
  List.iter
    (fun (u : Observation.unit_info) ->
      if Hashtbl.mem ambiguous_paths u.source_path
      then Hashtbl.replace ambiguous_units u.canonical () )
    obs.units ;
  let owner_of_path (path : string) : Interpretation.ownership =
    match Canonical.unit_prefix unit_paths path with
    | Some u -> Hashtbl.find ownership_map u
    | None ->
        { owner_module= path
        ; owner_class= Interpretation.Unclassified
        ; owner_service= "" }
  in
  let unit_owner_class path = (owner_of_path path).owner_class in
  let generated_units = Hashtbl.create 16 in
  List.iter
    (fun (u : Observation.unit_info) ->
      if generated_contract u
      then Hashtbl.replace generated_units u.canonical () )
    obs.units ;
  let generated_path path =
    match Canonical.unit_prefix unit_paths path with
    | Some unit -> Hashtbl.mem generated_units unit
    | None -> false
  in
  let contract_call_target (callee : string) :
      (Szaniec_architecture_access.Cyrograf.service * string (* method *))
      option =
    match Canonical.unit_prefix unit_paths callee with
    | None -> None
    | Some unit when Hashtbl.mem ambiguous_units unit -> None
    | Some unit -> (
      match
        (Hashtbl.find_opt contracts unit, Public_contracts.relative unit callee)
      with
      | Some contract, Some member ->
          let method_name =
            match Public_contracts.rpc_member cy contract member with
            | Some name -> name
            | None when Hashtbl.mem generated_units unit -> last_segment member
            | None -> member
          in
          if
            Public_contracts.data_member
              ~generated:(Hashtbl.mem generated_units unit)
              contract
              member
          then None
          else
            Option.map
              (fun s -> (s, method_name))
              (List.find_opt
                 (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
                   s.svc_name = contract.contract_name )
                 cy.services )
      | _ -> None )
  in
  let contract_member path =
    match Canonical.unit_prefix unit_paths path with
    | Some unit when Hashtbl.mem ambiguous_units unit -> None
    | Some unit -> (
      match
        (Hashtbl.find_opt contracts unit, Public_contracts.relative unit path)
      with
      | Some c, Some member -> Some (c, member)
      | _ -> None )
    | None -> None
  in
  let topic_values = Hashtbl.create 16 in
  List.iter
    (fun (c : Observation.call) ->
      if c.callee = "Well.topic"
      then Hashtbl.replace topic_values (c.call_unit ^ "." ^ c.caller) () )
    obs.calls ;
  let generated_member path =
    match contract_member path with
    | Some (c, member) ->
        Public_contracts.mechanic ~generated:(generated_path path) c member
        || Public_contracts.rpc_member cy c member <> None
        || Hashtbl.mem topic_values path
    | None -> false
  in
  let public_module_path path =
    match Canonical.unit_prefix unit_paths path with
    | None -> false
    | Some unit -> (
      match Hashtbl.find_opt contracts unit with
      | Some c -> (
          path = unit
          ||
          match Public_contracts.relative unit path with
          | Some member -> (
              List.mem member c.contract_messages
              || member = "Proxy"
              || generated_path path
                 && (not (List.mem path obs.defined_values))
                 &&
                 match Canonical.split_dots member with
                 | [_]
                  |[_; "Storage"] ->
                     true
                 | _ -> false )
          | None -> false )
      | None ->
          (owner_of_path unit).owner_class
          = Interpretation.Contract_data "aggregator" )
  in
  let resource_of_api (callee : string) : string option =
    match
      List.find_opt
        (fun (prefix, _) -> Canonical.starts_with ~prefix callee)
        framework_resources
    with
    | Some (_, name) -> Some name
    | None -> (
      match
        List.find_opt
          (fun (r : Policy.resource) ->
            List.exists
              (fun p -> Canonical.starts_with ~prefix:p callee)
              r.Policy.api_prefixes )
          policy.Policy.resources
      with
      | Some r -> Some r.Policy.resource_name
      | None -> None )
  in
  let node_of_call (c : Observation.call) : node =
    {n_unit= c.Observation.call_unit; n_symbol= c.Observation.caller}
  in
  let target_of_callee callee =
    match Canonical.unit_prefix unit_paths callee with
    | Some u ->
        let pl = String.length u + 1 in
        let rel =
          if String.length callee > pl
          then String.sub callee pl (String.length callee - pl)
          else callee
        in
        Some {n_unit= u; n_symbol= rel}
    | None -> None
  in
  (* in-boundary reverse edges *)
  let callers : (string, node list) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun (c : Observation.call) ->
      if String.length c.Observation.callee > 0
      then
        match target_of_callee c.Observation.callee with
        | Some target -> (
            let from_owner = owner_of_path c.Observation.call_unit in
            let to_owner = owner_of_path target.n_unit in
            match (from_owner.owner_class, to_owner.owner_class) with
            | _ when generated_member (c.call_unit ^ "." ^ c.caller) -> ()
            | _ ->
                if same_boundary from_owner to_owner
                then
                  let from_ = node_of_call c in
                  let key = node_id target in
                  let l =
                    try Hashtbl.find callers key with
                    | Not_found -> []
                  in
                  if
                    not
                      (List.exists
                         (fun n ->
                           String.equal n.n_unit from_.n_unit
                           && String.equal n.n_symbol from_.n_symbol )
                         l )
                  then Hashtbl.replace callers key (from_ :: l) )
        | None -> () )
    obs.Observation.calls ;
  let origins =
    List.filter
      (fun (c : Observation.call) ->
        match Hashtbl.find_opt callers (node_id (node_of_call c)) with
        | Some l -> l = []
        | None -> true )
      obs.Observation.calls
    |> List.map node_of_call
    |> List.sort_uniq (fun a b -> compare (node_id a) (node_id b))
  in
  let out_edges : (string, Observation.call list) Hashtbl.t =
    Hashtbl.create 64
  in
  List.iter
    (fun (c : Observation.call) ->
      let key = node_id (node_of_call c) in
      let l =
        try Hashtbl.find out_edges key with
        | Not_found -> []
      in
      Hashtbl.replace out_edges key (c :: l) )
    obs.Observation.calls ;
  let out_edges_of n =
    List.sort
      compare
      ( try Hashtbl.find out_edges (node_id n) with
      | Not_found -> [] )
  in
  let interactions : Interpretation.interaction list ref = ref [] in
  let gaps = ref (ownership_gaps @ contract_gaps @ surface_gaps) in
  let unresolved_seen : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  let record_interaction
      kind
      from_owner
      to_service
      to_method
      target_module
      resource
      api
      path
      site =
    interactions :=
      { Interpretation.kind
      ; from_owner
      ; to_service
      ; to_method
      ; target_module
      ; resource
      ; api
      ; evidence_path= path
      ; sites= [site] }
      :: !interactions
  in
  let from_name path =
    let o = owner_of_path path in
    if String.equal o.owner_service "" then o.owner_module else o.owner_service
  in
  let unresolved_gap (c : Observation.call) =
    let site = c.Observation.site in
    let allowed_unit =
      match unit_owner_class c.Observation.call_unit with
      | Interpretation.ExternalLibrary _ -> false
      | _ -> not (generated_member (c.call_unit ^ "." ^ c.caller))
    in
    if allowed_unit
    then
      let key2 =
        c.Observation.call_unit
        ^ "@"
        ^ Printf.sprintf
            "%s:%d:%d"
            site.Observation.site_path
            site.Observation.line
            site.Observation.col
      in
      if not (Hashtbl.mem unresolved_seen key2)
      then (
        Hashtbl.replace unresolved_seen key2 () ;
        gaps :=
          { gap_code= "GAP-UNRESOLVED-CALL"
          ; gap_path= site.Observation.site_path
          ; gap_detail=
              Printf.sprintf
                "call target cannot be resolved (%s) in %s.%s at %s:%d"
                ( match c.Observation.resolution with
                | Observation.Unresolved_local -> "locally bound variable"
                | Observation.Unresolved_field -> "record field"
                | _ -> "dynamic expression" )
                c.Observation.call_unit
                c.Observation.caller
                site.Observation.site_path
                site.Observation.line }
          :: !gaps )
  in
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 128 in
  let rec dfs
      (visited : (string, unit) Hashtbl.t)
      (n : node)
      (path : string list) =
    let key = node_id n in
    if Hashtbl.mem visited key
    then ()
    else
      let () = Hashtbl.replace visited key () in
      let () = Hashtbl.replace seen key () in
      let handle (c : Observation.call) =
        let site = c.Observation.site in
        if c.Observation.resolution <> Observation.Resolved
        then unresolved_gap c
        else if String.length c.Observation.callee = 0
        then ()
        else
          let callee = c.Observation.callee in
          let from_owner = owner_of_path c.Observation.call_unit in
          match resource_of_api callee with
          | Some resource ->
              record_interaction
                Interpretation.ResourceAccess
                (from_name c.Observation.call_unit)
                ""
                ""
                callee
                resource
                callee
                (path @ [callee])
                site
          | None -> (
            match
              Public_contracts.allowed_surface
                surfaces
                ~consumer:(from_name c.call_unit)
                callee
            with
            | Some p ->
                if p.public_service <> from_name c.call_unit
                then
                  record_interaction
                    Interpretation.ServiceRequest
                    (from_name c.call_unit)
                    p.public_service
                    (last_segment callee)
                    p.public_module
                    ""
                    callee
                    (path @ [callee])
                    site
            | None
              when generated_member callee
                   &&
                   match contract_member callee with
                   | Some (contract, member) ->
                       Public_contracts.rpc_member cy contract member = None
                       && member <> "make_spec"
                   | _ -> false ->
                ()
            | None -> (
              match contract_call_target callee with
              | Some (svc, method_name) ->
                  let target_unit =
                    match target_of_callee callee with
                    | Some t -> t.n_unit
                    | None -> ""
                  in
                  let to_owner = owner_of_path target_unit in
                  let self_call =
                    String.equal to_owner.owner_service from_owner.owner_service
                    && from_owner.owner_service <> ""
                  in
                  let declared =
                    List.exists
                      (fun m ->
                        String.equal
                          m.Szaniec_architecture_access.Cyrograf.m_name
                          method_name )
                      svc.Szaniec_architecture_access.Cyrograf.svc_methods
                  in
                  let mechanic = generated_member callee && not declared in
                  if
                    (not declared)
                    && (not mechanic)
                    && not
                         ( self_call
                         && generated_path callee
                         && generated_path (c.call_unit ^ "." ^ c.caller) )
                  then
                    gaps :=
                      { gap_code= "SPEC-UNDECLARED-METHOD"
                      ; gap_path= site.Observation.site_path
                      ; gap_detail=
                          Printf.sprintf
                            "call %s is not a declared rpc method of service %s"
                            callee
                            svc.Szaniec_architecture_access.Cyrograf.svc_name }
                      :: !gaps ;
                  (* make_spec on the service's own contract is binding
                   evidence. Any other non-mechanic member called from
                   another boundary is a service request, including
                   declared rpc methods. A self call (own proxy or codec)
                   stays inside the boundary and is not an interaction. *)
                  if String.equal (last_segment callee) "make_spec"
                  then
                    if self_call
                    then
                      record_interaction
                        Interpretation.Registration
                        (from_name c.Observation.call_unit)
                        svc.Szaniec_architecture_access.Cyrograf.svc_name
                        ""
                        callee
                        ""
                        callee
                        (path @ [callee])
                        site
                    else ()
                  else if (not self_call) && not mechanic
                  then
                    record_interaction
                      ( if declared || generated_path callee
                        then Interpretation.ServiceRequest
                        else Interpretation.ImplementationAccess )
                      (from_name c.Observation.call_unit)
                      svc.Szaniec_architecture_access.Cyrograf.svc_name
                      method_name
                      callee
                      ""
                      callee
                      (path @ [callee])
                      site
              | None -> (
                match target_of_callee callee with
                | None ->
                    (* Messaging APIs are classified in a later pass so a
                     request is never also a publication, and a
                     publication is never a service request. *)
                    if
                      List.exists
                        (fun a -> String.equal a callee)
                        messaging_apis
                    then ()
                    else
                      record_interaction
                        Interpretation.ExternalCall
                        (from_name c.Observation.call_unit)
                        ""
                        ""
                        callee
                        ""
                        callee
                        (path @ [callee])
                        site
                | Some target -> (
                    let to_owner = owner_of_path target.n_unit in
                    let self_call =
                      String.equal
                        to_owner.owner_service
                        from_owner.owner_service
                      && from_owner.owner_service <> ""
                    in
                    if Hashtbl.mem ambiguous_units target.n_unit
                    then
                      gaps :=
                        { gap_code= "GAP-UNRESOLVED-TARGET"
                        ; gap_path= site.Observation.site_path
                        ; gap_detail=
                            "target ownership cannot be resolved: " ^ callee }
                        :: !gaps
                    else
                      match to_owner.owner_class with
                      | Interpretation.Contract_of _ when self_call ->
                          if not (generated_member callee)
                          then dfs visited target (path @ [callee])
                      | Interpretation.Contract_of s ->
                          record_interaction
                            Interpretation.ImplementationAccess
                            (from_name c.Observation.call_unit)
                            s
                            ""
                            target.n_unit
                            ""
                            callee
                            (path @ [callee])
                            site
                      | Interpretation.Contract_data _ ->
                          if
                            (not (generated_member callee))
                            && target.n_unit <> c.call_unit
                          then
                            record_interaction
                              Interpretation.ImplementationAccess
                              (from_name c.call_unit)
                              ""
                              ""
                              target.n_unit
                              ""
                              callee
                              (path @ [callee])
                              site
                      | Interpretation.Implementation_of _ when self_call ->
                          dfs
                            visited
                            {n_unit= target.n_unit; n_symbol= target.n_symbol}
                            (path @ [callee])
                      | Interpretation.Helper_of _ when self_call ->
                          dfs
                            visited
                            {n_unit= target.n_unit; n_symbol= target.n_symbol}
                            (path @ [callee])
                      | Interpretation.Implementation_of s
                       |Interpretation.Helper_of s ->
                          record_interaction
                            Interpretation.ImplementationAccess
                            (from_name c.Observation.call_unit)
                            s
                            ""
                            target.n_unit
                            ""
                            callee
                            (path @ [callee])
                            site
                      | Interpretation.Unclassified
                        when from_owner.Interpretation.owner_service <> ""
                             && not
                                  (String.equal
                                     from_owner.Interpretation.owner_module
                                     target.n_unit ) ->
                          record_interaction
                            Interpretation.ImplementationAccess
                            (from_name c.Observation.call_unit)
                            ""
                            ""
                            target.n_unit
                            ""
                            callee
                            (path @ [callee])
                            site
                      | Interpretation.CompositionRoot
                       |Interpretation.Unclassified
                       |Interpretation.ExternalLibrary _ ->
                          () ) ) ) )
      in
      List.iter handle (out_edges_of n)
  in
  let walkable (n : node) =
    (not (Hashtbl.mem ambiguous_units n.n_unit))
    &&
    match unit_owner_class n.n_unit with
    | Interpretation.ExternalLibrary _ -> false
    | _ -> not (generated_member (n.n_unit ^ "." ^ n.n_symbol))
  in
  let walk_from origin =
    if walkable origin
    then dfs (Hashtbl.create 32) origin [origin.n_unit ^ "." ^ origin.n_symbol]
  in
  List.iter walk_from origins ;
  (* also walk caller nodes not reached from any origin so that no facts
     are silently dropped *)
  let leftover =
    List.filter
      (fun (c : Observation.call) ->
        let n = node_of_call c in
        walkable n && not (Hashtbl.mem seen (node_id n)) )
      obs.Observation.calls
    |> List.map node_of_call
    |> List.sort_uniq (fun a b -> compare (node_id a) (node_id b))
  in
  List.iter
    (fun n -> if not (Hashtbl.mem seen (node_id n)) then walk_from n)
    leftover ;
  (* registration evidence: spec references passed to registration APIs *)
  let bindings =
    List.filter_map
      (fun (v : Observation.value_ref) ->
        if not (String.equal (last_segment v.Observation.ref_target) "spec")
        then None
        else
          let caller_owner = owner_of_path v.Observation.ref_unit in
          match caller_owner.owner_class with
          | Interpretation.CompositionRoot -> (
              let is_wiring =
                List.exists
                  (fun (c : Observation.call) ->
                    String.equal c.Observation.call_unit v.Observation.ref_unit
                    && String.equal
                         c.Observation.caller
                         v.Observation.ref_caller
                    && List.exists
                         (fun a -> String.equal a c.Observation.callee)
                         (registration_apis @ route_apis)
                    && List.exists
                         (fun (a : Observation.call_arg) ->
                           a.arg_target = v.ref_target )
                         c.args )
                  obs.Observation.calls
              in
              if not is_wiring
              then None
              else
                let target_unit =
                  match
                    Canonical.unit_prefix
                      (List.map
                         (fun (u : Observation.unit_info) ->
                           u.Observation.canonical )
                         obs.Observation.units )
                      v.Observation.ref_target
                  with
                  | Some u -> u
                  | None -> v.Observation.ref_target
                in
                match Hashtbl.find_opt impl_of target_unit with
                | Some svc_name ->
                    Some
                      { Interpretation.binding_service= svc_name
                      ; binding_kind= "registration"
                      ; binding_module= v.Observation.ref_target }
                | None -> None )
          | _ -> None )
      obs.Observation.value_refs
  in
  (* implementation access by value reference, outside registration
     patterns *)
  List.iter
    (fun (v : Observation.value_ref) ->
      let caller_owner = owner_of_path v.Observation.ref_unit in
      match Canonical.unit_prefix unit_paths v.Observation.ref_target with
      | Some target_unit -> (
          let target_owner = owner_of_path target_unit in
          let is_wiring_ref =
            caller_owner.owner_class = Interpretation.CompositionRoot
            && List.exists
                 (fun (c : Observation.call) ->
                   String.equal c.Observation.call_unit v.Observation.ref_unit
                   && String.equal c.Observation.caller v.Observation.ref_caller
                   && List.exists
                        (fun a -> String.equal a c.Observation.callee)
                        (registration_apis @ route_apis)
                   && List.exists
                        (fun (a : Observation.call_arg) ->
                          a.arg_target = v.ref_target )
                        c.args )
                 obs.Observation.calls
          in
          let public_surface =
            Public_contracts.allowed_surface
              surfaces
              ~consumer:(from_name v.ref_unit)
              v.ref_target
          in
          if
            (not is_wiring_ref)
            && (not (Hashtbl.mem ambiguous_units target_unit))
            && (not (Hashtbl.mem ambiguous_units v.ref_unit))
            && (not (generated_member (v.ref_unit ^ "." ^ v.ref_caller)))
            && (not (generated_member v.ref_target))
            && not (public_module_path v.ref_target)
          then
            match public_surface with
            | Some p ->
                if p.public_service <> from_name v.ref_unit
                then
                  record_interaction
                    Interpretation.ServiceRequest
                    (from_name v.ref_unit)
                    p.public_service
                    (last_segment v.ref_target)
                    target_unit
                    ""
                    v.ref_target
                    [v.ref_target]
                    v.ref_site
            | None -> (
              match target_owner.owner_class with
              | Interpretation.Implementation_of s
                when not (same_boundary caller_owner target_owner) ->
                  record_interaction
                    Interpretation.ImplementationAccess
                    (from_name v.Observation.ref_unit)
                    s
                    ""
                    target_unit
                    ""
                    v.Observation.ref_target
                    [v.Observation.ref_target]
                    v.Observation.ref_site
              | Interpretation.Helper_of s
               |Interpretation.Contract_of s
                when not (same_boundary caller_owner target_owner) ->
                  record_interaction
                    Interpretation.ImplementationAccess
                    (from_name v.Observation.ref_unit)
                    s
                    ""
                    target_unit
                    ""
                    v.Observation.ref_target
                    [v.Observation.ref_target]
                    v.Observation.ref_site
              | Interpretation.Unclassified
               |Interpretation.Contract_data _
                when caller_owner.Interpretation.owner_service <> ""
                     && not
                          (String.equal
                             caller_owner.Interpretation.owner_module
                             target_unit ) ->
                  record_interaction
                    Interpretation.ImplementationAccess
                    (from_name v.Observation.ref_unit)
                    ""
                    ""
                    target_unit
                    ""
                    v.Observation.ref_target
                    [v.Observation.ref_target]
                    v.Observation.ref_site
              | _ -> () ) )
      | None -> () )
    obs.Observation.value_refs ;
  (* Queue and event calls. Subscriptions are collected first so a
     request can name the services that handle its topic. *)
  let messaging_calls =
    List.filter
      (fun (c : Observation.call) ->
        c.Observation.resolution = Observation.Resolved
        && List.exists
             (fun a -> String.equal a c.Observation.callee)
             messaging_apis
        && (not (Hashtbl.mem ambiguous_units c.Observation.call_unit))
        &&
        match unit_owner_class c.Observation.call_unit with
        | Interpretation.ExternalLibrary _ -> false
        | _ -> not (generated_member (c.call_unit ^ "." ^ c.caller)) )
      obs.Observation.calls
  in
  let subscribers : (string * string) list ref = ref [] in
  List.iter
    (fun (c : Observation.call) ->
      if
        List.exists
          (fun a -> String.equal a c.Observation.callee)
          subscribe_apis
      then
        match topic_key c.Observation.args ~labeled:"" with
        | Some topic ->
            let owner = from_name c.Observation.call_unit in
            if
              not
                (List.exists
                   (fun (t, o) -> t = topic && o = owner)
                   !subscribers )
            then subscribers := (topic, owner) :: !subscribers
        | None -> () )
    messaging_calls ;
  List.iter
    (fun (c : Observation.call) ->
      let from_owner = from_name c.Observation.call_unit in
      let site = c.Observation.site in
      let evidence =
        [ c.Observation.call_unit ^ "." ^ c.Observation.caller
        ; c.Observation.callee ]
      in
      let publish =
        List.exists (fun a -> String.equal a c.Observation.callee) publish_apis
      in
      let subscribe =
        List.exists
          (fun a -> String.equal a c.Observation.callee)
          subscribe_apis
      in
      if publish
      then
        let topic =
          Option.value (topic_key c.Observation.args ~labeled:"") ~default:""
        in
        record_interaction
          Interpretation.Publication
          from_owner
          ""
          ""
          c.Observation.callee
          ""
          topic
          evidence
          site
      else if subscribe
      then
        let topic =
          Option.value (topic_key c.Observation.args ~labeled:"") ~default:""
        in
        record_interaction
          Interpretation.Subscription
          from_owner
          ""
          ""
          c.Observation.callee
          ""
          topic
          evidence
          site
      else if
        List.exists (fun a -> String.equal a c.Observation.callee) request_apis
      then
        let unresolved detail =
          gaps :=
            { gap_code= "GAP-UNRESOLVED-TARGET"
            ; gap_path= site.Observation.site_path
            ; gap_detail= detail }
            :: !gaps ;
          record_interaction
            Interpretation.QueuedCommand
            from_owner
            ""
            ""
            c.Observation.callee
            ""
            ""
            evidence
            site
        in
        match topic_key c.Observation.args ~labeled:"cmd" with
        | None ->
            unresolved
              (Printf.sprintf
                 "queued command topic cannot be resolved in %s.%s at %s:%d"
                 c.Observation.call_unit
                 c.Observation.caller
                 site.Observation.site_path
                 site.Observation.line )
        | Some topic -> (
          match
            List.filter (fun (t, _) -> String.equal t topic) !subscribers
            |> List.map snd
            |> List.sort_uniq compare
          with
          | [] ->
              unresolved
                (Printf.sprintf
                   "queued command topic %s has no subscriber (%s.%s at %s:%d)"
                   topic
                   c.Observation.call_unit
                   c.Observation.caller
                   site.Observation.site_path
                   site.Observation.line )
          | targets ->
              List.iter
                (fun target ->
                  record_interaction
                    Interpretation.QueuedCommand
                    from_owner
                    target
                    ""
                    c.Observation.callee
                    ""
                    topic
                    evidence
                    site )
                targets ) )
    messaging_calls ;
  let ownerships =
    Hashtbl.fold (fun _ o acc -> o :: acc) ownership_map []
    |> List.sort (fun a b ->
        compare a.Interpretation.owner_module b.Interpretation.owner_module )
  in
  let execution_owner symbol =
    let owner = owner_of_path symbol in
    if owner.owner_service = "" then owner.owner_module else owner.owner_service
  in
  let execution_interactions =
    let definitions = Hashtbl.create 64 in
    List.iter
      (fun (d : Observation.execution_definition) ->
        Hashtbl.replace definitions d.symbol () )
      obs.execution.definitions ;
    Repetition.project
      ~execution:obs.execution
      ~owner_of:execution_owner
      ~eligible:(fun symbol ->
        match (owner_of_path symbol).owner_class with
        | Interpretation.Contract_of _
         |Contract_data _
         |ExternalLibrary _ ->
            false
        | _ -> not (generated_member symbol) )
      ~entry_point:(fun symbol ->
        let owner = owner_of_path symbol in
        let name = List.rev (Canonical.split_dots symbol) |> List.hd in
        List.exists
          (fun service ->
            service.Szaniec_architecture_access.Cyrograf.svc_name
            = owner.owner_service
            && List.exists
                 (fun method_ ->
                   method_.Szaniec_architecture_access.Cyrograf.m_name = name )
                 service.svc_methods )
          cy.Szaniec_architecture_access.Cyrograf.services )
      ~classify:(fun origin (call : Observation.execution_call) ->
        let api = call.execution_callee in
        let from_owner = owner_of_path origin in
        let target_owner = owner_of_path api in
        let make kind to_service to_method resource =
          Some
            { Interpretation.kind
            ; from_owner= execution_owner origin
            ; to_service
            ; to_method
            ; target_module= api
            ; resource
            ; api
            ; evidence_path= []
            ; sites= [call.execution_site] }
        in
        if call.execution_resolution <> Observation.Resolved
        then make Interpretation.ExternalCall "" "" ""
        else
          match resource_of_api api with
          | Some resource -> make Interpretation.ResourceAccess "" "" resource
          | None -> (
            match
              Public_contracts.allowed_surface
                surfaces
                ~consumer:(execution_owner origin)
                api
            with
            | Some surface ->
                if surface.public_service = execution_owner origin
                then None
                else
                  make
                    Interpretation.ServiceRequest
                    surface.public_service
                    (last_segment api)
                    ""
            | None -> (
              match contract_call_target api with
              | Some _ when last_segment api = "make_spec" -> None
              | Some (service, method_name) ->
                  if
                    List.exists
                      (fun method_ ->
                        method_.Szaniec_architecture_access.Cyrograf.m_name
                        = method_name )
                      service.svc_methods
                  then
                    make
                      Interpretation.ServiceRequest
                      service.svc_name
                      method_name
                      ""
                  else if generated_member api
                  then None
                  else
                    make
                      Interpretation.ImplementationAccess
                      service.svc_name
                      ""
                      ""
              | None
                when Hashtbl.mem definitions api
                     && same_boundary from_owner target_owner ->
                  None
              | None when generated_member api -> None
              | None ->
                  let kind =
                    match target_owner.owner_class with
                    | Interpretation.Implementation_of _
                     |Helper_of _
                      when not (same_boundary from_owner target_owner) ->
                        Interpretation.ImplementationAccess
                    | _ -> Interpretation.ExternalCall
                  in
                  make kind "" "" "" ) ) )
  in
  { Interpretation.ownerships
  ; bindings=
      List.sort_uniq
        (fun a b ->
          compare
            ( a.Interpretation.binding_module
            , a.Interpretation.binding_service
            , a.Interpretation.binding_kind )
            ( b.Interpretation.binding_module
            , b.Interpretation.binding_service
            , b.Interpretation.binding_kind ) )
        bindings
  ; interactions= merge_interactions !interactions
  ; execution_interactions
  ; gaps= List.sort_uniq compare !gaps }
