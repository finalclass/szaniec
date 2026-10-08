(* Canonical module paths.

   A canonical path is a dot-joined module path as seen from outside the
   declaring dune library:
   - wrapped library [app], unit [App__Services__Task_access_impl]
     -> "App.Services.Task_access_impl"
   - wrapped-false library, unit [task_access] -> "Task_access"
   - executable unit [Dune__exe__Main] -> "Main"
   - dune wrapper units ([App__], from .ml-gen files) are skipped from the
     unit list; references through them resolve to the library prefix. *)

type t = string

let split_dots (s : string) : string list =
  String.split_on_char '.' s |> List.filter (fun x -> x <> "")

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

(* Canonicalize a reference path (root identifier name + following
   segments) seen from inside a unit of a wrapped library capitalizing to
   [lib_cap]. [root] is either:
   - the current library's wrapper unit ([App__]) or a wrapped-library
     internal unit ([App__Pages__Shared]) -> library-qualified public path,
   - a persistent unit root ([Task_manager], [Well], [Stdlib], [App]),
   - [Dune__exe__Main] for executable units. *)
let of_ref
    ~(unit_canonical : string)
    ~(lib_cap : string)
    (segments : string list) : t =
  match segments with
  | [] -> unit_canonical
  | root :: rest ->
      let pl = String.length lib_cap + 2 in
      if root = lib_cap ^ "__"
      then join_dots (lib_cap :: rest)
      else if String.length root > pl && String.sub root 0 pl = lib_cap ^ "__"
      then
        join_dots
          ( lib_cap
            :: split_double (String.sub root pl (String.length root - pl))
          @ rest )
      else if String.length root >= 11 && String.sub root 0 11 = "Dune__exe__"
      then
        join_dots
          (split_double (String.sub root 11 (String.length root - 11)) @ rest)
      else join_dots (split_double root @ rest)

(* [true] when canonical path [c] is the declared name [d] or lies under
   it (matching a trailing ".d" boundary). Used for policy ownership. *)
let matches ~(declared : string) (c : t) : bool =
  c = declared
  ||
  let d = String.length declared and cl = String.length c in
  cl > d + 1 && String.sub c (cl - d - 1) (d + 1) = "." ^ declared

let starts_with ~(prefix : string) (c : t) : bool =
  let p = String.length prefix and cl = String.length c in
  cl >= p && String.sub c 0 p = prefix

(* Longest prefix of the path that appears in [units] (canonical unit
   paths), or None when nothing matches. *)
let unit_prefix (units : t list) (c : t) : t option =
  let segs = split_dots c in
  let rec try_n n =
    if n = 0
    then None
    else
      let cand = join_dots (List.filteri (fun i _ -> i < n) segs) in
      if List.mem cand units then Some cand else try_n (n - 1)
  in
  try_n (List.length segs)

let resolve_alias aliases path =
  let rec resolve visited path =
    match unit_prefix (List.map fst aliases) path with
    | None -> Some path
    | Some prefix ->
        if List.mem prefix visited
        then None
        else
          let target = List.assoc prefix aliases in
          let suffix =
            String.sub
              path
              (String.length prefix)
              (String.length path - String.length prefix)
          in
          resolve (prefix :: visited) (target ^ suffix)
  in
  resolve [] path
