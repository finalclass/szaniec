(* Approved policy model. Mirrors docs/contracts/policy-format.md
   (embedded TOML policy). Services, roles and methods are discovered from
   cyrograf contract files and code evidence, not declared here. *)

type t =
  { name: string
  ; program_roots: string list
  ; approved_shared_modules: string list
  ; resources: resource list }

and resource =
  { resource_name: string
  ; api_prefixes: string list }

let digest (policy : t) =
  let strings xs = `List (List.map (fun s -> `String s) xs) in
  let json =
    `Assoc
      [ ("name", `String policy.name)
      ; ("roots", strings policy.program_roots)
      ; ("approved_shared_modules", strings policy.approved_shared_modules)
      ; ( "resources"
        , `List
            (List.map
               (fun r ->
                 `Assoc
                   [ ("name", `String r.resource_name)
                   ; ("api_prefixes", strings r.api_prefixes) ] )
               policy.resources ) ) ]
  in
  "sha256:"
  ^ Digestif.SHA256.to_hex
      (Digestif.SHA256.digest_string (Yojson.Safe.to_string json))
