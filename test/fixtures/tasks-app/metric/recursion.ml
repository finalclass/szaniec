(* Recursive specimens for szaniec-cc/1. Each is one function: [recursive]
   is 2, and [even] and [odd] are 2. Calls between them make the Well
   adapter classify this unit as a helper of itself; the inventory still
   lists every definition. *)

let rec recursive n = if n <= 0 then 0 else n + recursive (n - 1)

let rec even n = if n = 0 then true else odd (n - 1)

and odd n = if n = 0 then false else even (n - 1)
