(* InspectionManager coverage workflow. Toolchain parsing stays in
   ProgramAccess; this module sequences the build, the scenario, and
   collection. *)

open Szaniec_model
module Facts = Szaniec_program_access.Coverage_facts

let ( // ) = Filename.concat

let find_dune_root start =
  let rec walk dir =
    if Sys.file_exists (dir // "dune-project")
    then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then start else walk parent
  in
  walk start

let abs_cwd path =
  if Filename.is_relative path then Sys.getcwd () // path else path

let inject_instrument = function
  | [] -> Error "coverage build command is empty"
  | dune :: rest -> (
      let base = Filename.basename dune in
      if base <> "dune" && not (String.starts_with ~prefix:"dune." base)
      then Error "coverage build command must start with dune"
      else if List.mem "--instrument-with" rest
      then Ok (dune :: rest)
      else
        match rest with
        | sub :: tail ->
            Ok
              ( dune
              :: sub
              :: "--instrument-with"
              :: "szaniec.instrumentation"
              :: tail )
        | [] -> Error "coverage build command needs a dune subcommand" )

let env_drop key =
  let starts prefix =
    String.length key >= String.length prefix
    && String.sub key 0 (String.length prefix) = prefix
  in
  starts "DUNE_"
  || starts "OCAML"
  || starts "CAML_"
  || starts "BUILD_PATH_PREFIX_MAP"
  || key = "INSIDE_DUNE"

let key_of entry =
  match String.index_opt entry '=' with
  | Some i -> String.sub entry 0 i
  | None -> entry

let build_env () =
  let kept =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry -> not (env_drop (key_of entry)))
  in
  Array.of_list ("DUNE_CACHE=disabled" :: kept)

let put entries key value =
  let prefix = key ^ "=" in
  let filtered =
    List.filter (fun entry -> not (String.starts_with ~prefix entry)) entries
  in
  (key ^ "=" ^ value) :: filtered

let run_argv ~cwd ~env argv =
  let old = Sys.getcwd () in
  Unix.chdir cwd ;
  let argv = Array.of_list argv in
  let pid =
    Unix.create_process_env
      argv.(0)
      argv
      (Array.of_list env)
      Unix.stdin
      Unix.stdout
      Unix.stderr
  in
  let _, status = Unix.waitpid [] pid in
  Unix.chdir old ;
  match status with
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED n
   |Unix.WSTOPPED n ->
      128 + n

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm_rf (path // name)) (Sys.readdir path) ;
      Unix.rmdir path )
    else Sys.remove path

let mkdir_p path =
  try Unix.mkdir path 0o755 with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let write_file path contents =
  let oc = open_out path in
  output_string oc contents ;
  close_out oc

let signal_name n =
  if n = Sys.sigkill
  then "KILL"
  else if n = Sys.sigterm
  then "TERM"
  else string_of_int n

let wait_port port =
  let deadline = Unix.gettimeofday () +. 10. in
  let rec loop () =
    if Unix.gettimeofday () > deadline
    then false
    else
      let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      match
        Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port))
      with
      | () ->
          Unix.close socket ;
          true
      | exception _ ->
          Unix.close socket ;
          Unix.sleepf 0.05 ;
          loop ()
  in
  loop ()

let child_env ~ctx ~pass_env ~prefix ~probe_dir =
  let wanted =
    ["PATH"; "HOME"; "LANG"; "LC_ALL"; "LC_CTYPE"; "USER"; "TMPDIR"; "TMP"]
    @ pass_env
  in
  let base =
    List.filter_map
      (fun key ->
        match Sys.getenv_opt key with
        | None -> None
        | Some value -> Some (key ^ "=" ^ value) )
      wanted
  in
  base
  @ [ "BISECT_FILE=" ^ prefix
    ; "BISECT_SILENT=YES"
    ; "SZANIEC_COVERAGE_CONTEXT=" ^ ctx
    ; "SZANIEC_PROBE_DIR=" ^ probe_dir ]

let write_node path node_id disposition code signal prefix records =
  let json =
    `Assoc
      [ ("id", `String node_id)
      ; ("disposition", `String disposition)
      ; ( "code"
        , match code with
          | Some n -> `Int n
          | None -> `Null )
      ; ( "signal"
        , match signal with
          | Some s -> `String s
          | None -> `Null )
      ; ("prefix", `String prefix)
      ; ("records", `Int records) ]
  in
  write_file path (Yojson.Safe.to_string json ^ "\n")

let supervise ~port ~pass_env command =
  match Sys.getenv_opt "SZANIEC_COVERAGE_CONTEXT" with
  | None ->
      prerr_endline "szaniec: SZANIEC_COVERAGE_CONTEXT is not set" ;
      exit 2
  | Some ctx -> (
    match command with
    | [] ->
        prerr_endline "szaniec: coverage supervise needs a command" ;
        exit 2
    | _ -> (
        let data = ctx // "data" in
        let nodes = ctx // "nodes" in
        let probe = ctx // "probe" in
        mkdir_p ctx ;
        mkdir_p data ;
        mkdir_p nodes ;
        mkdir_p probe ;
        Random.self_init () ;
        let node_id =
          Printf.sprintf "n%x-%x" (Unix.getpid ()) (Random.bits ())
        in
        let prefix = data // (node_id ^ "-") in
        let env = child_env ~ctx ~pass_env ~prefix ~probe_dir:probe in
        let silence = Unix.openfile "/dev/null" [Unix.O_RDWR] 0o0 in
        let pid =
          Unix.create_process_env
            (List.hd command)
            (Array.of_list command)
            (Array.of_list env)
            silence
            silence
            Unix.stderr
        in
        Unix.close silence ;
        Printf.printf "pid %d\n%!" pid ;
        let ready = wait_port port in
        if not ready
        then (
          ( try Unix.kill pid Sys.sigkill with
          | Unix.Unix_error _ -> () ) ;
          let _ = Unix.waitpid [] pid in
          write_node
            (nodes // (node_id ^ ".json"))
            node_id
            "signaled"
            None
            (Some "KILL")
            prefix
            0 ;
          prerr_endline
            "szaniec: instrumented server did not accept connections" ;
          exit 2 ) ;
        Printf.printf "ready\n%!" ;
        let _, status = Unix.waitpid [] pid in
        let disposition, code, signal =
          match status with
          | Unix.WEXITED code -> ("exited", Some code, None)
          | Unix.WSIGNALED n
           |Unix.WSTOPPED n ->
              ("signaled", None, Some (signal_name n))
        in
        let records =
          if Sys.file_exists data
          then
            Array.fold_left
              (fun n name ->
                if
                  String.starts_with ~prefix:(node_id ^ "-") name
                  && Filename.check_suffix name ".coverage"
                then n + 1
                else n )
              0
              (Sys.readdir data)
          else 0
        in
        write_node
          (nodes // (node_id ^ ".json"))
          node_id
          disposition
          code
          signal
          prefix
          records ;
        match code with
        | Some n -> exit n
        | None -> exit 0 ) )

let read_nodes dir =
  if not (Sys.file_exists dir)
  then []
  else
    let names =
      Array.to_list (Sys.readdir dir)
      |> List.filter (fun n -> Filename.check_suffix n ".json")
      |> List.sort compare
    in
    List.filter_map
      (fun name ->
        match Yojson.Safe.from_file (dir // name) with
        | `Assoc fields ->
            let str k =
              match List.assoc_opt k fields with
              | Some (`String s) -> Some s
              | _ -> None
            in
            let int_opt k =
              match List.assoc_opt k fields with
              | Some (`Int n) -> Some n
              | _ -> None
            in
            let id = Option.value ~default:name (str "id") in
            let disposition =
              match str "disposition" with
              | Some "exited" ->
                  Coverage.Exited (Option.value ~default:0 (int_opt "code"))
              | Some "signaled" ->
                  Coverage.Signaled
                    (Option.value ~default:"unknown" (str "signal"))
              | _ -> Coverage.Unknown
            in
            let records = Option.value ~default:0 (int_opt "records") in
            Some {Coverage.id; disposition; records}
        | _ -> None
        | exception _ -> None )
      names

let collect_points ~project_root ~dune_root data_dir =
  if not (Sys.file_exists data_dir)
  then ([], [])
  else
    let files =
      Array.to_list (Sys.readdir data_dir)
      |> List.filter (fun n -> Filename.check_suffix n ".coverage")
    in
    let gaps = ref [] in
    let items =
      List.concat_map
        (fun name ->
          match Facts.parse_coverage_file (data_dir // name) with
          | Error message ->
              gaps :=
                { Coverage.code= "COVERAGE-NO-EVIDENCE"
                ; message= "Point file could not be read: " ^ message
                ; path= name }
                :: !gaps ;
              ([] : Facts.file_points list)
          | Ok found ->
              List.map
                (fun (item : Facts.file_points) ->
                  { item with
                    Facts.path=
                      Facts.normalize_path
                        ~project_root
                        ~dune_root
                        item.Facts.path } )
                found )
        files
    in
    (items, !gaps)

let sort_gaps gaps =
  let key (g : Coverage.gap) = (g.code, g.path, g.message) in
  let sorted = List.sort (fun a b -> compare (key a) (key b)) gaps in
  let rec uniq prev acc = function
    | [] -> List.rev acc
    | g :: rest ->
        if Some (key g) = prev
        then uniq prev acc rest
        else uniq (Some (key g)) (g :: acc) rest
  in
  uniq None [] sorted

let empty_report ~snapshot ~scenario ~gaps =
  let functions = [] in
  { Coverage.status= Coverage.Incomplete
  ; scenario
  ; measurement_window= "process"
  ; coverage_kind= "point"
  ; denominator= "instrumented-points"
  ; facade= Version.instrumentation_facade
  ; engines=
      [ { Coverage.name= "points"
        ; version= Version.coverage_points
        ; kind= "point"
        ; visits= None }
      ; { name= "probe"
        ; version= Version.coverage_probe
        ; kind= "visit"
        ; visits= Some 0 } ]
  ; snapshot_digest= snapshot
  ; compiler= Sys.ocaml_version
  ; exclusions= Coverage.exclusions
  ; functions
  ; gaps= sort_gaps gaps
  ; nodes= []
  ; points_covered= 0
  ; points_total= 0 }

let node_gaps (nodes : Coverage.node list) =
  List.filter_map
    (fun (node : Coverage.node) ->
      match node.disposition with
      | Coverage.Signaled signal when node.records = 0 ->
          Some
            { Coverage.code= "COVERAGE-FORCED-TERMINATION"
            ; message=
                "Node "
                ^ node.id
                ^ " stopped on SIG"
                ^ signal
                ^ " without flushing point data"
            ; path= node.id }
      | Coverage.Exited _ when node.records = 0 ->
          Some
            { Coverage.code= "COVERAGE-MISSING-OUTPUT"
            ; message= "Node " ^ node.id ^ " exited without point data"
            ; path= node.id }
      | Coverage.Unknown when node.records = 0 ->
          Some
            { Coverage.code= "COVERAGE-MISSING-OUTPUT"
            ; message= "Node " ^ node.id ^ " has no point data"
            ; path= node.id }
      | _ -> None )
    nodes

let run
    ~project_root
    ~(config : Szaniec_config.Config.coverage)
    ~inventory
    ~keep_work =
  Random.self_init () ;
  let project_root = abs_cwd project_root in
  let dune_root = find_dune_root project_root in
  match inject_instrument config.build with
  | Error message -> Error message
  | Ok build ->
      let scope = config.scope in
      let snapshot, _ = Facts.snapshot dune_root scope in
      let work =
        Filename.get_temp_dir_name ()
        // Printf.sprintf "szaniec-cov-%x-%x" (Unix.getpid ()) (Random.bits ())
      in
      mkdir_p work ;
      mkdir_p (work // "data") ;
      mkdir_p (work // "nodes") ;
      mkdir_p (work // "probe") ;
      let cleanup () = if not keep_work then rm_rf work in
      let finish report =
        cleanup () ;
        if keep_work then prerr_endline ("szaniec coverage work: " ^ work) ;
        report
      in
      let env = Array.to_list (build_env ()) in
      let build_code = run_argv ~cwd:dune_root ~env build in
      if build_code <> 0
      then
        Ok
          (finish
             (empty_report
                ~snapshot
                ~scenario:Coverage.Not_run
                ~gaps:
                  [ { Coverage.code= "COVERAGE-BUILD-FAILED"
                    ; message=
                        "Instrumented build exited " ^ string_of_int build_code
                    ; path= dune_root } ] ) )
      else
        let server = dune_root // config.server in
        let scenario_env =
          let entries = Unix.environment () |> Array.to_list in
          let entries = put entries "SZANIEC_COVERAGE_CONTEXT" work in
          let entries = put entries "SZANIEC_BIN" (abs_cwd Sys.argv.(0)) in
          let entries = put entries "COVERAGE_SERVER" server in
          let entries = put entries "COVERAGE_PROJECT_ROOT" project_root in
          put entries "COVERAGE_DUNE_ROOT" dune_root
        in
        let scenario_code =
          if config.scenario = []
          then 0
          else run_argv ~cwd:dune_root ~env:scenario_env config.scenario
        in
        let scenario =
          if scenario_code = 0
          then Coverage.Passed scenario_code
          else Coverage.Failed scenario_code
        in
        let later, _ = Facts.snapshot dune_root scope in
        let stanzas, scan_gaps, _mlx = Facts.scan_stanzas dune_root scope in
        let index_files =
          Facts.files_under dune_root scope (fun name ->
              Filename.check_suffix name ".ml" )
        in
        let spans, parse_gaps = Facts.index_sources dune_root index_files in
        let expected = Facts.expected_sources dune_root stanzas in
        let points, read_gaps =
          collect_points ~project_root:dune_root ~dune_root (work // "data")
        in
        let merged, merge_gaps = Facts.merge_points points in
        let measured_paths =
          List.map (fun (f : Facts.file_points) -> f.Facts.path) merged
        in
        let evidence_gaps =
          List.filter_map
            (fun rel ->
              if List.mem rel measured_paths
              then None
              else
                Some
                  { Coverage.code= "COVERAGE-NO-EVIDENCE"
                  ; message= "Hooked source has no point file: " ^ rel
                  ; path= rel } )
            expected
        in
        let unmapped =
          List.filter_map
            (fun (file : Facts.file_points) ->
              let under =
                List.exists
                  (fun root ->
                    root = ""
                    || file.path = root
                    || String.starts_with ~prefix:(root ^ "/") file.path )
                  scope
              in
              if under && not (List.mem file.path index_files)
              then
                Some
                  { Coverage.code= "COVERAGE-UNMAPPED-FILE"
                  ; message=
                      "Point file does not match a source snapshot: "
                      ^ file.path
                  ; path= file.path }
              else None )
            merged
        in
        let stale =
          if later = snapshot
          then []
          else
            [ { Coverage.code= "COVERAGE-STALE-SNAPSHOT"
              ; message= "Sources changed during the coverage run"
              ; path= dune_root } ]
        in
        let inventory, inventory_gaps =
          match inventory with
          | None -> ([], [])
          | Some path -> (
            match Facts.load_inventory path with
            | Ok entries -> (entries, [])
            | Error gap -> ([], [gap]) )
        in
        let functions, points_covered, points_total =
          Facts.attribute ~spans ~measured:merged ~inventory
        in
        let nodes = read_nodes (work // "nodes") in
        let visits = Facts.count_probe_visits (work // "probe") in
        let probe_gaps =
          if
            visits = 0
            && List.exists
                 (fun (n : Coverage.node) ->
                   match n.disposition with
                   | Coverage.Exited 0 -> true
                   | _ -> false )
                 nodes
          then
            [ { Coverage.code= "COVERAGE-NO-EVIDENCE"
              ; message= "Probe engine produced no visits"
              ; path= work // "probe" } ]
          else []
        in
        let gaps =
          sort_gaps
            ( scan_gaps
            @ parse_gaps
            @ read_gaps
            @ merge_gaps
            @ evidence_gaps
            @ unmapped
            @ stale
            @ inventory_gaps
            @ node_gaps nodes
            @ probe_gaps )
        in
        let engines =
          [ { Coverage.name= "points"
            ; version= Version.coverage_points
            ; kind= "point"
            ; visits= None }
          ; { name= "probe"
            ; version= Version.coverage_probe
            ; kind= "visit"
            ; visits= Some visits } ]
        in
        Ok
          (finish
             { Coverage.status=
                 (if gaps = [] then Coverage.Complete else Coverage.Incomplete)
             ; scenario
             ; measurement_window= "process"
             ; coverage_kind= "point"
             ; denominator= "instrumented-points"
             ; facade= Version.instrumentation_facade
             ; engines
             ; snapshot_digest= snapshot
             ; compiler= Sys.ocaml_version
             ; exclusions= Coverage.exclusions
             ; functions
             ; gaps
             ; nodes
             ; points_covered
             ; points_total } )
