(* CheckClient: command line, rendering and exit status mapping. *)

open Szaniec_model

let usage =
  "usage:\n\
  \ szaniec approve --policy <path> [--approval <path>]\n\
  \ szaniec check --policy <path> [--approval <path>] [--project-root <dir>]\n\
  \               [--rebuild] [--json] [--out <path>] [--no-callgraph]\n\
  \ szaniec suggestions [--policy <path>] [--project-root <dir>] [--rebuild]\n\
  \               [--json] [--experimental] [--model <id>] [--cache <path>]\n\
  \               [--no-cache] [--refresh] [--timeout <seconds>]\n\
  \               [--budget-names <n>] [--budget-pairs <n>]\n\
  \               [--budget-responsibility <n>] [--budget-complexity <n>]\n\
  \               [--provider-fixture <path>] [--decisions <path>]\n\
  \               [--api-candidates <path>]\n\
  \ szaniec suggestions decide --id <id> --decision apply|reject|defer\n\
  \               --rationale <text> [--decisions <path>] [--project-root \
   <dir>]"

type args =
  { command: string
  ; subcommand: string
  ; policy: string
  ; approval: string option
  ; project_root: string
  ; rebuild: bool
  ; json: bool
  ; out: string option
  ; no_callgraph: bool
  ; experimental: bool
  ; model: string
  ; cache: string option
  ; no_cache: bool
  ; refresh: bool
  ; timeout_s: int
  ; budget_names: int
  ; budget_pairs: int
  ; budget_responsibility: int
  ; budget_complexity: int
  ; provider_fixture: string option
  ; decisions: string option
  ; api_candidates: string option
  ; suggestion_id: string
  ; decision: string
  ; rationale: string }

let int_arg (flag : string) (raw : string) : int =
  match int_of_string raw with
  | n when n >= 0 -> n
  | _ ->
      prerr_endline ("szaniec: " ^ flag ^ " expects a non-negative integer") ;
      exit 2
  | exception Failure _ ->
      prerr_endline ("szaniec: " ^ flag ^ " expects a non-negative integer") ;
      exit 2

let rec parse (argv : string list) (acc : args) : args =
  match argv with
  | [] -> acc
  | "--policy" :: p :: rest -> parse rest {acc with policy= p}
  | "--approval" :: p :: rest -> parse rest {acc with approval= Some p}
  | "--project-root" :: p :: rest -> parse rest {acc with project_root= p}
  | "--rebuild" :: rest -> parse rest {acc with rebuild= true}
  | "--json" :: rest -> parse rest {acc with json= true}
  | "--out" :: p :: rest -> parse rest {acc with out= Some p}
  | "--no-callgraph" :: rest -> parse rest {acc with no_callgraph= true}
  | "--experimental" :: rest -> parse rest {acc with experimental= true}
  | "--model" :: p :: rest -> parse rest {acc with model= p}
  | "--cache" :: p :: rest -> parse rest {acc with cache= Some p}
  | "--no-cache" :: rest -> parse rest {acc with no_cache= true}
  | "--refresh" :: rest -> parse rest {acc with refresh= true}
  | "--timeout" :: p :: rest ->
      parse rest {acc with timeout_s= int_arg "--timeout" p}
  | "--budget-names" :: p :: rest ->
      parse rest {acc with budget_names= int_arg "--budget-names" p}
  | "--budget-pairs" :: p :: rest ->
      parse rest {acc with budget_pairs= int_arg "--budget-pairs" p}
  | "--budget-responsibility" :: p :: rest ->
      parse
        rest
        {acc with budget_responsibility= int_arg "--budget-responsibility" p}
  | "--budget-complexity" :: p :: rest ->
      parse rest {acc with budget_complexity= int_arg "--budget-complexity" p}
  | "--provider-fixture" :: p :: rest ->
      parse rest {acc with provider_fixture= Some p}
  | "--decisions" :: p :: rest -> parse rest {acc with decisions= Some p}
  | "--api-candidates" :: p :: rest ->
      parse rest {acc with api_candidates= Some p}
  | "--id" :: p :: rest -> parse rest {acc with suggestion_id= p}
  | "--decision" :: p :: rest -> parse rest {acc with decision= p}
  | "--rationale" :: p :: rest -> parse rest {acc with rationale= p}
  | cmd :: rest
    when acc.command = ""
         && (cmd = "check" || cmd = "approve" || cmd = "suggestions") ->
      parse rest {acc with command= cmd}
  | "decide" :: rest when acc.command = "suggestions" && acc.subcommand = "" ->
      parse rest {acc with subcommand= "decide"}
  | bad :: _ ->
      prerr_endline ("szaniec: unknown argument: " ^ bad) ;
      prerr_endline usage ;
      exit 2

let default_args =
  { command= ""
  ; subcommand= ""
  ; policy= "szaniec/policy.json"
  ; approval= Some "szaniec/approval.json"
  ; project_root= Sys.getcwd ()
  ; rebuild= false
  ; json= false
  ; out= None
  ; no_callgraph= false
  ; experimental= false
  ; model= Szaniec_model.Version.suggestion_model
  ; cache= None
  ; no_cache= false
  ; refresh= false
  ; timeout_s= 30
  ; budget_names= 12
  ; budget_pairs= 6
  ; budget_responsibility= 6
  ; budget_complexity= 6
  ; provider_fixture= None
  ; decisions= None
  ; api_candidates= None
  ; suggestion_id= ""
  ; decision= ""
  ; rationale= "" }

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

let callgraph_json (cg : Callgraph.t) (inputs : Finding.inputs) : string =
  let jsite (s : Observation.site) =
    `Assoc
      [ ("path", `String s.Observation.site_path)
      ; ("line", `Int s.Observation.line)
      ; ("col", `Int s.Observation.col) ]
  in
  let jtarget (t : Callgraph.target) =
    match t with
    | Callgraph.Service_method (svc, method_name) ->
        `Assoc [("service", `String svc); ("method", `String method_name)]
    | Callgraph.Resource_target n ->
        `Assoc [("kind", `String "resource"); ("name", `String n)]
    | Callgraph.External_target api ->
        `Assoc [("kind", `String "external"); ("api", `String api)]
    | Callgraph.Unresolved_target detail ->
        `Assoc [("kind", `String "unresolved"); ("detail", `String detail)]
  in
  let jedge (e : Callgraph.edge) =
    `Assoc
      [ ("to", jtarget e.Callgraph.target)
      ; ("sites", `List (List.map jsite e.Callgraph.sites)) ]
  in
  let jmethod (m : Callgraph.method_info) =
    `Assoc
      [ ("name", `String m.Callgraph.mi_name)
      ; ("request", `String m.Callgraph.mi_request)
      ; ("response", `String m.Callgraph.mi_response)
      ; ("calls", `List (List.map jedge m.Callgraph.mi_calls))
      ; ( "calledBy"
        , `List
            (List.map
               (fun (svc, method_name) ->
                 `Assoc
                   [("service", `String svc); ("method", `String method_name)] )
               m.Callgraph.mi_called_by ) ) ]
  in
  let jservice (s : Callgraph.service_info) =
    `Assoc
      [ ("name", `String s.Callgraph.si_name)
      ; ("role", `String s.Callgraph.si_role)
      ; ("methods", `List (List.map jmethod s.Callgraph.si_methods)) ]
  in
  let junresolved (unit_name, caller, site) =
    `Assoc
      [ ("unit", `String unit_name)
      ; ("caller", `String caller)
      ; ("site", jsite site) ]
  in
  let json =
    `Assoc
      [ ("format", `String Version.callgraph_format)
      ; ( "inputs"
        , `Assoc
            [ ("policyName", `String inputs.Finding.policy.Finding.policy_name)
            ; ( "policyDigest"
              , `String inputs.Finding.policy.Finding.policy_digest )
            ; ("snapshotDigest", `String inputs.Finding.snapshot_digest)
            ; ("programAccess", `String Version.adapter_ocaml)
            ; ("interpretation", `String Version.adapter_well)
            ; ("rules", `String Version.rules) ] )
      ; ("services", `List (List.map jservice cg.Callgraph.services))
      ; ("unresolved", `List (List.map junresolved cg.Callgraph.unresolved))
      ; ( "unclassifiedUnits"
        , `List (List.map (fun u -> `String u) cg.Callgraph.unclassified_units)
        ) ]
  in
  Yojson.Safe.to_string json ^ "\n"

let write_callgraph (r : Finding.report) (out : string option) (root : string) :
    unit =
  match r.Finding.callgraph with
  | None -> ()
  | Some cg -> (
      let path =
        match out with
        | Some p -> p
        | None -> Filename.concat root "szaniec.json"
      in
      match cg.Callgraph.services with
      | []
        when cg.Callgraph.unresolved = []
             && cg.Callgraph.unclassified_units = [] ->
          ()
      | _ -> (
        try
          let oc = open_out path in
          output_string oc (callgraph_json cg r.Finding.inputs) ;
          close_out oc
        with
        | Sys_error e ->
            prerr_endline ("szaniec: cannot write " ^ path ^ ": " ^ e) ) )

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
  | "suggestions" when args.subcommand = "decide" -> (
      let path =
        let raw =
          Option.value
            ~default:"szaniec/suggestion-decisions.json"
            args.decisions
        in
        if Filename.is_relative raw
        then Filename.concat args.project_root raw
        else raw
      in
      match
        Szaniec_suggestion_manager.Suggestion_manager.record_decision
          ~path
          ~id:args.suggestion_id
          ~decision:args.decision
          ~rationale:args.rationale
      with
      | Ok () ->
          Printf.printf "recorded %s for %s\n" args.decision args.suggestion_id ;
          exit 0
      | Error e ->
          prerr_endline ("szaniec: " ^ e) ;
          exit 2 )
  | "suggestions" -> (
      let module S = Szaniec_suggestion_manager.Suggestion_manager in
      let resolve p =
        if Filename.is_relative p && not (Sys.file_exists p)
        then Filename.concat args.project_root p
        else p
      in
      let policy_path = resolve args.policy in
      let program_roots =
        match
          Szaniec_architecture_access.Architecture_access.parse_policy
            policy_path
        with
        | Error e ->
            prerr_endline ("szaniec: " ^ e) ;
            exit 2
        | Ok policy -> policy.Szaniec_model.Policy.program_roots
      in
      let decisions_path =
        let raw =
          Option.value
            ~default:"szaniec/suggestion-decisions.json"
            args.decisions
        in
        if Filename.is_relative raw
        then Filename.concat args.project_root raw
        else raw
      in
      let decisions =
        match S.read_decisions decisions_path with
        | Ok items -> items
        | Error e ->
            prerr_endline ("szaniec: " ^ e) ;
            exit 2
      in
      let provider =
        match args.provider_fixture with
        | None -> None
        | Some path -> (
          match
            Szaniec_model_access.Jev_provider.fixture_of_file (resolve path)
          with
          | Ok provider -> Some provider
          | Error e ->
              prerr_endline ("szaniec: " ^ e) ;
              exit 2 )
      in
      let api_candidates =
        match args.api_candidates with
        | None -> []
        | Some path -> (
          match S.load_api_candidates (resolve path) with
          | Ok items -> items
          | Error e ->
              prerr_endline ("szaniec: " ^ e) ;
              exit 2 )
      in
      let cache_path =
        if args.no_cache
        then None
        else
          Some
            ( match args.cache with
            | Some p ->
                if Filename.is_relative p
                then Filename.concat args.project_root p
                else p
            | None ->
                Filename.concat
                  args.project_root
                  "szaniec/suggestion-cache.json" )
      in
      let budgets : Szaniec_suggestion_manager.Retrieve.budgets =
        { Szaniec_suggestion_manager.Retrieve.names= args.budget_names
        ; pairs= args.budget_pairs
        ; responsibility= args.budget_responsibility
        ; complexity= args.budget_complexity
        ; experimental= 6
        ; body_chars= 1200 }
      in
      match
        S.run
          { S.project_root= args.project_root
          ; program_roots
          ; rebuild= args.rebuild
          ; experimental= args.experimental
          ; budgets
          ; model= args.model
          ; timeout_s= args.timeout_s
          ; cache_path
          ; refresh= args.refresh
          ; provider
          ; decisions
          ; api_candidates }
      with
      | Error e ->
          prerr_endline ("szaniec: " ^ e) ;
          exit 2
      | Ok report ->
          print_string
            ( if args.json
              then S.json_of_report report
              else S.text_of_report report ) ;
          exit (S.exit_code report) )
  | "check" -> (
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
        if not args.no_callgraph
        then write_callgraph report args.out args.project_root ;
        print_string
          (if args.json then json_report report else text_report report) ;
        exit (exit_code report)
      with
      | Szaniec_inspection_manager.Inspection_manager.Policy_error e ->
          prerr_endline ("szaniec: " ^ e) ;
          exit 2 )
  | _ ->
      prerr_endline usage ;
      exit 2
