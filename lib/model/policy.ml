(* Approved policy model. Mirrors docs/contracts/policy-format.md
   (szaniec-policy/1). *)

type role =
  | Client
  | Manager
  | Engine
  | Access

let role_of_string = function
  | "client" -> Some Client
  | "manager" -> Some Manager
  | "engine" -> Some Engine
  | "access" -> Some Access
  | _ -> None

let role_to_string = function
  | Client -> "client"
  | Manager -> "manager"
  | Engine -> "engine"
  | Access -> "access"

type service =
  { name: string
  ; role: role
  ; contract_modules: string list
  ; implementation_modules: string list
  ; helper_modules: string list }

type resource =
  { resource_name: string
  ; api_prefixes: string list
  ; accessors: string list }

type external_library =
  { lib_name: string
  ; unit_prefixes: string list }

type t =
  { name: string
  ; profile: string
  ; program_roots: string list
  ; composition_roots: string list
  ; services: service list
  ; approved_calls: (string * string) list
  ; approved_shared_modules: string list
  ; resources: resource list
  ; external_libraries: external_library list }
