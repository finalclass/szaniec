(* SuggestionManager: candidate selection, typed judgments, report composition.
   It does not call ConformanceEngine or change check results. *)

open Szaniec_model
module P = Szaniec_model_access.Jev_provider
module Cy = Szaniec_architecture_access.Cyrograf

type decision =
  { suggestion_id: string
  ; decision: string
  ; rationale: string }

type judgment =
  { id: string
  ; criterion: string
  ; scope: string
  ; primitive: string
  ; outcome: string
  ; subjects: string list
  ; locations: (string * int * int) list
  ; ownership_relation: string option
  ; model: string option
  ; noul: float option
  ; choice: string option
  ; score: float option
  ; confidence: float option
  ; probabilities: (string * float) list
  ; message: string option }

type suggestion =
  { id: string
  ; criterion: string
  ; scope: string
  ; origin: string
  ; message: string
  ; subjects: string list
  ; locations: (string * int * int) list
  ; ownership_relation: string option
  ; decision: string option
  ; rationale: string option }

type report =
  { status: string
  ; detail: string
  ; snapshot_digest: string
  ; model_requested: string
  ; model_returned: string option
  ; cache: string
  ; experimental: bool
  ; catalog_complete: bool
  ; input_tokens: int
  ; output_tokens: int
  ; judgments: judgment list
  ; suggestions: suggestion list
  ; criteria_not_run: (string * string) list
  ; gaps: Function_def.gap list
  ; definitions: int }

type request =
  { project_root: string
  ; program_roots: string list
  ; rebuild: bool
  ; experimental: bool
  ; budgets: Retrieve.budgets
  ; model: string
  ; timeout_s: int
  ; cache_path: string option
  ; refresh: bool
  ; provider: P.t option
  ; decisions: decision list
  ; api_candidates: string list }

let sha256 (s : string) : string =
  "sha256:" ^ Digestif.SHA256.to_hex (Digestif.SHA256.digest_string s)

let categories experimental =
  let base =
    [ "exact-duplicate"
    ; "name-quality"
    ; "semantic-reuse"
    ; "responsibility-mix"
    ; "complicated-construct" ]
  in
  let extra =
    if experimental
    then
      [ "vocabulary-consistency"
      ; "predicate-clarity"
      ; "unexpected-effects"
      ; "mode-flags"
      ; "comment-mismatch"
      ; "unnecessary-indirection"
      ; "idiomatic-alternative" ]
    else []
  in
  base @ extra

let loc_of (o : Retrieve.owned) = (o.fn.source_path, o.fn.line, o.fn.col)

let decision_for (decisions : decision list) (id : string) =
  List.find_opt (fun d -> String.equal d.suggestion_id id) decisions

let suggest (j : judgment) (origin : string) (decisions : decision list) :
    suggestion option =
  match j.message with
  | None -> None
  | Some message ->
      let recorded = decision_for decisions j.id in
      let chosen =
        match recorded with
        | None -> None
        | Some (item : decision) -> Some item.decision
      in
      let why =
        match recorded with
        | None -> None
        | Some (item : decision) -> Some item.rationale
      in
      Some
        { id= j.id
        ; criterion= j.criterion
        ; scope= j.scope
        ; origin
        ; message
        ; subjects= j.subjects
        ; locations= j.locations
        ; ownership_relation= j.ownership_relation
        ; decision= chosen
        ; rationale= why }

let static_judgment (p : Retrieve.pair) : judgment =
  let id = "exact-duplicate:" ^ p.left.fn.id ^ "|" ^ p.right.fn.id in
  { id
  ; criterion= "exact-duplicate"
  ; scope= "experimental"
  ; primitive= "static"
  ; outcome= "suggestion"
  ; subjects= [p.left.fn.id; p.right.fn.id]
  ; locations= [loc_of p.left; loc_of p.right]
  ; ownership_relation= Some p.relation
  ; model= None
  ; noul= None
  ; choice= None
  ; score= None
  ; confidence= None
  ; probabilities= []
  ; message= Some (Rubric.exact_message p) }

let floats_of probs =
  List.sort (fun a b -> String.compare (fst a) (fst b)) probs

type classified =
  { outcome: string
  ; choice: string option
  ; score: float option
  ; noul: float option
  ; confidence: float option
  ; probabilities: (string * float) list }

let outcome_of_answer (criterion : string) (answer : P.answer) : classified =
  match answer with
  | P.Noul n ->
      let outcome =
        if String.equal criterion "semantic-reuse"
        then
          if n >= 0.75
          then "suggestion"
          else if n >= 0.40
          then "uncertain"
          else "no-issue"
        else if n >= 0.72
        then "suggestion"
        else if n >= 0.40
        then "uncertain"
        else "no-issue"
      in
      { outcome
      ; choice= None
      ; score= None
      ; noul= Some n
      ; confidence= None
      ; probabilities= [] }
  | P.Choice {choice; probabilities; confidence} ->
      let outcome =
        if String.equal choice "insufficient-context" || confidence < 0.60
        then "uncertain"
        else if
          String.equal choice "misleading"
          || String.equal choice "uninformative"
          || String.equal choice "inconsistent"
        then "suggestion"
        else "no-issue"
      in
      { outcome
      ; choice= Some choice
      ; score= None
      ; noul= None
      ; confidence= Some confidence
      ; probabilities= floats_of probabilities }
  | P.Score {score; probabilities; confidence; _} ->
      let outcome =
        if score >= 1.40 && confidence >= 0.55
        then "suggestion"
        else if confidence < 0.55 && score >= 1.00
        then "uncertain"
        else "no-issue"
      in
      { outcome
      ; choice= None
      ; score= Some score
      ; noul= None
      ; confidence= Some confidence
      ; probabilities= floats_of probabilities }

let message_for
    ~criterion
    ~outcome
    ~choice
    (call : P.call)
    (sel : Retrieve.selection) : string option =
  if not (String.equal outcome "suggestion")
  then None
  else
    match criterion with
    | "name-quality" -> (
      match choice with
      | Some (("misleading" | "uninformative") as which) ->
          let subject =
            match String.rindex_opt call.id ':' with
            | Some i ->
                String.sub call.id (i + 1) (String.length call.id - i - 1)
            | None -> ""
          in
          let id =
            match call.id with
            | _ -> (
                let rest =
                  let prefix = "name-quality:" in
                  String.sub
                    call.id
                    (String.length prefix)
                    (String.length call.id - String.length prefix)
                in
                match String.rindex_opt rest ':' with
                | Some i -> String.sub rest 0 i
                | None -> rest )
          in
          Some (Rubric.name_message ~id ~name:subject ~choice:which)
      | Some _
       |None ->
          None )
    | "semantic-reuse" ->
        let pair =
          List.find_opt
            (fun (p : Retrieve.pair) ->
              String.equal
                call.id
                ("semantic-reuse:" ^ p.left.fn.id ^ "|" ^ p.right.fn.id) )
            sel.pairs
        in
        Option.map Rubric.semantic_message pair
    | "responsibility-mix"
     |"complicated-construct" ->
        let id =
          let prefix = criterion ^ ":" in
          String.sub
            call.id
            (String.length prefix)
            (String.length call.id - String.length prefix)
        in
        Some (Rubric.plain ~criterion ~id)
    | _ ->
        let id = call.id in
        Some (Rubric.plain ~criterion ~id)

let subjects_of (call : P.call) (sel : Retrieve.selection) :
    string list * (string * int * int) list * string option =
  let find_name id =
    List.find_opt
      (fun (h : Retrieve.name_hit) -> String.equal h.owned.fn.id id)
      (sel.names @ sel.predicates)
  in
  if String.equal call.criterion "semantic-reuse"
  then
    match
      List.find_opt
        (fun (p : Retrieve.pair) ->
          String.equal
            call.id
            ("semantic-reuse:" ^ p.left.fn.id ^ "|" ^ p.right.fn.id) )
        sel.pairs
    with
    | Some p ->
        ( [p.left.fn.id; p.right.fn.id]
        , [loc_of p.left; loc_of p.right]
        , Some p.relation )
    | None -> ([], [], None)
  else if String.starts_with ~prefix:"vocabulary-consistency:" call.id
  then
    let prefix = "vocabulary-consistency:" in
    let path =
      String.sub
        call.id
        (String.length prefix)
        (String.length call.id - String.length prefix)
    in
    ([path], [], None)
  else
    let body =
      match String.index_opt call.id ':' with
      | Some i -> String.sub call.id (i + 1) (String.length call.id - i - 1)
      | None -> call.id
    in
    let fn_id =
      match String.rindex_opt body ':' with
      | Some i
        when call.criterion = "name-quality"
             || call.criterion = "predicate-clarity"
             || call.criterion = "idiomatic-alternative" ->
          String.sub body 0 i
      | _ -> body
    in
    match find_name fn_id with
    | Some h -> ([h.owned.fn.id], [loc_of h.owned], None)
    | None -> (
        let owned =
          List.find_opt
            (fun (o : Retrieve.owned) -> String.equal o.fn.id fn_id)
            ( sel.responsibility
            @ sel.complexity
            @ sel.effects
            @ sel.modes
            @ sel.comments
            @ sel.indirections )
        in
        match owned with
        | Some o -> ([o.fn.id], [loc_of o], None)
        | None -> ([fn_id], [], None) )

let judgment_of
    ~(model : string)
    (sel : Retrieve.selection)
    (call : P.call)
    (answer : P.answer) : judgment =
  let classified = outcome_of_answer call.criterion answer in
  let subjects, locations, relation = subjects_of call sel in
  { id= call.id
  ; criterion= call.criterion
  ; scope= "experimental"
  ; primitive= call.primitive
  ; outcome= classified.outcome
  ; subjects
  ; locations
  ; ownership_relation= relation
  ; model= Some model
  ; noul= classified.noul
  ; choice= classified.choice
  ; score= classified.score
  ; confidence= classified.confidence
  ; probabilities= classified.probabilities
  ; message=
      message_for
        ~criterion:call.criterion
        ~outcome:classified.outcome
        ~choice:classified.choice
        call
        sel }

let cache_key
    ~(model : string)
    ~(experimental : bool)
    (budgets : Retrieve.budgets)
    ~(snapshot : string)
    (calls : P.call list) : string =
  let calls =
    List.sort (fun a b -> String.compare a.P.id b.P.id) calls
    |> List.map (fun (c : P.call) ->
        c.id
        ^ "\n"
        ^ Yojson.Safe.to_string c.state
        ^ "\n"
        ^ Yojson.Safe.to_string c.question )
    |> String.concat "\n"
  in
  sha256
    (String.concat
       "\n"
       [ Version.suggestion_rubric
       ; model
       ; string_of_bool experimental
       ; string_of_int budgets.names
       ; string_of_int budgets.pairs
       ; string_of_int budgets.responsibility
       ; string_of_int budgets.complexity
       ; string_of_int budgets.experimental
       ; string_of_int budgets.body_chars
       ; snapshot
       ; calls ] )

let answer_json = P.answer_to_json

let parse_cached_answer json =
  match P.parse_answer json with
  | Ok a -> Some a
  | Error _ -> None

let read_cache (path : string) : (string * Yojson.Safe.t) list =
  match Yojson.Safe.from_file path with
  | exception _ -> []
  | `Assoc fields -> (
    match List.assoc_opt "entries" fields with
    | Some (`List entries) ->
        List.filter_map
          (fun entry ->
            match entry with
            | `Assoc e -> (
              match (List.assoc_opt "key" e, List.assoc_opt "payload" e) with
              | Some (`String k), Some payload -> Some (k, payload)
              | _ -> None )
            | _ -> None )
          entries
    | _ -> [] )
  | _ -> []

let write_cache (path : string) (entries : (string * Yojson.Safe.t) list) =
  let entries =
    if List.length entries > 32
    then List.filteri (fun i _ -> i >= List.length entries - 32) entries
    else entries
  in
  let dir = Filename.dirname path in
  ( try Unix.mkdir dir 0o755 with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
  let json =
    `Assoc
      [ ("format", `String Version.suggestion_cache_format)
      ; ( "entries"
        , `List
            (List.map
               (fun (k, payload) ->
                 `Assoc [("key", `String k); ("payload", payload)] )
               entries ) ) ]
  in
  let oc = open_out path in
  output_string oc (Yojson.Safe.to_string json ^ "\n") ;
  close_out oc

let payload_of (batch : P.batch) : Yojson.Safe.t =
  `Assoc
    [ ("model", `String batch.model)
    ; ("inputTokens", `Int batch.input_tokens)
    ; ("outputTokens", `Int batch.output_tokens)
    ; ( "answers"
      , `Assoc
          (List.map
             (fun (id, answer) -> (id, answer_json answer))
             (List.sort
                (fun a b -> String.compare (fst a) (fst b))
                batch.answers ) ) ) ]

let batch_of_payload (payload : Yojson.Safe.t) (calls : P.call list) :
    (P.batch, string) result =
  match payload with
  | `Assoc fields -> (
    match
      ( List.assoc_opt "model" fields
      , List.assoc_opt "answers" fields
      , List.assoc_opt "inputTokens" fields
      , List.assoc_opt "outputTokens" fields )
    with
    | ( Some (`String model)
      , Some (`Assoc answers)
      , Some (`Int input_tokens)
      , Some (`Int output_tokens) ) -> (
        let rec take acc = function
          | [] -> Ok (List.rev acc)
          | call :: rest -> (
            match List.assoc_opt call.P.id answers with
            | None -> Error ("cache omitted answer for " ^ call.id)
            | Some json -> (
              match parse_cached_answer json with
              | None -> Error ("cache answer is unreadable for " ^ call.id)
              | Some answer -> take ((call.id, answer) :: acc) rest ) )
        in
        match take [] calls with
        | Error e -> Error e
        | Ok answers -> Ok {P.model; answers; input_tokens; output_tokens} )
    | _ -> Error "suggestion cache entry is incomplete" )
  | _ -> Error "suggestion cache entry is not an object"

let lookup_cache (path : string) (key : string) (calls : P.call list) =
  match List.assoc_opt key (read_cache path) with
  | None -> None
  | Some payload -> (
    match batch_of_payload payload calls with
    | Ok batch -> Some batch
    | Error _ -> None )

let store_cache (path : string) (key : string) (batch : P.batch) =
  let entries = List.remove_assoc key (read_cache path) in
  write_cache path (entries @ [(key, payload_of batch)])

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
      ; ("rationale", opt_s s.rationale) ]
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
                   ; ("detail", `String g.detail) ] )
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
      match s.decision with
      | Some d ->
          Buffer.add_string
            buf
            (Printf.sprintf
               "  decision: %s (%s)\n"
               d
               (Option.value ~default:"" s.rationale) )
      | None -> Buffer.add_string buf "  decision: undecided\n" )
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
        (Printf.sprintf "gap [%s] %s (%s)\n" g.code g.path g.detail) )
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

let sort_judgments (xs : judgment list) : judgment list =
  List.sort (fun (a : judgment) (b : judgment) -> String.compare a.id b.id) xs

let unavailable ~detail ~snapshot ~model ~experimental ~definitions ~gaps =
  { status= "unavailable"
  ; detail
  ; snapshot_digest= snapshot
  ; model_requested= model
  ; model_returned= None
  ; cache= "not-used"
  ; experimental
  ; catalog_complete= gaps = []
  ; input_tokens= 0
  ; output_tokens= 0
  ; judgments= []
  ; suggestions= []
  ; criteria_not_run= []
  ; gaps
  ; definitions }

let env_unsets () =
  Unix.environment ()
  |> Array.to_list
  |> List.filter_map (fun entry ->
      let k =
        match String.index_opt entry '=' with
        | Some i -> String.sub entry 0 i
        | None -> entry
      in
      let starts prefix =
        String.length k >= String.length prefix
        && String.sub k 0 (String.length prefix) = prefix
      in
      if
        starts "DUNE_"
        || starts "OCAML"
        || starts "CAML_"
        || k = "BUILD_PATH_PREFIX_MAP"
        || k = "INSIDE_DUNE"
      then Some k
      else None )
  |> List.sort_uniq String.compare
  |> String.concat " "

let rebuild (project_root : string) : (unit, string) result =
  let old = Sys.getcwd () in
  ( try Unix.chdir project_root with
  | Sys_error _ -> () ) ;
  let code =
    Sys.command ("unset " ^ env_unsets () ^ "; DUNE_CACHE=disabled dune build")
  in
  ( try Unix.chdir old with
  | Sys_error _ -> () ) ;
  if code = 0 then Ok () else Error "dune build failed before suggestions"

let load_api_candidates (path : string) : (string list, string) result =
  match Yojson.Safe.from_file path with
  | `List items ->
      Ok
        (List.filter_map
           (fun i ->
             match i with
             | `String s -> Some s
             | _ -> None )
           items )
  | _ -> Error "API candidate file must be a JSON array of strings"
  | exception _ -> Error "API candidate file is not valid JSON"

let criteria_not_run ~experimental ~api_candidates =
  if not experimental
  then
    [ ( "idiomatic-alternative"
      , "experimental criteria are off; pass --experimental to ask them" ) ]
  else if api_candidates = []
  then [("idiomatic-alternative", "no API candidate list supplied")]
  else []

let evaluate
    ~(catalog : Function_def.catalog)
    ~(services : Cy.t)
    ~(request : request)
    ~(provider : P.t) : report =
  let sel =
    Retrieve.select
      ~functions:catalog.functions
      ~services
      ~experimental:request.experimental
      request.budgets
  in
  let calls =
    Rubric.questions
      ~body_chars:request.budgets.body_chars
      ~experimental:request.experimental
      ~api_candidates:request.api_candidates
      catalog.uses
      sel
  in
  let static = List.map static_judgment sel.exact in
  let not_run =
    criteria_not_run
      ~experimental:request.experimental
      ~api_candidates:request.api_candidates
  in
  let finish ~cache ~batch =
    let model_judgments =
      List.map
        (fun (call : P.call) ->
          let answer = List.assoc call.id batch.P.answers in
          judgment_of ~model:batch.P.model sel call answer )
        calls
    in
    let judgments = sort_judgments (static @ model_judgments) in
    let suggestions =
      List.filter_map
        (fun (j : judgment) ->
          let origin =
            if String.equal j.primitive "static" then "static" else "model"
          in
          if String.equal j.outcome "suggestion"
          then suggest j origin request.decisions
          else None )
        judgments
    in
    { status= "available"
    ; detail= ""
    ; snapshot_digest= catalog.snapshot_digest
    ; model_requested= request.model
    ; model_returned= Some batch.P.model
    ; cache
    ; experimental= request.experimental
    ; catalog_complete= catalog.gaps = []
    ; input_tokens= batch.input_tokens
    ; output_tokens= batch.output_tokens
    ; judgments
    ; suggestions
    ; criteria_not_run= not_run
    ; gaps= catalog.gaps
    ; definitions= List.length catalog.functions }
  in
  if calls = []
  then
    finish
      ~cache:"not-used"
      ~batch:
        {P.model= request.model; answers= []; input_tokens= 0; output_tokens= 0}
  else
    let key =
      cache_key
        ~model:request.model
        ~experimental:request.experimental
        request.budgets
        ~snapshot:catalog.snapshot_digest
        calls
    in
    match request.cache_path with
    | Some path when not request.refresh -> (
      match lookup_cache path key calls with
      | Some batch -> finish ~cache:"hit" ~batch
      | None -> (
        match provider calls with
        | Error detail ->
            unavailable
              ~detail
              ~snapshot:catalog.snapshot_digest
              ~model:request.model
              ~experimental:request.experimental
              ~definitions:(List.length catalog.functions)
              ~gaps:catalog.gaps
        | Ok batch ->
            store_cache path key batch ;
            finish ~cache:"miss" ~batch ) )
    | Some path -> (
      match provider calls with
      | Error detail ->
          unavailable
            ~detail
            ~snapshot:catalog.snapshot_digest
            ~model:request.model
            ~experimental:request.experimental
            ~definitions:(List.length catalog.functions)
            ~gaps:catalog.gaps
      | Ok batch ->
          store_cache path key batch ;
          finish ~cache:"refreshed" ~batch )
    | None -> (
      match provider calls with
      | Error detail ->
          unavailable
            ~detail
            ~snapshot:catalog.snapshot_digest
            ~model:request.model
            ~experimental:request.experimental
            ~definitions:(List.length catalog.functions)
            ~gaps:catalog.gaps
      | Ok batch -> finish ~cache:"disabled" ~batch )

let run (request : request) : (report, string) result =
  let open_result =
    match request.rebuild with
    | false -> Ok ()
    | true -> rebuild request.project_root
  in
  match open_result with
  | Error e -> Error e
  | Ok () -> (
      let services =
        Cy.load
          ~project_root:request.project_root
          ~program_roots:request.program_roots
      in
      match services with
      | Error e -> Error e
      | Ok services ->
          let catalog =
            Szaniec_program_access.Function_catalog.collect
              ~project_root:request.project_root
              ~program_roots:request.program_roots
              ~assume_fresh:request.rebuild
              ()
          in
          let provider =
            match request.provider with
            | Some p -> p
            | None -> P.http ~timeout_s:request.timeout_s ~model:request.model
          in
          Ok (evaluate ~catalog ~services ~request ~provider) )

let read_decisions (path : string) : (decision list, string) result =
  if not (Sys.file_exists path)
  then Ok []
  else
    match Yojson.Safe.from_file path with
    | exception _ ->
        Error (Printf.sprintf "decision file %s is not valid JSON" path)
    | `Assoc fields -> (
      match
        (List.assoc_opt "format" fields, List.assoc_opt "decisions" fields)
      with
      | Some (`String fmt), Some (`List items)
        when String.equal fmt Version.suggestion_decisions_format ->
          let rec take acc = function
            | [] -> Ok (List.rev acc)
            | `Assoc item :: rest -> (
              match
                ( List.assoc_opt "suggestionId" item
                , List.assoc_opt "decision" item
                , List.assoc_opt "rationale" item )
              with
              | ( Some (`String id)
                , Some (`String decision)
                , Some (`String rationale) )
                when List.mem decision ["apply"; "reject"; "defer"]
                     && rationale <> "" ->
                  take ({suggestion_id= id; decision; rationale} :: acc) rest
              | _ -> Error "a decision record is incomplete" )
            | _ -> Error "a decision record is not an object"
          in
          take [] items
      | _ -> Error "decision file has the wrong format" )
    | _ -> Error "decision file is not an object"

let write_decisions (path : string) (items : decision list) =
  let items =
    List.sort (fun a b -> String.compare a.suggestion_id b.suggestion_id) items
  in
  let dir = Filename.dirname path in
  ( try Unix.mkdir dir 0o755 with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
  let json =
    `Assoc
      [ ("format", `String Version.suggestion_decisions_format)
      ; ( "decisions"
        , `List
            (List.map
               (fun d ->
                 `Assoc
                   [ ("suggestionId", `String d.suggestion_id)
                   ; ("decision", `String d.decision)
                   ; ("rationale", `String d.rationale) ] )
               items ) ) ]
  in
  let oc = open_out path in
  output_string oc (Yojson.Safe.to_string json ^ "\n") ;
  close_out oc

let record_decision
    ~(path : string)
    ~(id : string)
    ~(decision : string)
    ~(rationale : string) : (unit, string) result =
  if id = ""
  then Error "suggestion id is required"
  else if not (List.mem decision ["apply"; "reject"; "defer"])
  then Error "decision must be apply, reject, or defer"
  else if String.trim rationale = ""
  then Error "a rationale is required"
  else
    match read_decisions path with
    | Error e -> Error e
    | Ok existing ->
        let kept =
          List.filter (fun d -> not (String.equal d.suggestion_id id)) existing
        in
        write_decisions path ({suggestion_id= id; decision; rationale} :: kept) ;
        Ok ()

let exit_code (r : report) : int =
  if r.status <> "available" || r.gaps <> [] then 2 else 0
