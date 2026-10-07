(* ConformanceEngine: evaluates the interpretation model against the
   service roles and the policy using the rule catalog
   szaniec-rules/2.0.0. There is no permitted-calls list: conformance
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
    ~(policy : Policy.t)
    ~(cy : Szaniec_architecture_access.Cyrograf.t)
    ~(observation : Observation.t)
    ~(interpretation : Interpretation.t) : Finding.t list =
  let findings = ref [] in
  let add f = findings := f :: !findings in
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
          add
            (mk_finding
               "IMPL-ACCESS-CROSS-SERVICE"
               (Printf.sprintf
                  "%s uses implementation of service %s outside its public \
                   contract (module %s)"
                  i.Interpretation.from_owner
                  i.Interpretation.to_service
                  i.Interpretation.target_module )
               [i.Interpretation.from_owner; i.Interpretation.to_service]
               (sites_locations i.Interpretation.sites)
               i.Interpretation.evidence_path )
      | Interpretation.ResourceAccess ->
          (* Allowed performers: Access-role services, Utility-role
             services (the infrastructure bar) and approved shared
             modules. *)
          let from_role = role_of_name i.Interpretation.from_owner in
          let approved_shared =
            List.exists
              (fun m ->
                Canonical.matches ~declared:m i.Interpretation.from_owner )
              policy.Policy.approved_shared_modules
          in
          let allowed =
            from_role = Szaniec_architecture_access.Cyrograf.Access
            || from_role = Szaniec_architecture_access.Cyrograf.Utility
            || approved_shared
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
  (* shared consumption *)
  let unit_paths =
    List.map
      (fun (u : Observation.unit_info) -> u.Observation.canonical)
      observation.Observation.units
  in
  let consumers : (string, string list) Hashtbl.t = Hashtbl.create 32 in
  let consumer_sites : (string, Observation.site list) Hashtbl.t =
    Hashtbl.create 32
  in
  List.iter
    (fun (c : Observation.call) ->
      if String.length c.Observation.callee > 0
      then
        match Canonical.unit_prefix unit_paths c.Observation.callee with
        | Some target_unit -> (
            let target_owner =
              match
                List.find_opt
                  (fun (o : Interpretation.ownership) ->
                    String.equal o.Interpretation.owner_module target_unit )
                  interpretation.Interpretation.ownerships
              with
              | Some o -> o
              | None ->
                  { owner_module= target_unit
                  ; owner_class= Interpretation.Unclassified
                  ; owner_service= "" }
            in
            match target_owner.Interpretation.owner_class with
            | Interpretation.ExternalLibrary _
             |Interpretation.CompositionRoot
             |Interpretation.Contract_of _ ->
                ()
            | _ -> (
                let caller_owner =
                  match
                    List.find_opt
                      (fun (o : Interpretation.ownership) ->
                        String.equal
                          o.Interpretation.owner_module
                          c.Observation.call_unit )
                      interpretation.Interpretation.ownerships
                  with
                  | Some o -> o
                  | None ->
                      { owner_module= c.Observation.call_unit
                      ; owner_class= Interpretation.Unclassified
                      ; owner_service= "" }
                in
                match caller_owner.Interpretation.owner_class with
                | Interpretation.ExternalLibrary _ -> ()
                | _ -> (
                    let consumer =
                      if
                        String.equal
                          caller_owner.Interpretation.owner_service
                          ""
                      then caller_owner.Interpretation.owner_module
                      else caller_owner.Interpretation.owner_service
                    in
                    match Hashtbl.find_opt consumers target_unit with
                    | Some l ->
                        if not (List.mem consumer l)
                        then (
                          Hashtbl.replace consumers target_unit (consumer :: l) ;
                          Hashtbl.replace
                            consumer_sites
                            target_unit
                            ( c.Observation.site
                            ::
                            ( try Hashtbl.find consumer_sites target_unit with
                            | Not_found -> [] ) ) )
                    | None ->
                        Hashtbl.replace consumers target_unit [consumer] ;
                        Hashtbl.replace
                          consumer_sites
                          target_unit
                          [c.Observation.site] ) ) )
        | None -> () )
    observation.Observation.calls ;
  Hashtbl.iter
    (fun target cs ->
      let distinct = List.sort_uniq compare cs in
      if List.length distinct >= 2
      then
        if
          not
            (List.exists
               (fun m -> Canonical.matches ~declared:m target)
               policy.Policy.approved_shared_modules )
        then
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
                  (List.sort
                     compare
                     ( try Hashtbl.find consumer_sites target with
                     | Not_found -> [] ) ) )
               [target] )
        else () )
    consumers ;
  (* unclassified code *)
  List.iter
    (fun (o : Interpretation.ownership) ->
      match o.Interpretation.owner_class with
      | Interpretation.Unclassified ->
          let approved_shared =
            List.exists
              (fun m ->
                Canonical.matches ~declared:m o.Interpretation.owner_module )
              policy.Policy.approved_shared_modules
          in
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
          (* A stale unit was not read, so "no owner" is not established. *)
          if approved_shared || not fresh
          then ()
          else
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
