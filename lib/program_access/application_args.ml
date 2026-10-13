open Typedtree

(* Curried applications can repeat an omitted optional slot in the outer
   spine. Replace that slot in place rather than shifting later parameters. *)
let merge inner outer =
  let rec take label prefix = function
    | [] -> None
    | ((other, _) as entry) :: rest when label = other ->
        Some (entry, List.rev_append prefix rest)
    | entry :: rest -> take label (entry :: prefix) rest
  in
  let rec merge inner outer =
    match inner with
    | [] -> outer
    | ((label, Omitted _) as entry) :: rest -> (
      match take label [] outer with
      | Some (replacement, outer) -> replacement :: merge rest outer
      | None -> entry :: merge rest outer )
    | entry :: rest -> entry :: merge rest outer
  in
  merge inner outer
