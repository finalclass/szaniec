(* ArchitectureAccess: parse and validate the approved policy (szaniec-policy/1)
   and verify the approved-policy selection (szaniec-approval/1). *)

open Szaniec_model

type resolution =
  { policy: Policy.t
  ; policy_digest: string (* "sha256:<hex>" over the raw file bytes *)
  ; approved: bool
  ; approved_digest: string option
  ; approval_path: string }

type error = string

let sha256_file (path : string) : string =
  let data =
    try
      let ic = open_in_bin path in
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic ;
      s
    with
    | Sys_error _ -> ""
  in
  "sha256:" ^ Digestif.SHA256.to_hex (Digestif.SHA256.digest_string data)

let read_approval (path : string) : (string * string * string, string) result =
  (* returns (policyName, policyDigest, format) or error message *)
  match Yojson.Safe.from_file path with
  | exception _ ->
      Error (Printf.sprintf "approval file %s is not valid JSON" path)
  | json -> (
    match json with
    | `Assoc fields -> (
        let get k =
          match List.assoc_opt k fields with
          | Some (`String s) -> Some s
          | _ -> None
        in
        match (get "format", get "policyName", get "policyDigest") with
        | Some f, Some n, Some d
          when String.equal f Szaniec_model.Version.approval_format ->
            Ok (n, d, f)
        | Some _, _, _ ->
            Error
              (Printf.sprintf
                 "approval file %s is missing policyName or policyDigest"
                 path )
        | _ -> Error (Printf.sprintf "approval file %s has wrong format" path) )
    | _ -> Error (Printf.sprintf "approval file %s is not a JSON object" path) )

let string_list (json : Yojson.Safe.t) : string list =
  match json with
  | `List items ->
      List.filter_map
        (fun i ->
          match i with
          | `String s -> Some s
          | _ -> None )
        items
  | _ -> []

let parse_policy (path : string) : (Policy.t, error) result =
  match Yojson.Safe.from_file path with
  | exception _ ->
      Error (Printf.sprintf "policy file %s is not valid JSON" path)
  | json -> (
    match json with
    | `Assoc fields -> (
        let get k = List.assoc_opt k fields in
        let get_str k =
          match get k with
          | Some (`String s) -> Some s
          | _ -> None
        in
        match get_str "format" with
        | Some f when String.equal f Szaniec_model.Version.policy_format ->
            let name = Option.value ~default:"unnamed" (get_str "policyName") in
            let profile =
              Option.value ~default:Version.default_profile (get_str "profile")
            in
            let program_roots =
              match get "program" with
              | Some (`Assoc pf) -> (
                match List.assoc_opt "roots" pf with
                | Some roots -> string_list roots
                | None -> ["bin"; "lib"] )
              | _ -> ["bin"; "lib"]
            in
            let composition_roots =
              match get "compositionRoots" with
              | Some l -> string_list l
              | None -> []
            in
            let services =
              match get "services" with
              | Some (`List svcs) ->
                  List.filter_map
                    (fun s ->
                      match s with
                      | `Assoc sf -> (
                          let getf k =
                            match List.assoc_opt k sf with
                            | Some (`String x) -> Some x
                            | _ -> None
                          in
                          let getl k =
                            match List.assoc_opt k sf with
                            | Some x -> Some (string_list x)
                            | None -> None
                          in
                          match (getf "name", getf "role") with
                          | Some n, Some r -> (
                            match Policy.role_of_string r with
                            | Some role ->
                                Some
                                  { Policy.name= n
                                  ; role
                                  ; contract_modules=
                                      Option.value
                                        ~default:[]
                                        (getl "contractModules")
                                  ; implementation_modules=
                                      Option.value
                                        ~default:[]
                                        (getl "implementationModules")
                                  ; helper_modules=
                                      Option.value
                                        ~default:[]
                                        (getl "helperModules") }
                            | None -> None )
                          | _ -> None )
                      | _ -> None )
                    svcs
              | _ -> []
            in
            let approved_calls =
              match get "approvedCalls" with
              | Some (`List items) ->
                  List.filter_map
                    (fun i ->
                      match i with
                      | `Assoc ef -> (
                          let getf k =
                            match List.assoc_opt k ef with
                            | Some (`String x) -> Some x
                            | _ -> None
                          in
                          match (getf "from", getf "to") with
                          | Some a, Some b -> Some (a, b)
                          | _ -> None )
                      | _ -> None )
                    items
              | _ -> []
            in
            let approved_shared =
              match get "approvedSharedModules" with
              | Some l -> string_list l
              | None -> []
            in
            let resources =
              match get "resources" with
              | Some (`List items) ->
                  List.filter_map
                    (fun i ->
                      match i with
                      | `Assoc rf -> (
                          let getf k =
                            match List.assoc_opt k rf with
                            | Some (`String x) -> Some x
                            | _ -> None
                          in
                          let getl k =
                            match List.assoc_opt k rf with
                            | Some x -> Some (string_list x)
                            | None -> None
                          in
                          match getf "name" with
                          | Some n ->
                              Some
                                { Policy.resource_name= n
                                ; api_prefixes=
                                    Option.value
                                      ~default:[]
                                      (getl "apiPrefixes")
                                ; accessors=
                                    Option.value ~default:[] (getl "accessors")
                                }
                          | None -> None )
                      | _ -> None )
                    items
              | _ -> []
            in
            let externals =
              match get "externalLibraries" with
              | Some (`List items) ->
                  List.filter_map
                    (fun i ->
                      match i with
                      | `Assoc ef -> (
                          let getf k =
                            match List.assoc_opt k ef with
                            | Some (`String x) -> Some x
                            | _ -> None
                          in
                          let getl k =
                            match List.assoc_opt k ef with
                            | Some x -> Some (string_list x)
                            | None -> None
                          in
                          match getf "name" with
                          | Some n ->
                              Some
                                { Policy.lib_name= n
                                ; unit_prefixes=
                                    Option.value
                                      ~default:[]
                                      (getl "unitPrefixes") }
                          | None -> None )
                      | _ -> None )
                    items
              | _ -> []
            in
            Ok
              { Policy.name
              ; profile
              ; program_roots
              ; composition_roots
              ; services
              ; approved_calls
              ; approved_shared_modules= approved_shared
              ; resources
              ; external_libraries= externals }
        | Some _ ->
            Error (Printf.sprintf "policy file %s has wrong format" path)
        | None -> Error (Printf.sprintf "policy file %s is missing format" path)
        )
    | _ -> Error (Printf.sprintf "policy file %s is not a JSON object" path) )

(* Resolve the policy and its approval. The policy content is always used;
   approval is a recorded identity, verified against the current bytes. *)
let resolve ~(policy_path : string) ~(approval_path : string option) :
    (resolution * Szaniec_model.Observation.gap option, error) result =
  match parse_policy policy_path with
  | Error e -> Error e
  | Ok policy -> (
      let policy_digest = sha256_file policy_path in
      match approval_path with
      | None ->
          Ok
            ( { policy
              ; policy_digest
              ; approved= false
              ; approved_digest= None
              ; approval_path= "" }
            , Some
                { Observation.gap_code= "GAP-POLICY-NOT-APPROVED"
                ; gap_path= policy_path
                ; gap_detail= "no approved policy selected (--approval)" } )
      | Some ap -> (
        match read_approval ap with
        | Error e -> Error e
        | Ok (name, digest, _fmt) ->
            let matches_name = String.equal name policy.Policy.name in
            let matches_digest = String.equal digest policy_digest in
            let approved = matches_name && matches_digest in
            let gap =
              if approved
              then None
              else
                Some
                  { Observation.gap_code= "GAP-POLICY-NOT-APPROVED"
                  ; gap_path= policy_path
                  ; gap_detail=
                      Printf.sprintf
                        "policy content (%s) differs from the selected \
                         approved policy (%s)"
                        policy_digest
                        digest }
            in
            Ok
              ( { policy
                ; policy_digest
                ; approved
                ; approved_digest= Some digest
                ; approval_path= ap }
              , gap ) ) )

(* Write an approval file recording the current policy content. *)
let approve ~(policy_path : string) ~(approval_path : string) :
    (unit, error) result =
  match parse_policy policy_path with
  | Error e -> Error e
  | Ok policy ->
      let digest = sha256_file policy_path in
      let json =
        `Assoc
          [ ("format", `String Version.approval_format)
          ; ("policyName", `String policy.Policy.name)
          ; ("policyDigest", `String digest) ]
      in
      let oc = open_out approval_path in
      output_string oc (Yojson.Safe.to_string json) ;
      output_char oc '\n' ;
      close_out oc ;
      Ok ()
