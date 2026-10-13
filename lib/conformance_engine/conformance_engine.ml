(* ConformanceEngine: evaluates the interpretation model against the
   service roles and the policy using the rule catalog
   szaniec-rules/3.2.0. There is no permitted-calls list: conformance
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

let site_key (site : Observation.site) = (site.site_path, site.line, site.col)

let index_first key entries =
  let index = Hashtbl.create (List.length entries) in
  List.iter
    (fun entry ->
      let k = key entry in
      if not (Hashtbl.mem index k) then Hashtbl.add index k entry )
    entries ;
  index

let index_interaction_sites (interactions : Interpretation.interaction list) =
  let index = Hashtbl.create 128 in
  List.iteri
    (fun ordinal (i : Interpretation.interaction) ->
      List.iter
        (fun site ->
          let key = site_key site in
          let previous =
            match Hashtbl.find_opt index key with
            | None -> []
            | Some entries -> entries
          in
          Hashtbl.replace index key ((ordinal, i) :: previous) )
        i.sites )
    interactions ;
  index

(* Preserve observation order and include each interaction once even when
   several of its sites occur on the path. Ordinals distinguish separate
   interactions that happen to have identical record values. *)
let interactions_on index (steps : Observation.path_step list) :
    Interpretation.interaction list =
  let matching = Hashtbl.create 16 in
  List.iter
    (fun (step : Observation.path_step) ->
      match Hashtbl.find_opt index (site_key step.step_site) with
      | None -> ()
      | Some entries ->
          List.iter
            (fun (ordinal, i) -> Hashtbl.replace matching ordinal i)
            entries )
    steps ;
  Hashtbl.fold (fun ordinal i acc -> (ordinal, i) :: acc) matching []
  |> List.sort (fun (a, _) (b, _) -> compare a b)
  |> List.map snd

let evaluate_with_domains
    ~domains
    ~(approved : bool)
    ~(policy : Policy.t)
    ~(cy : Szaniec_architecture_access.Cyrograf.t)
    ~(observation : Observation.t)
    ~(interpretation : Interpretation.t) : Finding.t list =
  let findings = ref [] in
  let add f = findings := f :: !findings in
  let unit_index =
    index_first
      (fun (u : Observation.unit_info) -> u.canonical)
      observation.units
  in
  let resolve_unit =
    Canonical.unit_resolver
      (List.map
         (fun (u : Observation.unit_info) -> u.canonical)
         observation.units )
  in
  let ownership_index =
    index_first
      (fun (o : Interpretation.ownership) -> o.owner_module)
      interpretation.ownerships
  in
  let path_index =
    index_first
      (fun (p : Observation.exec_paths) -> (p.paths_unit, p.paths_caller))
      observation.exec_paths
  in
  let owner_of canonical : Interpretation.ownership =
    match Hashtbl.find_opt ownership_index canonical with
    | Some o -> o
    | None ->
        { owner_module= canonical
        ; owner_class= Interpretation.Unclassified
        ; owner_service= "" }
  in
  let paths_of unit caller = Hashtbl.find_opt path_index (unit, caller) in
  let contract_rpc_entry unit caller =
    match (owner_of unit).owner_class with
    | Interpretation.Contract_of service ->
        List.exists
          (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
            s.svc_name = service
            && List.exists
                 (fun m ->
                   m.Szaniec_architecture_access.Cyrograf.m_name = caller )
                 s.svc_methods )
          cy.Szaniec_architecture_access.Cyrograf.services
    | _ -> false
  in
  let call_index = Hashtbl.create 128 in
  List.iter
    (fun (call : Observation.call) ->
      let key = (call.call_unit, call.caller) in
      Hashtbl.replace
        call_index
        key
        (call :: Option.value ~default:[] (Hashtbl.find_opt call_index key)) )
    observation.calls ;
  let unit_prefix = resolve_unit in
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
            | ( Szaniec_architecture_access.Cyrograf.Manager
              , Szaniec_architecture_access.Cyrograf.Client ) ->
                add
                  (mk_finding
                     "ID-MANAGER-CLIENT"
                     (Printf.sprintf
                        "manager service %s calls client service %s"
                        i.Interpretation.from_owner
                        i.Interpretation.to_service )
                     [i.Interpretation.from_owner; i.Interpretation.to_service]
                     (sites_locations i.Interpretation.sites)
                     i.Interpretation.evidence_path )
            | ( Szaniec_architecture_access.Cyrograf.Engine
              , Szaniec_architecture_access.Cyrograf.Client ) ->
                add
                  (mk_finding
                     "ID-ENGINE-CLIENT"
                     (Printf.sprintf
                        "engine service %s calls client service %s"
                        i.Interpretation.from_owner
                        i.Interpretation.to_service )
                     [i.Interpretation.from_owner; i.Interpretation.to_service]
                     (sites_locations i.Interpretation.sites)
                     i.Interpretation.evidence_path )
            | ( Szaniec_architecture_access.Cyrograf.Access
              , Szaniec_architecture_access.Cyrograf.Client ) ->
                add
                  (mk_finding
                     "ID-ACCESS-CLIENT"
                     (Printf.sprintf
                        "access service %s calls client service %s"
                        i.Interpretation.from_owner
                        i.Interpretation.to_service )
                     [i.Interpretation.from_owner; i.Interpretation.to_service]
                     (sites_locations i.Interpretation.sites)
                     i.Interpretation.evidence_path )
            | ( Szaniec_architecture_access.Cyrograf.Manager
              , Szaniec_architecture_access.Cyrograf.Manager ) ->
                add
                  (mk_finding
                     "ID-MANAGER-MANAGER"
                     (Printf.sprintf
                        "manager service %s calls manager service %s \
                         synchronously (delegate with a queued command)"
                        i.Interpretation.from_owner
                        i.Interpretation.to_service )
                     [i.Interpretation.from_owner; i.Interpretation.to_service]
                     (sites_locations i.Interpretation.sites)
                     i.Interpretation.evidence_path )
            | ( Szaniec_architecture_access.Cyrograf.Client
              , ( Szaniec_architecture_access.Cyrograf.Client
                | Szaniec_architecture_access.Cyrograf.Manager
                | Szaniec_architecture_access.Cyrograf.Utility ) )
             |( Szaniec_architecture_access.Cyrograf.Manager
              , ( Szaniec_architecture_access.Cyrograf.Engine
                | Szaniec_architecture_access.Cyrograf.Access
                | Szaniec_architecture_access.Cyrograf.Utility ) )
             |( Szaniec_architecture_access.Cyrograf.Engine
              , ( Szaniec_architecture_access.Cyrograf.Manager
                | Szaniec_architecture_access.Cyrograf.Access
                | Szaniec_architecture_access.Cyrograf.Utility ) )
             |( Szaniec_architecture_access.Cyrograf.Access
              , Szaniec_architecture_access.Cyrograf.Utility )
             |( Szaniec_architecture_access.Cyrograf.Utility
              , ( Szaniec_architecture_access.Cyrograf.Client
                | Szaniec_architecture_access.Cyrograf.Manager
                | Szaniec_architecture_access.Cyrograf.Engine
                | Szaniec_architecture_access.Cyrograf.Access
                | Szaniec_architecture_access.Cyrograf.Utility ) ) ->
                () )
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
          let declared_service =
            List.exists
              (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
                s.svc_name = i.from_owner )
              cy.services
          in
          let allowed =
            declared_service
            && ( from_role = Szaniec_architecture_access.Cyrograf.Access
               || from_role = Szaniec_architecture_access.Cyrograf.Utility )
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
      | Interpretation.QueuedCommand ->
          let to_role = role_of_name i.Interpretation.to_service in
          if
            i.Interpretation.to_service <> ""
            && ( to_role = Szaniec_architecture_access.Cyrograf.Engine
               || to_role = Szaniec_architecture_access.Cyrograf.Access )
          then
            add
              (mk_finding
                 "Q-TARGET-ROLE"
                 (Printf.sprintf
                    "queued command from %s targets %s service %s"
                    i.Interpretation.from_owner
                    (Szaniec_architecture_access.Cyrograf.role_to_string
                       to_role )
                    i.Interpretation.to_service )
                 [i.Interpretation.from_owner; i.Interpretation.to_service]
                 (sites_locations i.Interpretation.sites)
                 i.Interpretation.evidence_path )
      | Interpretation.Publication ->
          let from_role = role_of_name i.Interpretation.from_owner in
          if from_role <> Szaniec_architecture_access.Cyrograf.Manager
          then
            add
              (mk_finding
                 "EVT-PUBLISH-ROLE"
                 (Printf.sprintf
                    "%s publishes (only a Manager may publish)"
                    i.Interpretation.from_owner )
                 [i.Interpretation.from_owner]
                 (sites_locations i.Interpretation.sites)
                 i.Interpretation.evidence_path )
      | Interpretation.Subscription ->
          let from_role = role_of_name i.Interpretation.from_owner in
          if
            from_role <> Szaniec_architecture_access.Cyrograf.Client
            && from_role <> Szaniec_architecture_access.Cyrograf.Manager
          then
            add
              (mk_finding
                 "EVT-SUBSCRIBE-ROLE"
                 (Printf.sprintf
                    "%s subscribes (only a Client or a Manager may subscribe)"
                    i.Interpretation.from_owner )
                 [i.Interpretation.from_owner]
                 (sites_locations i.Interpretation.sites)
                 i.Interpretation.evidence_path )
      | Interpretation.Registration
       |Interpretation.ExternalCall ->
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
          ; "GAP-MISSING-INPUT"
          ; "GAP-INCOMPLETE-ARTIFACT"
          ; "GAP-UNVERIFIABLE-TRANSFORMATION"
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
      if s.svc_methods <> [] && (not bound) && not evidence_missing
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
  let consumers : (string, string list) Hashtbl.t = Hashtbl.create 32 in
  let consumer_sites : (string, Observation.site list) Hashtbl.t =
    Hashtbl.create 32
  in
  let ref_paths : (string, string list) Hashtbl.t = Hashtbl.create 32 in
  let unavailable_units = Hashtbl.create 16 in
  List.iter
    (fun (u : Observation.unit_info) ->
      if
        (not u.fresh)
        || List.exists
             (fun (g : Observation.gap) ->
               g.gap_code = "GAP-AMBIGUOUS-OWNERSHIP"
               && g.gap_path = u.source_path )
             interpretation.gaps
      then Hashtbl.replace unavailable_units u.canonical () )
    observation.units ;
  let note_use target_path caller_unit site =
    if String.length target_path = 0
    then ()
    else
      match unit_prefix target_path with
      | None -> ()
      | Some target_unit
        when target_unit = caller_unit
             || Hashtbl.mem unavailable_units caller_unit
             || Hashtbl.mem unavailable_units target_unit ->
          ()
      | Some target_unit -> (
        match (owner_of target_unit).Interpretation.owner_class with
        | Interpretation.Unclassified when not (approved_shared target_unit)
          -> (
          match (owner_of caller_unit).Interpretation.owner_class with
          | Interpretation.ExternalLibrary _
           |Interpretation.CompositionRoot
           |Interpretation.Contract_of _
           |Interpretation.Contract_data _ ->
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
            match Hashtbl.find_opt unit_index o.Interpretation.owner_module with
            | Some u -> u.Observation.fresh
            | None -> true
          in
          (* A stale unit was not read, so "no owner" is not established.
             Ambiguous family evidence is a gap, not an unowned unit. *)
          let source_path =
            Option.map
              (fun (u : Observation.unit_info) -> u.source_path)
              (Hashtbl.find_opt unit_index o.Interpretation.owner_module)
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
  (* Use-case and queue fan-out. Alternatives come from ProgramAccess;
     helpers are inlined only inside one boundary. *)
  let boundary_name (o : Interpretation.ownership) : string =
    if o.Interpretation.owner_service = ""
    then o.Interpretation.owner_module
    else o.Interpretation.owner_service
  in
  let same_boundary (a : Interpretation.ownership) (b : Interpretation.ownership)
      : bool =
    a.Interpretation.owner_service <> ""
    && String.equal
         a.Interpretation.owner_service
         b.Interpretation.owner_service
    || String.equal a.Interpretation.owner_module b.Interpretation.owner_module
  in
  let target_of (callee : string) : (string * string) option =
    match unit_prefix callee with
    | Some u ->
        let pl = String.length u + 1 in
        let rel =
          if String.length callee > pl
          then String.sub callee pl (String.length callee - pl)
          else callee
        in
        Some (u, rel)
    | None -> None
  in
  let callbacks = Hashtbl.create 32 in
  List.iter
    (fun (callback : Interpretation.callback_evidence) ->
      let previous =
        Option.value
          ~default:[]
          (Hashtbl.find_opt callbacks callback.callback_site)
      in
      Hashtbl.replace callbacks callback.callback_site (callback :: previous) )
    interpretation.callbacks ;
  let invocation_index =
    index_first
      (fun (call : Observation.execution_call) ->
        (call.execution_site, call.execution_callee) )
      (List.filter
         (fun (call : Observation.execution_call) -> not call.execution_resumed)
         observation.execution.invocations )
  in
  let callback_paths = index_first fst interpretation.callback_paths in
  let returned_calls = Hashtbl.create 16 in
  List.iter
    (fun (site, source, target) ->
      Hashtbl.replace returned_calls (site, source) target )
    interpretation.returned_calls ;
  let returned_target step =
    if step.Observation.step_resumed
    then
      Option.value
        ~default:step.step_callee
        (Hashtbl.find_opt returned_calls (step.step_site, step.step_callee))
    else step.step_callee
  in
  let rec resolve_binding bindings visited target =
    if List.mem target visited
    then target
    else
      match List.assoc_opt target bindings with
      | None -> (
          let field = Canonical.parameter_field target in
          let forwarded =
            match Canonical.parameter_symbol target with
            | Some (owner, position) when field <> "" ->
                Option.map
                  (fun base -> base ^ "." ^ field)
                  (List.assoc_opt
                     (owner ^ ".<parameter@" ^ string_of_int position ^ ">")
                     bindings )
            | _ -> None
          in
          match
            (forwarded, List.assoc_opt target interpretation.parameter_targets)
          with
          | Some next, _ -> resolve_binding bindings (target :: visited) next
          | None, Some [next] ->
              resolve_binding bindings (target :: visited) next
          | _ -> target )
      | Some next -> resolve_binding bindings (target :: visited) next
  in
  let call_bindings bindings step =
    match
      Hashtbl.find_opt
        invocation_index
        (step.Observation.step_site, step.step_callee)
    with
    | None -> bindings
    | Some call ->
        let callee = resolve_binding bindings [] call.execution_callee in
        List.map
          (fun (arg : Observation.execution_arg) ->
            ( ( callee
              ^ ".<parameter@"
              ^ string_of_int arg.position
              ^ ">"
              ^ if arg.field = "" then "" else "." ^ arg.field )
            , resolve_binding bindings [] arg.target ) )
          call.execution_args
        @ List.filter
            (fun (symbol, _) ->
              match Canonical.parameter_symbol symbol with
              | Some (owner, position) ->
                  owner = callee && List.mem position call.execution_defaults
              | _ -> false )
            interpretation.parameter_defaults
        @ bindings
  in
  let rec expand
      (unit : string)
      (caller : string)
      (depth : int)
      (visiting : (string * string) list)
      (budget : int ref)
      bindings : (Observation.path_step list list, string) result =
    if depth > 64
    then Error "helper expansion depth exceeds 64"
    else if
      List.exists
        (fun (u, c) -> String.equal u unit && String.equal c caller)
        visiting
    then
      Error
        ( "recursive helper has no finite execution summary: "
        ^ unit
        ^ "."
        ^ caller )
    else
      match paths_of unit caller with
      | None -> Error ("helper body unavailable: " ^ unit ^ "." ^ caller)
      | Some p when p.Observation.ambiguous -> Error p.limiting_reason
      | Some p -> (
          let visiting = (unit, caller) :: visiting in
          let acc_alts = ref [] in
          let failed = ref None in
          List.iter
            (fun alt ->
              if !failed <> None
              then ()
              else
                let acc = ref [[]] in
                List.iter
                  (fun (step : Observation.path_step) ->
                    let original = step in
                    let target =
                      resolve_binding bindings [] (returned_target step)
                    in
                    let step =
                      if target = step.step_callee
                      then step
                      else
                        { step with
                          step_callee= target
                        ; step_resolution= Observation.Resolved }
                    in
                    decr budget ;
                    if
                      !failed <> None
                      || List.for_all
                           (List.exists (fun (step : Observation.path_step) ->
                                step.step_exit ) )
                           !acc
                    then ()
                    else
                      let pieces =
                        if
                          (not step.step_resumed)
                          && List.mem
                               step.step_site
                               interpretation.deferred_calls
                        then Ok [[]]
                        else if !budget < 0
                        then Error "helper summary traversal exceeds 4096 steps"
                        else if
                          step.Observation.step_resolution
                          <> Observation.Resolved
                          || step.Observation.step_callee = ""
                        then Ok [[step]]
                        else
                          match target_of step.Observation.step_callee with
                          | Some (tu, sym)
                            when same_boundary (owner_of unit) (owner_of tu)
                                 && (not (contract_rpc_entry tu sym))
                                 && paths_of tu sym <> None ->
                              expand
                                tu
                                sym
                                (depth + 1)
                                visiting
                                budget
                                (call_bindings bindings original)
                          | Some (tu, _sym)
                            when same_boundary (owner_of unit) (owner_of tu)
                                 && not (contract_rpc_entry tu _sym) ->
                              Error
                                ( "helper execution body unavailable: "
                                ^ tu
                                ^ "."
                                ^ _sym )
                          | _ -> Ok [[step]]
                      in
                      let pieces =
                        match
                          Hashtbl.find_opt callback_paths step.step_site
                        with
                        | Some (_, alternatives)
                          when match target_of step.step_callee with
                               | Some (target, _) ->
                                   not
                                     (same_boundary
                                        (owner_of unit)
                                        (owner_of target) )
                               | None -> true -> (
                            let callback_result =
                              List.fold_left
                                (fun all targets ->
                                  let path =
                                    List.fold_left
                                      (fun previous target ->
                                        let target =
                                          resolve_binding bindings [] target
                                        in
                                        let next =
                                          match target_of target with
                                          | Some (tu, symbol)
                                            when same_boundary
                                                   (owner_of unit)
                                                   (owner_of tu) ->
                                              expand
                                                tu
                                                symbol
                                                (depth + 1)
                                                visiting
                                                budget
                                                bindings
                                          | _
                                            when target = ""
                                                 || Canonical.parameter_symbol
                                                      target
                                                    <> None ->
                                              Error
                                                "callback input binding \
                                                 unavailable"
                                          | _ ->
                                              Ok
                                                [ [ { step with
                                                      step_callee= target
                                                    ; step_resolution=
                                                        Observation.Resolved }
                                                  ] ]
                                        in
                                        match (previous, next) with
                                        | Ok previous, Ok next ->
                                            Execution_paths.sequence
                                              previous
                                              next
                                        | Error reason, _
                                         |_, Error reason ->
                                            Error reason )
                                      (Ok [[]])
                                      targets
                                  in
                                  match (all, path) with
                                  | Ok all, Ok path ->
                                      Execution_paths.union all path
                                  | Error reason, _
                                   |_, Error reason ->
                                      Error reason )
                                (Ok [])
                                alternatives
                            in
                            match (pieces, callback_result) with
                            | Ok previous, Ok next ->
                                Execution_paths.sequence previous next
                            | Error reason, _
                             |_, Error reason ->
                                Error reason )
                        | Some _ -> pieces
                        | None ->
                            List.fold_left
                              (fun pieces
                                   (callback : Interpretation.callback_evidence)
                                 ->
                                match pieces with
                                | Error reason -> Error reason
                                | Ok previous
                                  when callback.callback_phase
                                       = Interpretation.Same_path
                                       && callback.callback_resumed
                                          = step.step_resumed -> (
                                    let next =
                                      let callback_target =
                                        resolve_binding
                                          bindings
                                          []
                                          callback.callback_target
                                      in
                                      match target_of callback_target with
                                      | Some (target, symbol)
                                        when same_boundary
                                               (owner_of unit)
                                               (owner_of target) ->
                                          expand
                                            target
                                            symbol
                                            (depth + 1)
                                            visiting
                                            budget
                                            bindings
                                      | _ when callback_target = "" ->
                                          Error
                                            "callback target provenance \
                                             unavailable"
                                      | _ ->
                                          Ok
                                            [ [ { step with
                                                  Observation.step_callee=
                                                    callback_target } ] ]
                                    in
                                    match next with
                                    | Error reason -> Error reason
                                    | Ok next ->
                                        Execution_paths.sequence previous next )
                                | Ok _ -> pieces )
                              pieces
                              (Option.value
                                 ~default:[]
                                 (Hashtbl.find_opt callbacks step.step_site) )
                      in
                      match pieces with
                      | Error reason -> failed := Some reason
                      | Ok parts -> (
                        match Execution_paths.sequence !acc parts with
                        | Error reason -> failed := Some reason
                        | Ok next -> acc := next ) )
                  alt ;
                if !failed = None
                then
                  match Execution_paths.union !acc !acc_alts with
                  | Ok next -> acc_alts := next
                  | Error reason -> failed := Some reason )
            p.Observation.alternatives ;
          match !failed with
          | Some reason -> Error reason
          | None -> Ok !acc_alts )
  in
  let targeted : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  List.iter
    (fun (c : Observation.call) ->
      if
        c.Observation.resolution = Observation.Resolved
        && c.Observation.callee <> ""
      then
        match target_of c.Observation.callee with
        | Some (tu, sym)
          when same_boundary (owner_of c.Observation.call_unit) (owner_of tu) ->
            Hashtbl.replace targeted (tu ^ "\n" ^ sym) ()
        | _ -> () )
    observation.Observation.calls ;
  List.iter
    (fun (callback : Interpretation.callback_evidence) ->
      if callback.callback_phase <> Interpretation.Independent
      then
        match target_of callback.callback_target with
        | Some (unit, symbol) ->
            Hashtbl.replace targeted (unit ^ "\n" ^ symbol) ()
        | None -> () )
    interpretation.callbacks ;
  List.iter
    (fun parameter ->
      Option.iter
        (fun (symbol, _) ->
          match target_of symbol with
          | Some (unit, caller) ->
              Hashtbl.replace targeted (unit ^ "\n" ^ caller) ()
          | None -> () )
        (Canonical.parameter_symbol parameter) )
    interpretation.bound_parameters ;
  let source_of unit =
    match Hashtbl.find_opt unit_index unit with
    | Some u -> u.Observation.source_path
    | None -> unit
  in
  let interactions_on =
    interactions_on
      (index_interaction_sites interpretation.Interpretation.interactions)
  in
  let ordered = index_first fst observation.execution.ordered in
  let reachability_bound unit caller =
    let rec union steps =
      List.fold_left
        (fun result step ->
          match (result, step) with
          | None, _ -> None
          | Some old, Observation.Invoke call -> Some (call :: old)
          | Some old, Choose branches ->
              Option.map
                (fun next -> List.sort_uniq compare (old @ next))
                (union (List.concat_map snd branches))
          | Some old, Repeat (_, _, condition, body) ->
              Option.map
                (fun next -> List.sort_uniq compare (old @ next))
                (union (condition @ body))
          | Some old, Leave _ -> Some old
          | Some old, Unknown_order (reason, _)
            when List.mem
                   reason
                   [ "exception flow unsupported"
                   ; "match exception flow unsupported"
                   ; "guard selection flow unsupported"
                   ; "operand evaluation order unspecified"
                   ; "operand ordering alternatives exceed limit" ] ->
              Some old
          | _, Unknown_order _ -> None )
        (Some [])
        steps
    in
    let visited = Hashtbl.create 16 in
    let budget = ref 65536 in
    let failure = ref "" in
    let fail reason =
      if !failure = "" then failure := reason ;
      Error ()
    in
    let rec collect unit caller bindings =
      let bindings =
        List.map
          (fun key -> (key, resolve_binding bindings [] key))
          (List.map fst bindings |> List.sort_uniq compare)
      in
      let symbol = unit ^ "." ^ caller in
      (* Callable inputs may capture another helper's parameters. Include that
         lexical context transitively before memoizing a helper invocation. *)
      let rec contexts scopes =
        let relevant =
          List.filter
            (fun (key, _) ->
              match Canonical.parameter_symbol key with
              | None -> true
              | Some (owner, _) ->
                  List.exists
                    (fun scope ->
                      owner = scope
                      || String.starts_with ~prefix:(owner ^ ".") scope )
                    scopes )
            bindings
        in
        let expanded =
          List.sort_uniq compare (scopes @ List.map snd relevant)
        in
        if expanded = scopes then relevant else contexts expanded
      in
      let relevant_bindings = contexts [symbol] in
      let key = (unit, caller, relevant_bindings) in
      if Hashtbl.mem visited key
      then Ok []
      else if !budget <= 0
      then fail "reachability budget"
      else (
        Hashtbl.replace visited key () ;
        match paths_of unit caller with
        | None -> fail ("body unavailable: " ^ unit ^ "." ^ caller)
        | Some paths ->
            let unsupported = ref false in
            let steps =
              if paths.ambiguous
              then
                (* The extractor retains all calls in body and handlers. Their
                   union is an upper bound, never a claim of co-execution. *)
                Option.bind
                  (Hashtbl.find_opt ordered (unit ^ "." ^ caller))
                  (fun (_, steps) -> union steps)
                |> ( function
                | Some calls -> calls
                | None ->
                    unsupported := true ;
                    [] )
                |> List.map (fun (call : Observation.execution_call) ->
                    { Observation.step_callee= call.execution_callee
                    ; step_resolution= call.execution_resolution
                    ; step_site= call.execution_site
                    ; step_args= []
                    ; step_resumed= call.execution_resumed
                    ; step_exit= false } )
              else List.concat paths.alternatives
            in
            if !unsupported
            then fail "unsupported reachability construct"
            else
              let steps =
                List.concat_map
                  (fun (step : Observation.path_step) ->
                    let target =
                      resolve_binding bindings [] (returned_target step)
                    in
                    match
                      ( Canonical.parameter_symbol target
                      , List.assoc_opt target interpretation.parameter_targets
                      )
                    with
                    | Some _, Some (_ :: _ as targets) ->
                        List.map
                          (fun target -> (step, [(step.step_callee, target)]))
                          targets
                    | _ -> [(step, [])] )
                  steps
              in
              List.fold_left
                (fun result ((step : Observation.path_step), overrides) ->
                  let bindings = overrides @ bindings in
                  let original = step in
                  let target =
                    resolve_binding bindings [] (returned_target step)
                  in
                  let step =
                    if target = step.step_callee
                    then step
                    else
                      { step with
                        step_callee= target
                      ; step_resolution= Observation.Resolved }
                  in
                  decr budget ;
                  match result with
                  | Error () -> Error ()
                  | Ok previous ->
                      if step.step_resolution <> Observation.Resolved
                      then
                        fail
                          (Printf.sprintf
                             "unresolved: %s at %s:%d:%d"
                             step.step_callee
                             step.step_site.site_path
                             step.step_site.line
                             step.step_site.col )
                      else if
                        (not step.step_resumed)
                        && List.mem step.step_site interpretation.deferred_calls
                      then Ok previous
                      else
                        let direct =
                          match target_of step.step_callee with
                          | Some (target, symbol)
                            when same_boundary (owner_of unit) (owner_of target)
                                 && not (contract_rpc_entry target symbol) -> (
                            match
                              collect
                                target
                                symbol
                                (call_bindings bindings original)
                            with
                            | Error () -> Error ()
                            | Ok nested -> Ok (nested @ previous) )
                          | _ -> Ok (step :: previous)
                        in
                        List.fold_left
                          (fun result
                               (callback : Interpretation.callback_evidence)
                             ->
                            match result with
                            | Error () -> Error ()
                            | Ok _
                              when callback.callback_phase
                                   = Interpretation.Unknown_callback ->
                                fail
                                  ( "unknown callback: "
                                  ^ callback.callback_target )
                            | Ok previous
                              when callback.callback_phase
                                   = Interpretation.Same_path
                                   && callback.callback_resumed
                                      = step.step_resumed -> (
                                let callback_target =
                                  resolve_binding
                                    bindings
                                    []
                                    callback.callback_target
                                in
                                match target_of callback_target with
                                | Some (target, symbol)
                                  when same_boundary
                                         (owner_of unit)
                                         (owner_of target) -> (
                                  match collect target symbol bindings with
                                  | Error () -> Error ()
                                  | Ok nested -> Ok (nested @ previous) )
                                | _ when callback_target = "" ->
                                    fail "empty callback"
                                | _ ->
                                    Ok
                                      ( {step with step_callee= callback_target}
                                      :: previous ) )
                            | Ok _ -> result )
                          direct
                          (Option.value
                             ~default:[]
                             (Hashtbl.find_opt callbacks step.step_site) ) )
                (Ok [])
                steps )
    in
    match collect unit caller [] with
    | Error () ->
        if Sys.getenv_opt "SZANIEC_BOUND_TRACE" = Some "1"
        then Printf.eprintf "bound failed %s.%s: %s\n%!" unit caller !failure ;
        false
    | Ok steps ->
        let interactions = interactions_on steps in
        let targets kind =
          interactions
          |> List.filter (fun (i : Interpretation.interaction) ->
              i.kind = kind
              && role_of_name i.to_service
                 = Szaniec_architecture_access.Cyrograf.Manager )
          |> List.map (fun i -> i.Interpretation.to_service)
          |> List.sort_uniq compare
        in
        let requests = targets Interpretation.ServiceRequest
        and queues = targets Interpretation.QueuedCommand in
        let proven = List.length requests <= 1 && List.length queues <= 1 in
        if (not proven) && Sys.getenv_opt "SZANIEC_BOUND_TRACE" = Some "1"
        then
          Printf.eprintf
            "bound multiple %s.%s: requests=%s queues=%s\n%!"
            unit
            caller
            (String.concat "," requests)
            (String.concat "," queues) ;
        proven
  in
  let evaluate_path (p : Observation.exec_paths) =
    let findings = ref [] in
    let add f = findings := f :: !findings in
    let gap_path unit caller reason =
      add
        { Finding.rule= "GAP-AMBIGUOUS-PATH"
        ; severity= Finding.GapFinding
        ; message=
            Printf.sprintf
              "executable paths of %s.%s cannot be built: %s; Client \
               multi-Manager and queued fan-out checks are unverified"
              unit
              caller
              reason
        ; participants= []
        ; locations=
            [{Finding.loc_path= source_of unit; loc_line= 0; loc_col= 0}]
        ; evidence_path= [] }
    in

    let key = p.Observation.paths_unit ^ "\n" ^ p.Observation.paths_caller in
    let anonymous = Execution_paths.local_symbol p.paths_caller in
    let independent =
      List.exists
        (fun (callback : Interpretation.callback_evidence) ->
          callback.callback_target = p.paths_unit ^ "." ^ p.paths_caller
          && callback.callback_phase = Interpretation.Independent )
        interpretation.callbacks
    in
    ( if Hashtbl.mem targeted key || (anonymous && not independent)
      then ()
      else
        let owner = owner_of p.Observation.paths_unit in
        match owner.Interpretation.owner_class with
        | Interpretation.Contract_of _
         |Interpretation.Contract_data _
         |Interpretation.ExternalLibrary _ ->
            ()
        | _ -> (
          match
            expand
              p.Observation.paths_unit
              p.Observation.paths_caller
              0
              []
              (ref 4096)
              []
          with
          | result ->
              let alts =
                match result with
                | Error _ when reachability_bound p.paths_unit p.paths_caller ->
                    []
                | Error reason -> (
                    gap_path
                      p.Observation.paths_unit
                      p.Observation.paths_caller
                      reason ;
                    match paths_of p.paths_unit p.paths_caller with
                    | Some original when not original.ambiguous ->
                        original.alternatives
                    | _ -> [] )
                | Ok alts -> alts
              in
              let boundary = boundary_name owner in
              let role = role_of_name boundary in
              let seen_uc = Hashtbl.create 4 in
              let seen_q = Hashtbl.create 4 in
              List.iter
                (fun steps ->
                  let on_path = interactions_on steps in
                  let names kind pred =
                    on_path
                    |> List.filter (fun (i : Interpretation.interaction) ->
                        i.Interpretation.kind = kind && pred i )
                    |> List.map (fun i -> i.Interpretation.to_service)
                    |> List.sort_uniq compare
                  in
                  let managers =
                    names Interpretation.ServiceRequest (fun i ->
                        role_of_name i.Interpretation.to_service
                        = Szaniec_architecture_access.Cyrograf.Manager )
                  in
                  let queued =
                    names Interpretation.QueuedCommand (fun i ->
                        i.Interpretation.to_service <> ""
                        && role_of_name i.Interpretation.to_service
                           = Szaniec_architecture_access.Cyrograf.Manager )
                  in
                  let evidence_of kind pred =
                    on_path
                    |> List.filter (fun (i : Interpretation.interaction) ->
                        i.Interpretation.kind = kind && pred i )
                    |> List.concat_map (fun i -> i.Interpretation.evidence_path)
                  in
                  let locs_of kind pred =
                    on_path
                    |> List.filter (fun (i : Interpretation.interaction) ->
                        i.Interpretation.kind = kind && pred i )
                    |> List.concat_map (fun i ->
                        sites_locations i.Interpretation.sites )
                  in
                  if
                    role = Szaniec_architecture_access.Cyrograf.Client
                    && List.length managers >= 2
                    && not (Hashtbl.mem seen_uc (String.concat "," managers))
                  then (
                    Hashtbl.replace seen_uc (String.concat "," managers) () ;
                    let is_mgr (i : Interpretation.interaction) =
                      i.Interpretation.kind = Interpretation.ServiceRequest
                      && role_of_name i.Interpretation.to_service
                         = Szaniec_architecture_access.Cyrograf.Manager
                    in
                    add
                      (mk_finding
                         "UC-CLIENT-MULTI-MANAGER"
                         (Printf.sprintf
                            "client %s calls managers %s on one executable path"
                            boundary
                            (String.concat ", " managers) )
                         (boundary :: managers)
                         (locs_of Interpretation.ServiceRequest is_mgr)
                         (evidence_of Interpretation.ServiceRequest is_mgr) ) ) ;
                  if
                    List.length queued >= 2
                    && not (Hashtbl.mem seen_q (String.concat "," queued))
                  then (
                    Hashtbl.replace seen_q (String.concat "," queued) () ;
                    let is_q (i : Interpretation.interaction) =
                      i.Interpretation.kind = Interpretation.QueuedCommand
                      && i.Interpretation.to_service <> ""
                      && role_of_name i.Interpretation.to_service
                         = Szaniec_architecture_access.Cyrograf.Manager
                    in
                    add
                      (mk_finding
                         "Q-MULTI-MANAGER"
                         (Printf.sprintf
                            "queued commands from %s target managers %s on one \
                             executable path"
                            boundary
                            (String.concat ", " queued) )
                         (boundary :: queued)
                         (locs_of Interpretation.QueuedCommand is_q)
                         (evidence_of Interpretation.QueuedCommand is_q) ) ) )
                alts ) ) ;
    !findings
  in
  Parallel_paths.map ~domains evaluate_path observation.Observation.exec_paths
  |> List.iter (fun local -> findings := local @ !findings) ;
  List.sort Finding.compare (Finding.dedupe !findings)

let evaluate ~approved ~policy ~cy ~observation ~interpretation =
  evaluate_with_domains
    ~domains:(Parallel_paths.configured_domains ())
    ~approved
    ~policy
    ~cy
    ~observation
    ~interpretation

let gap_finding (g : Observation.gap) : Finding.t =
  { Finding.rule= g.Observation.gap_code
  ; severity= Finding.GapFinding
  ; message= g.Observation.gap_detail
  ; participants= []
  ; locations=
      [{Finding.loc_path= g.Observation.gap_path; loc_line= 0; loc_col= 0}]
  ; evidence_path= [] }
