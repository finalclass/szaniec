(* Private helper of the Task_access family. Nested module Hex is the
   same compilation unit, so it stays inside the family. *)

module Hex = struct
  let of_string (s : string) : string = String.length s |> string_of_int
end

let sha_hex (s : string) : string = Hex.of_string s

let normalize (s : string) : string = String.trim s
