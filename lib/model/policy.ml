(* Approved policy model. Mirrors docs/contracts/policy-format.md
   (embedded TOML policy). Services, roles and methods are discovered from
   cyrograf contract files and code evidence, not declared here. *)

type t =
  { name: string
  ; program_roots: string list
  ; approved_shared_modules: string list
  ; contract_bindings: contract_binding list
  ; public_contracts: public_contract list
  ; resources: resource list }

and contract_binding =
  { contract_source: string
  ; contract_module: string }

and public_contract =
  { public_service: string
  ; public_module: string
  ; public_members: string list
  ; public_consumers: string list }

and resource =
  { resource_name: string
  ; api_prefixes: string list }

let digest (policy : t) =
  let strings xs = `List (List.map (fun s -> `String s) xs) in
  let fields =
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
  let fields =
    if policy.contract_bindings = []
    then fields
    else
      fields
      @ [ ( "contract_bindings"
          , `List
              (List.map
                 (fun b ->
                   `Assoc
                     [ ("source", `String b.contract_source)
                     ; ("module", `String b.contract_module) ] )
                 policy.contract_bindings ) ) ]
  in
  let fields =
    if policy.public_contracts = []
    then fields
    else
      fields
      @ [ ( "public_contracts"
          , `List
              (List.map
                 (fun p ->
                   `Assoc
                     [ ("service", `String p.public_service)
                     ; ("module", `String p.public_module)
                     ; ("members", strings p.public_members)
                     ; ("consumers", strings p.public_consumers) ] )
                 policy.public_contracts ) ) ]
  in
  let json = `Assoc fields in
  "sha256:"
  ^ Digestif.SHA256.to_hex
      (Digestif.SHA256.digest_string (Yojson.Safe.to_string json))
