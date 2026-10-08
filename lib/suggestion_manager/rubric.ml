(* Question construction and versioned suggestion templates. *)

open Szaniec_model
module P = Szaniec_model_access.Jev_provider

let clip (n : int) (text : string) : string * bool =
  if String.length text <= n then (text, false) else (String.sub text 0 n, true)

let string_list xs = `List (List.map (fun s -> `String s) xs)

let fn_state
    ~(body_chars : int)
    (uses : Function_def.use_site list)
    (o : Retrieve.owned)
    (subject_kind : string)
    (subject : string) : Yojson.Safe.t =
  let body, body_cut = clip body_chars o.fn.Function_def.body_text in
  let binding, binding_cut = clip body_chars o.fn.Function_def.binding_text in
  let relevant =
    uses
    |> List.filter (fun u ->
        String.equal u.Function_def.callee o.fn.Function_def.id
        || String.equal u.Function_def.callee o.fn.Function_def.name )
    |> List.map (fun u ->
        Printf.sprintf
          "%s at %s:%d"
          u.Function_def.caller
          u.Function_def.path
          u.line )
  in
  let relevant =
    if List.length relevant > 8 then Retrieve.take 8 relevant else relevant
  in
  `Assoc
    [ ( "function"
      , `Assoc
          [ ("id", `String o.fn.Function_def.id)
          ; ("name", `String o.fn.Function_def.name)
          ; ("parameters", string_list o.fn.Function_def.parameters)
          ; ("variables", string_list o.fn.Function_def.variables)
          ; ("ownership", `String (Retrieve.service_label o))
          ; ( "role"
            , match o.Retrieve.role with
              | Some r -> `String r
              | None -> `Null )
          ; ("binding", `String binding)
          ; ("body", `String body)
          ; ( "truncated"
            , `Bool (o.fn.Function_def.truncated || body_cut || binding_cut) )
          ; ("commentBefore", `String o.fn.Function_def.comment_before) ] )
    ; ( "subject"
      , `Assoc [("kind", `String subject_kind); ("name", `String subject)] )
    ; ("uses", string_list relevant) ]

let choice_name =
  `Assoc
    [ ("type", `String "choice")
    ; ( "instructions"
      , `Assoc
          [ ( "question"
            , `String
                "How does `subject.name` relate to the behavior visible in \
                 `function.body`, `function.binding`, and `uses`?" )
          ; ( "note"
            , `String
                "Judge only the supplied text. A short local name can be \
                 acceptable. Do not infer callees that are not shown." ) ] )
    ; ( "criteria"
      , `Assoc
          [ ( "misleading"
            , `String
                "The name asserts a behavior, polarity, or effect the body \
                 does not have." )
          ; ( "uninformative"
            , `String
                "The name gives almost no hint of the behavior, and the body \
                 is specific enough to support a better name." )
          ; ( "acceptable"
            , `String
                "The name is ordinary, conventional, or specific enough for \
                 this body." )
          ; ( "insufficient-context"
            , `String
                "The supplied body, types, or uses are not enough to judge the \
                 name." ) ] ) ]

let noul (question : string) (yes : string) (no : string) =
  `Assoc
    [ ("type", `String "noul")
    ; ("instructions", `Assoc [("question", `String question)])
    ; ("criteria", `Assoc [("true", `String yes); ("false", `String no)]) ]

let score_complexity =
  `Assoc
    [ ("type", `String "score")
    ; ( "instructions"
      , `Assoc
          [ ( "question"
            , `String
                "How unnecessarily complicated is the control structure \
                 visible in `function.body`? A match that follows the data is \
                 not complicated merely because it is a match." ) ] )
    ; ( "criteria"
      , `List
          [ `String "The structure is straightforward for the behavior shown."
          ; `String
              "One local construct is awkward but the behavior is still easy \
               to follow."
          ; `String
              "A specific construct in the body is unnecessarily complicated \
               for the behavior shown." ] ) ]

let pair_state ~(body_chars : int) (p : Retrieve.pair) : Yojson.Safe.t =
  let one (o : Retrieve.owned) =
    let body, cut = clip body_chars o.fn.body_text in
    `Assoc
      [ ("id", `String o.fn.id)
      ; ("name", `String o.fn.name)
      ; ("parameters", string_list o.fn.parameters)
      ; ("ownership", `String (Retrieve.service_label o))
      ; ("body", `String body)
      ; ("truncated", `Bool (o.fn.truncated || cut)) ]
  in
  `Assoc
    [ ("left", one p.left)
    ; ("right", one p.right)
    ; ("ownershipRelation", `String p.relation) ]

let questions
    ~(body_chars : int)
    ~(experimental : bool)
    ~(api_candidates : string list)
    (uses : Function_def.use_site list)
    (sel : Retrieve.selection) : P.call list =
  let acc = ref [] in
  let add call = acc := call :: !acc in
  List.iter
    (fun (h : Retrieve.name_hit) ->
      add
        { P.id= Printf.sprintf "name-quality:%s:%s" h.owned.fn.id h.subject
        ; criterion= "name-quality"
        ; primitive= "choice"
        ; state= fn_state ~body_chars uses h.owned h.subject_kind h.subject
        ; question= choice_name } )
    sel.names ;
  List.iter
    (fun (p : Retrieve.pair) ->
      let a, b = (p.left.fn.id, p.right.fn.id) in
      add
        { P.id= "semantic-reuse:" ^ a ^ "|" ^ b
        ; criterion= "semantic-reuse"
        ; primitive= "noul"
        ; state= pair_state ~body_chars p
        ; question=
            noul
              "Do `left.body` and `right.body` implement the same behavior, so \
               a reader could reuse one of them for the other's call sites? \
               Similar names alone are not enough. Different service ownership \
               may be intentional; answer only whether the behavior matches."
              "The supplied bodies implement the same behavior."
              "The bodies differ, or the text is not enough to say they match."
        } )
    sel.pairs ;
  List.iter
    (fun (o : Retrieve.owned) ->
      add
        { P.id= "responsibility-mix:" ^ o.fn.id
        ; criterion= "responsibility-mix"
        ; primitive= "noul"
        ; state= fn_state ~body_chars uses o "function" o.fn.name
        ; question=
            noul
              "Does `function.body` combine unrelated responsibilities that a \
               reader would more easily follow as separate functions? One \
               coherent operation that calls several helpers is not a mixture."
              "The body performs at least two unrelated jobs that are both \
               visible in the supplied text."
              "The body is one job, or the text is not enough to call it a \
               mixture." } )
    sel.responsibility ;
  List.iter
    (fun (o : Retrieve.owned) ->
      add
        { P.id= "complicated-construct:" ^ o.fn.id
        ; criterion= "complicated-construct"
        ; primitive= "score"
        ; state= fn_state ~body_chars uses o "function" o.fn.name
        ; question= score_complexity } )
    sel.complexity ;
  if experimental
  then (
    List.iter
      (fun (path, names, anchor) ->
        let state =
          `Assoc
            [ ("file", `String path)
            ; ("vocabulary", string_list names)
            ; ( "anchor"
              , fn_state ~body_chars uses anchor "function" anchor.fn.name ) ]
        in
        add
          { P.id= "vocabulary-consistency:" ^ path
          ; criterion= "vocabulary-consistency"
          ; primitive= "choice"
          ; state
          ; question=
              `Assoc
                [ ("type", `String "choice")
                ; ( "instructions"
                  , `Assoc
                      [ ( "question"
                        , `String
                            "Do the names in `vocabulary` use different terms \
                             for one concept, or one term for different \
                             concepts, in `file`?" ) ] )
                ; ( "criteria"
                  , `Assoc
                      [ ( "inconsistent"
                        , `String
                            "Neighboring names conflict on the supplied \
                             vocabulary." )
                      ; ( "consistent"
                        , `String "The supplied names can live together." )
                      ; ( "insufficient-context"
                        , `String "The vocabulary is too small to judge." ) ] )
                ] } )
      sel.vocabulary ;
    List.iter
      (fun (h : Retrieve.name_hit) ->
        add
          { P.id=
              Printf.sprintf "predicate-clarity:%s:%s" h.owned.fn.id h.subject
          ; criterion= "predicate-clarity"
          ; primitive= "noul"
          ; state= fn_state ~body_chars uses h.owned h.subject_kind h.subject
          ; question=
              noul
                "Is `subject.name` or a double negative difficult to interpret \
                 at the supplied `uses`? Judge only the supplied text."
                "A reader can reasonably misread the polarity at the supplied \
                 sites."
                "The polarity is readable, or the sites are not shown." } )
      sel.predicates ;
    List.iter
      (fun (o : Retrieve.owned) ->
        add
          { P.id= "unexpected-effects:" ^ o.fn.id
          ; criterion= "unexpected-effects"
          ; primitive= "noul"
          ; state= fn_state ~body_chars uses o "function" o.fn.name
          ; question=
              noul
                "Does `function.name` suggest a lookup or pure conversion \
                 while `function.body` shows mutation, persistence, or output? \
                 Do not infer effects of callees that are not shown."
                "The supplied body shows an effect the name conceals."
                "The name fits the shown effects, or no effect is visible." } )
      sel.effects ;
    List.iter
      (fun (o : Retrieve.owned) ->
        add
          { P.id= "mode-flags:" ^ o.fn.id
          ; criterion= "mode-flags"
          ; primitive= "noul"
          ; state= fn_state ~body_chars uses o "function" o.fn.name
          ; question=
              noul
                "Do the labelled parameters of `function` select unrelated \
                 operations such that separate named entry points would \
                 clarify the supplied body? A legitimate option such as force \
                 is not automatically a smell."
                "The supplied body uses mode flags for unrelated operations."
                "The flags are ordinary options, or the body does not show a \
                 split." } )
      sel.modes ;
    List.iter
      (fun (o : Retrieve.owned) ->
        add
          { P.id= "comment-mismatch:" ^ o.fn.id
          ; criterion= "comment-mismatch"
          ; primitive= "noul"
          ; state= fn_state ~body_chars uses o "function" o.fn.name
          ; question=
              noul
                "Does `function.commentBefore` contradict the immediately \
                 accompanying code, or only restate it without explaining \
                 intent? Do not compare it to a system specification."
                "The comment contradicts the binding or merely restates it."
                "The comment adds intent the code does not state, or there is \
                 nothing to judge." } )
      sel.comments ;
    List.iter
      (fun (o : Retrieve.owned) ->
        add
          { P.id= "unnecessary-indirection:" ^ o.fn.id
          ; criterion= "unnecessary-indirection"
          ; primitive= "noul"
          ; state= fn_state ~body_chars uses o "function" o.fn.name
          ; question=
              noul
                "Does `function.body` only forward to another callable without \
                 adding a useful name, adaptation, ownership, or abstraction \
                 role? Preserve legitimate service contracts."
                "The supplied wrapper adds none of those roles."
                "The wrapper names, adapts, or owns something visible, or the \
                 body is not a forward." } )
      sel.indirections ;
    let api_questions = ref 0 in
    List.iter
      (fun (o : Retrieve.owned) ->
        List.iter
          (fun api ->
            if !api_questions < 4
            then (
              api_questions := !api_questions + 1 ;
              let state =
                match fn_state ~body_chars uses o "function" o.fn.name with
                | `Assoc fields ->
                    `Assoc (("apiCandidate", `String api) :: fields)
                | other -> other
              in
              add
                { P.id= "idiomatic-alternative:" ^ o.fn.id ^ ":" ^ api
                ; criterion= "idiomatic-alternative"
                ; primitive= "noul"
                ; state
                ; question=
                    noul
                      "Given `function.body` and `apiCandidate`, is reuse of \
                       that supplied API plausibly clearer? Do not invent an \
                       API, and do not prefer a fold over a clearer body."
                      "The supplied API fits this body and would be clearer."
                      "The candidate does not fit, or the current body is \
                       already clearer." } ) )
          api_candidates )
      (sel.indirections @ sel.complexity) ) ;
  List.rev !acc

let name_message ~id ~name ~choice =
  Printf.sprintf
    "The name '%s' on '%s' is judged %s. This is not an architectural \
     violation; a coding agent may propose a replacement."
    name
    id
    choice

let exact_message (p : Retrieve.pair) : string =
  let a = p.left.fn.id in
  let b = p.right.fn.id in
  match p.relation with
  | "same-service" ->
      Printf.sprintf
        "Exact static match: '%s' and '%s' have the same normalized body. This \
         is not a model judgment. A coding agent may reuse one definition \
         inside service %s."
        a
        b
        (Retrieve.service_label p.left)
  | "distinct-services" ->
      Printf.sprintf
        "Exact static match: '%s' and '%s' have the same normalized body. They \
         belong to %s and %s. Do not merge them into an unapproved shared \
         module."
        a
        b
        (Retrieve.service_label p.left)
        (Retrieve.service_label p.right)
  | _ ->
      Printf.sprintf
        "Exact static match: '%s' and '%s' have the same normalized body. \
         Ownership is %s. This is not a model judgment."
        a
        b
        p.relation

let semantic_message (p : Retrieve.pair) : string =
  let a = p.left.fn.id in
  let b = p.right.fn.id in
  match p.relation with
  | "same-service" ->
      Printf.sprintf
        "Model judgment, not an exact static match: '%s' and '%s' may \
         implement the same behavior. Reuse must stay inside service %s."
        a
        b
        (Retrieve.service_label p.left)
  | "distinct-services" ->
      Printf.sprintf
        "Model judgment, not an exact static match: '%s' and '%s' may \
         implement the same behavior, but they belong to %s and %s. Do not \
         combine them into a shared business library."
        a
        b
        (Retrieve.service_label p.left)
        (Retrieve.service_label p.right)
  | _ ->
      Printf.sprintf
        "Model judgment, not an exact static match: '%s' and '%s' may \
         implement the same behavior. Ownership is %s."
        a
        b
        p.relation

let plain ~criterion ~id =
  match criterion with
  | "responsibility-mix" ->
      Printf.sprintf
        "The definition '%s' is judged to mix unrelated responsibilities \
         visible in its body. This does not change architecture policy."
        id
  | "complicated-construct" ->
      Printf.sprintf
        "The definition '%s' is judged to contain an unnecessarily complicated \
         construct. This is not a complexity gate and not a check failure."
        id
  | other ->
      Printf.sprintf
        "Experimental criterion %s judged '%s'. This is not an architectural \
         violation."
        other
        id
