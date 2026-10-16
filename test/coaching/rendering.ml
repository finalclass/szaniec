module S = Szaniec_suggestion_manager.Suggestion_manager
module J = Yojson.Safe.Util

let check label condition = if not condition then failwith label

let count text needle =
  let rec loop i n =
    if i + String.length needle > String.length text
    then n
    else if String.sub text i (String.length needle) = needle
    then loop (i + String.length needle) (n + 1)
    else loop (i + 1) n
  in
  loop 0 0

let selected criterion relation =
  Coaching.for_suggestion ~criterion ~ownership_relation:relation

let check_guide (g : Coaching.guide) =
  check "guide identity and intent" (g.id <> "" && g.intent <> "") ;
  List.iter
    (fun values ->
      check
        "nonempty actionable guide fields"
        (values <> [] && List.for_all (fun s -> s <> "") values) )
    [g.steps; g.avoid; g.verification] ;
  check "meaningful before/after example" (g.before <> "" && g.before <> g.after) ;
  let json = Coaching.to_json (Some g) in
  check
    "versioned JSON guide"
    (J.(json |> member "catalog" |> to_string) = "szaniec-coaching/1")

let suggestion id criterion relation : S.suggestion =
  { id
  ; criterion
  ; scope= "experimental"
  ; origin= "model"
  ; message= "Existing diagnostic " ^ id
  ; subjects= ["App.Tasks.operation"]
  ; locations= [("lib/tasks.ml", 7, 2)]
  ; ownership_relation= relation
  ; decision= Some "reject"
  ; rationale= Some "Different required behavior" }

let base =
  S.unavailable
    ~detail:""
    ~snapshot:"fixture-snapshot"
    ~model:"fixture-model"
    ~experimental:true
    ~definitions:5
    ~gaps:[]

let uncertain : S.judgment =
  { id= "uncertain-name"
  ; criterion= "name-quality"
  ; scope= "experimental"
  ; primitive= "choice"
  ; outcome= "uncertain"
  ; subjects= ["App.Tasks.operation"]
  ; locations= [("lib/tasks.ml", 7, 2)]
  ; ownership_relation= None
  ; model= Some "fixture-model"
  ; noul= None
  ; choice= Some "insufficient-context"
  ; score= None
  ; confidence= Some 0.5
  ; probabilities= []
  ; message= None }

let () =
  if Array.length Sys.argv = 2 && Sys.argv.(1) = "--catalog"
  then (
    let rules =
      List.concat_map
        (fun (rules, g) ->
          List.map (fun rule -> (rule, Coaching.to_json (Some g))) rules )
        Coaching.inspection_guides
    in
    let criteria =
      List.map
        (fun criterion ->
          (criterion, Coaching.to_json (selected criterion None)) )
        (S.categories true)
    in
    let reuse =
      List.map
        (fun relation ->
          ( relation
          , Coaching.to_json (selected "semantic-reuse" (Some relation)) ) )
        ["same-service"; "distinct-services"; "unclassified"]
    in
    print_endline
      (Yojson.Safe.to_string
         (`Assoc
            [ ("rules", `Assoc rules)
            ; ("criteria", `Assoc criteria)
            ; ("reuse", `Assoc reuse) ] ) ) ;
    exit 0 ) ;
  List.iter (fun (_, guide) -> check_guide guide) Coaching.inspection_guides ;
  List.iter (fun (_, guide) -> check_guide guide) Coaching.suggestion_guides ;
  List.iter
    (fun criterion ->
      check
        "every suggestion category has guidance"
        (selected criterion None <> None) )
    (S.categories true) ;
  List.iter
    (fun relation ->
      Option.iter check_guide (selected "semantic-reuse" relation) )
    [None; Some "same-service"; Some "distinct-services"; Some "ambiguous"] ;
  check "unknown rule stays uncoached" (Coaching.for_rule "FUTURE-RULE" = None) ;
  check
    "unknown category stays uncoached"
    (selected "future-category" None = None) ;
  check "missing guide JSON is explicit" (Coaching.to_json None = `Null) ;
  let id relation = Option.get (selected "exact-duplicate" relation) in
  check
    "same-owner reuse"
    ((id (Some "same-service")).id = "reuse-within-service") ;
  check
    "cross-owner reuse"
    ((id (Some "distinct-services")).id = "reuse-across-services") ;
  List.iter
    (fun relation ->
      check
        "unknown ownership cannot authorize reuse"
        ((id relation).id = "reuse-needs-ownership") )
    [None; Some "ambiguous"; Some "unclassified"; Some "future-relation"] ;
  let report =
    { base with
      status= "available"
    ; judgments= [uncertain]
    ; suggestions=
        [ suggestion "first" "exact-duplicate" (Some "same-service")
        ; suggestion "second" "semantic-reuse" (Some "same-service")
        ; suggestion "third" "exact-duplicate" (Some "distinct-services")
        ; suggestion "fourth" "complicated-construct" None
        ; suggestion "future" "future-category" None ]
    ; gaps=
        [ { Szaniec_model.Function_def.code= "GAP-SUGGESTION-NO-SOURCE"
          ; path= "lib/missing.ml"
          ; detail= "Missing slice" }
        ; { Szaniec_model.Function_def.code= "FUTURE-GAP"
          ; path= "lib/future.ml"
          ; detail= "Unknown evidence" } ] }
  in
  let text = Suggestion_render.text_of_report report in
  check "each diagnostic retained" (count text "Existing diagnostic" = 5) ;
  check "each source site retained" (count text "at lib/tasks.ml:7:2" = 5) ;
  check
    "each decision retained"
    (count text "decision: reject (Different required behavior)" = 5) ;
  check
    "same guide rendered once"
    (count text "coaching [szaniec-coaching/1/reuse-within-service]" = 1) ;
  check
    "ownership-specific guides remain distinct"
    (count text "coaching [szaniec-coaching/1/reuse-across-services]" = 1) ;
  check "unknown gap remains visible" (count text "gap [FUTURE-GAP]" = 1) ;
  check
    "no uncertain guide"
    (count text "coaching [szaniec-coaching/1/meaningful-name]" = 0) ;
  let json_text = Suggestion_render.json_of_report report in
  let json = Yojson.Safe.from_string json_text in
  let suggestions = J.(json |> member "suggestions" |> to_list) in
  check "every JSON suggestion retained" (List.length suggestions = 5) ;
  List.iter
    (fun item ->
      check
        "decision JSON unchanged"
        (J.(item |> member "decision" |> to_string) = "reject") )
    suggestions ;
  check
    "unknown suggestion has null guide"
    (J.(List.nth suggestions 4 |> member "coaching") = `Null) ;
  check
    "repeated JSON item has self-contained guide"
    ( J.(List.nth suggestions 0 |> member "coaching")
    = J.(List.nth suggestions 1 |> member "coaching") ) ;
  check
    "judgment remains uncoached"
    (not
       (List.mem_assoc
          "coaching"
          J.(json |> member "judgments" |> to_list |> List.hd |> to_assoc) ) ) ;
  check
    "uncertain summary preserved"
    (J.(json |> member "summary" |> member "uncertain" |> to_int) = 1) ;
  check
    "JSON rendering deterministic"
    (json_text = Suggestion_render.json_of_report report) ;
  check
    "render deduplication resets per report"
    (text = Suggestion_render.text_of_report report) ;
  let unavailable = {base with detail= "Provider unavailable"} in
  check
    "provider failure creates no guidance"
    (count (Suggestion_render.text_of_report unavailable) "coaching [" = 0) ;
  let clean = {base with status= "available"} in
  check
    "clean review creates no guidance"
    (count (Suggestion_render.text_of_report clean) "coaching [" = 0) ;
  print_endline
    "coaching: ownership, unknown evidence, decisions, deduplication and \
     deterministic rendering: ok"
