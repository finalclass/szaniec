(* ArchitectureAccess: verify the selected approved policy identity. *)
open Szaniec_model
module Config = Szaniec_config.Config

type resolution =
  { policy: Policy.t
  ; policy_digest: string
  ; approved: bool
  ; approved_digest: string option }

type error = string

let local_services
    ~approved
    ~(policy : Policy.t)
    ~(cy : Cyrograf.t)
    (obs : Observation.t) =
  let inside root path =
    path = root || Canonical.starts_with ~prefix:(root ^ "/") path
  in
  let gaps = ref [] in
  let services =
    List.filter_map
      (fun (s : Policy.local_service) ->
        let units =
          List.filter
            (fun (u : Observation.unit_info) ->
              inside s.local_root u.source_path )
            obs.units
        in
        let conflict =
          List.exists
            (fun (other : Policy.local_service) ->
              other != s
              && ( Cyrograf.normalize_stem other.local_name
                   = Cyrograf.normalize_stem s.local_name
                 || inside s.local_root other.local_root
                 || inside other.local_root s.local_root ) )
            policy.local_services
          || List.exists
               (fun (rpc : Cyrograf.service) ->
                 Cyrograf.normalize_stem rpc.svc_name
                 = Cyrograf.normalize_stem s.local_name )
               cy.services
        in
        if
          approved
          && (not conflict)
          && units <> []
          && List.for_all (fun (u : Observation.unit_info) -> u.fresh) units
          && List.exists
               (fun root -> inside root s.local_root)
               policy.program_roots
          && Cyrograf.segment_matches_service
               ~service:s.local_name
               (Filename.basename s.local_root)
        then
          Some
            { Cyrograf.svc_name= s.local_name
            ; svc_role= Cyrograf.role_of_suffix s.local_name
            ; svc_methods= [] }
        else (
          gaps :=
            { Observation.gap_code= "GAP-LOCAL-SERVICE"
            ; gap_path= s.local_root
            ; gap_detail=
                "local service requires approved, unique root/name and fresh \
                 typed ownership evidence: "
                ^ s.local_name }
            :: !gaps ;
          None ) )
      policy.local_services
  in
  ( {cy with Cyrograf.services= List.sort_uniq compare (cy.services @ services)}
  , List.sort_uniq compare !gaps )

let resolve ~(config : Config.t) =
  match Config.require_policy config with
  | Error e -> Error e
  | Ok policy ->
      let policy_digest = Policy.digest policy in
      let approved_digest =
        Option.map
          (fun (a : Config.approval) -> a.policy_digest)
          config.approval
      in
      let approved =
        match config.approval with
        | Some a ->
            a.policy_name = policy.Policy.name
            && a.policy_digest = policy_digest
        | None -> false
      in
      let gap =
        if approved
        then None
        else
          Some
            { Observation.gap_code= "GAP-POLICY-NOT-APPROVED"
            ; gap_path= config.path
            ; gap_detail=
                ( match approved_digest with
                | None -> "no approved policy selected ([approval])"
                | Some digest ->
                    Printf.sprintf
                      "policy content (%s) differs from the selected approved \
                       policy (%s)"
                      policy_digest
                      digest ) }
      in
      Ok ({policy; policy_digest; approved; approved_digest}, gap)
