(* InterpretationEngine: binds observed code to architectural boundaries
   and interprets interactions for Well applications.
   See docs/contracts/interpretation-schema.md. *)

open Szaniec_model

let exclusions =
  [ ".mlx view files (MLX preprocessor not in this profile)"
  ; ".mli interfaces (implementation facts only)"
  ; "dune wrapper units (.ml-gen)"
  ; "queued-command, publish/subscribe and use-case rules (messaging recorded \
     as evidence only)"
  ; "resource access beyond policy-declared apiPrefixes (recorded as external \
     calls)" ]

(* Well framework APIs interpreted as registration/wiring: implementation
   references passed through them are framework mechanics. *)
let registration_apis = ["Well.Service.register"; "Well.Service.expose"]

let route_apis = ["Well.get"; "Well.post"; "Well.live"]

let messaging_apis =
  ["Well.subscribe_keyed"; "Well.publish_keyed"; "Well.request"]

let external_of (policy : Policy.t) (canonical : string) : string option =
  List.find_map
    (fun (e : Policy.external_library) ->
      if
        List.exists
          (fun p -> Canonical.starts_with ~prefix:p canonical)
          e.Policy.unit_prefixes
      then Some e.Policy.lib_name
      else None )
    policy.Policy.external_libraries

type ownership_map = (string, Interpretation.ownership) Hashtbl.t

let classify_ownership (policy : Policy.t) (obs : Observation.t) :
    ownership_map * Observation.gap list =
  let map : ownership_map = Hashtbl.create 64 in
  let gaps = ref [] in
  let canonical_paths =
    List.map
      (fun (u : Observation.unit_info) -> u.Observation.canonical)
      obs.Observation.units
  in
  let declared :
      (string * string * string * Interpretation.ownership_class) list =
    List.concat_map
      (fun (s : Policy.service) ->
        let cls kind =
          match kind with
          | "contract" -> Interpretation.Contract_of s.Policy.name
          | "implementation" -> Interpretation.Implementation_of s.Policy.name
          | _ -> Interpretation.Helper_of s.Policy.name
        in
        List.map
          (fun m -> (m, s.Policy.name, "contract", cls "contract"))
          s.Policy.contract_modules
        @ List.map
            (fun m -> (m, s.Policy.name, "implementation", cls "implementation"))
            s.Policy.implementation_modules
        @ List.map
            (fun m -> (m, s.Policy.name, "helper", cls "helper"))
            s.Policy.helper_modules )
      policy.Policy.services
  in
  let candidates name =
    List.filter (fun c -> Canonical.matches ~declared:name c) canonical_paths
  in
  let add_gap code path detail =
    gaps :=
      {Observation.gap_code= code; gap_path= path; gap_detail= detail} :: !gaps
  in
  List.iter
    (fun (declared_name, service, kind, cls) ->
      match candidates declared_name with
      | [] -> ()
      | _ :: _ :: _ ->
          add_gap
            "GAP-AMBIGUOUS-OWNERSHIP"
            declared_name
            (Printf.sprintf
               "declared %s of %s matches several units: %s"
               kind
               service
               (String.concat ", " (candidates declared_name)) )
      | [c] -> (
        match Hashtbl.find_opt map c with
        | Some _ ->
            add_gap
              "GAP-AMBIGUOUS-OWNERSHIP"
              c
              (Printf.sprintf
                 "unit %s is claimed by more than one declared module"
                 c )
        | None ->
            Hashtbl.replace
              map
              c
              {owner_module= c; owner_class= cls; owner_service= service} ) )
    declared ;
  List.iter
    (fun name ->
      match candidates name with
      | [] -> ()
      | _ :: _ :: _ ->
          add_gap
            "GAP-AMBIGUOUS-OWNERSHIP"
            name
            (Printf.sprintf
               "declared module matches several units: %s"
               (String.concat ", " (candidates name)) )
      | [c] ->
          if not (Hashtbl.mem map c)
          then
            Hashtbl.replace
              map
              c
              { owner_module= c
              ; owner_class= Interpretation.CompositionRoot
              ; owner_service= "" } )
    (policy.Policy.composition_roots @ policy.Policy.approved_shared_modules) ;
  List.iter
    (fun (u : Observation.unit_info) ->
      if not (Hashtbl.mem map u.Observation.canonical)
      then
        match external_of policy u.Observation.canonical with
        | Some lib ->
            Hashtbl.replace
              map
              u.Observation.canonical
              { owner_module= u.Observation.canonical
              ; owner_class= Interpretation.ExternalLibrary lib
              ; owner_service= "" }
        | None ->
            Hashtbl.replace
              map
              u.Observation.canonical
              { owner_module= u.Observation.canonical
              ; owner_class= Interpretation.Unclassified
              ; owner_service= "" } )
    obs.Observation.units ;
  (map, List.sort_uniq compare !gaps)

type node =
  { n_unit: string
  ; n_symbol: string }

let node_id (n : node) = n.n_unit ^ "@" ^ n.n_symbol

let same_boundary (a : Interpretation.ownership) (b : Interpretation.ownership)
    : bool =
  a.Interpretation.owner_service <> ""
  && String.equal a.Interpretation.owner_service b.Interpretation.owner_service
  || String.equal a.Interpretation.owner_module b.Interpretation.owner_module

let interpret ~(policy : Policy.t) (obs : Observation.t) : Interpretation.t =
  let ownership_map, ownership_gaps = classify_ownership policy obs in
  let unit_paths =
    List.map
      (fun (u : Observation.unit_info) -> u.Observation.canonical)
      obs.Observation.units
  in
  let owner_of_path (path : string) : Interpretation.ownership =
    match Canonical.unit_prefix unit_paths path with
    | Some u -> Hashtbl.find ownership_map u
    | None ->
        { owner_module= path
        ; owner_class= Interpretation.Unclassified
        ; owner_service= "" }
  in
  let unit_owner_class path = (owner_of_path path).owner_class in
  let resource_of_api callee =
    List.find_map
      (fun (r : Policy.resource) ->
        if
          List.exists
            (fun p -> Canonical.starts_with ~prefix:p callee)
            r.Policy.api_prefixes
        then Some r.Policy.resource_name
        else None )
      policy.Policy.resources
  in
  let implementation_service module_path =
    List.find_map
      (fun (s : Policy.service) ->
        if
          List.exists
            (fun m -> Canonical.matches ~declared:m module_path)
            s.Policy.implementation_modules
        then Some s.Policy.name
        else None )
      policy.Policy.services
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
            | Interpretation.Contract_of _, _ -> ()
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
  let gaps = ref ownership_gaps in
  let unresolved_seen : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  let record_interaction
      kind
      from_owner
      to_service
      target_module
      resource
      api
      path
      site =
    interactions :=
      { Interpretation.kind
      ; from_owner
      ; to_service
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
      | Interpretation.Contract_of _
       |Interpretation.ExternalLibrary _ ->
          false
      | _ -> true
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
      List.iter
        (fun (c : Observation.call) ->
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
                  callee
                  resource
                  callee
                  (path @ [callee])
                  site
            | None -> (
              match target_of_callee callee with
              | None ->
                  (* not observed in the build tree: external package *)
                  let kind =
                    if
                      List.exists
                        (fun a -> String.equal a callee)
                        messaging_apis
                    then Interpretation.MessagingEvidence
                    else Interpretation.ExternalCall
                  in
                  record_interaction
                    kind
                    (from_name c.Observation.call_unit)
                    ""
                    callee
                    ""
                    callee
                    (path @ [callee])
                    site
              | Some target -> (
                  let to_owner = owner_of_path target.n_unit in
                  let self_call =
                    String.equal to_owner.owner_service from_owner.owner_service
                    && from_owner.owner_service <> ""
                  in
                  match to_owner.owner_class with
                  | Interpretation.Contract_of s when self_call ->
                      (* own contract: binding evidence, not an interaction *)
                      if Filename.basename callee = "make_spec"
                      then
                        record_interaction
                          Interpretation.Registration
                          (from_name c.Observation.call_unit)
                          s
                          target.n_unit
                          ""
                          callee
                          (path @ [callee])
                          site
                  | Interpretation.Contract_of s ->
                      record_interaction
                        Interpretation.ServiceRequest
                        (from_name c.Observation.call_unit)
                        s
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
                        target.n_unit
                        ""
                        callee
                        (path @ [callee])
                        site
                  | Interpretation.CompositionRoot
                   |Interpretation.Unclassified
                   |Interpretation.ExternalLibrary _ ->
                      (* no rule crosses into these; unclassified units report
                           their own interactions as origins *)
                      () ) ) )
        (out_edges_of n)
  in
  let walkable (n : node) =
    match unit_owner_class n.n_unit with
    | Interpretation.Contract_of _
     |Interpretation.ExternalLibrary _ ->
        false
    | _ -> true
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
  (* registration evidence: make_spec calls on own contract were recorded
     as Registration interactions; route-handler wiring recorded here *)
  let bindings =
    List.filter_map
      (fun (v : Observation.value_ref) ->
        let caller_owner = owner_of_path v.Observation.ref_unit in
        match caller_owner.owner_class with
        | Interpretation.CompositionRoot ->
            let is_wiring =
              List.exists
                (fun (c : Observation.call) ->
                  String.equal c.Observation.call_unit v.Observation.ref_unit
                  && String.equal c.Observation.caller v.Observation.ref_caller
                  && List.exists
                       (fun a -> String.equal a c.Observation.callee)
                       (registration_apis @ route_apis) )
                obs.Observation.calls
            in
            if is_wiring
            then
              match implementation_service v.Observation.ref_target with
              | Some s ->
                  Some
                    { Interpretation.binding_service= s
                    ; binding_kind= "registration"
                    ; binding_module= v.Observation.ref_target }
              | None -> (
                match
                  implementation_service
                    (owner_of_path v.Observation.ref_target).owner_module
                with
                | Some s ->
                    Some
                      { Interpretation.binding_service= s
                      ; binding_kind= "route-handler"
                      ; binding_module= v.Observation.ref_target }
                | None -> None )
            else None
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
                        (registration_apis @ route_apis) )
                 obs.Observation.calls
          in
          if not is_wiring_ref
          then
            match target_owner.owner_class with
            | Interpretation.Implementation_of s
              when not (same_boundary caller_owner target_owner) ->
                record_interaction
                  Interpretation.ImplementationAccess
                  (from_name v.Observation.ref_unit)
                  s
                  target_unit
                  ""
                  v.Observation.ref_target
                  [v.Observation.ref_target]
                  v.Observation.ref_site
            | Interpretation.Helper_of s
              when not (same_boundary caller_owner target_owner) ->
                record_interaction
                  Interpretation.ImplementationAccess
                  (from_name v.Observation.ref_unit)
                  s
                  target_unit
                  ""
                  v.Observation.ref_target
                  [v.Observation.ref_target]
                  v.Observation.ref_site
            | _ -> () )
      | None -> () )
    obs.Observation.value_refs ;
  let sort_interactions
      (a : Interpretation.interaction)
      (b : Interpretation.interaction) =
    compare
      ( Interpretation.kind_name a.kind
      , a.from_owner
      , a.to_service
      , a.target_module
      , a.api
      , String.concat ">" a.evidence_path )
      ( Interpretation.kind_name b.kind
      , b.from_owner
      , b.to_service
      , b.target_module
      , b.api
      , String.concat ">" b.evidence_path )
  in
  let ownerships =
    Hashtbl.fold (fun _ o acc -> o :: acc) ownership_map []
    |> List.sort (fun a b ->
        compare a.Interpretation.owner_module b.Interpretation.owner_module )
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
  ; interactions=
      List.sort_uniq sort_interactions !interactions
      |> List.map (fun i ->
          {i with Interpretation.sites= List.sort compare i.Interpretation.sites} )
  ; gaps= List.sort_uniq compare !gaps }
