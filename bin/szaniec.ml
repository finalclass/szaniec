(* CheckClient: command line, rendering and exit status mapping. *)

open Szaniec_model

let usage =
  "usage:\n\
  \ szaniec approve --policy <path> [--approval <path>]\n\
  \ szaniec check --policy <path> [--approval <path>] [--project-root <dir>]\n\
  \               [--rebuild] [--json]"

type args =
  { command: string
  ; policy: string
  ; approval: string option
  ; project_root: string
  ; rebuild: bool
  ; json: bool }

let rec parse (argv : string list) (acc : args) : args =
  match argv with
  | [] -> acc
  | "--policy" :: p :: rest -> parse rest {acc with policy= p}
  | "--approval" :: p :: rest -> parse rest {acc with approval= Some p}
  | "--project-root" :: p :: rest -> parse rest {acc with project_root= p}
  | "--rebuild" :: rest -> parse rest {acc with rebuild= true}
  | "--json" :: rest -> parse rest {acc with json= true}
  | cmd :: rest when acc.command = "" && (cmd = "check" || cmd = "approve") ->
      parse rest {acc with command= cmd}
  | bad :: _ ->
      prerr_endline ("szaniec: unknown argument: " ^ bad) ;
      prerr_endline usage ;
      exit 2

let default_args =
  { command= ""
  ; policy= "szaniec/policy.json"
  ; approval= Some "szaniec/approval.json"
  ; project_root= Sys.getcwd ()
  ; rebuild= false
  ; json= false }

(* ── rendering ────────────────────────────────────────────────────── *)

let render_finding (buf : Buffer.t) (f : Finding.t) =
  let sev =
    match f.Finding.severity with
    | Violation -> "violation"
    | GapFinding -> "gap"
  in
  Buffer.add_string
    buf
    (Printf.sprintf "%s [%s] %s\n" sev f.Finding.rule f.Finding.message) ;
  List.iter
    (fun p -> Buffer.add_string buf (Printf.sprintf "  participant: %s\n" p))
    f.Finding.participants ;
  List.iter
    (fun l ->
      Buffer.add_string
        buf
        (Printf.sprintf
           "  at %s:%d:%d\n"
           l.Finding.loc_path
           l.Finding.loc_line
           l.Finding.loc_col ) )
    f.Finding.locations ;
  if f.Finding.evidence_path <> []
  then
    Buffer.add_string
      buf
      (Printf.sprintf
         "  path: %s\n"
         (String.concat " -> " f.Finding.evidence_path) )

let text_report (r : Finding.report) : string =
  let buf = Buffer.create 512 in
  let policy = r.Finding.inputs.Finding.policy in
  Buffer.add_string
    buf
    (Printf.sprintf
       "szaniec %s: policy %s (%s)%s\n"
       ( match r.Finding.status with
       | Ok -> "ok"
       | Violations -> "violations"
       | Incomplete -> "incomplete" )
       policy.Finding.policy_name
       policy.Finding.policy_digest
       (if policy.Finding.approved then "" else " [NOT APPROVED]") ) ;
  Buffer.add_string
    buf
    (Printf.sprintf
       "  profile: %s; compiler: %s; snapshot: %s\n"
       r.Finding.inputs.Finding.profile
       r.Finding.inputs.Finding.compiler
       r.Finding.inputs.Finding.snapshot_digest ) ;
  Buffer.add_string
    buf
    (Printf.sprintf
       "  adapters: %s, %s, %s\n"
       Version.adapter_ocaml
       Version.adapter_well
       Version.rules ) ;
  Buffer.add_string buf "  exclusions:\n" ;
  List.iter
    (fun e -> Buffer.add_string buf (Printf.sprintf "    - %s\n" e))
    r.Finding.inputs.Finding.exclusions ;
  List.iter (render_finding buf) r.Finding.findings ;
  Buffer.add_string
    buf
    (Printf.sprintf
       "summary: %d violation(s), %d gap(s), %d unit(s), %d call(s), %d type \
        reference(s)\n"
       r.Finding.summary.Finding.violations
       r.Finding.summary.Finding.gaps
       r.Finding.summary.Finding.units
       r.Finding.summary.Finding.calls
       r.Finding.summary.Finding.type_refs ) ;
  Buffer.contents buf

let status_string (r : Finding.report) =
  match r.Finding.status with
  | Ok -> "ok"
  | Violations -> "violations"
  | Incomplete -> "incomplete"

let json_report (r : Finding.report) : string =
  let jloc (l : Finding.location) =
    `Assoc
      [ ("path", `String l.Finding.loc_path)
      ; ("line", `Int l.Finding.loc_line)
      ; ("col", `Int l.Finding.loc_col) ]
  in
  let jfinding (f : Finding.t) =
    `Assoc
      [ ("rule", `String f.Finding.rule)
      ; ( "severity"
        , `String
            ( match f.Finding.severity with
            | Violation -> "violation"
            | GapFinding -> "gap" ) )
      ; ("message", `String f.Finding.message)
      ; ( "participants"
        , `List (List.map (fun p -> `String p) f.Finding.participants) )
      ; ("locations", `List (List.map jloc f.Finding.locations))
      ; ( "evidencePath"
        , `List (List.map (fun p -> `String p) f.Finding.evidence_path) ) ]
  in
  let policy = r.Finding.inputs.Finding.policy in
  let json =
    `Assoc
      [ ("format", `String Version.report_format)
      ; ("status", `String (status_string r))
      ; ( "inputs"
        , `Assoc
            [ ( "policy"
              , `Assoc
                  [ ("name", `String policy.Finding.policy_name)
                  ; ("digest", `String policy.Finding.policy_digest)
                  ; ("approved", `Bool policy.Finding.approved)
                  ; ( "approvedDigest"
                    , match policy.Finding.approved_digest with
                      | Some d -> `String d
                      | None -> `Null ) ] )
            ; ("profile", `String r.Finding.inputs.Finding.profile)
            ; ( "programRoots"
              , `List
                  (List.map
                     (fun p -> `String p)
                     r.Finding.inputs.Finding.program_roots ) )
            ; ( "snapshotDigest"
              , `String r.Finding.inputs.Finding.snapshot_digest )
            ; ("compiler", `String r.Finding.inputs.Finding.compiler)
            ; ( "adapters"
              , `Assoc
                  [ ("programAccess", `String Version.adapter_ocaml)
                  ; ("interpretation", `String Version.adapter_well)
                  ; ("rules", `String Version.rules) ] )
            ; ( "exclusions"
              , `List
                  (List.map
                     (fun e -> `String e)
                     r.Finding.inputs.Finding.exclusions ) ) ] )
      ; ("findings", `List (List.map jfinding r.Finding.findings))
      ; ( "summary"
        , `Assoc
            [ ("violations", `Int r.Finding.summary.Finding.violations)
            ; ("gaps", `Int r.Finding.summary.Finding.gaps)
            ; ("units", `Int r.Finding.summary.Finding.units)
            ; ("calls", `Int r.Finding.summary.Finding.calls)
            ; ("typeRefs", `Int r.Finding.summary.Finding.type_refs) ] ) ]
  in
  Yojson.Safe.to_string json ^ "\n"

let exit_code (r : Finding.report) : int =
  match r.Finding.status with
  | Ok -> 0
  | Violations -> 1
  | Incomplete -> 2

(* ── entry point ──────────────────────────────────────────────────── *)

let () =
  let argv = List.tl (Array.to_list Sys.argv) in
  let args = parse argv default_args in
  if args.command = ""
  then (
    prerr_endline usage ;
    exit 2 ) ;
  match args.command with
  | "approve" -> (
      let resolve_path p =
        if Filename.is_relative p && not (Sys.file_exists p)
        then Filename.concat args.project_root p
        else p
      in
      let policy_path = resolve_path args.policy in
      let approval =
        resolve_path
          (Option.value ~default:"szaniec/approval.json" args.approval)
      in
      match
        Szaniec_architecture_access.Architecture_access.approve
          ~policy_path
          ~approval_path:approval
      with
      | Ok () ->
          Printf.printf
            "approved policy %s (digest recorded in %s)\n"
            args.policy
            approval ;
          exit 0
      | Error e ->
          prerr_endline ("szaniec: " ^ e) ;
          exit 2 )
  | _ -> (
      let policy_path =
        if Filename.is_relative args.policy && not (Sys.file_exists args.policy)
        then Filename.concat args.project_root args.policy
        else args.policy
      in
      let approval_path =
        match args.approval with
        | Some ap ->
            if Filename.is_relative ap && not (Sys.file_exists ap)
            then Some (Filename.concat args.project_root ap)
            else Some ap
        | None -> None
      in
      try
        let report =
          Szaniec_inspection_manager.Inspection_manager.check
            { Szaniec_inspection_manager.Inspection_manager.project_root=
                args.project_root
            ; policy_path
            ; approval_path
            ; rebuild= args.rebuild }
        in
        print_string
          (if args.json then json_report report else text_report report) ;
        exit (exit_code report)
      with
      | Szaniec_inspection_manager.Inspection_manager.Policy_error e ->
          prerr_endline ("szaniec: " ^ e) ;
          exit 2 )
