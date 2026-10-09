open Szaniec_model

let check condition message = if not condition then failwith message

let site line = {Observation.site_path= "lib/owner/impl.ml"; line; col= 2}

let definition symbol =
  { Observation.symbol
  ; definition_site= site 1
  ; definition_arity= 1
  ; definition_initializer= false }

let call ?(loops = []) caller callee =
  { Observation.execution_caller= caller
  ; execution_callee= callee
  ; execution_resolution= Observation.Resolved
  ; execution_site= site 2
  ; execution_loops= loops
  ; execution_partial= false
  ; execution_resumed= false
  ; execution_supplied= 1
  ; execution_args= [] }

let project names invocations =
  let execution =
    {Observation.definitions= List.map definition names; invocations}
  in
  Szaniec_interpretation_engine.Repetition.project
    ~execution
    ~owner_of:(fun _ -> "Owner")
    ~eligible:(fun _ -> true)
    ~entry_point:(fun name -> name = "rpc")
    ~classify:(fun _ call ->
      if List.mem call.Observation.execution_callee names
      then None
      else
        Some
          { Interpretation.kind= Interpretation.ExternalCall
          ; from_owner= "Owner"
          ; to_service= ""
          ; to_method= ""
          ; target_module= call.execution_callee
          ; resource= ""
          ; api= call.execution_callee
          ; evidence_path= []
          ; sites= [call.execution_site] } )

let contexts origin rows =
  List.filter_map
    (fun (row : Interpretation.execution_interaction) ->
      if row.execution_origin.symbol = origin
      then Some row.execution_context
      else None )
    rows

let () =
  let loop = {Observation.loop_kind= "for"; loop_site= site 4} in
  let rows =
    project
      ["rpc"; "left"; "right"; "leaf"]
      [ call "rpc" "left"
      ; call "rpc" "right"
      ; call "left" "leaf"
      ; call ~loops:[loop] "right" "leaf"
      ; call "leaf" "Other.request" ]
  in
  let paths = contexts "rpc" rows in
  check (List.length paths = 2) "shared helper retains both invocation paths" ;
  check
    (List.exists
       (fun (c : Interpretation.execution_context) -> c.loops = [])
       paths )
    "one ordinary helper use stays ordinary" ;
  check
    (List.exists
       (fun (c : Interpretation.execution_context) -> List.length c.loops = 1)
       paths )
    "one looped helper use stays looped" ;
  let rows =
    project ["caller"; "rpc"] [call "caller" "rpc"; call "rpc" "Other.request"]
  in
  check (contexts "rpc" rows <> []) "RPC is an origin even with a local caller" ;
  let rows =
    project
      ["a"; "b"; "c"]
      [ call "a" "b"
      ; call "b" "a"
      ; call "a" "c"
      ; call "c" "b"
      ; call "c" "Other.request" ]
  in
  check
    (List.for_all
       (fun origin ->
         List.exists
           (fun (c : Interpretation.execution_context) ->
             List.exists
               (fun (r : Interpretation.repetition) -> r.kind = "recursion")
               c.loops )
           (contexts origin rows) )
       ["a"; "b"; "c"] )
    "overlapping cycles retain every recursive origin" ;
  let names = List.init 70 (fun n -> "node" ^ string_of_int n) in
  let invocations =
    List.mapi
      (fun n name ->
        call name (if n = 69 then "Other.request" else List.nth names (n + 1)) )
      names
  in
  let rows = project names invocations in
  check
    (List.exists
       (fun (c : Interpretation.execution_context) ->
         List.mem "execution traversal limit" c.unknown_reasons )
       (contexts "node0" rows) )
    "bounded traversal preserves incomplete evidence" ;
  let rows =
    project
      ["rpc"; "callback"]
      [ { (call "rpc" "Stdlib.List.map") with
          execution_partial= true
        ; execution_args=
            [{Observation.position= 0; label= ""; target= "callback"}] }
      ; call "callback" "Other.request" ]
  in
  check
    (contexts "rpc" rows = [])
    "partial iterator construction does not invoke a callback" ;
  let inner = {loop with Observation.loop_site= site 10} in
  let rows =
    project
      ["rpc"; "callback"]
      [ { (call ~loops:[loop] "rpc" "Well.every") with
          execution_args=
            [{Observation.position= 0; label= ""; target= "callback"}] }
      ; call ~loops:[inner] "callback" "Other.request" ]
  in
  let callback_contexts =
    contexts "rpc" rows
    |> List.filter (fun (c : Interpretation.execution_context) ->
        List.mem "Other.request" c.context_path )
  in
  check (List.length callback_contexts = 1) "registered callback is visible" ;
  check
    (List.for_all
       (fun (c : Interpretation.execution_context) ->
         c.activations <> []
         && List.length c.loops = 1
         && (List.hd c.loops).site = site 10 )
       callback_contexts )
    "activation resets registration loops and retains callback loops" ;
  print_endline "repetition paths, recursion, deferred execution and limits: ok"
