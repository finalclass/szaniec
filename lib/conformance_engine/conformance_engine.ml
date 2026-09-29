(* ConformanceEngine: evaluates the interpretation model against the
   approved policy using the rule catalog szaniec-rules/1.0.0.
   See docs/contracts/rule-catalog.md. *)

open Szaniec_model

let role_of_owner (policy : Policy.t) (owner : string) : Policy.role option =
  match
    List.find_opt
      (fun (s : Policy.service) -> String.equal s.Policy.name owner)
      policy.Policy.services
  with
  | Some s -> Some s.Policy.role
  | None -> None

let service_names (policy : Policy.t) : string list =
  List.map (fun (s : Policy.service) -> s.Policy.name) policy.Policy.services

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

let evaluate
    ~(policy : Policy.t)
    ~(observation : Observation.t)
    ~(interpretation : Interpretation.t) : Finding.t list =
  let findings = ref [] in
  let add f = findings := f :: !findings in
  List.iter
    (fun (i : Interpretation.interaction) ->
      match i.Interpretation.kind with
      | Interpretation.ServiceRequest ->
          let from_role = role_of_owner policy i.Interpretation.from_owner in
          let to_role = role_of_owner policy i.Interpretation.to_service in
          let self_call =
            String.equal i.Interpretation.from_owner i.Interpretation.to_service
          in
          (* structural layer rules *)
          ( match (from_role, to_role) with
          | Some Policy.Client, Some Policy.Access ->
              add
                (mk_finding
                   "ID-CLIENT-ACCESS"
                   (Printf.sprintf
                      "client service %s calls access service %s directly"
                      i.Interpretation.from_owner
                      i.Interpretation.to_service )
                   [i.Interpretation.from_owner; i.Interpretation.to_service]
                   (sites_locations i.Interpretation.sites)
                   i.Interpretation.evidence_path )
          | Some Policy.Engine, Some Policy.Engine when not self_call ->
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
          | Some Policy.Access, Some _ when not self_call ->
              add
                (mk_finding
                   "ID-ACCESS-OUTBOUND"
                   (Printf.sprintf
                      "access service %s calls service %s"
                      i.Interpretation.from_owner
                      i.Interpretation.to_service )
                   [i.Interpretation.from_owner; i.Interpretation.to_service]
                   (sites_locations i.Interpretation.sites)
                   i.Interpretation.evidence_path )
          | _ -> () ) ;
          (* project policy *)
          if
            (not self_call)
            && not
                 (List.exists
                    (fun (a, b) ->
                      String.equal a i.Interpretation.from_owner
                      && String.equal b i.Interpretation.to_service )
                    policy.Policy.approved_calls )
          then
            add
              (mk_finding
                 "POLICY-UNAPPROVED-CALL"
                 (Printf.sprintf
                    "call %s -> %s is layer-correct but absent from \
                     approvedCalls"
                    i.Interpretation.from_owner
                    i.Interpretation.to_service )
                 [i.Interpretation.from_owner; i.Interpretation.to_service]
                 (sites_locations i.Interpretation.sites)
                 i.Interpretation.evidence_path )
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
          let allowed =
            List.exists
              (fun (r : Policy.resource) ->
                String.equal r.Policy.resource_name i.Interpretation.resource
                && List.exists
                     (fun a -> String.equal a i.Interpretation.from_owner)
                     r.Policy.accessors )
              policy.Policy.resources
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
  (* shared consumption *)
  let unit_paths =
    List.map
      (fun (u : Observation.unit_info) -> u.Observation.canonical)
      observation.Observation.units
  in
  (* consumers: unit -> (consumer name * call site) list *)
  let consumers : (string, (string * Observation.site) list) Hashtbl.t =
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
                        if List.exists (fun (n, _) -> String.equal n consumer) l
                        then ()
                        else
                          Hashtbl.replace
                            consumers
                            target_unit
                            ((consumer, c.Observation.site) :: l)
                    | None ->
                        Hashtbl.replace
                          consumers
                          target_unit
                          [(consumer, c.Observation.site)] ) ) )
        | None -> () )
    observation.Observation.calls ;
  Hashtbl.iter
    (fun target cs ->
      let distinct = List.sort_uniq compare (List.map fst cs) in
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
               (sites_locations (cs |> List.map snd |> List.sort compare))
               [target] )
        else () )
    consumers ;
  (* unclassified code *)
  List.iter
    (fun (o : Interpretation.ownership) ->
      match o.Interpretation.owner_class with
      | Interpretation.Unclassified ->
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
