(* ModelAccess for Jev. Typed questions in, typed answers out.
   The API key stays in the environment and is never recorded. *)

open Szaniec_model

type answer =
  | Noul of float
  | Choice of
      { choice: string
      ; probabilities: (string * float) list
      ; confidence: float }
  | Score of
      { score: float
      ; legend: (string * string) list
      ; probabilities: (string * float) list
      ; confidence: float }

type call =
  { id: string
  ; criterion: string
  ; primitive: string
  ; state: Yojson.Safe.t
  ; question: Yojson.Safe.t }

type batch =
  { model: string
  ; answers: (string * answer) list
  ; input_tokens: int
  ; output_tokens: int }

type t = call list -> (batch, string) result

let empty_batch model = {model; answers= []; input_tokens= 0; output_tokens= 0}

let assoc (json : Yojson.Safe.t) : (string * Yojson.Safe.t) list =
  match json with
  | `Assoc fields -> fields
  | _ -> []

let field name fields = List.assoc_opt name fields

let float_field name fields =
  match field name fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

let string_field name fields =
  match field name fields with
  | Some (`String s) -> Some s
  | _ -> None

let float_map (json : Yojson.Safe.t) : (string * float) list =
  assoc json
  |> List.filter_map (fun (k, v) ->
      match v with
      | `Float f -> Some (k, f)
      | `Int i -> Some (k, float_of_int i)
      | _ -> None )
  |> List.sort (fun a b -> String.compare (fst a) (fst b))

let string_map (json : Yojson.Safe.t) : (string * string) list =
  assoc json
  |> List.filter_map (fun (k, v) ->
      match v with
      | `String s -> Some (k, s)
      | _ -> None )
  |> List.sort (fun a b -> String.compare (fst a) (fst b))

let parse_answer (json : Yojson.Safe.t) : (answer, string) result =
  let fields = assoc json in
  match string_field "type" fields with
  | Some "noul" -> (
    match float_field "noul" fields with
    | Some n -> Ok (Noul n)
    | None -> Error "noul answer is missing noul" )
  | Some "choice" -> (
    match
      ( string_field "choice" fields
      , field "probabilities" fields
      , float_field "confidence" fields )
    with
    | Some choice, Some probs, Some confidence ->
        Ok (Choice {choice; probabilities= float_map probs; confidence})
    | _ -> Error "choice answer is incomplete" )
  | Some "score" -> (
    match
      ( float_field "score" fields
      , field "legend" fields
      , field "probabilities" fields
      , float_field "confidence" fields )
    with
    | Some score, Some legend, Some probs, Some confidence ->
        Ok
          (Score
             { score
             ; legend= string_map legend
             ; probabilities= float_map probs
             ; confidence } )
    | _ -> Error "score answer is incomplete" )
  | Some other -> Error ("unknown answer type " ^ other)
  | None -> Error "answer is missing type"

let answer_to_json (a : answer) : Yojson.Safe.t =
  let floats xs = `Assoc (List.map (fun (k, v) -> (k, `Float v)) xs) in
  match a with
  | Noul n -> `Assoc [("type", `String "noul"); ("noul", `Float n)]
  | Choice {choice; probabilities; confidence} ->
      `Assoc
        [ ("type", `String "choice")
        ; ("choice", `String choice)
        ; ("probabilities", floats probabilities)
        ; ("confidence", `Float confidence) ]
  | Score {score; legend; probabilities; confidence} ->
      `Assoc
        [ ("type", `String "score")
        ; ("score", `Float score)
        ; ("legend", `Assoc (List.map (fun (k, v) -> (k, `String v)) legend))
        ; ("probabilities", floats probabilities)
        ; ("confidence", `Float confidence) ]

let primitive_of_answer = function
  | Noul _ -> "noul"
  | Choice _ -> "choice"
  | Score _ -> "score"

let fixture_of_file (path : string) : (t, string) result =
  match Yojson.Safe.from_file path with
  | exception _ ->
      Error (Printf.sprintf "provider fixture %s is not valid JSON" path)
  | json -> (
    match json with
    | `Assoc fields -> (
        let model =
          match string_field "model" fields with
          | Some m -> m
          | None -> "fixture-model"
        in
        let fail = string_field "fail" fields in
        let on_missing =
          match string_field "onMissing" fields with
          | Some s -> s
          | None -> "error"
        in
        let answers =
          match field "answers" fields with
          | Some (`Assoc xs) -> xs
          | _ -> []
        in
        let defaults =
          match field "defaults" fields with
          | Some (`Assoc xs) -> xs
          | _ -> []
        in
        match string_field "format" fields with
        | Some fmt when String.equal fmt Version.suggestion_fixture_format ->
            let provider (calls : call list) =
              match fail with
              | Some detail -> Error detail
              | None -> (
                  let rec take acc = function
                    | [] -> Ok (List.rev acc)
                    | call :: rest -> (
                      match List.assoc_opt call.id answers with
                      | Some json -> (
                        match parse_answer json with
                        | Error e ->
                            Error (Printf.sprintf "%s for %s" e call.id)
                        | Ok answer ->
                            if
                              not
                                (String.equal
                                   (primitive_of_answer answer)
                                   call.primitive )
                            then
                              Error
                                ("fixture answer type mismatch for " ^ call.id)
                            else take ((call.id, answer) :: acc) rest )
                      | None -> (
                        match List.assoc_opt call.primitive defaults with
                        | Some json when on_missing = "default" -> (
                          match parse_answer json with
                          | Error e -> Error e
                          | Ok answer -> take ((call.id, answer) :: acc) rest )
                        | _ -> Error ("fixture has no answer for " ^ call.id) )
                      )
                  in
                  match take [] calls with
                  | Error e -> Error e
                  | Ok answers ->
                      Ok {model; answers; input_tokens= 0; output_tokens= 0} )
            in
            Ok provider
        | _ ->
            Error
              (Printf.sprintf "provider fixture %s has the wrong format" path) )
    | _ -> Error (Printf.sprintf "provider fixture %s is not an object" path) )

let write_file (path : string) (contents : string) =
  let oc = open_out_bin path in
  output_string oc contents ;
  close_out oc

let read_file (path : string) : string =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic ;
  s

let short_message (body : string) : string =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
    match string_field "message" fields with
    | Some s when String.length s <= 180 && not (String.contains s '\n') ->
        ": " ^ s
    | _ -> "" )
  | _ -> ""
  | exception _ -> ""

let post_once ~(timeout_s : int) ~(payload : string) :
    (int * string, string) result =
  let payload_path = Filename.temp_file "szaniec-jev" ".json" in
  let response_path = Filename.temp_file "szaniec-jev" ".out" in
  let status_path = Filename.temp_file "szaniec-jev" ".status" in
  let cleanup () =
    List.iter
      (fun p ->
        try Sys.remove p with
        | Sys_error _ -> () )
      [payload_path; response_path; status_path]
  in
  try
    write_file payload_path payload ;
    let script =
      "curl -sS --max-time \"$SZANIEC_JEV_TIMEOUT\" -H \"Authorization: Bearer \
       $TYPESAFE_API_KEY\" -H \"Content-Type: application/json\" --data-binary \
       @\"$SZANIEC_JEV_PAYLOAD\" -o \"$SZANIEC_JEV_RESPONSE\" -w \
       \"%{http_code}\" https://api.typesafe.ai/v1/systemone > \
       \"$SZANIEC_JEV_STATUS\""
    in
    let env =
      Array.append
        (Unix.environment ())
        [| "SZANIEC_JEV_TIMEOUT=" ^ string_of_int timeout_s
         ; "SZANIEC_JEV_PAYLOAD=" ^ payload_path
         ; "SZANIEC_JEV_RESPONSE=" ^ response_path
         ; "SZANIEC_JEV_STATUS=" ^ status_path |]
    in
    let pid =
      Unix.create_process_env
        "sh"
        [|"sh"; "-c"; script|]
        env
        Unix.stdin
        Unix.stdout
        Unix.stderr
    in
    let _pid, status = Unix.waitpid [] pid in
    match status with
    | Unix.WEXITED 0 ->
        let code =
          try int_of_string (String.trim (read_file status_path)) with
          | Failure _
           |Sys_error _ ->
              -1
        in
        let body =
          try read_file response_path with
          | Sys_error _ -> ""
        in
        cleanup () ;
        Ok (code, body)
    | Unix.WEXITED 127 ->
        cleanup () ;
        Error "curl is not available"
    | _ ->
        cleanup () ;
        Error "the provider request failed before an HTTP status"
  with
  | Unix.Unix_error (_, "create_process", _) ->
      cleanup () ;
      Error "curl is not available"
  | exn ->
      cleanup () ;
      Error ("the provider request failed: " ^ Printexc.to_string exn)

let post ~(timeout_s : int) ~(payload : string) : (int * string, string) result
    =
  match post_once ~timeout_s ~payload with
  | Ok (code, _) as result when code = 429 || code = 529 -> (
      Unix.sleep 1 ;
      match post_once ~timeout_s ~payload with
      | Ok _ as retried -> retried
      | Error _ -> result )
  | other -> other

let request_body ~(model : string) (calls : call list) : string =
  let state =
    match calls with
    | call :: _ -> call.state
    | [] -> `Assoc []
  in
  let questions =
    `Assoc
      ( List.map (fun (c : call) -> (c.id, c.question)) calls
      |> List.sort (fun a b -> String.compare (fst a) (fst b)) )
  in
  Yojson.Safe.to_string
    (`Assoc
       [("state", state); ("model", `String model); ("questions", questions)] )

let parse_response (body : string) (expected : call list) :
    (batch, string) result =
  match Yojson.Safe.from_string body with
  | exception _ -> Error "provider response was not JSON"
  | json -> (
    match json with
    | `Assoc fields -> (
        let model = string_field "model" fields |> Option.value ~default:"" in
        let usage =
          match field "usage" fields with
          | Some (`Assoc u) -> u
          | _ -> []
        in
        let input_tokens =
          float_field "input_tokens" usage
          |> Option.value ~default:0.
          |> int_of_float
        in
        let output_tokens =
          float_field "output_tokens" usage
          |> Option.value ~default:0.
          |> int_of_float
        in
        match field "answers" fields with
        | Some (`Assoc answers) -> (
            let rec take acc = function
              | [] -> Ok (List.rev acc)
              | call :: rest -> (
                match List.assoc_opt call.id answers with
                | None -> Error ("provider omitted answer for " ^ call.id)
                | Some json -> (
                  match parse_answer json with
                  | Error e -> Error (e ^ " for " ^ call.id)
                  | Ok answer ->
                      if
                        not
                          (String.equal
                             (primitive_of_answer answer)
                             call.primitive )
                      then Error ("provider answer type mismatch for " ^ call.id)
                      else take ((call.id, answer) :: acc) rest ) )
            in
            match take [] expected with
            | Error e -> Error e
            | Ok parsed ->
                if model = ""
                then Error "provider response omitted the model id"
                else Ok {model; answers= parsed; input_tokens; output_tokens} )
        | _ -> Error "provider response omitted answers" )
    | _ -> Error "provider response was not an object" )

let group_by_state (calls : call list) : call list list =
  let table : (string, call list) Hashtbl.t = Hashtbl.create 8 in
  let keys = ref [] in
  List.iter
    (fun (c : call) ->
      let key = Yojson.Safe.to_string c.state in
      match Hashtbl.find_opt table key with
      | Some existing -> Hashtbl.replace table key (c :: existing)
      | None ->
          keys := key :: !keys ;
          Hashtbl.add table key [c] )
    calls ;
  List.map
    (fun key ->
      Hashtbl.find table key |> List.sort (fun a b -> String.compare a.id b.id) )
    (List.rev !keys)

let http ~(timeout_s : int) ~(model : string) : t =
 fun calls ->
  if calls = []
  then Ok (empty_batch model)
  else
    match Sys.getenv_opt "TYPESAFE_API_KEY" with
    | None
     |Some "" ->
        Error "TYPESAFE_API_KEY is not set; no source was sent"
    | Some _ -> (
        let timeout_s = if timeout_s <= 0 then 30 else timeout_s in
        let groups = group_by_state calls in
        let rec go acc = function
          | [] -> Ok (List.rev acc)
          | group :: rest -> (
            match post ~timeout_s ~payload:(request_body ~model group) with
            | Error e -> Error e
            | Ok (200, body) -> (
              match parse_response body group with
              | Error e -> Error e
              | Ok batch -> go (batch :: acc) rest )
            | Ok (401, _) -> Error "provider rejected credentials (HTTP 401)"
            | Ok (code, body) ->
                Error
                  (Printf.sprintf
                     "provider returned HTTP %d%s"
                     code
                     (short_message body) ) )
        in
        match go [] groups with
        | Error e -> Error e
        | Ok batches -> (
            let model_ids =
              List.map (fun (b : batch) -> b.model) batches
              |> List.sort_uniq String.compare
            in
            match model_ids with
            | [returned] ->
                Ok
                  { model= returned
                  ; answers=
                      List.concat_map (fun (b : batch) -> b.answers) batches
                  ; input_tokens=
                      List.fold_left
                        (fun n (b : batch) -> n + b.input_tokens)
                        0
                        batches
                  ; output_tokens=
                      List.fold_left
                        (fun n (b : batch) -> n + b.output_tokens)
                        0
                        batches }
            | _ ->
                Error "provider returned inconsistent model ids across batches"
            ) )
