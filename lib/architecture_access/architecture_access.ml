(* ArchitectureAccess: verify the selected approved policy identity. *)
open Szaniec_model
module Config = Szaniec_config.Config

type resolution =
  { policy: Policy.t
  ; policy_digest: string
  ; approved: bool
  ; approved_digest: string option }

type error = string

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
