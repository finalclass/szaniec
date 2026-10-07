(* Fixed-provider tests for suggestion report composition. No network. *)

module S = Szaniec_suggestion_manager.Suggestion_manager
module R = Szaniec_suggestion_manager.Retrieve
module Cy = Szaniec_architecture_access.Cyrograf
module P = Szaniec_model_access.Jev_provider
open Szaniec_model

let failures = ref 0

let check name cond =
  if cond
  then Printf.printf "%s: ok\n" name
  else (
    Printf.printf "%s: FAIL\n" name ;
    failures := !failures + 1 )

let contains (hay : string) (needle : string) : bool =
  let n = String.length needle in
  let rec go i =
    if i + n > String.length hay
    then false
    else if String.sub hay i n = needle
    then true
    else go (i + 1)
  in
  n > 0 && go 0

let fn ?(parameters = []) ?(variables = []) ?(line = 1) id name body =
  { Function_def.id
  ; name
  ; unit_canonical= "App"
  ; source_path= "lib/example.ml"
  ; line
  ; col= 0
  ; end_line= line
  ; parameters
  ; variables
  ; binding_text= body
  ; body_text= body
  ; normalized_body= Function_def.normalize body
  ; comment_before= ""
  ; kind= "top-level"
  ; provenance= "authored"
  ; truncated= false
  ; source_status= "available" }

let service name =
  { Cy.svc_name= name
  ; svc_role= Cy.Manager
  ; svc_methods= [{Cy.m_name= "list_open"; m_request= "Req"; m_response= "Res"}]
  }

let services =
  {Cy.services= [service "Task_manager"; service "Notification_manager"]}

let catalog functions =
  { Function_def.snapshot_digest= "snap-1"
  ; compiler= "5.4"
  ; functions
  ; uses= []
  ; gaps= [] }

let request
    ?(cache_path = None)
    ?(refresh = false)
    ?(names = 12)
    ?(pairs = 6)
    ?(experimental = false)
    decisions =
  { S.project_root= "."
  ; program_roots= ["lib"]
  ; rebuild= false
  ; experimental
  ; budgets=
      { R.names
      ; pairs
      ; responsibility= 6
      ; complexity= 6
      ; experimental= 6
      ; body_chars= 1200 }
  ; model= "jev-latest"
  ; timeout_s= 5
  ; cache_path
  ; refresh
  ; provider= None
  ; decisions
  ; api_candidates= [] }

let body_a =
  "let trimmed = String.trim title in let lower = String.lowercase_ascii \
   trimmed in Buffer.contents buf"

let body_b =
  "let trimmed = String.trim title in let lower = String.lowercase_ascii \
   trimmed in extra Buffer.contents buf"

let choice which confidence =
  P.Choice
    { choice= which
    ; probabilities=
        [ ("acceptable", if which = "acceptable" then 0.9 else 0.05)
        ; ("misleading", if which = "misleading" then 0.9 else 0.05)
        ; ("uninformative", if which = "uninformative" then 0.9 else 0.0)
        ; ("insufficient-context", 0.05) ]
    ; confidence }

let noul n = P.Noul n

let provider answers calls =
  let found =
    List.map
      (fun (c : P.call) ->
        match List.assoc_opt c.P.id answers with
        | Some a -> (c.id, a)
        | None -> failwith ("unexpected question " ^ c.id) )
      calls
  in
  Ok
    { P.model= "fixture-model-1"
    ; answers= found
    ; input_tokens= 11
    ; output_tokens= 4 }

let fail _ = Error "timeout talking to the provider"

let ids_of report =
  List.map (fun (s : S.suggestion) -> s.S.id) report.S.suggestions

let () =
  let same_a =
    fn "App.Task_manager.Titles.normalize_title" "normalize_title" body_a
  in
  let same_b =
    fn
      "App.Task_manager.Titles.normalize_title_copy"
      "normalize_title_copy"
      body_a
  in
  let other =
    fn
      "App.Notification_manager.Titles.normalize_title"
      "normalize_title"
      body_a
  in
  let near = fn "App.Task_manager.Titles.clean_title" "clean_title" body_b in
  let bad =
    fn "App.Web_client.Names.x" "x" "String.uppercase_ascii (String.trim s)"
  in
  let good =
    fn
      "App.Web_client.Names.format_label"
      "format_label"
      "String.capitalize_ascii text"
  in
  let calls = ref 0 in
  let counting answers calls_in =
    incr calls ;
    provider answers calls_in
  in
  let exact =
    S.evaluate
      ~catalog:(catalog [same_a; same_b; good])
      ~services
      ~request:(request ~names:0 ~pairs:0 [])
      ~provider:fail
  in
  check "exact duplicate does not call the provider" (!calls = 0) ;
  check
    "exact duplicate same service"
    (List.exists
       (fun (s : S.suggestion) ->
         s.criterion = "exact-duplicate"
         && s.origin = "static"
         && s.ownership_relation = Some "same-service"
         && List.length s.subjects = 2 )
       exact.suggestions ) ;
  check
    "clear name is not judged"
    (not
       (List.exists
          (fun (j : S.judgment) ->
            List.mem "App.Web_client.Names.format_label" j.subjects )
          exact.judgments ) ) ;
  let cross =
    S.evaluate
      ~catalog:(catalog [same_a; other])
      ~services
      ~request:(request ~names:0 ~pairs:0 [])
      ~provider:fail
  in
  check
    "distinct service ownership is kept"
    (List.exists
       (fun (s : S.suggestion) ->
         s.ownership_relation = Some "distinct-services"
         && contains s.message "Do not merge" )
       cross.suggestions ) ;
  calls := 0 ;
  let semantic =
    S.evaluate
      ~catalog:(catalog [same_a; near])
      ~services
      ~request:(request ~names:0 [])
      ~provider:
        (counting
           [ ( "semantic-reuse:App.Task_manager.Titles.clean_title|App.Task_manager.Titles.normalize_title"
             , noul 0.91 ) ] )
  in
  check
    "semantic pair is a model judgment"
    (List.exists
       (fun (s : S.suggestion) ->
         s.criterion = "semantic-reuse"
         && s.origin = "model"
         && List.length s.subjects = 2 )
       semantic.suggestions ) ;
  let uncertain =
    S.evaluate
      ~catalog:(catalog [same_a; near])
      ~services
      ~request:(request ~names:0 [])
      ~provider:
        (provider
           [ ( "semantic-reuse:App.Task_manager.Titles.clean_title|App.Task_manager.Titles.normalize_title"
             , noul 0.5 ) ] )
  in
  check
    "mid noul stays uncertain and is not a suggestion"
    ( uncertain.suggestions = []
    && List.exists
         (fun (j : S.judgment) -> j.outcome = "uncertain")
         uncertain.judgments ) ;
  let down =
    S.evaluate
      ~catalog:(catalog [bad; good])
      ~services
      ~request:(request [])
      ~provider:
        (provider
           [("name-quality:App.Web_client.Names.x:x", choice "misleading" 0.88)] )
  in
  check
    "misleading name becomes a suggestion"
    (List.exists
       (fun (s : S.suggestion) -> s.id = "name-quality:App.Web_client.Names.x:x")
       down.suggestions ) ;
  check
    "acceptable names are absent"
    (not
       (List.exists
          (fun id ->
            String.starts_with
              ~prefix:"name-quality:App.Web_client.Names.format_label"
              id )
          (ids_of down) ) ) ;
  let unsure_name =
    S.evaluate
      ~catalog:(catalog [bad])
      ~services
      ~request:(request [])
      ~provider:
        (provider
           [("name-quality:App.Web_client.Names.x:x", choice "misleading" 0.2)] )
  in
  check
    "low confidence is uncertain"
    ( unsure_name.suggestions = []
    && List.exists
         (fun (j : S.judgment) -> j.outcome = "uncertain")
         unsure_name.judgments ) ;
  let broken =
    S.evaluate
      ~catalog:(catalog [bad; same_a; same_b])
      ~services
      ~request:(request ~names:4 ~pairs:0 [])
      ~provider:fail
  in
  check "provider failure is unavailable" (broken.S.status = "unavailable") ;
  check
    "provider failure does not report a finished review"
    (broken.suggestions = [] && broken.judgments = []) ;
  let cache = Filename.temp_file "szaniec-suggestion-cache" ".json" in
  let first =
    S.evaluate
      ~catalog:(catalog [bad])
      ~services
      ~request:(request ~cache_path:(Some cache) [])
      ~provider:
        (provider
           [ ( "name-quality:App.Web_client.Names.x:x"
             , choice "uninformative" 0.9 ) ] )
  in
  let second =
    S.evaluate
      ~catalog:(catalog [bad])
      ~services
      ~request:(request ~cache_path:(Some cache) [])
      ~provider:fail
  in
  check
    "cache hit replays without the provider"
    ( first.cache = "miss"
    && second.cache = "hit"
    && second.status = "available"
    && ids_of second = ids_of first ) ;
  let moved = {(catalog [bad]) with Function_def.snapshot_digest= "snap-2"} in
  let third =
    S.evaluate
      ~catalog:moved
      ~services
      ~request:(request ~cache_path:(Some cache) [])
      ~provider:
        (provider
           [("name-quality:App.Web_client.Names.x:x", choice "acceptable" 0.93)] )
  in
  check
    "changed snapshot misses the cache"
    (third.cache = "miss" && third.suggestions = []) ;
  let path = Filename.temp_file "szaniec-decisions" ".json" in
  Sys.remove path ;
  ( match
      S.record_decision
        ~path
        ~id:"name-quality:App.Web_client.Names.x:x"
        ~decision:"reject"
        ~rationale:"fixture name"
    with
  | Error e -> check ("record decision " ^ e) false
  | Ok () ->
      let again =
        S.evaluate
          ~catalog:(catalog [bad])
          ~services
          ~request:
            (request
               ~names:4
               ( match S.read_decisions path with
               | Ok items -> items
               | Error e -> failwith e ) )
          ~provider:
            (provider
               [ ( "name-quality:App.Web_client.Names.x:x"
                 , choice "misleading" 0.9 ) ] )
      in
      check
        "decision is attached and does not remove the suggestion"
        (List.exists
           (fun (s : S.suggestion) ->
             s.decision = Some "reject" && s.rationale = Some "fixture name" )
           again.suggestions ) ) ;
  check
    "empty rationale is rejected"
    ( match
        S.record_decision ~path ~id:"x" ~decision:"defer" ~rationale:"  "
      with
    | Error _ -> true
    | Ok () -> false ) ;
  if !failures = 0
  then Printf.printf "suggestions: all ok\n"
  else (
    Printf.printf "suggestions: %d failed\n" !failures ;
    exit 1 )
