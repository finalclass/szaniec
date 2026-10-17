open Szaniec_model
open Szaniec_suggestion_manager.Suggestion_manager

let json_of_report (r : report) : string =
  let jloc (path, line, col) =
    `Assoc [("path", `String path); ("line", `Int line); ("col", `Int col)]
  in
  let opt_s = function
    | None -> `Null
    | Some s -> `String s
  in
  let opt_f = function
    | None -> `Null
    | Some f -> `Float f
  in
  let jjudgment (j : judgment) =
    `Assoc
      [ ("id", `String j.id)
      ; ("criterion", `String j.criterion)
      ; ("scope", `String j.scope)
      ; ("primitive", `String j.primitive)
      ; ("outcome", `String j.outcome)
      ; ("subjects", `List (List.map (fun s -> `String s) j.subjects))
      ; ("locations", `List (List.map jloc j.locations))
      ; ("ownershipRelation", opt_s j.ownership_relation)
      ; ("model", opt_s j.model)
      ; ("noul", opt_f j.noul)
      ; ("choice", opt_s j.choice)
      ; ("score", opt_f j.score)
      ; ("confidence", opt_f j.confidence)
      ; ( "probabilities"
        , `Assoc (List.map (fun (k, v) -> (k, `Float v)) j.probabilities) )
      ; ("message", opt_s j.message) ]
  in
  let jsuggestion (s : suggestion) =
    `Assoc
      [ ("id", `String s.id)
      ; ("criterion", `String s.criterion)
      ; ("scope", `String s.scope)
      ; ("origin", `String s.origin)
      ; ("message", `String s.message)
      ; ("subjects", `List (List.map (fun x -> `String x) s.subjects))
      ; ("locations", `List (List.map jloc s.locations))
      ; ("ownershipRelation", opt_s s.ownership_relation)
      ; ("decision", opt_s s.decision)
      ; ("rationale", opt_s s.rationale)
      ; ( "coaching"
        , Coaching.to_json
            (Coaching.for_suggestion
               ~criterion:s.criterion
               ~ownership_relation:s.ownership_relation ) ) ]
  in
  let uncertain =
    List.fold_left
      (fun n (j : judgment) -> if j.outcome = "uncertain" then n + 1 else n)
      0
      r.judgments
  in
  let json =
    `Assoc
      [ ("format", `String Version.suggestion_format)
      ; ("status", `String r.status)
      ; ("detail", `String r.detail)
      ; ("rubric", `String Version.suggestion_rubric)
      ; ( "inputs"
        , `Assoc
            [ ("snapshotDigest", `String r.snapshot_digest)
            ; ("modelRequested", `String r.model_requested)
            ; ("modelReturned", opt_s r.model_returned)
            ; ("cache", `String r.cache)
            ; ("experimental", `Bool r.experimental)
            ; ("catalogComplete", `Bool r.catalog_complete)
            ; ("inputTokens", `Int r.input_tokens)
            ; ("outputTokens", `Int r.output_tokens) ] )
      ; ( "categories"
        , `List
            (List.map
               (fun id ->
                 `Assoc
                   [ ("id", `String id)
                   ; ("scope", `String "experimental")
                   ; ("promotion", `String "not-evaluated") ] )
               (categories r.experimental) ) )
      ; ("suggestions", `List (List.map jsuggestion r.suggestions))
      ; ("judgments", `List (List.map jjudgment r.judgments))
      ; ( "criteriaNotRun"
        , `List
            (List.map
               (fun (id, reason) ->
                 `Assoc [("id", `String id); ("reason", `String reason)] )
               r.criteria_not_run ) )
      ; ( "gaps"
        , `List
            (List.map
               (fun (g : Function_def.gap) ->
                 `Assoc
                   [ ("code", `String g.code)
                   ; ("path", `String g.path)
                   ; ("detail", `String g.detail)
                   ; ("coaching", Coaching.to_json (Coaching.for_rule g.code))
                   ] )
               r.gaps ) )
      ; ( "summary"
        , `Assoc
            [ ("suggestions", `Int (List.length r.suggestions))
            ; ("uncertain", `Int uncertain)
            ; ("definitions", `Int r.definitions)
            ; ("gaps", `Int (List.length r.gaps)) ] ) ]
  in
  Yojson.Safe.to_string json ^ "\n"

let text_of_report (r : report) : string =
  let buf = Buffer.create 1024 in
  let coach = Coaching.render_once () in
  Buffer.add_string buf (Printf.sprintf "szaniec suggestions: %s\n" r.status) ;
  if r.detail <> ""
  then Buffer.add_string buf (Printf.sprintf "  detail: %s\n" r.detail) ;
  Buffer.add_string
    buf
    (Printf.sprintf
       "  rubric: %s; model requested: %s; model returned: %s\n"
       Version.suggestion_rubric
       r.model_requested
       (Option.value ~default:"-" r.model_returned) ) ;
  Buffer.add_string
    buf
    (Printf.sprintf
       "  cache: %s; experimental: %b; catalog complete: %b; snapshot: %s\n"
       r.cache
       r.experimental
       r.catalog_complete
       r.snapshot_digest ) ;
  Buffer.add_string buf "  categories:\n" ;
  List.iter
    (fun id ->
      Buffer.add_string
        buf
        (Printf.sprintf "    - %s experimental, not-evaluated\n" id) )
    (categories r.experimental) ;
  List.iter
    (fun (id, reason) ->
      Buffer.add_string
        buf
        (Printf.sprintf "  criterion not run: %s (%s)\n" id reason) )
    r.criteria_not_run ;
  List.iter
    (fun (s : suggestion) ->
      Buffer.add_string
        buf
        (Printf.sprintf
           "suggestion [%s/%s] %s\n"
           s.origin
           s.criterion
           s.message ) ;
      Buffer.add_string buf (Printf.sprintf "  id: %s\n" s.id) ;
      List.iter
        (fun (path, line, col) ->
          Buffer.add_string buf (Printf.sprintf "  at %s:%d:%d\n" path line col) )
        s.locations ;
      ( match s.decision with
      | Some d ->
          Buffer.add_string
            buf
            (Printf.sprintf
               "  decision: %s (%s)\n"
               d
               (Option.value ~default:"" s.rationale) )
      | None -> Buffer.add_string buf "  decision: undecided\n" ) ;
      coach
        buf
        (Coaching.for_suggestion
           ~criterion:s.criterion
           ~ownership_relation:s.ownership_relation ) )
    r.suggestions ;
  let uncertain =
    List.fold_left
      (fun n (j : judgment) -> if j.outcome = "uncertain" then n + 1 else n)
      0
      r.judgments
  in
  List.iter
    (fun (j : judgment) ->
      if j.outcome = "uncertain"
      then
        Buffer.add_string
          buf
          (Printf.sprintf "uncertain [%s] %s\n" j.criterion j.id) )
    r.judgments ;
  List.iter
    (fun (g : Function_def.gap) ->
      Buffer.add_string
        buf
        (Printf.sprintf "gap [%s] %s (%s)\n" g.code g.path g.detail) ;
      coach buf (Coaching.for_rule g.code) )
    r.gaps ;
  Buffer.add_string
    buf
    (Printf.sprintf
       "summary: %d suggestion(s), %d uncertain judgment(s), %d definition(s), \
        %d gap(s)\n"
       (List.length r.suggestions)
       uncertain
       r.definitions
       (List.length r.gaps) ) ;
  Buffer.contents buf
