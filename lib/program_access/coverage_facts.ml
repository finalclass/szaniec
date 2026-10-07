(* ProgramAccess coverage facts: source snapshot, function spans, Dune hook
   scan, and internal point-file parsing. No conformance judgment. *)

open Szaniec_model

let ( // ) = Filename.concat

type sexp =
  | Atom of string
  | List of sexp list

type span =
  { id: string
  ; path: string
  ; name: string
  ; kind: Coverage.kind
  ; provenance: string
  ; line: int
  ; col: int
  ; start: int
  ; end_: int }

type file_points =
  { path: string
  ; points: int array
  ; counts: int array }

type inventory_entry =
  { path: string
  ; name: string
  ; line: int
  ; complexity: int option }

(* ── sexp ─────────────────────────────────────────────────────────── *)

let parse_sexps (src : string) : (sexp list, string) result =
  let n = String.length src in
  let i = ref 0 in
  let fail msg = Error (Printf.sprintf "dune syntax at %d: %s" !i msg) in
  let rec skip () =
    if !i >= n
    then ()
    else
      match src.[!i] with
      | ' '
       |'\t'
       |'\n'
       |'\r' ->
          incr i ;
          skip ()
      | ';' ->
          while !i < n && src.[!i] <> '\n' do
            incr i
          done ;
          skip ()
      | '#' when !i + 1 < n && src.[!i + 1] = '|' ->
          i := !i + 2 ;
          let rec block () =
            if !i + 1 >= n
            then ()
            else if src.[!i] = '|' && src.[!i + 1] = '#'
            then i := !i + 2
            else (
              incr i ;
              block () )
          in
          block () ;
          skip ()
      | _ -> ()
  in
  let rec parse_one () =
    skip () ;
    if !i >= n
    then fail "truncated s-expression"
    else
      match src.[!i] with
      | '(' ->
          incr i ;
          let rec elems acc =
            skip () ;
            if !i >= n
            then fail "unclosed list"
            else if src.[!i] = ')'
            then (
              incr i ;
              Ok (List (List.rev acc)) )
            else
              match parse_one () with
              | Error _ as e -> e
              | Ok s -> elems (s :: acc)
          in
          elems []
      | '"' ->
          incr i ;
          let buf = Buffer.create 16 in
          let rec str () =
            if !i >= n
            then fail "unclosed string"
            else
              match src.[!i] with
              | '"' ->
                  incr i ;
                  Ok (Atom (Buffer.contents buf))
              | '\\' when !i + 1 < n ->
                  Buffer.add_char buf src.[!i + 1] ;
                  i := !i + 2 ;
                  str ()
              | c ->
                  Buffer.add_char buf c ;
                  incr i ;
                  str ()
          in
          str ()
      | ')' -> fail "unexpected )"
      | _ ->
          let start = !i in
          while !i < n && not (String.contains " \t\n\r();#" src.[!i]) do
            incr i
          done ;
          Ok (Atom (String.sub src start (!i - start)))
  in
  let rec many acc =
    skip () ;
    if !i >= n
    then Ok (List.rev acc)
    else
      match parse_one () with
      | Error _ as e -> e
      | Ok s -> many (s :: acc)
  in
  many []

let atom = function
  | Atom s -> Some s
  | List _ -> None

let rec field name = function
  | [] -> None
  | List (Atom n :: rest) :: _ when n = name -> Some rest
  | _ :: tl -> field name tl

let has_backend stanza =
  let rec search = function
    | [] -> false
    | List (Atom "instrumentation" :: body) :: tl ->
        let here =
          List.exists
            (function
              | List (Atom "backend" :: Atom "szaniec.instrumentation" :: _) ->
                  true
              | _ -> false )
            body
        in
        here || search tl
    | _ :: tl -> search tl
  in
  search stanza

let stanza_names body =
  match field "names" body with
  | Some atoms -> List.filter_map atom atoms
  | None -> (
    match field "name" body with
    | Some [Atom n] -> [n]
    | Some (Atom n :: _) -> [n]
    | _ -> (
      match field "public_name" body with
      | Some [Atom n] -> [n]
      | _ -> [] ) )

let is_ppx_kind body =
  match field "kind" body with
  | Some [Atom "ppx_rewriter"]
   |Some [Atom "ppx_deriver"] ->
      true
  | _ -> false

let has_action_preprocess body =
  let rec search = function
    | [] -> false
    | List (Atom "preprocess" :: inner) :: _ ->
        List.exists
          (function
            | List (Atom "action" :: _) -> true
            | _ -> false )
          inner
    | _ :: tl -> search tl
  in
  search body

let module_list body =
  match field "modules" body with
  | None -> None
  | Some items ->
      let atoms = List.filter_map atom items in
      if List.length atoms = List.length items && atoms <> []
      then Some atoms
      else None

(* ── snapshot and files ───────────────────────────────────────────── *)

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic ;
  s

let skip_dir name =
  name = "_build"
  || name = "node_modules"
  || name = ".git"
  || name = "test"
  || name = "tests"

let rec collect_files root rel pred acc =
  let dir = if rel = "" then root else root // rel in
  let entries =
    try Sys.readdir dir with
    | Sys_error _ -> [||]
  in
  Array.iter
    (fun e ->
      if e = "." || e = ".." || (e <> "" && e.[0] = '.')
      then ()
      else
        let rel_e = if rel = "" then e else rel // e in
        let path = root // rel_e in
        if Sys.is_directory path
        then if skip_dir e then () else collect_files root rel_e pred acc
        else if pred e
        then acc := rel_e :: !acc )
    entries

let files_under root rels pred =
  let acc = ref [] in
  List.iter
    (fun rel ->
      let path = if rel = "" then root else root // rel in
      if Sys.file_exists path && Sys.is_directory path
      then collect_files root rel pred acc
      else if Sys.file_exists path && pred (Filename.basename path)
      then acc := rel :: !acc )
    rels ;
  List.sort_uniq compare !acc

let sha256_pairs (pairs : (string * string) list) : string =
  let feed ctx text = Digestif.SHA256.feed_string ctx text in
  let ctx =
    List.fold_left
      (fun ctx (path, contents) ->
        feed (feed (feed (feed ctx path) "\n") contents) "\n" )
      (Digestif.SHA256.init ())
      pairs
  in
  "sha256:" ^ Digestif.SHA256.to_hex (Digestif.SHA256.get ctx)

let snapshot (project_root : string) (scope : string list) :
    string * string list =
  let mls =
    files_under project_root scope (fun n -> Filename.check_suffix n ".ml")
  in
  let mlx =
    files_under project_root scope (fun n -> Filename.check_suffix n ".mlx")
  in
  let files = List.sort_uniq compare (mls @ mlx) in
  let pairs =
    List.map (fun rel -> (rel, read_file (project_root // rel))) files
  in
  (sha256_pairs pairs, files)

let is_test_path rel =
  let parts = String.split_on_char '/' rel in
  let rec go = function
    | [] -> false
    | ("test" | "tests") :: "fixtures" :: _ -> false
    | ("test" | "tests") :: _ -> true
    | _ :: rest -> go rest
  in
  go parts

let provenance rel contents =
  if Filename.check_suffix rel ".ml-gen"
  then "generated"
  else if is_test_path rel
  then "test"
  else if
    String.starts_with ~prefix:"(* szaniec-generated" contents
    || String.starts_with ~prefix:"szaniec-generated" contents
  then "generated"
  else "authored"

(* ── function spans ───────────────────────────────────────────────── *)

let loc_line (loc : Location.t) = loc.loc_start.Lexing.pos_lnum

let loc_col (loc : Location.t) =
  loc.loc_start.Lexing.pos_cnum - loc.loc_start.Lexing.pos_bol

let rec pattern_name (p : Parsetree.pattern) =
  match p.ppat_desc with
  | Ppat_var s -> Some s.txt
  | Ppat_constraint (p, _)
   |Ppat_alias (p, _) ->
      pattern_name p
  | _ -> None

let rec peel (e : Parsetree.expression) =
  match e.pexp_desc with
  | Pexp_constraint (e, _)
   |Pexp_coerce (e, _, _) ->
      peel e
  | _ -> e

let index_structure
    (path : string)
    (provenance_s : string)
    (structure : Parsetree.structure) : span list * bool =
  let spans = ref [] in
  let in_body = ref false in
  let add ~name ~kind ~loc =
    let start = loc.Location.loc_start.Lexing.pos_cnum in
    let end_ = loc.Location.loc_end.Lexing.pos_cnum in
    if end_ > start
    then
      let line = loc_line loc in
      let col = loc_col loc in
      let id =
        Printf.sprintf
          "%s:%s:%s:%d:%d"
          path
          (Coverage.kind_string kind)
          name
          line
          col
      in
      spans :=
        {id; path; name; kind; provenance= provenance_s; line; col; start; end_}
        :: !spans
  in
  let super = Ast_iterator.default_iterator in
  let walk_param this (p : Parsetree.function_param) =
    match p.pparam_desc with
    | Pparam_val (_, Some default, _) -> this.Ast_iterator.expr this default
    | Pparam_val (_, None, _)
     |Pparam_newtype _ ->
        ()
  in
  let walk_body this (body : Parsetree.function_body) =
    let saved = !in_body in
    in_body := true ;
    ( match body with
    | Pfunction_body e -> this.Ast_iterator.expr this e
    | Pfunction_cases (cases, _, _) ->
        List.iter (this.Ast_iterator.case this) cases ) ;
    in_body := saved
  in
  let iter =
    { super with
      expr=
        (fun this e ->
          match (peel e).pexp_desc with
          | Pexp_function (params, _, body) ->
              add ~name:"anonymous" ~kind:Coverage.Anonymous ~loc:e.pexp_loc ;
              List.iter (walk_param this) params ;
              walk_body this body
          | _ -> super.expr this e )
    ; value_binding=
        (fun this vb ->
          let expr = peel vb.Parsetree.pvb_expr in
          match expr.pexp_desc with
          | Pexp_function (params, _, body) ->
              let name, kind =
                match pattern_name vb.pvb_pat with
                | Some n ->
                    let kind =
                      if !in_body then Coverage.Local else Coverage.Function
                    in
                    (n, kind)
                | None -> ("anonymous", Coverage.Anonymous)
              in
              add ~name ~kind ~loc:vb.pvb_loc ;
              List.iter (walk_param this) params ;
              walk_body this body
          | _ -> super.value_binding this vb ) }
  in
  iter.structure iter structure ;
  let classes =
    let rec scan items =
      List.exists
        (fun (item : Parsetree.structure_item) ->
          match item.pstr_desc with
          | Pstr_class _
           |Pstr_class_type _ ->
              true
          | Pstr_module mb -> (
            match mb.pmb_expr.pmod_desc with
            | Pmod_structure s -> scan s
            | _ -> false )
          | _ -> false )
        items
    in
    scan structure
  in
  (List.rev !spans, classes)

let parse_implementation (path : string) (src : string) =
  let lexbuf = Lexing.from_string src in
  let start = {Lexing.pos_fname= path; pos_lnum= 1; pos_bol= 0; pos_cnum= 0} in
  lexbuf.lex_start_p <- start ;
  lexbuf.lex_curr_p <- start ;
  Parse.implementation lexbuf

let index_sources (project_root : string) (ml_files : string list) :
    span list * Coverage.gap list =
  let spans = ref [] in
  let gaps = ref [] in
  List.iter
    (fun rel ->
      let src = read_file (project_root // rel) in
      match parse_implementation rel src with
      | (exception Syntaxerr.Error _)
       |(exception Parsing.Parse_error) ->
          gaps :=
            { Coverage.code= "COVERAGE-SOURCE-UNPARSED"
            ; message= "In-scope source could not be parsed: " ^ rel
            ; path= rel }
            :: !gaps
      | structure ->
          let found, has_class =
            index_structure rel (provenance rel src) structure
          in
          spans := found @ !spans ;
          if has_class
          then
            gaps :=
              { Coverage.code= "COVERAGE-UNSUPPORTED-CONSTRUCT"
              ; message=
                  "Class and object methods are outside the function index: "
                  ^ rel
              ; path= rel }
              :: !gaps )
    ml_files ;
  (!spans, !gaps)

(* ── dune hook scan ───────────────────────────────────────────────── *)

type stanza_info =
  { dune_path: string
  ; names: string list
  ; hooked: bool
  ; action_preprocess: bool
  ; modules: string list option
  ; directory: string }

let scan_stanzas (project_root : string) (scope : string list) :
    stanza_info list * Coverage.gap list * bool =
  let dune_files =
    files_under project_root scope (fun n -> n = "dune" || n = "dune.inc")
  in
  let gaps = ref [] in
  let stanzas = ref [] in
  List.iter
    (fun rel ->
      let src = read_file (project_root // rel) in
      match parse_sexps src with
      | Error msg ->
          gaps :=
            {Coverage.code= "COVERAGE-SOURCE-UNPARSED"; message= msg; path= rel}
            :: !gaps
      | Ok sexps ->
          let directory = Filename.dirname rel in
          let directory = if directory = "." then "" else directory in
          List.iter
            (function
              | List
                  ( Atom (("library" | "executable" | "executables") as _kind)
                  :: body ) ->
                  if is_ppx_kind body
                  then ()
                  else
                    stanzas :=
                      { dune_path= rel
                      ; names= stanza_names body
                      ; hooked= has_backend body
                      ; action_preprocess= has_action_preprocess body
                      ; modules= module_list body
                      ; directory }
                      :: !stanzas ;
                  if has_action_preprocess body
                  then
                    gaps :=
                      { Coverage.code= "COVERAGE-UNSUPPORTED-PREPROCESS"
                      ; message=
                          "Action preprocessors are not instrumented: " ^ rel
                      ; path= rel }
                      :: !gaps ;
                  if (not (is_ppx_kind body)) && not (has_backend body)
                  then
                    let names =
                      match stanza_names body with
                      | [] -> rel
                      | ns -> String.concat ", " ns
                    in
                    gaps :=
                      { Coverage.code= "COVERAGE-MISSING-HOOK"
                      ; message=
                          "In-scope target lacks backend \
                           szaniec.instrumentation: "
                          ^ names
                      ; path= rel }
                      :: !gaps
              | _ -> () )
            sexps )
    dune_files ;
  let project_src =
    let path = project_root // "dune-project" in
    if Sys.file_exists path then read_file path else ""
  in
  let mlx_dialect =
    match parse_sexps project_src with
    | Error _ -> false
    | Ok sexps ->
        List.exists
          (function
            | List (Atom "dialect" :: body) ->
                List.exists
                  (function
                    | List (Atom "name" :: Atom "mlx" :: _) -> true
                    | List
                        ( Atom "implementation"
                        :: List (Atom "extension" :: Atom "mlx" :: _)
                        :: _ ) ->
                        true
                    | _ -> false )
                  body
            | _ -> false )
          sexps
  in
  let mlx_files =
    files_under project_root scope (fun n -> Filename.check_suffix n ".mlx")
  in
  if mlx_dialect && mlx_files <> []
  then
    List.iter
      (fun rel ->
        gaps :=
          { Coverage.code= "COVERAGE-UNSUPPORTED-DIALECT"
          ; message= "MLX dialect source is not instrumented: " ^ rel
          ; path= rel }
          :: !gaps )
      mlx_files ;
  (!stanzas, !gaps, mlx_files <> [])

let expected_sources (project_root : string) (stanzas : stanza_info list) :
    string list =
  let acc = ref [] in
  List.iter
    (fun stanza ->
      if stanza.hooked
      then
        let present =
          files_under project_root [stanza.directory] (fun n ->
              Filename.check_suffix n ".ml" )
          |> List.filter (fun rel ->
              Filename.dirname rel = stanza.directory
              || (stanza.directory = "" && not (String.contains rel '/')) )
        in
        let present =
          match stanza.modules with
          | None -> present
          | Some names ->
              List.filter
                (fun rel ->
                  let base = Filename.basename rel in
                  let stem =
                    if Filename.check_suffix base ".ml"
                    then Filename.chop_suffix base ".ml"
                    else base
                  in
                  List.mem stem names )
                present
        in
        acc := present @ !acc )
    stanzas ;
  List.sort_uniq compare !acc

(* ── point files ──────────────────────────────────────────────────── *)

let parse_coverage_text (text : string) : (file_points list, string) result =
  let n = String.length text in
  let ident = "BISECT-COVERAGE-4" in
  if not (String.starts_with ~prefix:ident text)
  then Error "point file does not start with the facade point marker"
  else
    let i = ref (String.length ident) in
    let is_space c = c = ' ' || c = '\n' || c = '\r' || c = '\t' in
    let skip_space () =
      while !i < n && is_space text.[!i] do
        incr i
      done
    in
    let read_int () =
      skip_space () ;
      let start = !i in
      if !i < n && text.[!i] = '-' then incr i ;
      while !i < n && text.[!i] >= '0' && text.[!i] <= '9' do
        incr i
      done ;
      if start = !i
      then Error "expected integer"
      else Ok (int_of_string (String.sub text start (!i - start)))
    in
    let read_string () =
      match read_int () with
      | Error _ as e -> e
      | Ok len ->
          if !i < n && text.[!i] = ' ' then incr i ;
          if !i + len > n
          then Error "truncated string"
          else
            let s = String.sub text !i len in
            i := !i + len ;
            Ok s
    in
    let read_ints () =
      match read_int () with
      | Error _ as e -> e
      | Ok count ->
          let rec go k acc =
            if k = 0
            then Ok (Array.of_list (List.rev acc))
            else
              match read_int () with
              | Error _ as e -> e
              | Ok v -> go (k - 1) (v :: acc)
          in
          go count []
    in
    match read_int () with
    | Error _ as e -> e
    | Ok file_count ->
        let rec files k acc =
          if k = 0
          then Ok (List.rev acc)
          else
            match read_string () with
            | Error _ as e -> e
            | Ok path -> (
              match read_ints () with
              | Error _ as e -> e
              | Ok points -> (
                match read_ints () with
                | Error _ as e -> e
                | Ok counts -> files (k - 1) ({path; points; counts} :: acc) ) )
        in
        files file_count []

let parse_coverage_file path = parse_coverage_text (read_file path)

let add_count a b = if a > max_int - b then max_int else a + b

let merge_points (files : file_points list) :
    file_points list * Coverage.gap list =
  let table : (string, file_points) Hashtbl.t = Hashtbl.create 16 in
  let gaps = ref [] in
  List.iter
    (fun (file : file_points) ->
      match Hashtbl.find_opt table file.path with
      | None -> Hashtbl.add table file.path file
      | Some prev ->
          if prev.points <> file.points
          then
            gaps :=
              { Coverage.code= "COVERAGE-INCOMPATIBLE-RECORDS"
              ; message=
                  "Point maps differ for "
                  ^ file.path
                  ^ "; records were not merged"
              ; path= file.path }
              :: !gaps
          else
            let counts =
              Array.mapi (fun i c -> add_count c file.counts.(i)) prev.counts
            in
            Hashtbl.replace table file.path {prev with counts} )
    files ;
  let merged =
    Hashtbl.fold (fun _ (file : file_points) acc -> file :: acc) table []
  in
  let merged =
    List.sort
      (fun (a : file_points) (b : file_points) -> compare a.path b.path)
      merged
  in
  (merged, !gaps)

let strip_build_prefix path =
  let marker = "_build/default/" in
  let marker_len = String.length marker in
  let rec find i =
    if i + marker_len > String.length path
    then path
    else if String.sub path i marker_len = marker
    then String.sub path (i + marker_len) (String.length path - i - marker_len)
    else find (i + 1)
  in
  find 0

let normalize_path ~(project_root : string) ~(dune_root : string) path =
  let path = strip_build_prefix path in
  let path =
    if String.starts_with ~prefix:"./" path
    then String.sub path 2 (String.length path - 2)
    else path
  in
  let strip root p =
    let root = if String.ends_with ~suffix:"/" root then root else root ^ "/" in
    if String.starts_with ~prefix:root p
    then
      Some
        (String.sub
           p
           (String.length root)
           (String.length p - String.length root) )
    else None
  in
  match strip project_root path with
  | Some rel -> rel
  | None -> (
    match strip dune_root path with
    | Some rel -> rel
    | None -> path )

(* ── attribution and CRAP ─────────────────────────────────────────── *)

let crap_score ~complexity ~covered ~total =
  if total <= 0
  then Coverage.Unavailable "coverage-missing"
  else
    let c = float_of_int complexity in
    let un = float_of_int (total - covered) /. float_of_int total in
    let score = (c *. c *. un *. un *. un) +. c in
    Coverage.Available (Printf.sprintf "%.2f" score)

let attribute
    ~(spans : span list)
    ~(measured : file_points list)
    ~(inventory : inventory_entry list) : Coverage.func list * int * int =
  let by_path =
    List.fold_left
      (fun acc (span : span) ->
        let prev =
          try List.assoc span.path acc with
          | Not_found -> []
        in
        (span.path, span :: prev) :: List.remove_assoc span.path acc )
      []
      spans
  in
  let inventory_of path name line =
    List.find_opt
      (fun (e : inventory_entry) ->
        e.path = path && e.name = name && e.line = line )
      inventory
  in
  let funcs = ref [] in
  let covered_total = ref 0 in
  let points_total = ref 0 in
  let measured_paths = List.map (fun (f : file_points) -> f.path) measured in
  let all_paths =
    List.sort_uniq
      compare
      (List.map (fun (s : span) -> s.path) spans @ measured_paths)
  in
  List.iter
    (fun path ->
      let spans =
        try List.assoc path by_path with
        | Not_found -> []
      in
      let file =
        List.find_opt (fun (f : file_points) -> f.path = path) measured
      in
      let buckets = Hashtbl.create 16 in
      List.iter (fun span -> Hashtbl.add buckets span.id (0, 0)) spans ;
      let extra = ref None in
      ( match file with
      | None -> ()
      | Some file ->
          for i = 0 to Array.length file.points - 1 do
            let offset = file.points.(i) in
            let count = file.counts.(i) in
            incr points_total ;
            if count > 0 then incr covered_total ;
            let container =
              List.fold_left
                (fun best span ->
                  if offset >= span.start && offset < span.end_
                  then
                    match best with
                    | None -> Some span
                    | Some prev ->
                        let size s = s.end_ - s.start in
                        if size span < size prev then Some span else best
                  else best )
                None
                spans
            in
            match container with
            | Some span ->
                let c, t = Hashtbl.find buckets span.id in
                Hashtbl.replace
                  buckets
                  span.id
                  ((c + if count > 0 then 1 else 0), t + 1)
            | None ->
                let c, t =
                  match !extra with
                  | None -> (0, 0)
                  | Some v -> v
                in
                extra := Some ((c + if count > 0 then 1 else 0), t + 1)
          done ) ;
      List.iter
        (fun span ->
          let covered, total =
            try Hashtbl.find buckets span.id with
            | Not_found -> (0, 0)
          in
          let measurement =
            if total = 0
            then Coverage.Uninstrumented
            else Coverage.Measured {covered; total; executed= covered > 0}
          in
          let complexity =
            match inventory_of span.path span.name span.line with
            | Some {complexity; _} -> complexity
            | None -> None
          in
          let crap =
            match (complexity, measurement) with
            | Some c, Coverage.Measured m ->
                crap_score ~complexity:c ~covered:m.covered ~total:m.total
            | Some _, Coverage.Uninstrumented ->
                Coverage.Unavailable "coverage-missing"
            | None, _ -> Coverage.Unavailable "complexity-missing"
          in
          funcs :=
            { Coverage.id= span.id
            ; path= span.path
            ; name= span.name
            ; kind= span.kind
            ; provenance= span.provenance
            ; line= span.line
            ; col= span.col
            ; measurement
            ; complexity
            ; crap }
            :: !funcs )
        spans ;
      match !extra with
      | None -> ()
      | Some (covered, total) ->
          funcs :=
            { Coverage.id= path ^ ":toplevel:<toplevel>:1:0"
            ; path
            ; name= "<toplevel>"
            ; kind= Coverage.Toplevel
            ; provenance= "authored"
            ; line= 1
            ; col= 0
            ; measurement=
                Coverage.Measured {covered; total; executed= covered > 0}
            ; complexity= None
            ; crap= Coverage.Unavailable "complexity-missing" }
            :: !funcs )
    all_paths ;
  let funcs =
    List.sort
      (fun (a : Coverage.func) (b : Coverage.func) ->
        compare a.Coverage.id b.Coverage.id )
      !funcs
  in
  (funcs, !covered_total, !points_total)

let load_inventory (path : string) : (inventory_entry list, Coverage.gap) result
    =
  match Yojson.Safe.from_file path with
  | exception _ ->
      Error
        { Coverage.code= "COVERAGE-INVENTORY-INVALID"
        ; message= "Function inventory is not readable JSON: " ^ path
        ; path }
  | `Assoc fields -> (
      let format =
        match List.assoc_opt "format" fields with
        | Some (`String s) -> s
        | _ -> ""
      in
      if format <> Version.functions_format
      then
        Error
          { Coverage.code= "COVERAGE-INVENTORY-INVALID"
          ; message=
              "Function inventory format must be " ^ Version.functions_format
          ; path }
      else
        match List.assoc_opt "functions" fields with
        | Some (`List items) ->
            let entries =
              List.filter_map
                (function
                  | `Assoc f -> (
                      let str k =
                        match List.assoc_opt k f with
                        | Some (`String s) -> Some s
                        | _ -> None
                      in
                      let line =
                        match List.assoc_opt "line" f with
                        | Some (`Int n) -> n
                        | _ -> 0
                      in
                      let complexity =
                        match List.assoc_opt "complexity" f with
                        | Some (`Int n) -> Some n
                        | _ -> None
                      in
                      match (str "path", str "name") with
                      | Some p, Some name ->
                          Some {path= p; name; line; complexity}
                      | _ -> None )
                  | _ -> None )
                items
            in
            Ok entries
        | _ ->
            Error
              { Coverage.code= "COVERAGE-INVENTORY-INVALID"
              ; message= "Function inventory has no functions array"
              ; path } )
  | _ ->
      Error
        { Coverage.code= "COVERAGE-INVENTORY-INVALID"
        ; message= "Function inventory must be a JSON object"
        ; path }

let count_probe_visits (dir : string) : int =
  if not (Sys.file_exists dir)
  then 0
  else
    let acc = ref 0 in
    let files = Sys.readdir dir in
    Array.iter
      (fun name ->
        if Filename.check_suffix name ".visits"
        then
          let ic = open_in (dir // name) in
          try
            while true do
              let _ = input_line ic in
              incr acc
            done
          with
          | End_of_file -> close_in ic )
      files ;
    !acc
