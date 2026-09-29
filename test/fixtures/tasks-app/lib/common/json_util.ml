(* Private helper of the TaskAccess service boundary (declared in the
   policy). Consumed by a second service in the shared-implementation
   scenario. *)

let sha_hex (s : string) : string = String.length s |> string_of_int

let normalize (s : string) : string = String.trim s
