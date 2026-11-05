(* ProjectAccess: reads a dune project's build description.

   Walks the source tree the way dune does (skipping "_" and "."
   directories by default, honouring dirs, data_only_dirs and
   vendored_dirs), parses dune-project and every dune file, and returns
   library, executable and test stanzas with their declared dependencies
   and source positions. Never reads _build and never runs a build. *)

open Szaniec_model
open Structure

type error =
  { error_at: position
  ; error_message: string }

exception Failed of error

let ( // ) a b = if a = "" then b else Filename.concat a b

let fail path (p : Sexp.pos) message =
  raise
    (Failed {error_at= {path; line= p.line; col= p.col}; error_message= message})

let position path (p : Sexp.pos) = {path; line= p.line; col= p.col}

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* Parse one file; [rel] is relative to the project root. *)
let parse ~root rel : Sexp.t list =
  let text =
    try read_file (root // rel) with
    | Sys_error e -> fail rel {line= 1; col= 1} ("cannot read file: " ^ e)
  in
  if String.starts_with ~prefix:"(* -*- tuareg -*- *)" text
  then fail rel {line= 1; col= 1} "dune files in OCaml syntax are not supported" ;
  try Sexp.parse_string text with
  | Sexp.Error (p, message) -> fail rel p ("parse error: " ^ message)

let atom_value = function
  | Sexp.Atom (s, _)
   |Sexp.Quoted (s, _) ->
      Some s
  | Sexp.List _ -> None

(* ── dune's predicate language for directory sets ─────────────────── *)

(* Glob with "*", "?", "[...]" and "{a,b}". *)
let rec glob_match (pattern : string) (s : string) : bool =
  let pl = String.length pattern and sl = String.length s in
  let rec go pi si =
    if pi = pl
    then si = sl
    else
      match pattern.[pi] with
      | '*' -> go (pi + 1) si || (si < sl && go pi (si + 1))
      | '?' -> si < sl && go (pi + 1) (si + 1)
      | '[' -> (
        match String.index_from_opt pattern pi ']' with
        | Some close when si < sl ->
            let set = String.sub pattern (pi + 1) (close - pi - 1) in
            String.contains set s.[si] && go (close + 1) (si + 1)
        | _ -> false )
      | '{' -> (
        match String.index_from_opt pattern pi '}' with
        | Some close ->
            let alternatives =
              String.split_on_char
                ','
                (String.sub pattern (pi + 1) (close - pi - 1))
            in
            let rest = String.sub pattern (close + 1) (pl - close - 1) in
            let remaining = String.sub s si (sl - si) in
            List.exists
              (fun alt -> glob_match (alt ^ rest) remaining)
              alternatives
        | None -> si < sl && s.[si] = '{' && go (pi + 1) (si + 1) )
      | c -> si < sl && s.[si] = c && go (pi + 1) (si + 1)
  in
  go 0 0

let standard_dir name =
  not (String.length name > 0 && (name.[0] = '.' || name.[0] = '_'))

(* Evaluate a predicate-language list over a directory name. Items before
   the first backslash are united; each later group is subtracted. *)
let rec predicate ~path ~(standard : string -> bool) (items : Sexp.t list) :
    string -> bool =
  let groups =
    List.fold_left
      (fun groups item ->
        match item with
        | Sexp.Atom ("\\", _) -> [] :: groups
        | _ -> (
          match groups with
          | g :: rest -> (item :: g) :: rest
          | [] -> [[item]] ) )
      [[]]
      items
    |> List.rev_map List.rev
  in
  let element item =
    match item with
    | Sexp.Atom (":standard", _) -> standard
    | Sexp.Atom (s, p) when String.length s > 0 && s.[0] = ':' ->
        fail path p ("unsupported directory set " ^ s)
    | Sexp.Atom (s, _)
     |Sexp.Quoted (s, _) ->
        glob_match s
    | Sexp.List (Sexp.Atom ("or", _) :: xs, _) ->
        let ps = List.map (fun x -> predicate ~path ~standard [x]) xs in
        fun n -> List.exists (fun p -> p n) ps
    | Sexp.List (Sexp.Atom ("and", _) :: xs, _) ->
        let ps = List.map (fun x -> predicate ~path ~standard [x]) xs in
        fun n -> List.for_all (fun p -> p n) ps
    | Sexp.List ([Sexp.Atom ("not", _); x], _) ->
        let p = predicate ~path ~standard [x] in
        fun n -> not (p n)
    | Sexp.List (xs, _) -> predicate ~path ~standard xs
  in
  let union group =
    let ps = List.map element group in
    fun n -> List.exists (fun p -> p n) ps
  in
  match groups with
  | [] -> fun _ -> false
  | first :: rest ->
      let keep = union first and drop = List.map union rest in
      fun n -> keep n && not (List.exists (fun d -> d n) drop)

(* ── stanza extraction ────────────────────────────────────────────── *)

let is_variable s = String.length s > 1 && s.[0] = '%' && s.[1] = '{'

type collected =
  { mutable stanzas: stanza list
  ; mutable unsupported: unsupported list }

let field name fields =
  List.find_map
    (function
      | Sexp.List (Sexp.Atom (n, _) :: args, p) when n = name -> Some (args, p)
      | _ -> None )
    fields

(* Position of the field's name atom. *)
let field_atom name fields =
  List.find_map
    (function
      | Sexp.List (Sexp.Atom (n, p) :: _, _) when n = name -> Some p
      | _ -> None )
    fields

let dependencies ~path ~(note : string -> string -> position -> unit) fields :
    dependency list =
  let deps = ref [] in
  let add source = function
    | Sexp.Atom (s, p)
     |Sexp.Quoted (s, p) ->
        if is_variable s
        then
          note
            "variable dependency"
            ("dependency " ^ s ^ " is computed by a dune variable")
            (position path p)
        else
          deps :=
            {dep_name= s; dep_source= source; dep_at= position path p} :: !deps
    | Sexp.List (_, p) -> fail path p "expected a library name"
  in
  ( match field "libraries" fields with
  | None -> ()
  | Some (items, _) ->
      List.iter
        (function
          | Sexp.List (Sexp.Atom ("re_export", _) :: [x], _) -> add Re_export x
          | Sexp.List
              (Sexp.Atom ("select", _) :: _ :: Sexp.Atom ("from", _) :: alts, _)
            ->
              List.iter
                (function
                  | Sexp.List (choice, _) ->
                      let rec before_arrow = function
                        | Sexp.Atom ("->", _) :: _ -> ()
                        | (Sexp.Atom (s, _) as x) :: rest ->
                            if not (String.length s > 0 && s.[0] = '!')
                            then add Select x ;
                            before_arrow rest
                        | x :: rest ->
                            add Select x ;
                            before_arrow rest
                        | [] -> ()
                      in
                      before_arrow choice
                  | x ->
                      fail path (Sexp.pos_of x) "malformed select alternative" )
                alts
          | Sexp.List (_, p) -> fail path p "unsupported form in libraries"
          | x -> add Libraries x )
        items ) ;
  ( match field "preprocess" fields with
  | None -> ()
  | Some (spec, _) ->
      let rec find = function
        | Sexp.List (Sexp.Atom (("pps" | "staged_pps"), _) :: args, _) ->
            let rec take = function
              | Sexp.Atom ("--", _) :: _ -> ()
              | (Sexp.Atom (s, _) as x) :: rest ->
                  if not (String.length s > 0 && s.[0] = '-') then add Pps x ;
                  take rest
              | _ :: rest -> take rest
              | [] -> ()
            in
            take args
        | Sexp.List (xs, _) -> List.iter find xs
        | _ -> ()
      in
      List.iter find spec ) ;
  ( match field "ppx_runtime_libraries" fields with
  | None -> ()
  | Some (items, _) -> List.iter (add Ppx_runtime) items ) ;
  List.rev !deps

let names_of ~path kind fields =
  let single = function
    | [x] -> (
      match atom_value x with
      | Some s -> [(s, Sexp.pos_of x)]
      | None -> fail path (Sexp.pos_of x) "expected a name" )
    | _ -> []
  in
  match kind with
  | `Single -> (
    match field "name" fields with
    | Some (args, _) -> single args
    | None -> [] )
  | `Plural -> (
    match field "names" fields with
    | Some (args, _) ->
        List.map
          (fun x ->
            match atom_value x with
            | Some s -> (s, Sexp.pos_of x)
            | None -> fail path (Sexp.pos_of x) "expected a name" )
          args
    | None -> [] )

let add_stanza (acc : collected) ~path ~stanza_pos kind arity fields =
  let names = names_of ~path arity fields in
  if names = [] then fail path stanza_pos "stanza without a name" ;
  let owner = fst (List.hd names) in
  let owner_kind = stanza_kind_name kind in
  let note construct detail at =
    acc.unsupported <-
      {construct; detail; owner; owner_kind; unsupported_at= at}
      :: acc.unsupported
  in
  List.iter
    (fun name ->
      match field_atom name fields with
      | Some p ->
          note
            name
            ( "("
            ^ name
            ^ ") selects an implementation outside the declared dependencies" )
            (position path p)
      | None -> () )
    ["virtual_modules"; "implements"; "default_implementation"] ;
  let deps = dependencies ~path ~note fields in
  let public_name =
    match field "public_name" fields with
    | Some ([x], _) -> atom_value x
    | _ -> None
  in
  List.iter
    (fun (name, p) ->
      acc.stanzas <-
        {kind; name; public_name; at= position path p; deps} :: acc.stanzas )
    names

(* copy_files sources that leave the stanza's directory. *)
let copy_files (acc : collected) ~dir ~path construct args =
  let source =
    match args with
    | [((Sexp.Atom _ | Sexp.Quoted _) as x)] ->
        Option.map (fun s -> (s, Sexp.pos_of x)) (atom_value x)
    | _ ->
        Option.bind (field "files" args) (function
          | [x], _ -> Option.map (fun s -> (s, Sexp.pos_of x)) (atom_value x)
          | _ -> None )
  in
  match source with
  | Some (glob, p) ->
      let leaves =
        (String.length glob > 0 && glob.[0] = '/')
        || List.mem ".." (String.split_on_char '/' glob)
        || is_variable glob
      in
      if leaves
      then
        acc.unsupported <-
          { construct
          ; detail=
              "("
              ^ construct
              ^ " "
              ^ glob
              ^ ") compiles sources from outside the stanza's directory"
          ; owner= (if dir = "" then "." else dir)
          ; owner_kind= "directory"
          ; unsupported_at= position path p }
          :: acc.unsupported
  | None -> ()

(* Directory-level settings collected from dune files. *)
type dir_settings =
  { mutable dirs: (Sexp.t list * string) option
  ; mutable data_only: (Sexp.t list * string) list
  ; mutable vendored: (Sexp.t list * string) list
  ; mutable forms: (Sexp.t * string) list (* stanza, file *) }

let settings_table : (string, dir_settings) Hashtbl.t -> string -> dir_settings
    =
 fun table dir ->
  match Hashtbl.find_opt table dir with
  | Some s -> s
  | None ->
      let s = {dirs= None; data_only= []; vendored= []; forms= []} in
      Hashtbl.add table dir s ;
      s

(* Distribute the forms of one file to directories, following subdir and
   include. *)
let rec distribute ~root table ~dir ~path (forms : Sexp.t list) =
  List.iter
    (fun form ->
      match form with
      | Sexp.List (Sexp.Atom ("subdir", _) :: target :: body, p) -> (
        match atom_value target with
        | Some sub ->
            let sub_dir =
              String.split_on_char '/' sub
              |> List.filter (fun s -> s <> "" && s <> ".")
              |> List.fold_left ( // ) dir
            in
            if List.mem ".." (String.split_on_char '/' sub)
            then fail path p "subdir outside the current directory" ;
            distribute ~root table ~dir:sub_dir ~path body
        | None -> fail path p "malformed subdir" )
      | Sexp.List ([Sexp.Atom ("include", _); file], p) -> (
        match atom_value file with
        | Some f ->
            let included = dir // f in
            if not (Sys.file_exists (root // included))
            then fail path p ("included file not found: " ^ f) ;
            distribute ~root table ~dir ~path:included (parse ~root included)
        | None -> fail path p "malformed include" )
      | Sexp.List (Sexp.Atom ("dirs", _) :: items, _) ->
          (settings_table table dir).dirs <- Some (items, path)
      | Sexp.List (Sexp.Atom ("ignored_subdirs", _) :: [Sexp.List (items, _)], _)
        ->
          let s = settings_table table dir in
          s.dirs <-
            Some
              ( [ Sexp.Atom (":standard", {line= 0; col= 0})
                ; Sexp.Atom ("\\", {line= 0; col= 0}) ]
                @ items
              , path )
      | Sexp.List (Sexp.Atom ("data_only_dirs", _) :: items, _) ->
          let s = settings_table table dir in
          s.data_only <- (items, path) :: s.data_only
      | Sexp.List (Sexp.Atom ("vendored_dirs", _) :: items, _) ->
          let s = settings_table table dir in
          s.vendored <- (items, path) :: s.vendored
      | _ ->
          let s = settings_table table dir in
          s.forms <- (form, path) :: s.forms )
    forms

let interpret (acc : collected) ~dir (form, path) =
  match form with
  | Sexp.List (Sexp.Atom (("library" as k), _) :: fields, p)
   |Sexp.List (Sexp.Atom (("executable" as k), _) :: fields, p)
   |Sexp.List (Sexp.Atom (("executables" as k), _) :: fields, p)
   |Sexp.List (Sexp.Atom (("test" as k), _) :: fields, p)
   |Sexp.List (Sexp.Atom (("tests" as k), _) :: fields, p) ->
      let kind, arity =
        match k with
        | "library" -> (Library, `Single)
        | "executable" -> (Executable, `Single)
        | "executables" -> (Executable, `Plural)
        | "test" -> (Test, `Single)
        | _ -> (Test, `Plural)
      in
      add_stanza acc ~path ~stanza_pos:p kind arity fields
  | Sexp.List (Sexp.Atom ((("copy_files" | "copy_files#") as c), _) :: args, _)
    ->
      copy_files acc ~dir ~path c args
  | _ -> ()

let read_dune_project ~root rel : dune_project =
  let forms = parse ~root rel in
  let find name =
    List.find_map
      (function
        | Sexp.List ([Sexp.Atom (n, _); v], _) when n = name -> (
          match atom_value v with
          | Some s -> Some (s, position rel (Sexp.pos_of v))
          | None -> None )
        | Sexp.List (Sexp.Atom ("lang", _) :: Sexp.Atom ("dune", _) :: [v], _)
          when name = "lang" -> (
          match atom_value v with
          | Some s -> Some (s, position rel (Sexp.pos_of v))
          | None -> None )
        | _ -> None )
      forms
  in
  { project_path= rel
  ; lang= find "lang"
  ; implicit_transitive_deps= find "implicit_transitive_deps" }

let load ~(root : string) : (project, error) result =
  try
    if not (Sys.file_exists (root // "dune-project"))
    then
      raise
        (Failed
           { error_at= {path= "dune-project"; line= 1; col= 1}
           ; error_message= "not a dune project: dune-project is missing" } ) ;
    let table = Hashtbl.create 64 in
    let acc = {stanzas= []; unsupported= []} in
    let projects = ref [] in
    let directories = ref [] in
    let visited = Hashtbl.create 64 in
    let rec walk dir ~data_only =
      let real =
        try Unix.realpath (root // dir) with
        | _ -> root // dir
      in
      if not (Hashtbl.mem visited real)
      then (
        Hashtbl.add visited real () ;
        directories := dir :: !directories ;
        let entries =
          try Sys.readdir (root // dir) |> Array.to_list with
          | Sys_error _ -> []
        in
        if (not data_only) && List.mem "dune-project" entries
        then
          projects :=
            read_dune_project ~root (dir // "dune-project") :: !projects ;
        if (not data_only) && List.mem "dune" entries
        then
          distribute
            ~root
            table
            ~dir
            ~path:(dir // "dune")
            (parse ~root (dir // "dune")) ;
        let settings = settings_table table dir in
        if not data_only
        then List.iter (interpret acc ~dir) (List.rev settings.forms) ;
        let on_disk =
          List.filter
            (fun e ->
              e <> "_build"
              &&
              try Sys.is_directory (root // dir // e) with
              | Sys_error _ -> false )
            entries
        in
        (* subdir stanzas may name directories that do not exist *)
        let virtual_children =
          let prefix = if dir = "" then "" else dir ^ "/" in
          Hashtbl.fold
            (fun d _ acc ->
              if d <> dir && String.starts_with ~prefix d
              then
                let rest =
                  String.sub
                    d
                    (String.length prefix)
                    (String.length d - String.length prefix)
                in
                List.hd (String.split_on_char '/' rest) :: acc
              else acc )
            table
            []
        in
        let children = List.sort_uniq compare (on_disk @ virtual_children) in
        let included =
          if data_only
          then standard_dir
          else
            match settings.dirs with
            | Some (items, path) -> predicate ~path ~standard:standard_dir items
            | None -> standard_dir
        in
        let member sets =
          let ps =
            List.map
              (fun (items, path) ->
                predicate ~path ~standard:(fun _ -> false) items )
              sets
          in
          fun n -> List.exists (fun p -> p n) ps
        in
        let vendored = member settings.vendored in
        let data = member settings.data_only in
        List.iter
          (fun child ->
            if included child && child <> "_build" && not (vendored child)
            then walk (dir // child) ~data_only:(data_only || data child) )
          children )
    in
    walk "" ~data_only:false ;
    let projects =
      List.sort
        (fun a b ->
          compare
            (a.project_path <> "dune-project", a.project_path)
            (b.project_path <> "dune-project", b.project_path) )
        !projects
    in
    let by_position a b =
      compare (a.path, a.line, a.col) (b.path, b.line, b.col)
    in
    Ok
      { root
      ; dune_projects= projects
      ; stanzas= List.sort (fun a b -> by_position a.at b.at) acc.stanzas
      ; unsupported=
          List.sort
            (fun a b -> by_position a.unsupported_at b.unsupported_at)
            acc.unsupported
      ; directories= List.sort compare !directories }
  with
  | Failed e -> Error e
