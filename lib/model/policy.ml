(* Approved policy model. Mirrors docs/contracts/policy-format.md
   (szaniec-policy/2). Services, roles and methods are discovered from
   cyrograf contract files and code evidence, not declared here. *)

type t =
  { name: string
  ; program_roots: string list
  ; approved_shared_modules: string list
  ; resources: resource list }

and resource =
  { resource_name: string
  ; api_prefixes: string list }
