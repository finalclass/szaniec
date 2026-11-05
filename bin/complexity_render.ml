(* CheckClient rendering of the complexity report (szaniec-complexity/1).
   The JSON report is one line starting with {"format":...: consumers
   locate it by that prefix. *)

open Szaniec_model

let text (r : Complexity.t) : string =
  let buf = Buffer.create 1024 in
  Buffer.add_string
    buf
    (Printf.sprintf
       "szaniec complexity %s (%s)\n"
       r.Complexity.status
       r.Complexity.metric ) ;
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
      Buffer.add_string
        buf
        (Printf.sprintf
           "%s  %s  %s  %s:%d:%d\n"
           e.Complexity.id
           cc
           e.Complexity.provenance
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

let json (r : Complexity.t) : string =
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
      ; ("nested", `Bool e.Complexity.nested)
      ; ("provenance", `String e.Complexity.provenance)
      ; ("module", `String e.Complexity.module_path)
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
      ; ("metric", `String r.Complexity.metric) ]
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
      ; ("metric", `String r.Complexity.metric)
      ; ("status", `String r.Complexity.status)
      ; ("sort", `String r.Complexity.sort)
      ; ( "inputs"
        , `Assoc
            [ ("profile", `String r.Complexity.profile)
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
