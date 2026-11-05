open Szaniec_model

(* Build configuration evidence per Dune file: the file's own digest, the
   identities of its declared dependencies and run commands, and whether all
   of them were available. A receipt covers only the Dune files that govern
   its unit (see [governing_files]), not every project input. *)
type dune_file =
  { file_identity: string list
  ; file_available: bool }

type t =
  { root: string
  ; files: (string, dune_file) Hashtbl.t
  ; unavailable: string list
  ; digests: (string, string) Hashtbl.t }

let hash text = Digestif.SHA256.to_hex (Digestif.SHA256.digest_string text)

let rec digest path =
  try
    if Sys.is_directory path
    then
      Sys.readdir path
      |> Array.to_list
      |> List.sort compare
      |> List.map (fun name -> name ^ ":" ^ digest (Filename.concat path name))
      |> String.concat "\n"
      |> hash
    else Digest.to_hex (Digest.file path)
  with
  | Sys_error _ -> "missing"

let executable_on_path name =
  String.split_on_char ':' (Option.value ~default:"" (Sys.getenv_opt "PATH"))
  |> List.find_map (fun dir ->
      let path = Filename.concat dir name in
      if Sys.file_exists path then Some path else None )

let dune_tokens file =
  let input = open_in file in
  let text =
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () -> really_input_string input (in_channel_length input))
  in
  let tokenized = Buffer.create (String.length text) in
  let comment = ref false in
  String.iter
    (function
      | '\n' ->
          comment := false ;
          Buffer.add_char tokenized ' '
      | ';' -> comment := true
      | _ when !comment -> ()
      | '(' -> Buffer.add_string tokenized " ( "
      | ')' -> Buffer.add_string tokenized " ) "
      | '\t'
       |'\r'
       |'"' ->
          Buffer.add_char tokenized ' '
      | ch -> Buffer.add_char tokenized ch )
    text ;
  Buffer.contents tokenized
  |> String.split_on_char ' '
  |> List.filter (( <> ) "")

let dune_commands file =
  let tokens = dune_tokens file in
  let rec commands = function
    | "(" :: "run" :: executable :: rest -> executable :: commands rest
    | _ :: rest -> commands rest
    | [] -> []
  in
  commands tokens

let dune_dependencies tokens =
  let rec inside depth = function
    | [] -> []
    | ")" :: _ when depth = 0 -> []
    | "(" :: "universe" :: ")" :: rest -> inside depth rest
    | "(" :: ("alias" | "alias_rec") :: _ :: ")" :: rest -> inside depth rest
    | "(" :: ("file" | "source_tree") :: path :: ")" :: rest ->
        path :: inside depth rest
    | "(" :: rest -> inside (depth + 1) rest
    | ")" :: rest -> inside (depth - 1) rest
    | token :: rest ->
        let rest = inside depth rest in
        if
          String.starts_with ~prefix:":" token
          || String.starts_with ~prefix:"%{" token
             && not (String.starts_with ~prefix:"%{workspace_root}" token)
        then rest
        else token :: rest
  in
  let rec collect = function
    | "(" :: ("deps" | "preprocessor_deps") :: rest ->
        inside 0 rest @ collect rest
    | _ :: rest -> collect rest
    | [] -> []
  in
  collect tokens

let expand_workspace ~root value =
  let prefix = "%{workspace_root}" in
  if String.starts_with ~prefix value
  then
    root
    ^ String.sub
        value
        (String.length prefix)
        (String.length value - String.length prefix)
  else value

type dune_token =
  | Open
  | Close
  | Word of string
  | Datum_comment

(* A Dune s-expression lexer: quoted strings may contain parentheses and
   semicolons, and line, block and datum comments are dropped. *)
let dune_lex text =
  let n = String.length text in
  let tokens = ref [] in
  let i = ref 0 in
  let at offset ch = !i + offset < n && text.[!i + offset] = ch in
  while !i < n do
    match text.[!i] with
    | '(' ->
        tokens := Open :: !tokens ;
        incr i
    | ')' ->
        tokens := Close :: !tokens ;
        incr i
    | ' '
     |'\t'
     |'\n'
     |'\r' ->
        incr i
    | ';' ->
        while !i < n && text.[!i] <> '\n' do
          incr i
        done
    | '#' when at 1 '|' ->
        let depth = ref 1 in
        i := !i + 2 ;
        while !i < n && !depth > 0 do
          if at 0 '|' && at 1 '#'
          then (
            decr depth ;
            i := !i + 2 )
          else if at 0 '#' && at 1 '|'
          then (
            incr depth ;
            i := !i + 2 )
          else incr i
        done
    | '#' when at 1 ';' ->
        tokens := Datum_comment :: !tokens ;
        i := !i + 2
    | '"' ->
        let buffer = Buffer.create 16 in
        incr i ;
        while !i < n && text.[!i] <> '"' do
          if text.[!i] = '\\' && !i + 1 < n
          then (
            Buffer.add_char buffer text.[!i + 1] ;
            i := !i + 2 )
          else (
            Buffer.add_char buffer text.[!i] ;
            incr i )
        done ;
        incr i ;
        tokens := Word (Buffer.contents buffer) :: !tokens
    | _ ->
        let start = !i in
        while !i < n && not (String.contains "() \t\n\r;\"" text.[!i]) do
          incr i
        done ;
        tokens := Word (String.sub text start (!i - start)) :: !tokens
  done ;
  List.rev !tokens

type dune_form =
  | Atom of string
  | Form of dune_form list

let dune_forms text =
  let rec items acc = function
    | [] -> (List.rev acc, [])
    | Close :: rest -> (List.rev acc, rest)
    | Open :: rest ->
        let inner, rest = items [] rest in
        items (Form inner :: acc) rest
    | Word word :: rest -> items (Atom word :: acc) rest
    | Datum_comment :: rest -> items acc (skip rest)
  and skip = function
    | Open :: rest -> snd (items [] rest)
    | Word _ :: rest -> rest
    | Datum_comment :: rest -> skip (skip rest)
    | (Close :: _ | []) as rest -> rest
  in
  fst (items [] (dune_lex text))

let read_text file =
  let input = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

(* PPX rewriters that Dune runs through [(preprocess (pps ...))] or
   [staged_pps] are ordinary build dependencies: Dune reruns them when the
   rewriter, its [preprocessor_deps] or the source change. Their output is
   therefore trusted like any other Dune target and needs no receipt. Keys
   are object directories ([dir/.name.objs], [dir/.name.eobjs]). Action
   preprocessors, per-module specifications, dialects such as MLX and
   compiler flags ([-pp], [-ppx]) are not covered and keep receipts. *)
let dune_rewriter_object_dirs ~root inputs =
  let dirs = Hashtbl.create 16 in
  List.iter
    (fun file ->
      if Filename.basename file = "dune"
      then
        try
          let directory = Filename.dirname file in
          let prefix = if directory = "." then "" else directory ^ "/" in
          List.iter
            (function
              | Form (Atom kind :: fields) -> (
                  let field name =
                    List.find_map
                      (function
                        | Form (Atom key :: values) when key = name ->
                            Some values
                        | _ -> None )
                      fields
                  in
                  let rewritten =
                    match field "preprocess" with
                    | Some [Form (Atom ("pps" | "staged_pps") :: _)] -> true
                    | _ -> false
                  in
                  let names =
                    List.concat_map
                      (fun key ->
                        Option.value ~default:[] (field key)
                        |> List.filter_map (function
                          | Atom name -> Some name
                          | Form _ -> None ) )
                      ["name"; "names"]
                  in
                  let suffix =
                    match kind with
                    | "library" -> Some ".objs"
                    | "executable"
                     |"executables"
                     |"test"
                     |"tests" ->
                        Some ".eobjs"
                    | _ -> None
                  in
                  match suffix with
                  | Some suffix when rewritten ->
                      List.iter
                        (fun name ->
                          Hashtbl.replace dirs (prefix ^ "." ^ name ^ suffix) () )
                        names
                  | _ -> () )
              | _ -> () )
            (dune_forms (read_text (Filename.concat root file)))
        with
        | Sys_error _ -> () )
    inputs ;
  dirs

(* Build-only OCaml inputs need an authored generator declaration. Merely
   finding a file under _build must not admit an unowned or stale source. *)
let generated_source ~root relative =
  let dune =
    Filename.concat root (Filename.concat (Filename.dirname relative) "dune")
  in
  let target = Filename.basename relative in
  let rec declared = function
    | "(" :: ("target" | "targets") :: rest ->
        let rec names = function
          | []
           |")" :: _ ->
              false
          | name :: rest -> name = target || names rest
        in
        names rest || declared rest
    | _ :: rest -> declared rest
    | [] -> false
  in
  try
    let generated =
      Filename.concat root (Filename.concat "_build/default" relative)
    in
    if declared (dune_tokens dune) && Sys.file_exists generated
    then Some generated
    else None
  with
  | Sys_error _ -> None

let create ~root ~inputs =
  (* Several Dune rules name the same generator or dependency. Hash each
     path once while assembling this snapshot, rather than once per rule. *)
  let digests = Hashtbl.create 64 in
  let digest path =
    match Hashtbl.find_opt digests path with
    | Some identity -> identity
    | None ->
        let identity = digest path in
        Hashtbl.add digests path identity ;
        identity
  in
  let dependencies file =
    let tokens = dune_tokens (Filename.concat root file) in
    let explicit =
      dune_dependencies tokens
      |> List.map (fun dependency ->
          let relative =
            let dependency = expand_workspace ~root dependency in
            if Filename.is_relative dependency
            then Filename.concat (Filename.dirname file) dependency
            else dependency
          in
          let source =
            if Filename.is_relative relative
            then Filename.concat root relative
            else relative
          in
          let path =
            if Sys.file_exists source
            then source
            else
              Filename.concat (Filename.concat root "_build/default") relative
          in
          path ^ ":" ^ digest path )
    in
    explicit
    @ ( tokens
      |> List.filter_map (fun token ->
          List.find_map
            (fun prefix ->
              if
                String.starts_with ~prefix token
                && String.ends_with ~suffix:"}" token
              then
                let value =
                  String.sub
                    token
                    (String.length prefix)
                    (String.length token - String.length prefix - 1)
                in
                let path =
                  Filename.concat
                    root
                    (Filename.concat (Filename.dirname file) value)
                in
                let path =
                  if Sys.file_exists path
                  then path
                  else
                    Filename.concat
                      (Filename.concat root "_build/default")
                      (Filename.concat (Filename.dirname file) value)
                in
                Some (path ^ ":" ^ digest path)
              else None )
            ["%{dep:"; "%{read:"; "%{read-lines:"; "%{read-strings:"] ) )
  in
  let commands file =
    dune_commands (Filename.concat root file)
    |> List.map (fun command ->
        let command =
          if
            String.starts_with ~prefix:"%{bin:" command
            && String.ends_with ~suffix:"}" command
          then String.sub command 6 (String.length command - 7)
          else expand_workspace ~root command
        in
        let executable =
          if not (Filename.is_relative command)
          then Some command
          else if String.contains command '/'
          then
            let build =
              Filename.concat
                (Filename.concat root "_build/default")
                (Filename.concat (Filename.dirname file) command)
            in
            if Sys.file_exists build
            then Some build
            else
              Some
                (Filename.concat
                   root
                   (Filename.concat (Filename.dirname file) command) )
          else executable_on_path command
        in
        match executable with
        | Some path when Sys.file_exists path -> command ^ ":" ^ digest path
        | _ -> command ^ ":unavailable" )
  in
  let missing identity =
    String.ends_with ~suffix:":missing" identity
    || String.ends_with ~suffix:":unavailable" identity
  in
  let files = Hashtbl.create 64 in
  List.iter
    (fun file ->
      if
        List.mem
          (Filename.basename file)
          ["dune"; "dune-project"; "dune-workspace"]
      then
        let identity =
          try
            (file ^ ":" ^ digest (Filename.concat root file))
            :: dependencies file
            @ commands file
            |> List.sort_uniq compare
          with
          | Sys_error _ -> [file ^ ":unavailable"]
        in
        Hashtbl.replace
          files
          file
          { file_identity= identity
          ; file_available= not (List.exists missing identity) } )
    inputs ;
  { root
  ; files
  ; unavailable=
      Hashtbl.fold
        (fun _ file acc -> List.filter missing file.file_identity @ acc)
        files
        []
      |> List.sort_uniq compare
  ; digests= Hashtbl.create 16 }

(* The Dune files that can change how a source is transformed: the project
   and workspace files (dialects such as MLX) and every [dune] file from the
   source directory up to the root (stanzas apply to subdirectories through
   [include_subdirs]). Edits elsewhere in the project do not invalidate the
   receipt; imported interfaces are checked separately by the adapter. *)
let governing_files t source =
  let relative =
    List.find_map
      (fun prefix ->
        if String.starts_with ~prefix source
        then
          Some
            (String.sub
               source
               (String.length prefix)
               (String.length source - String.length prefix) )
        else None )
      [Filename.concat t.root "_build/default/"; t.root ^ "/"]
    |> Option.value ~default:source
  in
  let rec ancestors directory =
    let file = if directory = "." then "dune" else directory ^ "/dune" in
    let parent = Filename.dirname directory in
    file :: (if parent = directory then [] else ancestors parent)
  in
  "dune-project" :: "dune-workspace" :: ancestors (Filename.dirname relative)
  |> List.filter_map (Hashtbl.find_opt t.files)

let path t (cmt : Cmt_format.cmt_infos) input =
  if Filename.is_relative input
  then Filename.concat (Filename.concat t.root "_build/default") input
  else if Sys.file_exists input
  then input
  else
    let prefix = cmt.cmt_builddir ^ "/" in
    if Canonical.starts_with ~prefix input
    then
      Filename.concat
        (Filename.concat t.root "_build/default")
        (String.sub
           input
           (String.length prefix)
           (String.length input - String.length prefix) )
    else input

let identity t ~source cmt artifact =
  let tools = ref [] in
  let available = ref true in
  let tool_identity executable =
    match Hashtbl.find_opt t.digests executable with
    | Some identity -> identity
    | None ->
        let identity = digest executable in
        Hashtbl.replace t.digests executable identity ;
        identity
  in
  if Array.length cmt.Cmt_format.cmt_args > 0
  then (
    let compiler = path t cmt cmt.cmt_args.(0) in
    let identity = tool_identity compiler in
    if identity = "missing" then available := false ;
    tools := ("compiler:" ^ identity) :: !tools ) ;
  Array.iteri
    (fun i arg ->
      if
        (arg = "-pp" || arg = "-ppx")
        && i + 1 < Array.length cmt.Cmt_format.cmt_args
      then (
        let command = cmt.cmt_args.(i + 1) in
        let executable = String.split_on_char ' ' command |> List.hd in
        let executable =
          if String.contains executable '/'
          then path t cmt executable
          else
            String.split_on_char
              ':'
              (Option.value ~default:"" (Sys.getenv_opt "PATH"))
            |> List.find_map (fun dir ->
                let p = Filename.concat dir executable in
                if Sys.file_exists p then Some p else None )
            |> Option.value ~default:executable
        in
        if not (Sys.file_exists executable) then available := false ;
        let identity = tool_identity executable in
        if identity = "missing" then available := false ;
        tools := (command ^ ":" ^ identity) :: !tools ) )
    cmt.cmt_args ;
  let input = Option.map (path t cmt) cmt.cmt_sourcefile in
  let governing = governing_files t source in
  (* The receipt certifies the transformation, not the compilation: the
     artifact only has to be compiled from the receipted input. A recompile
     caused by a changed imported interface keeps the receipt valid. Dune PPX
     drivers under [_build/default/.ppx] are Dune targets whose bytes need not
     be reproducible across builds; Dune reruns a rewrite when its driver
     changes, and the rewritten input digest is part of the identity. Tools
     Dune does not track (dialect commands, compiler [-pp]/[-ppx]) stay. *)
  ignore artifact ;
  if
    (not !available)
    || List.exists (fun file -> not file.file_available) governing
    ||
    match input with
    | Some input when Sys.file_exists input ->
        Some (Digest.file input) <> cmt.cmt_source_digest
    | _ -> true
  then None
  else
    Some
      (hash
         (String.concat
            "\n"
            ( [ Version.adapter_ocaml
              ; t.root
              ; source
              ; digest source
              ; Option.fold ~none:"missing" ~some:digest input
              ; String.concat "\n" (Array.to_list cmt.cmt_args)
              ; String.concat "\n" (List.rev !tools) ]
            @ List.concat_map (fun file -> file.file_identity) governing ) ) )

(* Dune deletes files it did not produce from its build directories on every
   build, so a receipt beside its artifact would not survive an ordinary
   external build. Receipts live in [_build/.szaniec-provenance], which Dune
   does not manage, named by the artifact path below [_build/default]. *)
let receipt_directory = "_build/.szaniec-provenance"

let receipt_path artifact =
  let marker = "/_build/default/" in
  let length = String.length artifact in
  let rec find index =
    if index + String.length marker > length
    then None
    else if String.sub artifact index (String.length marker) = marker
    then Some index
    else find (index + 1)
  in
  Option.map
    (fun index ->
      let start = index + String.length marker in
      Filename.concat
        (Filename.concat (String.sub artifact 0 index) receipt_directory)
        (hash (String.sub artifact start (length - start))) )
    (find 0)

let read_receipt artifact read =
  match receipt_path artifact with
  | None -> None
  | Some receipt -> (
    try
      let input = open_in receipt in
      Fun.protect
        ~finally:(fun () -> close_in_noerr input)
        (fun () -> Some (read input))
    with
    | Sys_error _
     |End_of_file ->
        None )

let current t ~source cmt artifact =
  match identity t ~source cmt artifact with
  | None -> false
  | Some expected -> read_receipt artifact input_line = Some expected

let source_changed ~source artifact =
  read_receipt artifact (fun input ->
      ignore (input_line input) ;
      let old_source = input_line input in
      let old_artifact = input_line input in
      old_artifact = digest artifact && old_source <> digest source )
  = Some true

let record t ~source cmt artifact =
  match (identity t ~source cmt artifact, receipt_path artifact) with
  | None, _
   |_, None ->
      ()
  | Some identity, Some receipt -> (
    try
      ( try Unix.mkdir (Filename.dirname receipt) 0o700 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
      let temporary, output =
        Filename.open_temp_file
          ~temp_dir:(Filename.dirname receipt)
          ".szaniec-proof-"
          ".tmp"
      in
      Fun.protect
        ~finally:(fun () ->
          close_out_noerr output ;
          if Sys.file_exists temporary then Sys.remove temporary )
        (fun () ->
          output_string
            output
            (identity ^ "\n" ^ digest source ^ "\n" ^ digest artifact ^ "\n") ;
          close_out output ;
          Unix.rename temporary receipt )
    with
    | Sys_error _
     |Unix.Unix_error _ ->
        () )
