(* CheckClient: command line, rendering and exit status mapping. *)

open Szaniec_model
module Config = Szaniec_config.Config

let usage =
  "usage:\n\
  \ szaniec approve [--config <path>] [--project-root <dir>]\n\
  \ szaniec check [--config <path>] [--project-root <dir>]\n\
  \               [--rebuild] [--json] [--out <path>] [--no-callgraph]\n\
  \ szaniec complexity [--config <path>] [--project-root <dir>]\n\
  \                    [--rebuild] [--json] [--sort location|complexity]\n\
  \ szaniec coverage [--project-root <dir>] [--config <path>] [--json]\n\
  \                  [--out <path>] [--keep-work] [--function-inventory <path>]\n\
  \ szaniec coverage supervise --port <int> [--pass-env <name>]... -- \
   <command>...\n\
  \ szaniec suggestions [--config <path>] [--project-root <dir>] [--rebuild]\n\
  \               [--json] [--experimental] [--model <id>] [--cache <path>]\n\
  \               [--no-cache] [--refresh] [--timeout <seconds>]\n\
  \               [--budget-names <n>] [--budget-pairs <n>]\n\
  \               [--budget-responsibility <n>] [--budget-complexity <n>]\n\
  \               [--provider-fixture <path>] [--decisions <path>]\n\
  \ szaniec suggestions decide --id <id> --decision apply|reject|defer\n\
  \               --rationale <text> [--decisions <path>] [--project-root \
   <dir>] [--config <path>]"

type args =
  { command: string
  ; subcommand: string
  ; config: string option
  ; project_root: string option
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
  ; suggestion_id: string
  ; decision: string
  ; rationale: string
  ; sort: string }

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
  | "--config" :: p :: rest -> parse rest {acc with config= Some p}
  | "--project-root" :: p :: rest -> parse rest {acc with project_root= Some p}
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
  | "--id" :: p :: rest -> parse rest {acc with suggestion_id= p}
  | "--decision" :: p :: rest -> parse rest {acc with decision= p}
  | "--rationale" :: p :: rest -> parse rest {acc with rationale= p}
  | "--sort" :: s :: rest -> parse rest {acc with sort= s}
  | cmd :: rest
    when acc.command = ""
         && ( cmd = "check"
            || cmd = "approve"
            || cmd = "suggestions"
            || cmd = "complexity" ) ->
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
  ; config= None
  ; project_root= None
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
  ; suggestion_id= ""
  ; decision= ""
  ; rationale= ""
  ; sort= "" }

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

let complexity_text (r : Complexity.t) : string =
  let buf = Buffer.create 1024 in
  Buffer.add_string
    buf
    (Printf.sprintf
       "szaniec complexity %s (%s)\n"
       r.Complexity.status
       Version.complexity_metric ) ;
  Buffer.add_string
    buf
    (Printf.sprintf
       "  policy %s (%s)%s\n"
       r.Complexity.policy_name
       r.Complexity.policy_digest
       (if r.Complexity.approved then "" else " [NOT APPROVED]") ) ;
  Buffer.add_string
    buf
    (Printf.sprintf
       "  profile: %s; compiler: %s; snapshot: %s; sort: %s\n"
       r.Complexity.profile
       r.Complexity.compiler
       r.Complexity.snapshot_digest
       r.Complexity.sort ) ;
  Buffer.add_string buf "  exclusions:\n" ;
  List.iter
    (fun e -> Buffer.add_string buf (Printf.sprintf "    - %s\n" e))
    r.Complexity.exclusions ;
  Buffer.add_string buf "  coverage:\n" ;
  List.iter
    (fun (c : Observation.file_coverage) ->
      Buffer.add_string
        buf
        (Printf.sprintf
           "    %s %s %s %d\n"
           c.Observation.cov_path
           (Complexity.provenance_name c.Observation.cov_provenance)
           c.Observation.cov_status
           c.Observation.cov_functions ) )
    r.Complexity.coverage ;
  if r.Complexity.gaps = []
  then Buffer.add_string buf "  gaps: none\n"
  else (
    Buffer.add_string buf "  gaps:\n" ;
    List.iter
      (fun (g : Observation.gap) ->
        Buffer.add_string
          buf
          (Printf.sprintf
             "    %s %s (%s)\n"
             g.Observation.gap_code
             g.Observation.gap_path
             g.Observation.gap_detail ) )
      r.Complexity.gaps ) ;
  List.iter
    (fun (e : Complexity.entry) ->
      let cc =
        match e.Complexity.complexity with
        | Some n -> string_of_int n
        | None -> "-"
      in
      let service =
        if e.Complexity.service = "" then "-" else e.Complexity.service
      in
      Buffer.add_string
        buf
        (Printf.sprintf
           "%s  %s  %s  %s  %s  %s  %s:%d:%d\n"
           e.Complexity.id
           cc
           e.Complexity.binding
           e.Complexity.provenance
           e.Complexity.ownership
           service
           e.Complexity.path
           e.Complexity.line
           e.Complexity.col ) )
    r.Complexity.functions ;
  let max_cc =
    match Complexity.max_complexity r.Complexity.functions with
    | Some n -> string_of_int n
    | None -> "-"
  in
  Buffer.add_string
    buf
    (Printf.sprintf
       "summary: %d function(s), %d measured, %d unmeasurable, max %s, %d gap(s)\n"
       (List.length r.Complexity.functions)
       (Complexity.measured_count r.Complexity.functions)
       (Complexity.unmeasurable_count r.Complexity.functions)
       max_cc
       (List.length r.Complexity.gaps) ) ;
  Buffer.contents buf

let complexity_json (r : Complexity.t) : string =
  let opt_int = function
    | Some n -> `Int n
    | None -> `Null
  in
  let jentry (e : Complexity.entry) =
    `Assoc
      [ ("id", `String e.Complexity.id)
      ; ("name", `String e.Complexity.name)
      ; ("qualname", `String e.Complexity.qualname)
      ; ("kind", `String e.Complexity.kind)
      ; ("binding", `String e.Complexity.binding)
      ; ("nested", `Bool e.Complexity.nested)
      ; ("provenance", `String e.Complexity.provenance)
      ; ("module", `String e.Complexity.module_path)
      ; ( "service"
        , if e.Complexity.service = ""
          then `Null
          else `String e.Complexity.service )
      ; ("ownership", `String e.Complexity.ownership)
      ; ( "location"
        , `Assoc
            [ ("path", `String e.Complexity.path)
            ; ("line", `Int e.Complexity.line)
            ; ("col", `Int e.Complexity.col) ] )
      ; ( "end"
        , `Assoc
            [ ("line", `Int e.Complexity.end_line)
            ; ("col", `Int e.Complexity.end_col) ] )
      ; ("complexity", opt_int e.Complexity.complexity)
      ; ("status", `String e.Complexity.status)
      ; ("metric", `String Version.complexity_metric) ]
  in
  let jcov (c : Observation.file_coverage) =
    `Assoc
      [ ("path", `String c.Observation.cov_path)
      ; ( "provenance"
        , `String (Complexity.provenance_name c.Observation.cov_provenance) )
      ; ("status", `String c.Observation.cov_status)
      ; ("functions", `Int c.Observation.cov_functions) ]
  in
  let jgap (g : Observation.gap) =
    `Assoc
      [ ("code", `String g.Observation.gap_code)
      ; ("path", `String g.Observation.gap_path)
      ; ("detail", `String g.Observation.gap_detail) ]
  in
  let max_cc = Complexity.max_complexity r.Complexity.functions in
  let json =
    `Assoc
      [ ("format", `String Version.complexity_format)
      ; ("metric", `String Version.complexity_metric)
      ; ("status", `String r.Complexity.status)
      ; ("sort", `String r.Complexity.sort)
      ; ( "inputs"
        , `Assoc
            [ ("policyName", `String r.Complexity.policy_name)
            ; ("policyDigest", `String r.Complexity.policy_digest)
            ; ("approved", `Bool r.Complexity.approved)
            ; ("profile", `String r.Complexity.profile)
            ; ( "programRoots"
              , `List (List.map (fun p -> `String p) r.Complexity.program_roots)
              )
            ; ("snapshotDigest", `String r.Complexity.snapshot_digest)
            ; ("compiler", `String r.Complexity.compiler)
            ; ("programAccess", `String Version.adapter_ocaml) ] )
      ; ("functions", `List (List.map jentry r.Complexity.functions))
      ; ("coverage", `List (List.map jcov r.Complexity.coverage))
      ; ("gaps", `List (List.map jgap r.Complexity.gaps))
      ; ( "exclusions"
        , `List (List.map (fun e -> `String e) r.Complexity.exclusions) )
      ; ( "summary"
        , `Assoc
            [ ("functions", `Int (List.length r.Complexity.functions))
            ; ( "measured"
              , `Int (Complexity.measured_count r.Complexity.functions) )
            ; ( "unmeasurable"
              , `Int (Complexity.unmeasurable_count r.Complexity.functions) )
            ; ("maxComplexity", opt_int max_cc)
            ; ("gaps", `Int (List.length r.Complexity.gaps)) ] ) ]
  in
  Yojson.Safe.to_string json ^ "\n"

let exit_code (r : Finding.report) : int =
  match r.Finding.status with
  | Ok -> 0
  | Violations -> 1
  | Incomplete -> 2

(* ── coverage rendering ───────────────────────────────────────────── *)

let measurement_json (m : Coverage.measurement) =
  match m with
  | Uninstrumented -> (`String "uninstrumented", `Bool false, `Null)
  | Measured {covered; total; executed} ->
      ( `String "measured"
      , `Bool executed
      , `Assoc [("covered", `Int covered); ("total", `Int total)] )

let crap_json = function
  | Coverage.Available score ->
      `Assoc [("status", `String "available"); ("score", `String score)]
  | Coverage.Unavailable reason ->
      `Assoc [("status", `String "unavailable"); ("reason", `String reason)]

let coverage_json (r : Coverage.report) =
  let func (f : Coverage.func) =
    let measurement, executed, points = measurement_json f.measurement in
    `Assoc
      [ ("id", `String f.id)
      ; ("path", `String f.path)
      ; ("name", `String f.name)
      ; ("kind", `String (Coverage.kind_string f.kind))
      ; ("provenance", `String f.provenance)
      ; ("line", `Int f.line)
      ; ("col", `Int f.col)
      ; ("measurement", measurement)
      ; ("executed", executed)
      ; ("points", points)
      ; ( "complexity"
        , match f.complexity with
          | Some n -> `Int n
          | None -> `Null )
      ; ("crap", crap_json f.crap) ]
  in
  let gap (g : Coverage.gap) =
    `Assoc
      [ ("code", `String g.code)
      ; ("message", `String g.message)
      ; ("path", `String g.path) ]
  in
  let node (n : Coverage.node) =
    let disposition, code, signal =
      match n.disposition with
      | Exited code -> ("exited", `Int code, `Null)
      | Signaled signal -> ("signaled", `Null, `String signal)
      | Unknown -> ("unknown", `Null, `Null)
    in
    `Assoc
      [ ("id", `String n.id)
      ; ("disposition", `String disposition)
      ; ("code", code)
      ; ("signal", signal)
      ; ("records", `Int n.records) ]
  in
  let engine (e : Coverage.engine) =
    let fields =
      [ ("name", `String e.name)
      ; ("version", `String e.version)
      ; ("kind", `String e.kind) ]
    in
    `Assoc
      ( match e.visits with
      | None -> fields
      | Some n -> fields @ [("visits", `Int n)] )
  in
  let scenario_status, scenario_exit =
    match r.scenario with
    | Passed code -> ("passed", `Int code)
    | Failed code -> ("failed", `Int code)
    | Not_run -> ("not-run", `Null)
  in
  let measured, unexecuted, uninstrumented =
    List.fold_left
      (fun (m, u, i) (f : Coverage.func) ->
        match f.measurement with
        | Uninstrumented -> (m, u, i + 1)
        | Measured {executed= true; _} -> (m + 1, u, i)
        | Measured {executed= false; _} -> (m + 1, u + 1, i) )
      (0, 0, 0)
      r.functions
  in
  let status =
    match r.status with
    | Complete -> "complete"
    | Incomplete -> "incomplete"
  in
  let json =
    `Assoc
      [ ("format", `String Version.coverage_format)
      ; ("status", `String status)
      ; ( "scenario"
        , `Assoc [("status", `String scenario_status); ("exit", scenario_exit)]
        )
      ; ("measurementWindow", `String r.measurement_window)
      ; ("coverageKind", `String r.coverage_kind)
      ; ("denominator", `String r.denominator)
      ; ("facade", `String r.facade)
      ; ("engines", `List (List.map engine r.engines))
      ; ("snapshotDigest", `String r.snapshot_digest)
      ; ("compiler", `String r.compiler)
      ; ("exclusions", `List (List.map (fun e -> `String e) r.exclusions))
      ; ( "summary"
        , `Assoc
            [ ("pointsCovered", `Int r.points_covered)
            ; ("pointsTotal", `Int r.points_total)
            ; ("functionsMeasured", `Int measured)
            ; ("functionsUnexecuted", `Int unexecuted)
            ; ("functionsUninstrumented", `Int uninstrumented)
            ; ("gaps", `Int (List.length r.gaps)) ] )
      ; ("functions", `List (List.map func r.functions))
      ; ("gaps", `List (List.map gap r.gaps))
      ; ("nodes", `List (List.map node r.nodes)) ]
  in
  Yojson.Safe.to_string json ^ "\n"

let coverage_text (r : Coverage.report) =
  let buf = Buffer.create 512 in
  let status =
    match r.status with
    | Complete -> "complete"
    | Incomplete -> "incomplete"
  in
  let scenario =
    match r.scenario with
    | Passed code -> Printf.sprintf "passed (%d)" code
    | Failed code -> Printf.sprintf "failed (%d)" code
    | Not_run -> "not-run"
  in
  Buffer.add_string
    buf
    (Printf.sprintf
       "szaniec coverage: %s; scenario %s; facade %s; snapshot %s\n"
       status
       scenario
       r.facade
       r.snapshot_digest ) ;
  Buffer.add_string
    buf
    (Printf.sprintf
       "  kind: %s; denominator: %s; window: %s; compiler: %s\n"
       r.coverage_kind
       r.denominator
       r.measurement_window
       r.compiler ) ;
  List.iter
    (fun (e : Coverage.engine) ->
      let visits =
        match e.visits with
        | None -> ""
        | Some n -> Printf.sprintf "; visits %d" n
      in
      Buffer.add_string
        buf
        (Printf.sprintf
           "  engine %s %s (%s)%s\n"
           e.name
           e.version
           e.kind
           visits ) )
    r.engines ;
  Buffer.add_string buf "  exclusions:\n" ;
  List.iter
    (fun e -> Buffer.add_string buf (Printf.sprintf "    - %s\n" e))
    r.exclusions ;
  Buffer.add_string
    buf
    (Printf.sprintf "  points: %d/%d\n" r.points_covered r.points_total) ;
  List.iter
    (fun (f : Coverage.func) ->
      let detail =
        match f.measurement with
        | Uninstrumented -> "uninstrumented"
        | Measured {covered; total; executed} ->
            Printf.sprintf
              "%s %d/%d"
              (if executed then "executed" else "unexecuted")
              covered
              total
      in
      Buffer.add_string buf (Printf.sprintf "  %s %s [%s]\n" f.id f.name detail) )
    r.functions ;
  List.iter
    (fun (g : Coverage.gap) ->
      Buffer.add_string
        buf
        (Printf.sprintf "gap [%s] %s (%s)\n" g.code g.message g.path) )
    r.gaps ;
  Buffer.contents buf

let coverage_exit (r : Coverage.report) =
  match (r.status, r.scenario) with
  | Complete, Passed _ -> 0
  | Complete, Failed _ -> 1
  | _ -> 2

let rec parse_supervise pass_env port command = function
  | [] -> (pass_env, port, List.rev command)
  | "--" :: rest -> (pass_env, port, List.rev command @ rest)
  | "--port" :: n :: rest ->
      parse_supervise pass_env (int_of_string n) command rest
  | "--pass-env" :: name :: rest ->
      parse_supervise (name :: pass_env) port command rest
  | arg :: rest -> parse_supervise pass_env port (arg :: command) rest

let rec parse_coverage project config json out keep inventory = function
  | [] -> (project, config, json, out, keep, inventory)
  | "--project-root" :: p :: rest ->
      parse_coverage p config json out keep inventory rest
  | "--config" :: p :: rest ->
      parse_coverage project p json out keep inventory rest
  | "--json" :: rest ->
      parse_coverage project config true out keep inventory rest
  | "--out" :: p :: rest ->
      parse_coverage project config json (Some p) keep inventory rest
  | "--keep-work" :: rest ->
      parse_coverage project config json out true inventory rest
  | "--function-inventory" :: p :: rest ->
      parse_coverage project config json out keep (Some p) rest
  | bad :: _ ->
      prerr_endline ("szaniec: unknown argument: " ^ bad) ;
      prerr_endline usage ;
      exit 2

let load_config project_root path =
  match Config.load ?project_root ?path () with
  | Ok config -> config
  | Error e ->
      prerr_endline ("szaniec: " ^ e) ;
      exit 2

let require_policy config =
  match Config.require_policy config with
  | Ok policy -> policy
  | Error e ->
      prerr_endline ("szaniec: " ^ e) ;
      exit 2

let run_coverage argv =
  let project, path, _, _, _, _ =
    parse_coverage "" "" false None false None argv
  in
  let config =
    load_config
      (if project = "" then None else Some project)
      (if path = "" then None else Some path)
  in
  let coverage =
    match config.Config.coverage with
    | Some coverage -> coverage
    | None ->
        prerr_endline ("szaniec: " ^ config.path ^ ": [coverage] is required") ;
        exit 2
  in
  let _, _, json, out, keep, inventory =
    parse_coverage
      config.project_root
      config.path
      coverage.json
      coverage.out
      coverage.keep_work
      coverage.function_inventory
      argv
  in
  let resolve = Config.resolve_path config.project_root in
  match
    Szaniec_inspection_manager.Coverage_run.run
      ~project_root:config.project_root
      ~config:coverage
      ~inventory:(Option.map resolve inventory)
      ~keep_work:keep
  with
  | Error message ->
      prerr_endline ("szaniec: " ^ message) ;
      exit 2
  | Ok report ->
      Option.iter
        (fun path ->
          let oc = open_out (resolve path) in
          Fun.protect
            ~finally:(fun () -> close_out_noerr oc)
            (fun () -> output_string oc (coverage_json report)) )
        out ;
      print_string (if json then coverage_json report else coverage_text report) ;
      exit (coverage_exit report)

let configured_args (config : Config.t) command =
  let defaults =
    { default_args with
      project_root= Some config.project_root
    ; config= Some config.path }
  in
  match command with
  | "check" ->
      let c = config.check in
      { defaults with
        rebuild= c.rebuild
      ; json= c.json
      ; out= c.out
      ; no_callgraph= c.no_callgraph }
  | "complexity" ->
      let c = config.complexity in
      {defaults with rebuild= c.rebuild; json= c.json; sort= c.sort}
  | "suggestions" ->
      let c = config.suggestions in
      { defaults with
        rebuild= c.rebuild
      ; json= c.json
      ; experimental= c.experimental
      ; model= c.model
      ; timeout_s= c.timeout
      ; budget_names= c.budget_names
      ; budget_pairs= c.budget_pairs
      ; budget_responsibility= c.budget_responsibility
      ; budget_complexity= c.budget_complexity
      ; cache= Some c.cache
      ; no_cache= c.no_cache
      ; refresh= c.refresh
      ; provider_fixture= c.provider_fixture
      ; decisions= Some c.decisions }
  | _ -> defaults

(* ── entry point ──────────────────────────────────────────────────── *)

let main () =
  let argv = List.tl (Array.to_list Sys.argv) in
  match argv with
  | "coverage" :: "supervise" :: rest ->
      let pass_env, port, command = parse_supervise [] 0 [] rest in
      if port <= 0
      then (
        prerr_endline "szaniec: coverage supervise requires --port" ;
        exit 2 ) ;
      Szaniec_inspection_manager.Coverage_run.supervise ~port ~pass_env command
  | "coverage" :: rest -> run_coverage rest
  | _ -> (
      let args = parse argv default_args in
      if args.command = ""
      then (
        prerr_endline usage ;
        exit 2 ) ;
      if args.command <> "complexity" && args.sort <> ""
      then (
        prerr_endline "szaniec: --sort is only valid with complexity" ;
        exit 2 ) ;
      let config = load_config args.project_root args.config in
      let args = parse argv (configured_args config args.command) in
      let root = config.project_root in
      let resolve = Config.resolve_path root in
      match args.command with
      | "approve" -> (
          let policy = require_policy config in
          match
            Config.write_approval
              config
              ~policy_name:policy.Policy.name
              ~policy_digest:(Policy.digest policy)
          with
          | Ok () ->
              Printf.printf
                "approved policy %s (digest recorded in %s)\n"
                policy.name
                config.path ;
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
            if Filename.is_relative raw then Filename.concat root raw else raw
          in
          match
            Szaniec_suggestion_manager.Suggestion_manager.record_decision
              ~path
              ~id:args.suggestion_id
              ~decision:args.decision
              ~rationale:args.rationale
          with
          | Ok () ->
              Printf.printf
                "recorded %s for %s\n"
                args.decision
                args.suggestion_id ;
              exit 0
          | Error e ->
              prerr_endline ("szaniec: " ^ e) ;
              exit 2 )
      | "suggestions" -> (
          let module S = Szaniec_suggestion_manager.Suggestion_manager in
          let program_roots = (require_policy config).Policy.program_roots in
          let decisions_path =
            let raw =
              Option.value
                ~default:"szaniec/suggestion-decisions.json"
                args.decisions
            in
            if Filename.is_relative raw then Filename.concat root raw else raw
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
          let api_candidates = config.suggestions.api_candidates in
          let cache_path =
            if args.no_cache
            then None
            else
              Some
                ( match args.cache with
                | Some p ->
                    if Filename.is_relative p then Filename.concat root p else p
                | None -> Filename.concat root "szaniec/suggestion-cache.json"
                )
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
              { S.project_root= root
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
      | "complexity" -> (
          let sort = if args.sort = "" then "location" else args.sort in
          if sort <> "location" && sort <> "complexity"
          then (
            prerr_endline
              ("szaniec: --sort must be location or complexity, not " ^ sort) ;
            exit 2 ) ;
          try
            let report =
              Szaniec_inspection_manager.Inspection_manager.complexity
                ~sort
                { Szaniec_inspection_manager.Inspection_manager.project_root=
                    root
                ; config
                ; rebuild= args.rebuild }
            in
            print_string
              ( if args.json
                then complexity_json report
                else complexity_text report ) ;
            exit (if report.Complexity.status = "ok" then 0 else 2)
          with
          | Szaniec_inspection_manager.Inspection_manager.Policy_error e ->
              prerr_endline ("szaniec: " ^ e) ;
              exit 2 )
      | "check" -> (
        try
          let report =
            Szaniec_inspection_manager.Inspection_manager.check
              { Szaniec_inspection_manager.Inspection_manager.project_root= root
              ; config
              ; rebuild= args.rebuild }
          in
          if not args.no_callgraph
          then write_callgraph report (Option.map resolve args.out) root ;
          print_string
            (if args.json then json_report report else text_report report) ;
          exit (exit_code report)
        with
        | Szaniec_inspection_manager.Inspection_manager.Policy_error e ->
            prerr_endline ("szaniec: " ^ e) ;
            exit 2 )
      | _ ->
          prerr_endline usage ;
          exit 2 )

let () =
  try main () with
  | Sys_error e ->
      prerr_endline ("szaniec: " ^ e) ;
      exit 2
  | Unix.Unix_error (e, fn, arg) ->
      prerr_endline ("szaniec: " ^ fn ^ " " ^ arg ^ ": " ^ Unix.error_message e) ;
      exit 2
