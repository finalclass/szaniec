open Szaniec_model

let project ~execution ~owner_of ~available ~eligible ~entry_point ~classify =
  let definitions = Hashtbl.create 64 in
  let bodies = Hashtbl.create 64 in
  let incoming = Hashtbl.create 64 in
  let activations = Hashtbl.create 16 in
  List.iter
    (fun (d : Observation.execution_definition) ->
      Hashtbl.replace definitions d.symbol d )
    execution.Observation.definitions ;
  List.iter
    (fun (symbol, steps) -> Hashtbl.replace bodies symbol steps)
    execution.ordered ;
  List.iter
    (fun (call : Observation.execution_call) ->
      List.iter
        (fun target ->
          if owner_of target = owner_of call.execution_caller
          then Hashtbl.replace incoming target () )
        ( call.execution_callee
        :: List.map
             (fun (a : Observation.execution_arg) -> a.target)
             call.execution_args ) ;
      List.iter
        (fun argument ->
          if
            Repetition.callback_mode call.execution_callee argument
            = Repetition.Activation
          then Hashtbl.replace activations argument.Observation.target () )
        call.execution_args )
    execution.invocations ;
  let roots =
    List.filter
      (fun (d : Observation.execution_definition) ->
        eligible d.symbol
        && ( entry_point d.symbol
           || d.definition_initializer
           || Hashtbl.mem activations d.symbol
           || not (Hashtbl.mem incoming d.symbol) ) )
      execution.definitions
  in
  List.map
    (fun (origin : Observation.execution_definition) ->
      let complete = ref true in
      let budget = ref 4096 in
      let unknown site reason =
        complete := false ;
        [Interpretation.Flow_unknown (reason, site)]
      in
      let rec walk depth path symbol =
        let site =
          match Hashtbl.find_opt definitions symbol with
          | Some d -> d.Observation.definition_site
          | None -> origin.definition_site
        in
        if depth >= 64 || !budget <= 0
        then unknown site "execution traversal limit"
        else
          match Hashtbl.find_opt bodies symbol with
          | None -> unknown site "execution body unavailable"
          | Some steps -> project_steps depth path steps
      and project_steps depth path steps =
        List.concat_map
          (fun step ->
            decr budget ;
            if !budget < 0
            then unknown origin.definition_site "execution traversal limit"
            else
              match step with
              | Observation.Unknown_order (reason, site) -> unknown site reason
              | Leave (outcome, site) ->
                  [Interpretation.Flow_exit (outcome, site)]
              | Choose branches ->
                  let branches =
                    List.map
                      (fun (label, steps) ->
                        (label, project_steps depth path steps) )
                      branches
                  in
                  if List.for_all (fun (_, steps) -> steps = []) branches
                  then []
                  else [Interpretation.Flow_choice branches]
              | Repeat (kind, site, condition, body) ->
                  [ Interpretation.Flow_loop
                      ( kind
                      , site
                      , ""
                      , project_steps depth path condition
                      , project_steps depth path body ) ]
              | Invoke call -> invoke depth path call )
          steps
      and invoke depth path (call : Observation.execution_call) =
        let api = call.execution_callee in
        let arity =
          match Hashtbl.find_opt definitions api with
          | Some d -> Some d.Observation.definition_arity
          | None -> Repetition.collection_arity api
        in
        let deferred =
          call.execution_partial
          && Option.fold
               ~none:false
               ~some:(fun arity -> arity > call.execution_supplied)
               arity
        in
        if deferred
        then []
        else if
          call.execution_resumed
          && Option.fold
               ~none:true
               ~some:(fun arity -> arity <= call.execution_supplied)
               arity
        then unknown call.execution_site "returned function target unresolved"
        else
          let rows = classify origin.symbol call in
          let callback_wrapper =
            List.mem api ["Stdlib.@@"; "Stdlib.|>"]
            || List.exists
                 (fun argument ->
                   Repetition.callback_mode api argument = Repetition.Iteration )
                 call.execution_args
          in
          let own_body =
            Hashtbl.mem definitions api
            && owner_of api = owner_of origin.symbol
            && rows = []
          in
          let steps =
            if call.execution_resolution <> Observation.Resolved
            then unknown call.execution_site "unresolved execution target"
            else if not (available api)
            then
              unknown
                call.execution_site
                ("target ownership cannot be resolved: " ^ api)
            else if own_body && List.mem api path
            then
              let reference =
                { Interpretation.kind= Interpretation.ExternalCall
                ; from_owner= owner_of origin.symbol
                ; to_service= ""
                ; to_method= ""
                ; target_module= api
                ; resource= ""
                ; api
                ; evidence_path= path @ [api]
                ; sites= [call.execution_site] }
              in
              Interpretation.Flow_call reference
              :: unknown call.execution_site "recursive helper reference"
            else if own_body
            then walk (depth + 1) (path @ [api]) api
            else if callback_wrapper
            then []
            else
              List.map
                (fun (i : Interpretation.interaction) ->
                  Interpretation.Flow_call
                    { i with
                      evidence_path= path @ [api]
                    ; sites= [call.execution_site] } )
                rows
          in
          let phase =
            ( if call.execution_partial && arity = None
              then
                unknown
                  call.execution_site
                  "partial application execution phase unknown"
              else [] )
            @
            if
              api = "Well.request"
              && not
                   (List.exists
                      (fun (i : Interpretation.interaction) ->
                        i.kind = QueuedCommand )
                      rows )
            then unknown call.execution_site "queued command target unresolved"
            else []
          in
          let callbacks =
            List.concat_map
              (fun (argument : Observation.execution_arg) ->
                let mode = Repetition.callback_mode api argument in
                let run () =
                  let callback =
                    { call with
                      execution_callee= argument.target
                    ; execution_resolution=
                        ( if argument.target = ""
                          then Observation.Unresolved_dynamic
                          else Observation.Resolved )
                    ; execution_args= []
                    ; execution_partial= false
                    ; execution_resumed= false }
                  in
                  invoke (depth + 1) (path @ [api]) callback
                in
                match mode with
                | Repetition.Ignored
                 |Activation ->
                    []
                | Once when api = "Well.MessageBus.once" ->
                    unknown
                      call.execution_site
                      "one-shot callback execution order unknown"
                    @ [ Interpretation.Flow_choice
                          [ ("callback-not-invoked", [])
                          ; ("callback-invoked", run ()) ] ]
                | Once -> run ()
                | Iteration ->
                    [ Interpretation.Flow_loop
                        ("iterator", call.execution_site, api, [], run ()) ]
                | Unknown ->
                    unknown
                      call.execution_site
                      ("unknown callback semantics: " ^ api)
                    @ [ Interpretation.Flow_choice
                          [ ("callback-not-invoked", [])
                          ; ("callback-invoked", run ()) ] ] )
              call.execution_args
          in
          phase @ steps @ callbacks
      in
      let steps = walk 0 [origin.symbol] origin.symbol in
      let steps =
        steps @ [Interpretation.Flow_exit ("return", origin.definition_site)]
      in
      { Interpretation.flow_origin= origin
      ; flow_owner= owner_of origin.symbol
      ; flow= {complete= !complete; steps} } )
    roots
