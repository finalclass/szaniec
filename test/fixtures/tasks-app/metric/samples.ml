(* szaniec-cc/1 specimens. Expected complexities are asserted by
   test/acceptance/complexity_runner.ml. [alias_of_straight] and
   [partial_apply] are not function definitions. *)

let straight x = x

let alias_of_straight = straight

let conditional x = if x then 1 else 0

let multi x =
  match x with
  | 0 -> "a"
  | 1 -> "b"
  | _ -> "c"

let guarded x =
  match x with
  | n when n > 0 -> n
  | _ -> 0

let short x y z = (x && y) || z

let if_and x y = if x && y then 1 else 0

let loop_for n =
  let r = ref 0 in
  for i = 1 to n do
    r := !r + i
  done ;
  !r

let loop_while n =
  let r = ref n in
  while !r > 0 do
    r := !r - 1
  done ;
  !r

let exceptional f =
  try f () with
  | Failure _ -> 0

let two_handlers f =
  try f () with
  | Failure _ -> 0
  | _ -> 1

let match_exn thunk =
  match thunk () with
  | 0 -> 1
  | exception Failure _ -> 0
[@@warning "-8"]

let or_pat x =
  match x with
  | 0
   |1 ->
      "a"
  | _ -> "b"

let partial_match (x : int option) =
  match x with
  | Some n -> n
[@@warning "-8"]

let outer x =
  let nested y = if y then 1 else 0 in
  nested x

let curried a b = if a then b else 0

let partial_apply : bool list -> bool list = List.map straight

let uses_anon xs = List.map (fun x -> if x then 1 else 0) xs

let returns_fun x = fun y -> if y then x else 0

let shadow x = x

let shadow_kept = shadow

let shadow x = if x then 1 else 0

let unused_plain () = 1

let as_function = function
  | 0 -> 1
  | 1 -> 2
  | _ -> 3

let if_unit x = if x then ()

let just_raise x = if x then raise Exit else 0

module Local = struct
  let hidden () = 1
end

type _ Effect.t += Sample : unit Effect.t

let with_effect (f : unit -> int) =
  try f () with
  | effect Sample, k -> Effect.Deep.continue k ()
