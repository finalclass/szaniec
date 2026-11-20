open Szaniec_model

type error =
  { error_at: Structure.position
  ; error_message: string }

exception Failed of error

let ( // ) a b = if a = "" then b else Filename.concat a b

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let git_output root arguments =
  match
    Unix.open_process_args_full
      "git"
      (Array.of_list ("git" :: "-C" :: root :: arguments))
      (Unix.environment ())
  with
  | exception Unix.Unix_error _ -> None
  | (out, input, err) as process -> (
      close_out input ;
      let text = In_channel.input_all out in
      ignore (In_channel.input_all err) ;
      match Unix.close_process_full process with
      | Unix.WEXITED 0 -> Some text
      | _ -> None )

let git_listed_files root =
  match git_output root ["rev-parse"; "--is-inside-work-tree"] with
  | Some answer when String.trim answer = "true" -> (
    match
      git_output
        root
        ["ls-files"; "-z"; "--cached"; "--others"; "--exclude-standard"]
    with
    | Some listing ->
        Some (String.split_on_char '\000' listing |> List.filter (( <> ) ""))
    | None ->
        raise
          (Failed
             { error_at= {path= "."; line= 1; col= 1}
             ; error_message= "cannot list the files of the git work tree" } ) )
  | _ -> None

let directory_files root directories =
  List.concat_map
    (fun dir ->
      ( try Sys.readdir (root // dir) |> Array.to_list with
        | Sys_error _ -> [] )
      |> List.map (fun entry -> dir // entry) )
    directories

let candidate_files ~root ~directories =
  let files =
    match git_listed_files root with
    | Some listed ->
        let walked = Hashtbl.create 256 in
        List.iter (fun dir -> Hashtbl.replace walked dir ()) directories ;
        List.filter
          (fun rel ->
            let dir = Filename.dirname rel in
            Hashtbl.mem walked (if dir = "." then "" else dir) )
          listed
    | None -> directory_files root directories
  in
  List.sort_uniq compare files
  |> List.filter (fun rel ->
      let path = root // rel in
      Sys.file_exists path && not (Sys.is_directory path) )

let extension_languages =
  [ (".ml", ("OCaml", Comment_lexer.Ocaml))
  ; (".mli", ("OCaml", Comment_lexer.Ocaml))
  ; (".mlx", ("OCaml", Comment_lexer.Ocaml))
  ; (".ts", ("TypeScript", Comment_lexer.Script {templates= true; regex= true}))
  ; (".tsx", ("TypeScript", Comment_lexer.Script {templates= true; regex= true}))
  ; (".mts", ("TypeScript", Comment_lexer.Script {templates= true; regex= true}))
  ; (".cts", ("TypeScript", Comment_lexer.Script {templates= true; regex= true}))
  ; (".js", ("JavaScript", Comment_lexer.Script {templates= true; regex= true}))
  ; (".jsx", ("JavaScript", Comment_lexer.Script {templates= true; regex= true}))
  ; (".mjs", ("JavaScript", Comment_lexer.Script {templates= true; regex= true}))
  ; (".cjs", ("JavaScript", Comment_lexer.Script {templates= true; regex= true}))
  ; (".c", ("C", Comment_lexer.Script {templates= false; regex= false}))
  ; (".h", ("C", Comment_lexer.Script {templates= false; regex= false}))
  ; (".css", ("CSS", Comment_lexer.Css))
  ; (".sh", ("shell", Comment_lexer.Shell))
  ; (".bash", ("shell", Comment_lexer.Shell))
  ; (".ps1", ("PowerShell", Comment_lexer.Powershell))
  ; (".psm1", ("PowerShell", Comment_lexer.Powershell))
  ; (".psd1", ("PowerShell", Comment_lexer.Powershell))
  ; (".bas", ("VBA", Comment_lexer.Basic))
  ; (".cls", ("VBA", Comment_lexer.Basic))
  ; (".frm", ("VBA", Comment_lexer.Basic))
  ; (".pq", ("Power Query M", Comment_lexer.Power_query))
  ; (".pqm", ("Power Query M", Comment_lexer.Power_query))
  ; (".cmd", ("batch", Comment_lexer.Batch))
  ; (".bat", ("batch", Comment_lexer.Batch)) ]

let interpreter_languages =
  [ ("sh", ("shell", Comment_lexer.Shell))
  ; ("bash", ("shell", Comment_lexer.Shell))
  ; ("dash", ("shell", Comment_lexer.Shell))
  ; ("zsh", ("shell", Comment_lexer.Shell))
  ; ("ksh", ("shell", Comment_lexer.Shell))
  ; ("deno", ("TypeScript", Comment_lexer.Script {templates= true; regex= true}))
  ; ("bun", ("TypeScript", Comment_lexer.Script {templates= true; regex= true}))
  ; ("node", ("JavaScript", Comment_lexer.Script {templates= true; regex= true}))
  ; ("pwsh", ("PowerShell", Comment_lexer.Powershell)) ]

let interpreter_of_shebang text =
  let line = String.sub text 2 (Comment_lexer.line_end text 0 - 2) in
  let words =
    String.split_on_char ' ' line
    |> List.concat_map (String.split_on_char '\t')
    |> List.filter (( <> ) "")
  in
  let program = function
    | first :: rest when Filename.basename first = "env" ->
        List.find_opt (fun w -> not (String.starts_with ~prefix:"-" w)) rest
    | first :: _ -> Some first
    | [] -> None
  in
  Option.map Filename.basename (program words)

let language_of rel text =
  let extension = String.lowercase_ascii (Filename.extension rel) in
  match List.assoc_opt extension extension_languages with
  | Some language -> Some language
  | None when extension = "" && String.starts_with ~prefix:"#!" text -> (
      let interpreter = interpreter_of_shebang text in
      match
        Option.bind interpreter (fun i ->
            List.assoc_opt i interpreter_languages )
      with
      | Some language -> Some language
      | None ->
          raise
            (Failed
               { error_at= {path= rel; line= 1; col= 1}
               ; error_message=
                   "cannot check comments of a script run by "
                   ^ Option.value ~default:"an unnamed interpreter" interpreter
               } ) )
  | None -> None

let line_starts text =
  let starts = ref [0] in
  String.iteri (fun i c -> if c = '\n' then starts := (i + 1) :: !starts) text ;
  Array.of_list (List.rev !starts)

let position_of starts rel offset : Structure.position =
  let rec search low high =
    if low >= high
    then low
    else
      let middle = (low + high + 1) / 2 in
      if starts.(middle) <= offset
      then search middle high
      else search low (middle - 1)
  in
  let index = search 0 (Array.length starts - 1) in
  {path= rel; line= index + 1; col= offset - starts.(index) + 1}

let comment_kind = function
  | Comment_lexer.Line -> Structure.Line_comment
  | Comment_lexer.Block -> Structure.Block_comment
  | Comment_lexer.Documentation -> Structure.Documentation_comment
  | Comment_lexer.Shebang -> Structure.Shebang

let file_comments root rel =
  let text = read_file (root // rel) in
  match language_of rel text with
  | None -> []
  | Some (language, syntax) -> (
      let starts = line_starts text in
      match Comment_lexer.spans syntax text with
      | spans ->
          List.map
            (fun (span : Comment_lexer.span) ->
              { Structure.comment_language= language
              ; comment_kind= comment_kind span.kind
              ; comment_at= position_of starts rel span.start
              ; comment_end= position_of starts rel span.stop } )
            spans
      | exception Comment_lexer.Malformed (offset, message) ->
          raise
            (Failed
               { error_at= position_of starts rel offset
               ; error_message=
                   Printf.sprintf "cannot read %s source: %s" language message
               } ) )

let comments ~(root : string) ~(directories : string list) :
    (Structure.comment list, error) result =
  try
    Ok
      (List.concat_map
         (file_comments root)
         (candidate_files ~root ~directories) )
  with
  | Failed e -> Error e
  | Sys_error message ->
      Error {error_at= {path= "."; line= 1; col= 1}; error_message= message}
