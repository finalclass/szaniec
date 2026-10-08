(* ConformanceEngine: evaluates the interpretation model against the
   service roles and the policy using the rule catalog
   szaniec-rules/3.1.0. There is no permitted-calls list: conformance
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
  (* Use-case and queue fan-out. Alternatives come from ProgramAccess;
     helpers are inlined only inside one boundary. *)
  let owner_of (module_path : string) : Interpretation.ownership =
    match
      List.find_opt
        (fun (o : Interpretation.ownership) ->
          String.equal o.Interpretation.owner_module module_path )
        interpretation.Interpretation.ownerships
    with
    | Some o -> o
    | None ->
        { owner_module= module_path
        ; owner_class= Interpretation.Unclassified
        ; owner_service= "" }
  in
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
    match Canonical.unit_prefix unit_paths callee with
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
  let paths_of (unit : string) (caller : string) : Observation.exec_paths option
      =
    List.find_opt
      (fun (p : Observation.exec_paths) ->
        String.equal p.Observation.paths_unit unit
        && String.equal p.Observation.paths_caller caller )
      observation.Observation.exec_paths
  in
  let max_alts = 48 in
  let rec expand
      (unit : string)
      (caller : string)
      (depth : int)
      (visiting : (string * string) list) :
      (Observation.path_step list list, unit) result =
    if
      depth > 8
      || List.exists
           (fun (u, c) -> String.equal u unit && String.equal c caller)
           visiting
    then Error ()
    else
      match paths_of unit caller with
      | None -> Error ()
      | Some p when p.Observation.ambiguous -> Error ()
      | Some p ->
          let visiting = (unit, caller) :: visiting in
          let acc_alts = ref [] in
          let failed = ref false in
          List.iter
            (fun alt ->
              if !failed
              then ()
              else
                let acc = ref [[]] in
                List.iter
                  (fun (step : Observation.path_step) ->
                    if !failed
                    then ()
                    else
                      let pieces =
                        if
                          step.Observation.step_resolution
                          <> Observation.Resolved
                          || step.Observation.step_callee = ""
                        then Ok [[step]]
                        else
                          match target_of step.Observation.step_callee with
                          | Some (tu, sym)
                            when same_boundary (owner_of unit) (owner_of tu)
                                 && paths_of tu sym <> None ->
                              expand tu sym (depth + 1) visiting
                          | Some (tu, _sym)
                            when same_boundary (owner_of unit) (owner_of tu) ->
                              Error ()
                          | _ -> Ok [[step]]
                      in
                      match pieces with
                      | Error () -> failed := true
                      | Ok parts ->
                          let next =
                            List.concat_map
                              (fun left ->
                                List.map (fun right -> left @ right) parts )
                              !acc
                          in
                          if List.length next > max_alts
                          then failed := true
                          else acc := next )
                  alt ;
                if not !failed then acc_alts := !acc @ !acc_alts )
            p.Observation.alternatives ;
          if !failed then Error () else Ok !acc_alts
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
  let source_of unit =
    match
      List.find_opt
        (fun (u : Observation.unit_info) ->
          String.equal u.Observation.canonical unit )
        observation.Observation.units
    with
    | Some u -> u.Observation.source_path
    | None -> unit
  in
  let interactions_on =
    interactions_on
      (index_interaction_sites interpretation.Interpretation.interactions)
  in
  let gap_path unit caller =
    add
      { Finding.rule= "GAP-AMBIGUOUS-PATH"
      ; severity= Finding.GapFinding
      ; message=
          Printf.sprintf "executable paths of %s.%s cannot be built" unit caller
      ; participants= []
      ; locations= [{Finding.loc_path= source_of unit; loc_line= 0; loc_col= 0}]
      ; evidence_path= [] }
  in
  List.iter
    (fun (p : Observation.exec_paths) ->
      let key = p.Observation.paths_unit ^ "\n" ^ p.Observation.paths_caller in
      if Hashtbl.mem targeted key
      then ()
      else
        let owner = owner_of p.Observation.paths_unit in
        match owner.Interpretation.owner_class with
        | Interpretation.Contract_of _
         |Interpretation.ExternalLibrary _ ->
            ()
        | _ -> (
          match
            expand p.Observation.paths_unit p.Observation.paths_caller 0 []
          with
          | Error () ->
              gap_path p.Observation.paths_unit p.Observation.paths_caller
          | Ok alts ->
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
                alts ) )
    observation.Observation.exec_paths ;
  List.sort Finding.compare (Finding.dedupe !findings)

let gap_finding (g : Observation.gap) : Finding.t =
  { Finding.rule= g.Observation.gap_code
  ; severity= Finding.GapFinding
  ; message= g.Observation.gap_detail
  ; participants= []
  ; locations=
      [{Finding.loc_path= g.Observation.gap_path; loc_line= 0; loc_col= 0}]
  ; evidence_path= [] }
