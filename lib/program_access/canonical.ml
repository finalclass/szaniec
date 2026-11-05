(* Canonical module paths of compiler units.

   A canonical path is a dot-joined module path as seen from outside the
   declaring dune library:
   - wrapped library [app], unit [App__Services__Task_access_impl]
     -> "App.Services.Task_access_impl"
   - wrapped-false library, unit [task_access] -> "Task_access"
   - executable unit [Dune__exe__Main] -> "Main" *)

(* Split on double underscores only (dune reserves "__" as separator; user
   module names keep single underscores intact). *)
let split_double (s : string) : string list =
  let n = String.length s in
  let rec go i cur acc =
    if i >= n
    then List.rev (cur :: acc)
    else if i + 1 < n && s.[i] = '_' && s.[i + 1] = '_'
    then go (i + 2) "" (cur :: acc)
    else go (i + 1) (cur ^ String.make 1 s.[i]) acc
  in
  go 0 "" []

let join_dots (segs : string list) : string =
  String.concat "." (List.filter (( <> ) "") segs)

(* Canonicalize a compiler unit name given the name of the dune library
   (or executable) that produced the artifact. *)
let of_unit_name ~(library : string) ~(unit_name : string) : string =
  let lib_cap = String.capitalize_ascii library in
  if String.length unit_name >= 11 && String.sub unit_name 0 11 = "Dune__exe__"
  then String.sub unit_name 11 (String.length unit_name - 11)
  else
    let pl = String.length lib_cap + 2 in
    if
      String.length unit_name > pl && String.sub unit_name 0 pl = lib_cap ^ "__"
    then
      join_dots
        ( lib_cap
        :: split_double (String.sub unit_name pl (String.length unit_name - pl))
        )
    else join_dots (split_double unit_name)
