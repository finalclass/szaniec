open Szaniec_model
module Cy = Szaniec_architecture_access.Cyrograf

let bind ~approved ~(policy : Policy.t) ~(cy : Cy.t) (obs : Observation.t) =
  let bindings = Hashtbl.create 32 in
  let rejected = Hashtbl.create 8 in
  let gaps = ref [] in
  let gap code path detail =
    gaps :=
      {Observation.gap_code= code; gap_path= path; gap_detail= detail} :: !gaps
  in
  let add (u : Observation.unit_info) (c : Cy.contract) =
    match Hashtbl.find_opt bindings u.canonical with
    | Some previous when previous <> c ->
        Hashtbl.replace rejected u.canonical () ;
        gap
          "GAP-AMBIGUOUS-OWNERSHIP"
          u.source_path
          ("conflicting contracts for " ^ u.canonical)
    | _ -> if u.fresh then Hashtbl.replace bindings u.canonical c
  in
  List.iter
    (fun (u : Observation.unit_info) ->
      List.iter
        (fun (c : Cy.contract) ->
          if
            Filename.dirname u.source_path = Filename.dirname c.contract_source
            && Cy.segment_matches_service
                 ~service:c.contract_name
                 (Filename.remove_extension (Filename.basename u.source_path))
          then add u c )
        cy.contracts )
    obs.units ;
  if approved
  then
    List.iter
      (fun (b : Policy.contract_binding) ->
        let canonical =
          Canonical.resolve_alias obs.module_aliases b.contract_module
        in
        match
          ( List.find_opt
              (fun (c : Cy.contract) -> c.contract_source = b.contract_source)
              cy.contracts
          , List.find_opt
              (fun (u : Observation.unit_info) -> Some u.canonical = canonical)
              obs.units )
        with
        | Some c, Some u when u.fresh -> add u c
        | _ ->
            gap
              "GAP-PUBLIC-CONTRACT"
              b.contract_source
              ( "contract binding lacks a fresh source/unit: "
              ^ b.contract_module ) )
      policy.contract_bindings ;
  Hashtbl.iter (fun unit () -> Hashtbl.remove bindings unit) rejected ;
  (bindings, List.sort_uniq compare !gaps)

let relative unit path =
  let prefix = unit ^ "." in
  if Canonical.starts_with ~prefix path
  then
    Some
      (String.sub
         path
         (String.length prefix)
         (String.length path - String.length prefix) )
  else None

let data_member (c : Cy.contract) member =
  let segments = Canonical.split_dots member in
  match segments with
  | [message; fn] ->
      List.mem
        fn
        [ "make"
        ; "to_wire"
        ; "of_wire"
        ; "to_data"
        ; "from_data"
        ; "to_drut"
        ; "from_drut"
        ; "wire_of_storage"
        ; "storage_of_wire"
        ; "to_storage_value"
        ; "from_storage_value" ]
      && List.mem message c.contract_messages
  | _ -> false

let rpc_member (cy : Cy.t) (c : Cy.contract) member =
  let name =
    match Canonical.split_dots member with
    | [name]
     |["Proxy"; name] ->
        Some name
    | _ -> None
  in
  match
    ( name
    , List.find_opt
        (fun (s : Cy.service) -> s.svc_name = c.contract_name)
        cy.services )
  with
  | Some name, Some s
    when List.exists (fun (m : Cy.method_decl) -> m.m_name = name) s.svc_methods
    ->
      Some name
  | _ -> None

let mechanic c member =
  data_member c member || List.mem member ["make_spec"; "spec"; "_service_ref"]

let validate_surfaces
    ~approved
    ~(policy : Policy.t)
    ~(cy : Cy.t)
    (obs : Observation.t)
    ownerships =
  let gaps = ref [] in
  let surfaces = if approved then policy.public_contracts else [] in
  let valid =
    List.filter
      (fun (p : Policy.public_contract) ->
        let unit =
          Canonical.unit_prefix
            (List.map
               (fun (u : Observation.unit_info) -> u.canonical)
               obs.units )
            p.public_module
        in
        let owner = Option.bind unit (Hashtbl.find_opt ownerships) in
        let valid =
          List.exists
            (fun (s : Cy.service) -> s.svc_name = p.public_service)
            cy.services
          && ( match owner with
            | Some o -> (
                o.Interpretation.owner_service = p.public_service
                &&
                match o.owner_class with
                | Interpretation.Implementation_of _
                 |Interpretation.Helper_of _ ->
                    true
                | _ -> false )
            | None -> false )
          && List.for_all
               (fun member ->
                 List.mem (p.public_module ^ "." ^ member) obs.defined_values )
               p.public_members
          && List.exists
               (fun (u : Observation.unit_info) ->
                 Some u.canonical = unit && u.fresh )
               obs.units
        in
        if not valid
        then
          gaps :=
            { Observation.gap_code= "GAP-PUBLIC-CONTRACT"
            ; gap_path= p.public_module
            ; gap_detail=
                "owned public surface lacks consistent owner, members or fresh \
                 compiler evidence" }
            :: !gaps ;
        valid )
      surfaces
  in
  let conflicts =
    List.filter
      (fun (p : Policy.public_contract) ->
        List.exists
          (fun (q : Policy.public_contract) ->
            p.public_module = q.public_module && p <> q )
          valid )
      valid
  in
  List.iter
    (fun (p : Policy.public_contract) ->
      gaps :=
        { Observation.gap_code= "GAP-AMBIGUOUS-OWNERSHIP"
        ; gap_path= p.public_module
        ; gap_detail= "conflicting owned public surface declarations" }
        :: !gaps )
    conflicts ;
  ( List.filter (fun p -> not (List.mem p conflicts)) valid
  , List.sort_uniq compare !gaps )

let allowed_surface surfaces ~consumer path =
  List.find_opt
    (fun (p : Policy.public_contract) ->
      List.exists
        (fun member -> path = p.public_module ^ "." ^ member)
        p.public_members
      && (consumer = p.public_service || List.mem consumer p.public_consumers) )
    surfaces
