open Szaniec_model

module Bodies = Hashtbl.Make (struct
  type t = Observation.ordered_step list

  let equal a b = a == b

  let hash = Hashtbl.hash
end)

(* ProgramAccess records compiler-proven callable result projections. Only the
   framework adapter gives an external producer's result an execution meaning. *)
let bind (obs : Observation.t) =
  let targets = Hashtbl.create 32 in
  let result_calls = Hashtbl.create 32 in
  List.iter
    (fun (source, target) ->
      Hashtbl.replace
        targets
        source
        (target :: Option.value ~default:[] (Hashtbl.find_opt targets source)) )
    obs.execution.returned_functions ;
  List.iter
    (fun (call : Observation.execution_call) ->
      if
        call.execution_result <> ""
        && call.execution_callee <> ""
        && not call.execution_resumed
      then (
        Hashtbl.replace result_calls call.execution_result call ;
        Hashtbl.replace
          targets
          call.execution_result
          [call.execution_callee ^ ".<result>"] ) )
    obs.execution.invocations ;
  (* A fresh fiber key has no value outside with_binding's dynamic extent.
     A Some projection can therefore only contain one of its observed bound
     values. Refuse escaped keys and unknown/multiple writers. *)
  let fiber_value key =
    let value position call =
      List.find_map
        (fun (i, target, _) -> if i = position then Some target else None)
        call.Observation.execution_values
    in
    let fresh =
      List.exists
        (fun (call : Observation.execution_call) ->
          call.execution_callee = "Eio.Fiber.create_key"
          && List.mem (key, call.execution_result) obs.execution.value_origins )
        obs.execution.invocations
    in
    let uses =
      List.filter
        (fun (call : Observation.execution_call) ->
          List.exists (fun (_, value, _) -> value = key) call.execution_values )
        obs.execution.invocations
    in
    let closed =
      List.for_all
        (fun (call : Observation.execution_call) ->
          value 0 call = Some key
          && List.mem
               call.execution_callee
               ["Eio.Fiber.get"; "Eio.Fiber.with_binding"] )
        uses
    in
    let sites =
      List.concat_map
        (fun (call : Observation.execution_call) ->
          List.filter_map
            (fun (_, value, site) -> if value = key then Some site else None)
            call.execution_values )
        uses
    in
    let closed =
      closed
      && List.for_all
           (fun (reference : Observation.value_ref) ->
             reference.ref_target <> key || List.mem reference.ref_site sites )
           obs.value_refs
    in
    let writers =
      List.filter
        (fun (c : Observation.execution_call) ->
          c.execution_callee = "Eio.Fiber.with_binding" )
        uses
    in
    let values =
      List.map
        (fun (c : Observation.execution_call) ->
          List.find_opt
            (fun (a : Observation.execution_arg) ->
              a.position = 1 && a.field = "" )
            c.execution_args
          |> Option.fold ~none:"" ~some:(fun a -> a.Observation.target) )
        writers
      |> List.sort_uniq compare
    in
    if fresh && closed
    then
      match values with
      | [value] when value <> "" && Canonical.parameter_symbol value = None ->
          Some value
      | _ -> None
    else None
  in
  List.iter
    (fun (call : Observation.execution_call) ->
      if call.execution_callee = "Eio.Fiber.get"
      then
        Option.iter
          (fun value ->
            Hashtbl.replace
              targets
              (call.execution_result ^ ".<constructor@Some:0>")
              [value] )
          (Option.bind
             (List.find_map
                (fun (i, value, _) -> if i = 0 then Some value else None)
                call.execution_values )
             fiber_value ) )
    obs.execution.invocations ;
  let projection symbol = List.mem "<result>" (Canonical.split_dots symbol) in
  let arities = Hashtbl.create 64 in
  List.iter
    (fun (d : Observation.execution_definition) ->
      Hashtbl.replace arities d.symbol d.definition_arity )
    obs.execution.definitions ;
  List.iter
    (fun (call : Observation.execution_call) ->
      if call.execution_resumed
      then
        match Hashtbl.find_opt arities call.execution_callee with
        | Some arity when arity > call.execution_supplied ->
            let source = call.execution_caller ^ ".<result>" in
            Hashtbl.replace
              arities
              call.execution_caller
              (arity - call.execution_supplied) ;
            Hashtbl.replace result_calls source call ;
            Hashtbl.replace targets source [call.execution_callee ^ ".<result>"]
        | _ -> () )
    obs.execution.invocations ;
  let parameters = Parameter_callbacks.create obs.execution in
  let sequence_tail_suffix = ".<result>.<constructor@Cons:1>" in
  let sequence_producer symbol =
    List.exists
      (fun (call : Observation.execution_call) ->
        call.execution_caller = symbol
        && call.execution_resumed
        && List.mem
             call.execution_callee
             [ "Stdlib.Seq.map"
             ; "Stdlib.Seq.filter"
             ; "Stdlib.Seq.filter_map"
             ; "Stdlib.Seq.append"
             ; "Stdlib.Seq.flat_map"
             ; "Stdlib.List.to_seq"
             ; "Stdlib.String.to_seq" ] )
      obs.execution.invocations
  in
  let unknown symbol =
    let rec walk prefix = function
      | [] -> false
      | segment :: rest ->
          let prefix =
            if prefix = "" then segment else prefix ^ "." ^ segment
          in
          Hashtbl.mem targets (prefix ^ ".<unknown>") || walk prefix rest
    in
    walk "" (Canonical.split_dots symbol)
  in
  let rec sequence_sources visited symbol =
    if List.mem symbol visited
    then Some []
    else if List.length visited >= 64
    then None
    else if sequence_producer symbol
    then Some [symbol]
    else
      match Canonical.parameter_symbol symbol with
      | Some _ when not (projection symbol) ->
          Option.bind
            (Parameter_callbacks.possible_targets parameters [] symbol)
            (fun values ->
              List.fold_left
                (fun previous value ->
                  match
                    (previous, sequence_sources (symbol :: visited) value)
                  with
                  | Some a, Some b -> Some (List.sort_uniq compare (a @ b))
                  | _ -> None )
                (Some [])
                values )
      | _ when projection symbol -> (
        match resolve visited symbol with
        | Some target -> sequence_sources (symbol :: visited) target
        | None -> None )
      | _ -> None
  and resolve ?(arguments = []) visited symbol =
    let replacement =
      List.find_map
        (fun (parameter, value) ->
          if symbol = parameter
          then Some value
          else if String.starts_with ~prefix:(parameter ^ ".") symbol
          then
            Some
              ( value
              ^ String.sub
                  symbol
                  (String.length parameter)
                  (String.length symbol - String.length parameter) )
          else None )
        arguments
    in
    let arguments_at source =
      match Hashtbl.find_opt result_calls source with
      | None -> arguments
      | Some call ->
          List.map
            (fun (a : Observation.execution_arg) ->
              ( ( call.execution_callee
                ^ ".<parameter@"
                ^ string_of_int a.position
                ^ ">"
                ^ if a.field = "" then "" else "." ^ a.field )
              , a.target ) )
            call.execution_args
          @ arguments
    in
    if List.mem symbol visited || List.length visited >= 64
    then None
    else if replacement <> None && replacement <> Some symbol
    then Option.bind replacement (resolve ~arguments (symbol :: visited))
    else if symbol = "Well.open_http_stream.<result>.<tuple@2>"
    then Some "Well.Http_stream.iter"
    else if not (projection symbol)
    then Some symbol
    else if unknown symbol
    then None
    else
      match Hashtbl.find_opt targets symbol with
      | Some values -> (
        match List.sort_uniq compare values with
        | [target] when target <> "" ->
            resolve ~arguments:(arguments_at symbol) (symbol :: visited) target
        | _ -> None )
      | None
        when String.ends_with ~suffix:sequence_tail_suffix symbol
             &&
             let source =
               String.sub
                 symbol
                 0
                 (String.length symbol - String.length sequence_tail_suffix)
             in
             Canonical.parameter_symbol source <> None
             || sequence_producer source -> (
          let source =
            String.sub
              symbol
              0
              (String.length symbol - String.length sequence_tail_suffix)
          in
          match sequence_sources (symbol :: visited) source with
          | Some [target] -> Some target
          | _ -> None )
      | None ->
          let rec prefix suffix = function
            | [] -> None
            | parts -> (
                let name = String.concat "." parts in
                match Hashtbl.find_opt targets name with
                | Some [target] when target <> "" ->
                    resolve
                      ~arguments:(arguments_at name)
                      (symbol :: visited)
                      (target ^ suffix)
                | Some _ -> None
                | None ->
                    let reversed = List.rev parts in
                    prefix
                      ("." ^ List.hd reversed ^ suffix)
                      (List.rev (List.tl reversed)) )
          in
          prefix "" (Canonical.split_dots symbol)
  in
  let bindings = Hashtbl.create 32 in
  let rec rejected visited source =
    if List.mem source visited || List.length visited >= 64 || unknown source
    then false
    else
      let constructors =
        List.filter_map
          (fun (name, constructor) ->
            if name = source then Some constructor else None )
          obs.execution.returned_constructors
      in
      let aliases =
        Option.value ~default:[] (Hashtbl.find_opt targets source)
      in
      (constructors <> [] || aliases <> [])
      && List.for_all (( = ) "Stream_reject") constructors
      && List.for_all (rejected (source :: visited)) aliases
  in
  let target symbol =
    match resolve [] symbol with
    | Some resolved ->
        if resolved <> symbol then Hashtbl.replace bindings symbol [resolved] ;
        resolved
    | None -> symbol
  in
  let resolution symbol previous =
    if projection symbol
    then
      match resolve [] symbol with
      | Some target when Canonical.parameter_symbol target <> None ->
          Observation.Unresolved_local
      | Some _ -> Observation.Resolved
      | None -> Observation.Unresolved_field
    else previous
  in
  let invocation (call : Observation.execution_call) =
    let arguments =
      if call.execution_callee <> "Stdlib.Seq.flat_map"
      then call.execution_args
      else
        call.execution_args
        @ List.filter_map
            (fun (argument : Observation.execution_arg) ->
              if argument.position <> 0
              then None
              else
                match Hashtbl.find_opt arities argument.target with
                | Some 1 ->
                    Some
                      { argument with
                        position= 1
                      ; target=
                          Option.value
                            ~default:""
                            (resolve [] (argument.target ^ ".<result>")) }
                | _ -> None )
            call.execution_args
    in
    { call with
      execution_callee= target call.execution_callee
    ; execution_resolution=
        resolution call.execution_callee call.execution_resolution
    ; execution_args=
        List.map
          (fun (a : Observation.execution_arg) ->
            {a with target= target a.target} )
          arguments }
  in
  let streams =
    List.concat_map
      (fun (call : Observation.execution_call) ->
        if call.execution_callee <> "Well.stream_open"
        then []
        else
          List.filter_map
            (fun (argument : Observation.execution_arg) ->
              let projection =
                argument.target
                ^ ".<result>.<constructor@Stream_accept:0>.<field@accept_iter>"
              in
              let callback =
                match resolve [] projection with
                | Some target when Canonical.parameter_symbol target <> None ->
                    Some ""
                | Some _ as target -> target
                | None when rejected [] (argument.target ^ ".<result>") -> None
                | None -> Some ""
              in
              match callback with
              | Some target ->
                  Some
                    { call with
                      execution_caller= argument.target
                    ; execution_callee= "Well.Stream_accept.iter"
                    ; execution_args=
                        [ { Observation.position= 0
                          ; label= ""
                          ; field= ""
                          ; embedded= false
                          ; target } ]
                    ; execution_values= []
                    ; execution_result= ""
                    ; execution_partial= false
                    ; execution_resumed= false
                    ; execution_supplied= 1 }
              | None -> None )
            call.execution_args )
      obs.execution.invocations
  in
  let bodies = Bodies.create 128 in
  let rec steps values =
    match Bodies.find_opt bodies values with
    | Some mapped -> mapped
    | None ->
        let mapped = List.map step values in
        Bodies.add bodies values mapped ;
        mapped
  and step = function
    | Observation.Invoke call
      when call.execution_callee = "Stdlib.Seq.append"
           && (not call.execution_resumed)
           && call.execution_supplied >= 3 ->
        Observation.Choose
          [ ( "single node"
            , [ Observation.Unknown_order
                  ( "single-node Seq.append has conditional source execution"
                  , call.execution_site )
              ; Observation.Invoke (invocation call) ] ) ]
    | Observation.Invoke call -> Observation.Invoke (invocation call)
    | Choose branches ->
        Choose (List.map (fun (label, body) -> (label, steps body)) branches)
    | Repeat (kind, site, condition, body) ->
        Repeat (kind, site, steps condition, steps body)
    | other -> other
  in
  let observation =
    { obs with
      calls=
        List.map
          (fun (c : Observation.call) ->
            { c with
              callee= target c.callee
            ; resolution= resolution c.callee c.resolution } )
          obs.calls
    ; exec_paths=
        List.map
          (fun (p : Observation.exec_paths) ->
            { p with
              alternatives=
                List.map
                  (List.map (fun (s : Observation.path_step) ->
                       { s with
                         step_callee= target s.step_callee
                       ; step_resolution=
                           resolution s.step_callee s.step_resolution } ) )
                  p.alternatives } )
          obs.exec_paths
    ; execution=
        { obs.execution with
          invocations= List.map invocation (streams @ obs.execution.invocations)
        ; ordered=
            List.map
              (fun (symbol, body) -> (symbol, steps body))
              obs.execution.ordered } }
  in
  (observation, Hashtbl.to_seq bindings |> List.of_seq |> List.sort compare)
