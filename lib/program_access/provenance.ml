open Szaniec_model

type t =
  { root: string
  ; inputs: string
  ; tools: string
  ; tools_available: bool
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
  let tools_available = ref true in
  let dependencies =
    List.filter
      (fun file ->
        List.mem
          (Filename.basename file)
          ["dune"; "dune-project"; "dune-workspace"] )
      inputs
    |> List.concat_map (fun file ->
        try
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
                    Filename.concat
                      (Filename.concat root "_build/default")
                      relative
                in
                let identity = digest path in
                if identity = "missing" then tools_available := false ;
                path ^ ":" ^ identity )
          in
          explicit
          @ ( tokens
            |> List.filter_map (fun token ->
                List.find_map
                  (fun prefix ->
                    if
                      String.starts_with ~prefix token
                      && String.ends_with ~suffix:"}" token
                    then (
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
                      let identity = digest path in
                      if identity = "missing" then tools_available := false ;
                      Some (path ^ ":" ^ identity) )
                    else None )
                  ["%{dep:"; "%{read:"; "%{read-lines:"; "%{read-strings:"] ) )
        with
        | Sys_error _ ->
            tools_available := false ;
            [file ^ ":unavailable"] )
    |> List.sort_uniq compare
  in
  let rec ppx_tools directory =
    try
      Array.to_list (Sys.readdir directory)
      |> List.sort compare
      |> List.concat_map (fun name ->
          let path = Filename.concat directory name in
          if Sys.is_directory path
          then ppx_tools path
          else if
            List.exists
              (Filename.check_suffix name)
              [".exe"; ".bc"; ".cmxs"; ".so"]
          then [path ^ ":" ^ digest path]
          else [] )
    with
    | Sys_error _ -> []
  in
  let tools =
    List.filter
      (fun file ->
        List.mem
          (Filename.basename file)
          ["dune"; "dune-project"; "dune-workspace"] )
      inputs
    |> List.concat_map (fun file ->
        try
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
              | Some path when Sys.file_exists path ->
                  let identity = digest path in
                  if identity = "missing" then tools_available := false ;
                  command ^ ":" ^ identity
              | _ ->
                  tools_available := false ;
                  command ^ ":unavailable" )
        with
        | Sys_error _ ->
            tools_available := false ;
            [file ^ ":unavailable"] )
    |> List.sort_uniq compare
  in
  { root
  ; unavailable=
      List.filter
        (fun identity ->
          String.ends_with ~suffix:":missing" identity
          || String.ends_with ~suffix:":unavailable" identity )
        (dependencies @ tools)
  ; tools=
      String.concat
        "\n"
        (tools @ ppx_tools (Filename.concat root "_build/default/.ppx"))
  ; tools_available= !tools_available
  ; digests= Hashtbl.create 16
  ; inputs=
      hash
        (String.concat
           "\n"
           ( dependencies
           @ List.map
               (fun p -> p ^ ":" ^ digest (Filename.concat root p))
               inputs ) ) }

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
  if
    (not !available)
    || (not t.tools_available)
    || Option.fold ~none:true ~some:(fun p -> not (Sys.file_exists p)) input
  then None
  else
    Some
      (hash
         (String.concat
            "\n"
            [ Version.adapter_ocaml
            ; t.root
            ; t.inputs
            ; t.tools
            ; source
            ; digest source
            ; artifact
            ; digest artifact
            ; Option.fold ~none:"missing" ~some:digest input
            ; String.concat "\n" (Array.to_list cmt.cmt_args)
            ; String.concat "\n" (List.rev !tools) ] ) )

let current t ~source cmt artifact =
  let receipt = artifact ^ ".szaniec-provenance" in
  match identity t ~source cmt artifact with
  | None -> false
  | Some expected -> (
    try
      let input = open_in receipt in
      Fun.protect
        ~finally:(fun () -> close_in_noerr input)
        (fun () -> input_line input = expected)
    with
    | Sys_error _
     |End_of_file ->
        false )

let source_changed ~source artifact =
  try
    let input = open_in (artifact ^ ".szaniec-provenance") in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
        ignore (input_line input) ;
        let old_source = input_line input in
        let old_artifact = input_line input in
        old_artifact = digest artifact && old_source <> digest source )
  with
  | Sys_error _
   |End_of_file ->
      false

let record t ~source cmt artifact =
  match identity t ~source cmt artifact with
  | None -> ()
  | Some identity -> (
    try
      let temporary, output =
        Filename.open_temp_file
          ~temp_dir:(Filename.dirname artifact)
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
          Unix.rename temporary (artifact ^ ".szaniec-provenance") )
    with
    | Sys_error _
     |Unix.Unix_error _ ->
        () )
