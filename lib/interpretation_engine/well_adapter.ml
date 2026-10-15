(* InterpretationEngine: binds observed code to architectural boundaries
   and interprets interactions for Well applications.
   See docs/contracts/interpretation-schema.md and
   docs/decisions/donts-based-rules.md. *)

open Szaniec_model

let exclusions =
  [ ".mli bodies (interface freshness recorded)"
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

let sqlite_value_operation api =
  List.mem
    api
    [ "Sqlite3.Rc.to_string"
    ; "Sqlite3.Rc.is_success"
    ; "Sqlite3.Rc.check"
    ; "Sqlite3.Rc.int_of_unknown" ]
  || List.exists
       (fun member -> api = "Sqlite3.Data." ^ member)
       [ "opt_text"
       ; "opt_int"
       ; "opt_nativeint"
       ; "opt_int32"
       ; "opt_int64"
       ; "opt_float"
       ; "opt_bool"
       ; "to_string_exn"
       ; "to_int_exn"
       ; "to_nativeint_exn"
       ; "to_int32_exn"
       ; "to_int64_exn"
       ; "to_float_exn"
       ; "to_bool_exn"
       ; "to_string"
       ; "to_int"
       ; "to_nativeint"
       ; "to_int32"
       ; "to_int64"
       ; "to_float"
       ; "to_bool"
       ; "to_string_coerce"
       ; "to_string_debug" ]

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
    ~unavailable_contracts
    ~serialization_runtimes
    ~local_services
    (cy : Szaniec_architecture_access.Cyrograf.t)
    (obs : Observation.t) :
    ownership_map * Observation.gap list * (string, string) Hashtbl.t =
  let resolve_unit =
    Canonical.unit_resolver
      (List.map (fun (u : Observation.unit_info) -> u.canonical) obs.units)
  in
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
            Option.bind (resolve_unit c.callee) (Hashtbl.find_opt contracts)
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
      | "spec" :: unit_root :: _ -> (
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
                match resolve_unit v.Observation.ref_target with
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
      let local_owners =
        List.filter
          (fun (s : Policy.local_service) ->
            Canonical.starts_with ~prefix:(s.local_root ^ "/") u.source_path
            && List.exists
                 (fun (owner : Szaniec_architecture_access.Cyrograf.service) ->
                   owner.svc_name = s.local_name )
                 cy.services )
          local_services
      in
      let cy =
        { cy with
          Szaniec_architecture_access.Cyrograf.services=
            List.filter
              (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
                (not
                   (List.exists
                      (fun (local : Policy.local_service) ->
                        local.local_name = s.svc_name )
                      local_services ) )
                || List.exists
                     (fun (local : Policy.local_service) ->
                       local.local_name = s.svc_name )
                     local_owners )
              cy.services }
      in
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
                generated_families
                @ List.map
                    (fun (local : Policy.local_service) -> local.local_name)
                    local_owners
                |> fun acc ->
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
                    && List.exists
                         (fun (c : Szaniec_architecture_access.Cyrograf.contract)
                            ->
                           Szaniec_architecture_access.Cyrograf
                           .segment_matches_service
                             ~service:c.contract_name
                             wrapper )
                         cy.contracts
                  then (
                    gaps :=
                      { Observation.gap_code= "GAP-AMBIGUOUS-OWNERSHIP"
                      ; gap_path= u.Observation.source_path
                      ; gap_detail=
                          Printf.sprintf
                            "generated contract provenance cannot be \
                             established for %s"
                            canonical }
                      :: !gaps ;
                    gaps :=
                      { Observation.gap_code= "GAP-PUBLIC-CONTRACT"
                      ; gap_path= u.source_path
                      ; gap_detail=
                          "unmarked generated binding requires an approved \
                           policy.contract_bindings declaration for module "
                          ^ canonical
                          ^ "; select its exact .cyrograf source and run \
                             approve after review" }
                      :: !gaps ) ;
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
        Hashtbl.replace ambiguous_units unit () ;
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
  Hashtbl.iter
    (fun unit () ->
      match Hashtbl.find_opt map unit with
      | Some o
        when o.owner_class = Interpretation.Unclassified
             && not (Hashtbl.mem ambiguous_units unit) ->
          Hashtbl.replace
            map
            unit
            { o with
              owner_class= Interpretation.Contract_data "serialization runtime"
            }
      | _ -> () )
    serialization_runtimes ;
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
                match resolve_unit target with
                | Some target -> (
                  match (Hashtbl.find map target).owner_class with
                  | Interpretation.Contract_of _
                   |Interpretation.Contract_data _ ->
                      true
                  | _ -> false )
                | None -> false )
            in
            let unavailable_alias (_, target) =
              match Canonical.resolve_alias obs.module_aliases target with
              | None -> true
              | Some target ->
                  List.exists
                    (fun prefix ->
                      target = prefix
                      || Canonical.starts_with ~prefix:(prefix ^ ".") target )
                    unavailable_contracts
                  || List.exists
                       (fun (u : Observation.unit_info) ->
                         ( target = u.canonical
                         || Canonical.starts_with
                              ~prefix:(u.canonical ^ ".")
                              target )
                         && ( (not u.fresh)
                            || Hashtbl.mem ambiguous_units u.canonical ) )
                       obs.units
            in
            if aliases <> [] && List.for_all contract_target aliases
            then (
              changed := true ;
              Hashtbl.replace
                map
                unit
                {o with owner_class= Interpretation.Contract_data "aggregator"}
              )
            else if List.exists unavailable_alias aliases
            then (
              changed := true ;
              Hashtbl.replace ambiguous_units unit () ;
              let source =
                List.find
                  (fun (u : Observation.unit_info) -> u.canonical = unit)
                  obs.units
              in
              gaps :=
                { Observation.gap_code= "GAP-AMBIGUOUS-OWNERSHIP"
                ; gap_path= source.source_path
                ; gap_detail=
                    "alias aggregator ownership requires fresh, resolved \
                     contract targets: "
                    ^ unit }
                :: !gaps )
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
          ( resolve_unit c.Observation.callee
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

let resolve_ownership
    ?(approved = false)
    ~(policy : Policy.t)
    ~(cy : Szaniec_architecture_access.Cyrograf.t)
    (obs : Observation.t) =
  let obs, result_targets = Result_callbacks.bind obs in
  let contracts, contract_gaps, unavailable_contracts =
    Public_contracts.bind ~approved ~policy ~cy obs
  in
  let serialization_runtimes =
    Public_contracts.serialization_runtimes contracts obs
  in
  let ownership_map, ownership_gaps, impl_of =
    classify_ownership
      ~contracts
      ~unavailable_contracts
      ~serialization_runtimes
      ~local_services:policy.local_services
      cy
      obs
  in
  ( obs
  , result_targets
  , (contracts, contract_gaps, unavailable_contracts, serialization_runtimes)
  , (ownership_map, ownership_gaps, impl_of) )

let sorted_ownerships map =
  Hashtbl.fold (fun _ o acc -> o :: acc) map []
  |> List.sort (fun a b ->
      compare a.Interpretation.owner_module b.Interpretation.owner_module )

(* Measurement needs exactly the same ownership evidence as a full check,
   without constructing interactions, callback paths or conformance flows. *)
let ownerships ?approved ~policy ~cy obs =
  let _, _, _, (map, _, _) = resolve_ownership ?approved ~policy ~cy obs in
  sorted_ownerships map

let interpret
    ?(approved = false)
    ~(policy : Policy.t)
    ~(cy : Szaniec_architecture_access.Cyrograf.t)
    (obs : Observation.t) : Interpretation.t =
  let ( obs
      , result_targets
      , (contracts, contract_gaps, unavailable_contracts, serialization_runtimes)
      , (ownership_map, ownership_gaps, impl_of) ) =
    resolve_ownership ~approved ~policy ~cy obs
  in
  let surfaces, surface_gaps =
    Public_contracts.validate_surfaces ~approved ~policy ~cy obs ownership_map
  in
  let unit_paths =
    List.map
      (fun (u : Observation.unit_info) -> u.Observation.canonical)
      obs.Observation.units
  in
  let resolve_unit = Canonical.unit_resolver unit_paths in
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
  let unavailable_units = Hashtbl.copy ambiguous_units in
  List.iter
    (fun (u : Observation.unit_info) ->
      if not u.fresh then Hashtbl.replace unavailable_units u.canonical () )
    obs.units ;
  let unavailable_target path =
    List.exists
      (fun prefix ->
        path = prefix || Canonical.starts_with ~prefix:(prefix ^ ".") path )
      unavailable_contracts
    ||
    match resolve_unit path with
    | Some unit -> Hashtbl.mem unavailable_units unit
    | None -> false
  in
  let owner_of_path (path : string) : Interpretation.ownership =
    match resolve_unit path with
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
    match resolve_unit path with
    | Some unit -> Hashtbl.mem generated_units unit
    | None -> false
  in
  let contract_call_target (callee : string) :
      (Szaniec_architecture_access.Cyrograf.service * string (* method *))
      option =
    match resolve_unit callee with
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
            || Public_contracts.serializer_body
                 ~generated:(Hashtbl.mem generated_units unit)
                 contract
                 member
            ||
            match Canonical.split_dots member with
            | [_]
             |["Proxy"; _] ->
                false
            | _ -> true
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
    match resolve_unit path with
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
  let serializer_body path =
    match contract_member path with
    | Some (c, member) ->
        Public_contracts.serializer_body
          ~generated:(generated_path path)
          c
          member
    | None -> false
  in
  let serialization_dependency caller target =
    serializer_body caller
    &&
    match resolve_unit target with
    | Some unit
      when Hashtbl.mem serialization_runtimes unit
           && unit_owner_class unit
              = Interpretation.Contract_data "serialization runtime" ->
        (* The runtime is private to this projection library. *)
        let caller_unit = resolve_unit caller in
        let prefix =
          String.sub unit 0 (String.length unit - String.length "Drut_runtime")
        in
        Option.fold
          ~none:false
          ~some:(Canonical.starts_with ~prefix)
          caller_unit
        && Option.fold
             ~none:false
             ~some:Public_contracts.runtime_member
             (Public_contracts.relative unit target)
    | _ -> false
  in
  let public_module_path path =
    match resolve_unit path with
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
        (fun (r : Policy.resource) ->
          List.exists
            (fun prefix -> Canonical.starts_with ~prefix callee)
            r.api_prefixes )
        policy.resources
    with
    | Some r -> Some r.resource_name
    | None when sqlite_value_operation callee -> None
    | None -> (
      match
        List.find_opt
          (fun (prefix, _) -> Canonical.starts_with ~prefix callee)
          framework_resources
      with
      | Some (_, name) -> Some name
      | None -> None )
  in
  let arities = Hashtbl.create 32 in
  let instance_call (call : Observation.execution_call) =
    List.find_map
      (fun (instance, fn, arg, _) ->
        let prefix = instance ^ "." in
        if
          List.mem fn ["Stdlib.Set.Make"; "Stdlib.Map.Make"]
          && String.starts_with ~prefix call.execution_callee
        then
          let method_ =
            String.sub
              call.execution_callee
              (String.length prefix)
              (String.length call.execution_callee - String.length prefix)
          in
          if String.contains method_ '.'
          then None
          else
            let api = String.sub fn 0 (String.length fn - 5) ^ "." ^ method_ in
            let compared =
              List.mem
                method_
                [ "mem"
                ; "add"
                ; "remove"
                ; "union"
                ; "inter"
                ; "diff"
                ; "compare"
                ; "equal"
                ; "subset"
                ; "disjoint"
                ; "find"
                ; "find_opt"
                ; "split"
                ; "of_list"
                ; "of_seq"
                ; "map"
                ; "update"
                ; "merge" ]
            in
            let args =
              if compared
              then
                { Observation.position= -1
                ; label= "compare"
                ; target= arg ^ ".compare"
                ; field= ""
                ; embedded= false }
                :: call.execution_args
              else call.execution_args
            in
            Some {call with execution_callee= api; execution_args= args}
        else None )
      obs.execution.functor_instances
  in
  let functor_targets =
    obs.execution.invocations
    |> List.filter_map (fun call ->
        Option.map
          (fun mapped ->
            ( call.Observation.execution_callee
            , [mapped.Observation.execution_callee] ) )
          (instance_call call) )
    |> List.sort_uniq compare
  in
  List.iter
    (fun (d : Observation.execution_definition) ->
      Hashtbl.replace arities d.symbol d.definition_arity )
    obs.execution.definitions ;
  List.iter
    (fun (call : Observation.execution_call) ->
      if call.execution_resumed
      then
        match Hashtbl.find_opt arities call.execution_callee with
        | Some arity when arity > call.execution_supplied ->
            Hashtbl.replace
              arities
              call.execution_caller
              (arity - call.execution_supplied)
        | _ -> () )
    obs.execution.invocations ;
  let returned_calls =
    obs.execution.invocations
    |> List.filter_map (fun (call : Observation.execution_call) ->
        if
          call.execution_resumed
          && Option.fold
               ~none:false
               ~some:(fun arity -> arity <= call.execution_supplied)
               (Hashtbl.find_opt arities call.execution_callee)
        then
          Option.map
            (fun target -> (call.execution_site, call.execution_callee, target))
            (List.assoc_opt
               call.execution_callee
               obs.execution.returned_functions )
        else None )
    |> List.sort_uniq compare
  in
  let returned_target (call : Observation.execution_call) =
    if call.execution_resumed
    then
      List.find_map
        (fun (site, source, target) ->
          if site = call.execution_site && source = call.execution_callee
          then Some target
          else None )
        returned_calls
    else None
  in
  let execution =
    { obs.execution with
      invocations=
        List.map
          (fun call ->
            let call = Option.value ~default:call (instance_call call) in
            match returned_target call with
            | Some target ->
                { call with
                  execution_callee= target
                ; execution_resolution= Observation.Resolved }
            | None -> call )
          obs.execution.invocations
    ; Observation.definitions=
        List.map
          (fun (d : Observation.execution_definition) ->
            { d with
              definition_arity=
                Option.value
                  ~default:d.definition_arity
                  (Hashtbl.find_opt arities d.symbol) } )
          obs.execution.definitions }
  in
  let deferred_calls =
    List.filter_map
      (fun (call : Observation.execution_call) ->
        let arity =
          match Hashtbl.find_opt arities call.execution_callee with
          | Some _ as arity -> arity
          | None -> Repetition.collection_arity call.execution_callee
        in
        if
          call.execution_partial
          && Option.fold
               ~none:false
               ~some:(fun arity -> arity > call.execution_supplied)
               arity
        then Some call.execution_site
        else None )
      obs.execution.invocations
    |> List.sort_uniq compare
  in
  let node_of_call (c : Observation.call) : node =
    {n_unit= c.Observation.call_unit; n_symbol= c.Observation.caller}
  in
  let target_of_callee callee =
    match resolve_unit callee with
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
  let unavailable_gap path site =
    let reason =
      match resolve_unit path with
      | None -> "target identity ambiguous or unavailable"
      | Some unit -> (
        match
          List.find_opt
            (fun (u : Observation.unit_info) -> u.canonical = unit)
            obs.units
        with
        | None -> "target unit unavailable"
        | Some u ->
            List.filter
              (fun (g : Observation.gap) -> g.gap_path = u.source_path)
              obs.gaps
            |> List.map (fun g -> g.Observation.gap_code ^ ": " ^ g.gap_detail)
            |> String.concat "; " )
    in
    gaps :=
      { Observation.gap_code= "GAP-UNRESOLVED-TARGET"
      ; gap_path= site.Observation.site_path
      ; gap_detail=
          ( "target ownership cannot be resolved: "
          ^ path
          ^ if reason = "" then "" else "; " ^ reason ) }
      :: !gaps
  in
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
  let known_callback_mode api argument =
    match resolve_unit api with
    | Some unit
      when Hashtbl.mem serialization_runtimes unit
           && argument.Observation.position = 0 -> (
      match Public_contracts.relative unit api with
      | Some ("enc_list" | "dec_list") -> Repetition.Iteration
      | Some ("enc_option" | "dec_option") -> Repetition.Once
      | _ -> Repetition.callback_mode api argument )
    | _ -> Repetition.callback_mode api argument
  in
  let parameter_callbacks =
    Parameter_callbacks.create
      ~callback_mode:known_callback_mode
      ~supplied_parameter:(fun api argument position field ->
        if
          List.mem api ["Well.Db.query"; "Well.Db.query_one"]
          && argument.Observation.position = 3
          && argument.field = ""
          && position = 0
          && List.mem
               field
               [ "int"
               ; "float"
               ; "text"
               ; "bool"
               ; "int_opt"
               ; "float_opt"
               ; "text_opt"
               ; "bool_opt" ]
        then Some ["Well.Db.Row_getter." ^ field]
        else if
          api = "Well.use"
          && argument.position = 0
          && position = 0
          && field = ""
        then Some ["Well.Middleware.next"]
        else None )
      execution
  in
  Parameter_callbacks.bind_calls parameter_callbacks execution ;
  let execution =
    { execution with
      Observation.invocations=
        List.map
          (fun (call : Observation.execution_call) ->
            if Canonical.parameter_symbol call.execution_callee = None
            then call
            else
              match
                Parameter_callbacks.possible_targets
                  parameter_callbacks
                  []
                  call.execution_callee
              with
              | Some [target] ->
                  { call with
                    execution_callee= target
                  ; execution_resolution= Observation.Resolved }
              | _ -> call )
          execution.invocations }
  in
  let bound_parameter target =
    Parameter_callbacks.parameter target <> None
    && Option.fold
         ~none:false
         ~some:(fun targets -> targets <> [])
         (Parameter_callbacks.possible_targets parameter_callbacks [] target)
  in
  let bound_parameters =
    obs.execution.invocations
    |> List.concat_map (fun (c : Observation.execution_call) ->
        c.execution_callee
        :: List.map
             (fun (a : Observation.execution_arg) -> a.target)
             c.execution_args )
    |> List.filter bound_parameter
    |> List.sort_uniq compare
  in
  let unresolved_gap (c : Observation.call) =
    let site = c.Observation.site in
    let allowed_unit =
      match unit_owner_class c.Observation.call_unit with
      | Interpretation.ExternalLibrary _ -> false
      | Interpretation.Contract_data "serialization runtime"
        when c.resolution = Observation.Unresolved_local
             && Public_contracts.runtime_member
                  (List.hd (String.split_on_char '.' c.caller)) ->
          false (* Primitive runtime callbacks stay in the raw observation. *)
      | _ ->
          (not (generated_member (c.call_unit ^ "." ^ c.caller)))
          || serializer_body (c.call_unit ^ "." ^ c.caller)
    in
    let inactive_literal =
      List.exists
        (String.starts_with ~prefix:"<callback@")
        (Canonical.split_dots c.caller)
      && Parameter_callbacks.inert_callback
           parameter_callbacks
           (c.call_unit ^ "." ^ c.caller)
    in
    if allowed_unit && (not inactive_literal) && not (bound_parameter c.callee)
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
                | Observation.Unresolved_ambiguous ->
                    "ambiguous compiler-known callback targets"
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
        if
          List.mem site deferred_calls
          && ( resource_of_api c.callee <> None
             || contract_call_target c.callee <> None
             || same_boundary
                  (owner_of_path c.call_unit)
                  (owner_of_path c.callee) )
        then ()
        else if c.Observation.resolution <> Observation.Resolved
        then unresolved_gap c
        else if String.length c.Observation.callee = 0
        then ()
        else if unavailable_target c.callee && resource_of_api c.callee = None
        then unavailable_gap c.callee site
        else if
          serialization_dependency (c.call_unit ^ "." ^ c.caller) c.callee
          && resource_of_api c.callee = None
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
    | _ ->
        (not (generated_member (n.n_unit ^ "." ^ n.n_symbol)))
        || serializer_body (n.n_unit ^ "." ^ n.n_symbol)
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
                  match resolve_unit v.Observation.ref_target with
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
      match resolve_unit v.Observation.ref_target with
      | _ when unavailable_target v.ref_target ->
          unavailable_gap v.ref_target v.ref_site
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
          let public_surface_module =
            List.exists
              (fun (p : Policy.public_contract) ->
                v.ref_target = p.public_module
                && ( from_name v.ref_unit = p.public_service
                   || List.mem (from_name v.ref_unit) p.public_consumers ) )
              surfaces
          in
          if
            (not is_wiring_ref)
            && (not (Hashtbl.mem ambiguous_units target_unit))
            && (not (Hashtbl.mem ambiguous_units v.ref_unit))
            && ( (not (generated_member (v.ref_unit ^ "." ^ v.ref_caller)))
               || serializer_body (v.ref_unit ^ "." ^ v.ref_caller) )
            && (not (generated_member v.ref_target))
            && (not
                  (serialization_dependency
                     (v.ref_unit ^ "." ^ v.ref_caller)
                     v.ref_target ) )
            && (not (public_module_path v.ref_target))
            && not public_surface_module
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
  let ownerships = sorted_ownerships ownership_map in
  let execution_owner symbol =
    let owner = owner_of_path symbol in
    if owner.owner_service = "" then owner.owner_module else owner.owner_service
  in
  let definitions =
    let definitions = Hashtbl.create 64 in
    List.iter
      (fun (d : Observation.execution_definition) ->
        Hashtbl.replace definitions d.symbol () )
      obs.execution.definitions ;
    definitions
  in
  let eligible symbol =
    if
      Option.fold
        ~none:false
        ~some:(Hashtbl.mem ambiguous_units)
        (resolve_unit symbol)
    then false
    else
      match (owner_of_path symbol).owner_class with
      | Interpretation.Contract_of _
       |Contract_data _
       |ExternalLibrary _ ->
          false
      | _ -> not (generated_member symbol)
  in
  let entry_point symbol =
    let owner = owner_of_path symbol in
    let name =
      match List.rev (Canonical.split_dots symbol) with
      | name :: _ -> name
      | [] -> ""
    in
    List.exists
      (fun service ->
        service.Szaniec_architecture_access.Cyrograf.svc_name
        = owner.owner_service
        && List.exists
             (fun method_ ->
               method_.Szaniec_architecture_access.Cyrograf.m_name = name )
             service.svc_methods )
      cy.Szaniec_architecture_access.Cyrograf.services
  in
  let classify_execution origin (call : Observation.execution_call) =
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
    else if unavailable_target api && resource_of_api api = None
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
                make Interpretation.ImplementationAccess service.svc_name "" ""
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
              make kind "" "" "" ) )
  in
  let execution_interactions =
    Repetition.project_with_callbacks
      ~callback_mode:(fun api arg ->
        let factory_method =
          match contract_member api with
          | Some (contract, "make_spec") ->
              List.exists
                (fun (service : Szaniec_architecture_access.Cyrograf.service) ->
                  service.svc_name = contract.contract_name
                  && List.exists
                       (fun method_ ->
                         method_.Szaniec_architecture_access.Cyrograf.m_name
                         = arg.Observation.field )
                       service.svc_methods )
                cy.services
          | _ -> false
        in
        if factory_method
        then Repetition.Activation
        else if
          Hashtbl.mem definitions api
          && Hashtbl.mem parameter_callbacks.uses api
        then
          match Parameter_callbacks.summary parameter_callbacks [] api with
          | Some groups
            when List.exists
                   (List.exists (fun (position, field) ->
                        position = arg.Observation.position
                        && (arg.field = field || arg.field = "") ) )
                   groups ->
              Repetition.Once
          | Some _ -> Repetition.Ignored
          | None -> known_callback_mode api arg
        else known_callback_mode api arg )
      ~execution
      ~owner_of:execution_owner
      ~eligible
      ~entry_point
      ~classify:classify_execution
    |> List.map (fun (e : Interpretation.execution_interaction) ->
        let path = e.execution_interaction.api in
        if
          e.execution_interaction.kind = Interpretation.ExternalCall
          && unavailable_target path
        then
          { e with
            execution_interaction= {e.execution_interaction with api= ""}
          ; execution_context=
              { e.execution_context with
                unknown_reasons=
                  List.sort_uniq
                    compare
                    ( ("target ownership cannot be resolved: " ^ path)
                    :: e.execution_context.unknown_reasons ) } }
        else e )
  in
  let flow_interactions = Hashtbl.create 32 in
  List.iter
    (fun (i : Interpretation.interaction) ->
      if
        List.mem
          i.kind
          [Interpretation.QueuedCommand; Publication; Subscription; Registration]
      then
        List.iter
          (fun site ->
            let key = (i.api, site) in
            let rows =
              Option.value ~default:[] (Hashtbl.find_opt flow_interactions key)
            in
            Hashtbl.replace flow_interactions key (i :: rows) )
          i.sites )
    !interactions ;
  let classify_flow origin call =
    match
      Option.value
        ~default:[]
        (Hashtbl.find_opt
           flow_interactions
           (call.Observation.execution_callee, call.execution_site) )
    with
    | [] -> Option.to_list (classify_execution origin call)
    | rows -> List.sort_uniq compare rows
  in
  let execution_flows =
    Ordered_flow.project
      ~execution
      ~owner_of:execution_owner
      ~available:(fun api ->
        (not (unavailable_target api)) || resource_of_api api <> None )
      ~eligible
      ~entry_point
      ~classify:classify_flow
  in
  let callbacks =
    List.concat_map
      (fun (call : Observation.execution_call) ->
        List.map
          (fun (argument : Observation.execution_arg) ->
            let phase =
              let factory_method =
                match contract_member call.execution_callee with
                | Some (contract, "make_spec") ->
                    List.exists
                      (fun (service :
                             Szaniec_architecture_access.Cyrograf.service )
                         ->
                        service.svc_name = contract.contract_name
                        && List.exists
                             (fun method_ ->
                               method_
                                 .Szaniec_architecture_access.Cyrograf.m_name
                               = argument.Observation.field )
                             service.svc_methods )
                      cy.services
                | _ -> false
              in
              if factory_method
              then Interpretation.Independent
              else if
                Hashtbl.mem definitions call.execution_callee
                && Parameter_callbacks.summary
                     parameter_callbacks
                     []
                     call.execution_callee
                   <> None
                && Hashtbl.mem parameter_callbacks.uses call.execution_callee
              then
                let groups =
                  Option.get
                    (Parameter_callbacks.summary
                       parameter_callbacks
                       []
                       call.execution_callee )
                in
                if
                  List.exists
                    (List.exists (fun (position, field) ->
                         position = argument.position
                         && (argument.field = field || argument.field = "") ) )
                    groups
                then Interpretation.Same_path
                else Interpretation.Deferred
              else if
                Hashtbl.mem definitions call.execution_callee
                && eligible call.execution_callee
                && same_boundary
                     (owner_of_path call.execution_caller)
                     (owner_of_path call.execution_callee)
              then Interpretation.Deferred
              else
                match known_callback_mode call.execution_callee argument with
                | Repetition.Iteration
                 |Once
                  when call.execution_resumed
                       || not (List.mem call.execution_site deferred_calls) ->
                    Interpretation.Same_path
                | Activation -> Interpretation.Independent
                | Ignored -> Interpretation.Deferred
                | _
                  when (not call.execution_resumed)
                       && List.mem call.execution_site deferred_calls ->
                    Interpretation.Deferred
                | _ -> Interpretation.Unknown_callback
            in
            let phase =
              if
                List.mem phase [Interpretation.Same_path; Independent]
                && call.execution_callee <> "Stdlib.Scanf.sscanf"
                && Option.fold
                     ~none:false
                     ~some:(fun arity ->
                       arity
                       > Option.value
                           ~default:
                             (Repetition.argument_arity
                                call.execution_callee
                                argument )
                           (Parameter_callbacks.input_arity
                              parameter_callbacks
                              []
                              call.execution_callee
                              argument.position ) )
                     (Hashtbl.find_opt arities argument.target)
              then Interpretation.Deferred
              else phase
            in
            if
              argument.target = ""
              && List.mem phase [Interpretation.Same_path; Independent]
              && eligible call.execution_caller
            then
              gaps :=
                { Observation.gap_code= "GAP-UNRESOLVED-CALL"
                ; gap_path= call.execution_site.site_path
                ; gap_detail=
                    "callback target provenance cannot be resolved for "
                    ^ call.execution_callee }
                :: !gaps ;
            if
              phase = Interpretation.Unknown_callback
              && eligible call.execution_caller
              && ( argument.target = ""
                 || Hashtbl.mem definitions argument.target
                 || resource_of_api argument.target <> None )
            then
              gaps :=
                { Observation.gap_code= "GAP-CALLBACK-SEMANTICS"
                ; gap_path= call.execution_site.site_path
                ; gap_detail=
                    "callback execution is unknown for API "
                    ^ call.execution_callee
                    ^ "; closure construction/passing does not prove invocation"
                }
                :: !gaps ;
            { Interpretation.callback_site= call.execution_site
            ; callback_target= argument.target
            ; callback_resumed= call.execution_resumed
            ; callback_phase= phase } )
          call.execution_args )
      execution.invocations
    |> List.sort_uniq compare
  in
  let callback_paths =
    obs.execution.invocations
    |> List.filter_map (fun (call : Observation.execution_call) ->
        if
          call.execution_resumed
          || List.mem call.execution_site deferred_calls
          || not (Hashtbl.mem parameter_callbacks.uses call.execution_callee)
        then None
        else
          Option.map
            (fun paths -> (call.execution_site, paths))
            (Parameter_callbacks.paths
               parameter_callbacks
               ~invoked:(fun position target ->
                 Option.fold
                   ~none:true
                   ~some:(fun arity ->
                     arity
                     <= Option.value
                          ~default:1
                          (Parameter_callbacks.input_arity
                             parameter_callbacks
                             []
                             call.execution_callee
                             position ) )
                   (Hashtbl.find_opt arities target) )
               call ) )
  in
  List.iter
    (fun (call : Observation.execution_call) ->
      if
        call.execution_resumed
        && eligible call.execution_caller
        && returned_target call = None
      then
        let arity =
          match Hashtbl.find_opt arities call.execution_callee with
          | Some _ as value -> value
          | None -> Repetition.collection_arity call.execution_callee
        in
        if
          Option.fold
            ~none:true
            ~some:(fun arity -> arity <= call.execution_supplied)
            arity
        then
          let sites =
            List.filter_map
              (fun (use : Observation.execution_call) ->
                if use.execution_callee = call.execution_caller
                then Some use.execution_site
                else None )
              obs.execution.invocations
            @ List.filter_map
                (fun (callback : Interpretation.callback_evidence) ->
                  if
                    callback.callback_target = call.execution_caller
                    && List.mem
                         callback.callback_phase
                         [Interpretation.Same_path; Independent]
                  then Some callback.callback_site
                  else None )
                callbacks
          in
          List.iter
            (fun site ->
              gaps :=
                { Observation.gap_code= "GAP-RETURNED-CLOSURE"
                ; gap_path= site.Observation.site_path
                ; gap_detail=
                    "returned function execution target cannot be established \
                     from factory "
                    ^ call.execution_callee }
                :: !gaps )
            sites )
    obs.execution.invocations ;
  let callback_interactions =
    execution_interactions
    |> List.filter_map (fun (e : Interpretation.execution_interaction) ->
        let i = e.execution_interaction in
        if
          e.execution_context.unknown_reasons <> []
          || (not
                (List.mem
                   i.kind
                   [Interpretation.ServiceRequest; ResourceAccess; QueuedCommand] ) )
          || List.exists
               (fun (previous : Interpretation.interaction) ->
                 previous.kind = i.kind
                 && previous.from_owner = i.from_owner
                 && previous.to_service = i.to_service
                 && previous.api = i.api
                 && List.exists
                      (fun site -> List.mem site previous.sites)
                      i.sites )
               !interactions
        then None
        else Some i )
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
  ; interactions= merge_interactions (!interactions @ callback_interactions)
  ; execution_interactions
  ; execution_flows
  ; callbacks
  ; callback_paths
  ; bound_parameters
  ; returned_calls
  ; parameter_defaults= obs.execution.parameter_defaults
  ; parameter_targets=
      List.filter_map
        (fun symbol ->
          Option.map
            (fun targets -> (symbol, targets))
            (Parameter_callbacks.possible_targets parameter_callbacks [] symbol) )
        bound_parameters
      @ functor_targets
      @ result_targets
  ; deferred_calls
  ; gaps= List.sort_uniq compare !gaps }
