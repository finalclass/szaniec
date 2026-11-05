(* InspectionManager: runs the two use cases.

   check: ProjectAccess reads the dune build description, ArchitectureAccess
   reads the .cyrograf services, ConformanceEngine evaluates them. No build,
   no compiler artifacts.

   complexity: optionally runs the project's build, then ProgramAccess
   measures every function from current compiler artifacts. *)

open Szaniec_model

type check_error =
  { error_at: Structure.position option
  ; error_message: string }

let check ~(project_root : string) : (Conformance.report, check_error) result =
  match Szaniec_project_access.Project_access.load ~root:project_root with
  | Error e ->
      Error
        { error_at= Some e.Szaniec_project_access.Project_access.error_at
        ; error_message= e.error_message }
  | Ok project -> (
    match
      Szaniec_architecture_access.Architecture_access.services
        ~root:project_root
        ~directories:project.Structure.directories
    with
    | Error message -> Error {error_at= None; error_message= message}
    | Ok services ->
        Ok
          (Szaniec_conformance_engine.Conformance_engine.evaluate
             ~project
             ~services ) )

type complexity_request =
  { project_root: string
  ; rebuild: bool
  ; build: string (* shell command *)
  ; roots: string list
  ; sort: string (* "location" | "complexity" *)
  ; metric: string (* "cognitive" | "cyclomatic" *) }

(* When szaniec itself is invoked from inside a dune process (e.g. `dune
   exec` or a dune action), the injected variables point at the outer
   workspace and break the nested build of the inspected project. Strip
   them so the nested dune resolves its own toolchain and roots. *)
let env_unsets_for_nested_dune : string list =
  Unix.environment ()
  |> Array.to_list
  |> List.filter_map (fun entry ->
      let k =
        match String.index_opt entry '=' with
        | Some i -> String.sub entry 0 i
        | None -> entry
      in
      if
        String.starts_with ~prefix:"DUNE_" k
        || String.starts_with ~prefix:"OCAML" k
        || String.starts_with ~prefix:"CAML_" k
        || String.starts_with ~prefix:"BUILD_PATH_PREFIX_MAP" k
        || k = "INSIDE_DUNE"
      then Some k
      else None )
  |> List.sort_uniq compare

(* Run the build command through the shell in the project root. Its output
   goes to stderr so stdout carries only the report. *)
let run_build (project_root : string) (command : string) : int =
  let unsets =
    match env_unsets_for_nested_dune with
    | [] -> ""
    | names -> "unset " ^ String.concat " " names ^ "; "
  in
  (* DUNE_CACHE=disabled: cache-restored artifacts carry old mtimes, which
     would defeat the mtime-based freshness check. *)
  Sys.command
    (Printf.sprintf
       "cd %s && %sDUNE_CACHE=disabled; export DUNE_CACHE; ( %s ) >&2"
       (Filename.quote project_root)
       unsets
       command )

let complexity (req : complexity_request) : Complexity.t =
  let build_code =
    if req.rebuild then Some (run_build req.project_root req.build) else None
  in
  let observation =
    Szaniec_program_access.Ocaml_adapter.observe
      ~project_root:req.project_root
      ~program_roots:req.roots
      ~assume_fresh:(build_code = Some 0)
      ()
  in
  let build_gaps =
    match build_code with
    | Some code when code <> 0 ->
        [ { Observation.gap_code= "GAP-BUILD"
          ; gap_path= "dune-project"
          ; gap_detail=
              Printf.sprintf "build command failed (exit %d): %s" code req.build
          } ]
    | _ -> []
  in
  let entries =
    List.map
      (fun (f : Observation.function_def) ->
        { Complexity.id= f.fn_id
        ; name= f.fn_name
        ; qualname= f.fn_qualname
        ; kind= Complexity.kind_name f.fn_kind
        ; nested= f.fn_nested
        ; provenance= Complexity.provenance_name f.fn_provenance
        ; module_path= f.fn_unit
        ; path= f.fn_path
        ; line= f.fn_line
        ; col= f.fn_col
        ; end_line= f.fn_end_line
        ; end_col= f.fn_end_col
        ; complexity= Complexity.complexity_of ~metric:req.metric f.fn_measure
        ; status= Complexity.status_name f.fn_measure } )
      observation.functions
  in
  let gaps = build_gaps @ observation.gaps in
  let functions = Complexity.sort_entries req.sort entries in
  let incomplete = gaps <> [] || Complexity.unmeasurable_count functions > 0 in
  { Complexity.metric=
      ( if req.metric = "cyclomatic"
        then Version.cyclomatic_metric
        else Version.complexity_metric )
  ; status= (if incomplete then "incomplete" else "ok")
  ; snapshot_digest= observation.snapshot_digest
  ; compiler= observation.compiler_series
  ; profile= Version.complexity_profile
  ; program_roots= req.roots
  ; sort= req.sort
  ; functions
  ; coverage= observation.coverage
  ; gaps
  ; exclusions= Complexity.exclusions }
