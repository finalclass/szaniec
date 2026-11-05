(* CheckClient: command line, rendering and exit status mapping. *)

module Inspection = Szaniec_inspection_manager.Inspection_manager

let usage =
  "Szaniec: protects an IDesign architecture expressed as dune libraries, and \
   measures OCaml Cognitive Complexity.\n\n\
   usage:\n\
  \ szaniec --help | -h\n\
  \   Show this help.\n\n\
  \ szaniec check [<dir> | --project-root <dir>] [--json]\n\
  \   Check that dune files declare only dependencies allowed by IDesign rules.\n\
  \   No build and no configuration file. Exit 0 conforming, 1 violations, 2 \
   error.\n\n\
  \ szaniec complexity [--project-root <dir>] [--rebuild] [--build <command>]\n\
  \                    [--root <dir>]... [--json] [--sort location|complexity]\n\
  \                    [--metric cognitive|cyclomatic]\n\
  \   List functions and their Cognitive Complexity (default) or cyclomatic \
   complexity\n\
  \   from current compiler artifacts. --rebuild runs --build (default \"dune \
   build\")\n\
  \   through the shell first. --root defaults to lib. Exit 0 complete, 2 \
   incomplete."

let die message =
  prerr_endline ("szaniec: " ^ message) ;
  prerr_endline "Run szaniec --help for usage." ;
  exit 2

let absolute dir =
  if not (Sys.file_exists dir && Sys.is_directory dir)
  then die ("not a directory: " ^ dir) ;
  try Unix.realpath dir with
  | Unix.Unix_error _ -> die ("cannot resolve directory: " ^ dir)

let run_check args =
  let rec parse dir json = function
    | [] -> (dir, json)
    | "--json" :: rest -> parse dir true rest
    | "--project-root" :: d :: rest when dir = None -> parse (Some d) json rest
    | ("-h" | "--help") :: _ ->
        print_endline usage ;
        exit 0
    | d :: rest when dir = None && not (String.starts_with ~prefix:"-" d) ->
        parse (Some d) json rest
    | arg :: _ -> die ("unexpected check argument: " ^ arg)
  in
  let dir, json = parse None false args in
  let root = absolute (Option.value ~default:"." dir) in
  match Inspection.check ~project_root:root with
  | Error {error_at; error_message} ->
      ( match error_at with
      | Some p ->
          Printf.eprintf
            "szaniec: %s:%d:%d: %s\n"
            p.Szaniec_model.Structure.path
            p.line
            p.col
            error_message
      | None -> Printf.eprintf "szaniec: %s\n" error_message ) ;
      exit 2
  | Ok report ->
      print_string
        (if json then Check_render.json report else Check_render.text report) ;
      exit (if report.findings = [] then 0 else 1)

type complexity_args =
  { project: string option
  ; rebuild: bool
  ; build: string option
  ; roots: string list
  ; json: bool
  ; sort: string
  ; metric: string }

let run_complexity args =
  let rec parse a = function
    | [] -> a
    | "--json" :: rest -> parse {a with json= true} rest
    | "--rebuild" :: rest -> parse {a with rebuild= true} rest
    | "--project-root" :: d :: rest -> parse {a with project= Some d} rest
    | "--build" :: c :: rest -> parse {a with build= Some c} rest
    | "--root" :: r :: rest -> parse {a with roots= a.roots @ [r]} rest
    | "--sort" :: s :: rest ->
        if s <> "location" && s <> "complexity"
        then die ("--sort must be location or complexity, not " ^ s) ;
        parse {a with sort= s} rest
    | "--metric" :: m :: rest ->
        if m <> "cognitive" && m <> "cyclomatic"
        then die ("--metric must be cognitive or cyclomatic, not " ^ m) ;
        parse {a with metric= m} rest
    | ("-h" | "--help") :: _ ->
        print_endline usage ;
        exit 0
    | arg :: _ -> die ("unexpected complexity argument: " ^ arg)
  in
  let a =
    parse
      { project= None
      ; rebuild= false
      ; build= None
      ; roots= []
      ; json= false
      ; sort= "location"
      ; metric= "cognitive" }
      args
  in
  if a.build <> None && not a.rebuild then die "--build requires --rebuild" ;
  let roots =
    (if a.roots = [] then ["lib"] else a.roots)
    |> List.map (fun r ->
        let r =
          if String.ends_with ~suffix:"/" r && String.length r > 1
          then String.sub r 0 (String.length r - 1)
          else r
        in
        if r = "" || r = "." || not (Filename.is_relative r)
        then die ("--root must be a relative subdirectory, not " ^ r) ;
        r )
  in
  let report =
    Inspection.complexity
      { project_root= absolute (Option.value ~default:"." a.project)
      ; rebuild= a.rebuild
      ; build= Option.value ~default:"dune build" a.build
      ; roots
      ; sort= a.sort
      ; metric= a.metric }
  in
  print_string
    ( if a.json
      then Complexity_render.json report
      else Complexity_render.text report ) ;
  exit (if report.status = "ok" then 0 else 2)

let () =
  match Array.to_list Sys.argv with
  | _ :: ("-h" | "--help") :: _
   |[_] ->
      print_endline usage ;
      exit 0
  | _ :: "check" :: rest -> run_check rest
  | _ :: "complexity" :: rest -> (
    try run_complexity rest with
    | Sys_error e
     |Failure e ->
        prerr_endline ("szaniec: " ^ e) ;
        exit 2 )
  | _ :: command :: _ -> die ("unknown command: " ^ command)
  | [] -> exit 2
