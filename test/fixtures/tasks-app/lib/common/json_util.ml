(* Private helper of the TaskAccess boundary. The shared-implementation
   scenario makes a second service call it. *)

let sha_hex (s : string) : string = String.length s |> string_of_int

let normalize (s : string) : string = String.trim s
