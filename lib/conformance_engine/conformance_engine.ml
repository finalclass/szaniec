(* ConformanceEngine: evaluates the interpretation model against the
   service roles and the policy using the rule catalog
   szaniec-rules/2.1.0. There is no permitted-calls list: conformance
   follows the structural IDesign don'ts and closed-architecture
   layering. See docs/contracts/rule-catalog.md. *)

open Szaniec_model

let mk_finding rule message participants locations evidence_path =
  { Finding.rule
  ; severity= Finding.Violation
  ; message
  ; participants
  ; locations
  ; evidence_path }

let sites_locations (sites : Observation.site list) : Finding.location list =
  List.map
    (fun s ->
      { Finding.loc_path= s.Observation.site_path
      ; loc_line= s.Observation.line
      ; loc_col= s.Observation.col } )
    sites

(* Role of a boundary name: suffix rule (decision record). *)
let role_of_name = Szaniec_architecture_access.Cyrograf.role_of_suffix

let evaluate
    ~(approved : bool)
    ~(policy : Policy.t)
    ~(cy : Szaniec_architecture_access.Cyrograf.t)
    ~(observation : Observation.t)
    ~(interpretation : Interpretation.t) : Finding.t list =
  let findings = ref [] in
  let add f = findings := f :: !findings in
  (* Whitelist exceptions belong to the selected approved policy. An
     edited file is still checked, but its list does not grant them. *)
  let shared_modules =
    if approved then policy.Policy.approved_shared_modules else []
  in
  let units_matching (declared : string) : string list =
    observation.Observation.units
    |> List.filter_map (fun (u : Observation.unit_info) ->
        if Canonical.matches ~declared u.Observation.canonical
        then Some u.Observation.canonical
        else None )
    |> List.sort_uniq compare
  in
  let ambiguous_shared =
    List.filter
      (fun declared -> List.length (units_matching declared) > 1)
      shared_modules
  in
  List.iter
    (fun declared ->
      add
        { Finding.rule= "GAP-AMBIGUOUS-OWNERSHIP"
        ; severity= Finding.GapFinding
        ; message=
            Printf.sprintf
              "approved shared module %s matches more than one unit"
              declared
        ; participants= units_matching declared
        ; locations= []
        ; evidence_path= [declared] } )
    ambiguous_shared ;
  let approved_shared (path : string) : bool =
    List.exists
      (fun declared ->
        (not (List.mem declared ambiguous_shared))
        && Canonical.matches ~declared path )
      shared_modules
  in
  List.iter
    (fun (i : Interpretation.interaction) ->
      match i.Interpretation.kind with
      | Interpretation.ServiceRequest -> (
          let from_role = role_of_name i.Interpretation.from_owner in
          let to_role = role_of_name i.Interpretation.to_service in
          let self_call =
            String.equal i.Interpretation.from_owner i.Interpretation.to_service
          in
          if not self_call
          then
            match (from_role, to_role) with
            | ( Szaniec_architecture_access.Cyrograf.Client
              , Szaniec_architecture_access.Cyrograf.Access ) ->
                add
                  (mk_finding
                     "ID-CLIENT-ACCESS"
                     (Printf.sprintf
                        "client service %s calls access service %s directly \
                         (must reach it through a Manager)"
                        i.Interpretation.from_owner
                        i.Interpretation.to_service )
                     [i.Interpretation.from_owner; i.Interpretation.to_service]
                     (sites_locations i.Interpretation.sites)
                     i.Interpretation.evidence_path )
            | ( Szaniec_architecture_access.Cyrograf.Client
              , Szaniec_architecture_access.Cyrograf.Engine ) ->
                add
                  (mk_finding
                     "ID-CLIENT-ENGINE"
                     (Printf.sprintf
                        "client service %s calls engine service %s (the only \
                         entry points to the business layer are Managers)"
                        i.Interpretation.from_owner
                        i.Interpretation.to_service )
                     [i.Interpretation.from_owner; i.Interpretation.to_service]
                     (sites_locations i.Interpretation.sites)
                     i.Interpretation.evidence_path )
            | ( Szaniec_architecture_access.Cyrograf.Engine
              , Szaniec_architecture_access.Cyrograf.Engine ) ->
                add
                  (mk_finding
                     "ID-ENGINE-ENGINE"
                     (Printf.sprintf
                        "engine service %s calls engine service %s"
                        i.Interpretation.from_owner
                        i.Interpretation.to_service )
                     [i.Interpretation.from_owner; i.Interpretation.to_service]
                     (sites_locations i.Interpretation.sites)
                     i.Interpretation.evidence_path )
            | ( Szaniec_architecture_access.Cyrograf.Access
              , Szaniec_architecture_access.Cyrograf.Access ) ->
                add
                  (mk_finding
                     "ID-ACCESS-ACCESS"
                     (Printf.sprintf
                        "access service %s calls access service %s (an atomic \
                         business verb cannot require another)"
                        i.Interpretation.from_owner
                        i.Interpretation.to_service )
                     [i.Interpretation.from_owner; i.Interpretation.to_service]
                     (sites_locations i.Interpretation.sites)
                     i.Interpretation.evidence_path )
            | ( Szaniec_architecture_access.Cyrograf.Access
              , ( Szaniec_architecture_access.Cyrograf.Manager
                | Szaniec_architecture_access.Cyrograf.Engine ) ) ->
                add
                  (mk_finding
                     "ID-ACCESS-OUTBOUND"
                     (Printf.sprintf
                        "access service %s calls %s service %s (upward call)"
                        i.Interpretation.from_owner
                        (Szaniec_architecture_access.Cyrograf.role_to_string
                           to_role )
                        i.Interpretation.to_service )
                     [i.Interpretation.from_owner; i.Interpretation.to_service]
                     (sites_locations i.Interpretation.sites)
                     i.Interpretation.evidence_path )
            | _ -> () )
      | Interpretation.ImplementationAccess ->
          if approved_shared i.Interpretation.target_module
          then ()
          else
            let message, participants =
              if String.equal i.Interpretation.to_service ""
              then
                ( Printf.sprintf
                    "%s uses executable implementation %s outside its service \
                     family"
                    i.Interpretation.from_owner
                    i.Interpretation.target_module
                , [i.Interpretation.from_owner; i.Interpretation.target_module]
                )
              else
                ( Printf.sprintf
                    "%s uses implementation of service %s outside its public \
                     contract (module %s)"
                    i.Interpretation.from_owner
                    i.Interpretation.to_service
                    i.Interpretation.target_module
                , [i.Interpretation.from_owner; i.Interpretation.to_service] )
            in
            add
              (mk_finding
                 "IMPL-ACCESS-CROSS-SERVICE"
                 message
                 participants
                 (sites_locations i.Interpretation.sites)
                 i.Interpretation.evidence_path )
      | Interpretation.ResourceAccess ->
          (* Allowed performers: Access-role services, Utility-role
             services (the infrastructure bar) and approved shared
             modules. *)
          let from_role = role_of_name i.Interpretation.from_owner in
          let allowed =
            from_role = Szaniec_architecture_access.Cyrograf.Access
            || from_role = Szaniec_architecture_access.Cyrograf.Utility
            || approved_shared i.Interpretation.from_owner
          in
          if not allowed
          then
            add
              (mk_finding
                 "RESOURCE-BOUNDARY"
                 (Printf.sprintf
                    "%s accesses protected resource %s through %s"
                    i.Interpretation.from_owner
                    i.Interpretation.resource
                    i.Interpretation.api )
                 [i.Interpretation.from_owner; i.Interpretation.resource]
                 (sites_locations i.Interpretation.sites)
                 i.Interpretation.evidence_path )
      | Interpretation.Registration
       |Interpretation.ExternalCall
       |Interpretation.MessagingEvidence ->
          () )
    interpretation.Interpretation.interactions ;
  (* specification rules *)
  (* undeclared methods are carried as findings from the interpreter *)
  List.iter
    (fun (g : Observation.gap) ->
      if String.equal g.Observation.gap_code "SPEC-UNDECLARED-METHOD"
      then
        add
          { Finding.rule= "SPEC-UNDECLARED-METHOD"
          ; severity= Finding.Violation
          ; message= g.Observation.gap_detail
          ; participants= []
          ; locations=
              [ { Finding.loc_path= g.Observation.gap_path
                ; loc_line= 0
                ; loc_col= 0 } ]
          ; evidence_path= [] }
        |> ignore )
    interpretation.Interpretation.gaps ;
  (* unregistered services. A missing binding is not evidence when
     artifacts were not read: the registration may sit in a stale unit. *)
  let evidence_missing =
    List.exists
      (fun (g : Observation.gap) ->
        List.mem
          g.Observation.gap_code
          [ "GAP-STALE-ARTIFACT"
          ; "GAP-UNOBSERVED-SOURCE"
          ; "GAP-ARTIFACT-READ"
          ; "GAP-UNSUPPORTED-COMPILER" ] )
      observation.Observation.gaps
  in
  List.iter
    (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
      let bound =
        List.exists
          (fun (b : Interpretation.binding) ->
            String.equal
              b.Interpretation.binding_service
              s.Szaniec_architecture_access.Cyrograf.svc_name )
          interpretation.Interpretation.bindings
      in
      if (not bound) && not evidence_missing
      then
        add
          (mk_finding
             "SPEC-UNREGISTERED-SERVICE"
             (Printf.sprintf
                "service %s declares rpc methods but no implementation is \
                 registered"
                s.Szaniec_architecture_access.Cyrograf.svc_name )
             [s.Szaniec_architecture_access.Cyrograf.svc_name]
             []
             [s.Szaniec_architecture_access.Cyrograf.svc_name] ) )
    cy.Szaniec_architecture_access.Cyrograf.services ;
  (* shared consumption of unclassified repository-local modules.
     Calls and value references count; type references do not. A module
     owned by one family is not generic sharing. *)
  let unit_paths =
    List.map
      (fun (u : Observation.unit_info) -> u.Observation.canonical)
      observation.Observation.units
  in
  let owner_of (canonical : string) : Interpretation.ownership =
    match
      List.find_opt
        (fun (o : Interpretation.ownership) ->
          String.equal o.Interpretation.owner_module canonical )
        interpretation.Interpretation.ownerships
    with
    | Some o -> o
    | None ->
        { owner_module= canonical
        ; owner_class= Interpretation.Unclassified
        ; owner_service= "" }
  in
  let consumers : (string, string list) Hashtbl.t = Hashtbl.create 32 in
  let consumer_sites : (string, Observation.site list) Hashtbl.t =
    Hashtbl.create 32
  in
  let ref_paths : (string, string list) Hashtbl.t = Hashtbl.create 32 in
  let note_use target_path caller_unit site =
    if String.length target_path = 0
    then ()
    else
      match Canonical.unit_prefix unit_paths target_path with
      | None -> ()
      | Some target_unit -> (
        match (owner_of target_unit).Interpretation.owner_class with
        | Interpretation.Unclassified when not (approved_shared target_unit)
          -> (
          match (owner_of caller_unit).Interpretation.owner_class with
          | Interpretation.ExternalLibrary _
           |Interpretation.CompositionRoot
           |Interpretation.Contract_of _ ->
              ()
          | _ ->
              let caller = owner_of caller_unit in
              let consumer =
                if String.equal caller.Interpretation.owner_service ""
                then caller.Interpretation.owner_module
                else caller.Interpretation.owner_service
              in
              let prev =
                match Hashtbl.find_opt consumers target_unit with
                | Some l -> l
                | None -> []
              in
              if not (List.mem consumer prev)
              then Hashtbl.replace consumers target_unit (consumer :: prev) ;
              let sites =
                match Hashtbl.find_opt consumer_sites target_unit with
                | Some l -> l
                | None -> []
              in
              Hashtbl.replace consumer_sites target_unit (site :: sites) ;
              let paths =
                match Hashtbl.find_opt ref_paths target_unit with
                | Some l -> l
                | None -> []
              in
              if not (List.mem target_path paths)
              then Hashtbl.replace ref_paths target_unit (target_path :: paths)
          )
        | _ -> () )
  in
  List.iter
    (fun (c : Observation.call) ->
      if
        c.Observation.resolution = Observation.Resolved
        && String.length c.Observation.callee > 0
      then
        note_use c.Observation.callee c.Observation.call_unit c.Observation.site )
    observation.Observation.calls ;
  List.iter
    (fun (v : Observation.value_ref) ->
      let wiring =
        (owner_of v.Observation.ref_unit).Interpretation.owner_class
        = Interpretation.CompositionRoot
        &&
        let last =
          match List.rev (Canonical.split_dots v.Observation.ref_target) with
          | name :: _ -> name
          | [] -> ""
        in
        String.equal last "spec"
      in
      if not wiring
      then
        note_use
          v.Observation.ref_target
          v.Observation.ref_unit
          v.Observation.ref_site )
    observation.Observation.value_refs ;
  Hashtbl.iter
    (fun target cs ->
      let distinct = List.sort_uniq compare cs in
      if List.length distinct >= 2
      then
        let paths =
          List.sort_uniq
            compare
            ( match Hashtbl.find_opt ref_paths target with
            | Some l -> l
            | None -> [target] )
        in
        add
          (mk_finding
             "SHARED-UNAPPROVED"
             (Printf.sprintf
                "module %s is consumed by %s without an approved sharing \
                 declaration"
                target
                (String.concat ", " distinct) )
             (target :: distinct)
             (sites_locations
                (List.sort_uniq
                   compare
                   ( match Hashtbl.find_opt consumer_sites target with
                   | Some l -> l
                   | None -> [] ) ) )
             paths ) )
    consumers ;
  (* unclassified code *)
  List.iter
    (fun (o : Interpretation.ownership) ->
      match o.Interpretation.owner_class with
      | Interpretation.Unclassified ->
          let fresh =
            match
              List.find_opt
                (fun (u : Observation.unit_info) ->
                  String.equal
                    u.Observation.canonical
                    o.Interpretation.owner_module )
                observation.Observation.units
            with
            | Some u -> u.Observation.fresh
            | None -> true
          in
          (* A stale unit was not read, so "no owner" is not established.
             Ambiguous family evidence is a gap, not an unowned unit. *)
          let source_path =
            List.find_map
              (fun (u : Observation.unit_info) ->
                if
                  String.equal
                    u.Observation.canonical
                    o.Interpretation.owner_module
                then Some u.Observation.source_path
                else None )
              observation.Observation.units
          in
          let ambiguous =
            match source_path with
            | None -> false
            | Some sp ->
                List.exists
                  (fun (g : Observation.gap) ->
                    String.equal
                      g.Observation.gap_code
                      "GAP-AMBIGUOUS-OWNERSHIP"
                    && String.equal g.Observation.gap_path sp )
                  interpretation.Interpretation.gaps
          in
          if
            approved_shared o.Interpretation.owner_module
            || (not fresh)
            || ambiguous
          then ()
          else
            let locations =
              match source_path with
              | Some sp -> [{Finding.loc_path= sp; loc_line= 0; loc_col= 0}]
              | None -> []
            in
            add
              (mk_finding
                 "POLICY-UNCLASSIFIED"
                 (Printf.sprintf
                    "unit %s has no declared owner"
                    o.Interpretation.owner_module )
                 [o.Interpretation.owner_module]
                 locations
                 [o.Interpretation.owner_module] )
      | _ -> () )
    interpretation.Interpretation.ownerships ;
  List.sort Finding.compare (Finding.dedupe !findings)

let gap_finding (g : Observation.gap) : Finding.t =
  { Finding.rule= g.Observation.gap_code
  ; severity= Finding.GapFinding
  ; message= g.Observation.gap_detail
  ; participants= []
  ; locations=
      [{Finding.loc_path= g.Observation.gap_path; loc_line= 0; loc_col= 0}]
  ; evidence_path= [] }
