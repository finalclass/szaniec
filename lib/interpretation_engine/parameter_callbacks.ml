open Szaniec_model

let parameter = Canonical.parameter_symbol

type t =
  { bodies: (string, Observation.ordered_step list) Hashtbl.t
  ; calls: (string, Observation.execution_call list) Hashtbl.t
  ; summaries: (string, (int * string) list list option) Hashtbl.t
  ; forwarded:
      ( string
      , (Observation.execution_call * Observation.execution_arg) list )
      Hashtbl.t
  ; arities: (string, int option) Hashtbl.t
  ; callback_sources:
      (string, (string * Observation.execution_arg) list) Hashtbl.t
  ; supplied_parameter:
      string -> Observation.execution_arg -> int -> string -> string list option
  ; uses: (string, unit) Hashtbl.t
  ; defaults: (string * string) list
  ; callback_mode:
      string -> Observation.execution_arg -> Repetition.callback_mode }

let create
    ?(supplied_parameter = fun _ _ _ _ -> None)
    ?(callback_mode = Repetition.callback_mode)
    (execution : Observation.execution) =
  let bodies = Hashtbl.create 128 in
  List.iter
    (fun (symbol, body) -> Hashtbl.replace bodies symbol body)
    execution.ordered ;
  let calls = Hashtbl.create 128 in
  List.iter
    (fun (call : Observation.execution_call) ->
      if (not call.execution_partial) && not call.execution_resumed
      then
        Hashtbl.replace
          calls
          call.execution_callee
          ( call
          :: Option.value
               ~default:[]
               (Hashtbl.find_opt calls call.execution_callee) ) )
    execution.invocations ;
  let uses = Hashtbl.create 64 in
  let callback_sources = Hashtbl.create 64 in
  let forwarded = Hashtbl.create 64 in
  let note symbol =
    Option.iter
      (fun (owner, _) -> Hashtbl.replace uses owner ())
      (parameter symbol)
  in
  List.iter
    (fun (c : Observation.execution_call) ->
      note c.execution_callee ;
      List.iter
        (fun (a : Observation.execution_arg) ->
          Hashtbl.replace
            callback_sources
            a.target
            ( (c.execution_callee, a)
            :: Option.value
                 ~default:[]
                 (Hashtbl.find_opt callback_sources a.target) ) ;
          note a.target ;
          if parameter a.target <> None
          then
            Hashtbl.replace
              forwarded
              a.target
              ( (c, a)
              :: Option.value ~default:[] (Hashtbl.find_opt forwarded a.target)
              ) )
        c.execution_args )
    execution.invocations ;
  let definition_arities = Hashtbl.create 64 in
  List.iter
    (fun (d : Observation.execution_definition) ->
      Hashtbl.replace definition_arities d.symbol d.definition_arity )
    execution.definitions ;
  List.iter
    (fun (call : Observation.execution_call) ->
      let arity =
        match Hashtbl.find_opt definition_arities call.execution_callee with
        | Some _ as known -> known
        | None -> Repetition.collection_arity call.execution_callee
      in
      if
        call.execution_resumed
        && Option.fold
             ~none:false
             ~some:(fun arity -> call.execution_supplied < arity)
             arity
      then
        let direct =
          Option.value
            ~default:[]
            (Hashtbl.find_opt calls call.execution_caller)
        in
        let direct =
          List.map
            (fun (use : Observation.execution_call) ->
              { call with
                execution_caller= use.execution_caller
              ; execution_args=
                  call.execution_args
                  @ List.map
                      (fun (arg : Observation.execution_arg) ->
                        { arg with
                          position= arg.position + call.execution_supplied } )
                      use.execution_args
              ; execution_resumed= false
              ; execution_partial= false
              ; execution_supplied=
                  call.execution_supplied + use.execution_supplied } )
            direct
        in
        let activated =
          Option.value
            ~default:[]
            (Hashtbl.find_opt callback_sources call.execution_caller)
          |> List.filter_map (fun (api, arg) ->
              if
                List.mem
                  (callback_mode api arg)
                  [Repetition.Once; Iteration; Activation]
              then
                Some
                  { call with
                    execution_resumed= false
                  ; execution_args=
                      call.execution_args
                      @ List.init
                          (Repetition.argument_arity api arg)
                          (fun position ->
                            { Observation.position=
                                call.execution_supplied + position
                            ; label= ""
                            ; field= ""
                            ; embedded= false
                            ; target=
                                call.execution_caller
                                ^ ".<parameter@"
                                ^ string_of_int position
                                ^ ">" } ) }
              else None )
        in
        let previous =
          Option.value
            ~default:[]
            (Hashtbl.find_opt calls call.execution_callee)
        in
        if direct @ activated <> []
        then
          Hashtbl.replace
            calls
            call.execution_callee
            (direct @ activated @ previous) )
    execution.invocations ;
  { bodies
  ; callback_mode
  ; defaults= execution.parameter_defaults
  ; calls
  ; callback_sources
  ; supplied_parameter
  ; summaries= Hashtbl.create 128
  ; uses
  ; forwarded
  ; arities= Hashtbl.create 64 }

let normalize groups =
  let groups =
    List.map (List.sort_uniq compare) groups |> List.sort_uniq compare
  in
  if List.length groups > 256 then None else Some groups

let sequence left right =
  match (left, right) with
  | Some left, Some right when List.length left * List.length right <= 4096 ->
      normalize
        (List.concat_map (fun a -> List.map (fun b -> a @ b) right) left)
  | _ -> None

(* A summary describes which callable input positions may execute together.
   It does not adopt those callbacks into the provider's service boundary. *)
let rec summary t visiting owner =
  match Hashtbl.find_opt t.summaries owner with
  | Some value -> value
  | None when not (Hashtbl.mem t.uses owner) -> Some [[]]
  | None when List.mem owner visiting || List.length visiting >= 64 -> None
  | None ->
      let uncertain_order = ref false in
      let rec body visiting steps =
        List.fold_left
          (fun previous step -> sequence previous (step_summary visiting step))
          (Some [[]])
          steps
      and input visiting (arg : Observation.execution_arg) =
        match parameter arg.target with
        | Some (provider, position) when provider = owner ->
            Some [[(position, Canonical.parameter_field arg.target)]]
        | Some _ -> Some [[]]
        | None when Hashtbl.mem t.bodies arg.target ->
            if List.mem arg.target visiting
            then None
            else
              body (arg.target :: visiting) (Hashtbl.find t.bodies arg.target)
        | _ -> Some [[]]
      and invoke visiting (call : Observation.execution_call) =
        match parameter call.execution_callee with
        | Some (provider, position) when provider = owner ->
            Some [[(position, Canonical.parameter_field call.execution_callee)]]
        | Some _ -> Some [[]]
        | None ->
            if
              String.starts_with ~prefix:(owner ^ ".") call.execution_callee
              && Hashtbl.mem t.bodies call.execution_callee
            then
              if List.mem call.execution_callee visiting
              then None
              else
                body
                  (call.execution_callee :: visiting)
                  (Hashtbl.find t.bodies call.execution_callee)
            else if
              Hashtbl.mem t.bodies call.execution_callee
              && not
                   (List.exists
                      (fun arg ->
                        t.callback_mode call.execution_callee arg
                        <> Repetition.callback_mode call.execution_callee arg )
                      call.execution_args )
            then
              match summary t (owner :: visiting) call.execution_callee with
              | None -> None
              | Some groups ->
                  List.fold_left
                    (fun all group ->
                      let mapped =
                        List.fold_left
                          (fun result (position, field) ->
                            match
                              List.find_opt
                                (fun (a : Observation.execution_arg) ->
                                  a.position = position
                                  && (a.field = field || a.field = "") )
                                call.execution_args
                            with
                            | None -> result
                            | Some arg ->
                                let arg =
                                  if
                                    field <> ""
                                    && arg.field = ""
                                    && parameter arg.target <> None
                                  then
                                    {arg with target= arg.target ^ "." ^ field}
                                  else arg
                                in
                                sequence result (input visiting arg) )
                          (Some [[]])
                          group
                      in
                      match (all, mapped) with
                      | Some all, Some mapped -> normalize (all @ mapped)
                      | _ -> None )
                    (Some [])
                    groups
            else
              List.fold_left
                (fun result (arg : Observation.execution_arg) ->
                  let input_summary = input visiting arg in
                  match t.callback_mode call.execution_callee arg with
                  | Repetition.Once
                   |Iteration ->
                      sequence result input_summary
                  | Ignored -> result
                  | Activation
                   |Unknown ->
                      if input_summary = Some [[]] then result else None )
                (Some [[]])
                call.execution_args
      and step_summary visiting = function
        | Observation.Invoke call -> invoke visiting call
        | Choose branches ->
            List.fold_left
              (fun all (_, steps) ->
                match (all, body visiting steps) with
                | Some all, Some next -> normalize (all @ next)
                | _ -> None )
              (Some [])
              branches
        | Repeat (_, _, condition, steps) ->
            sequence (body visiting condition) (body visiting steps)
        | Leave _ -> Some [[]]
        | Unknown_order ("operand evaluation order unspecified", _) -> Some [[]]
        | Unknown_order (reason, _)
          when List.mem
                 reason
                 [ "exception flow unsupported"
                 ; "match exception flow unsupported"
                 ; "guard selection flow unsupported"
                 ; "operand ordering alternatives exceed limit" ] ->
            uncertain_order := true ;
            Some [[]]
        | Unknown_order _ -> None
      in
      let value =
        Option.bind (Hashtbl.find_opt t.bodies owner) (body (owner :: visiting))
      in
      let value =
        Option.bind value (fun groups ->
            if
              !uncertain_order
              && List.length (List.sort_uniq compare (List.concat groups)) > 1
            then None
            else Some groups )
      in
      Hashtbl.replace t.summaries owner value ;
      value

let paths t ~invoked (call : Observation.execution_call) =
  Option.map
    (List.map
       (List.filter_map (fun (position, field) ->
            List.find_opt
              (fun (arg : Observation.execution_arg) ->
                arg.position = position && (arg.field = field || arg.field = "") )
              call.execution_args
            |> fun arg ->
            Option.bind arg (fun arg ->
                let target =
                  if
                    field <> ""
                    && arg.field = ""
                    && parameter arg.target <> None
                  then arg.target ^ "." ^ field
                  else arg.target
                in
                if invoked position target then Some target else None ) ) ) )
    (summary t [] call.execution_callee)

let rec input_arity t visited owner position =
  let key = owner ^ ".<parameter@" ^ string_of_int position ^ ">" in
  if Hashtbl.mem t.arities key
  then Hashtbl.find t.arities key
  else if List.mem key visited
  then None
  else
    let direct =
      Option.value ~default:[] (Hashtbl.find_opt t.calls key)
      |> List.map (fun (c : Observation.execution_call) -> c.execution_supplied)
    in
    let forwarded =
      Option.value ~default:[] (Hashtbl.find_opt t.forwarded key)
      |> List.filter_map
           (fun
             ((c : Observation.execution_call), (a : Observation.execution_arg))
           ->
             if a.target <> key
             then None
             else if Hashtbl.mem t.bodies c.execution_callee
             then input_arity t (key :: visited) c.execution_callee a.position
             else if
               List.mem
                 (t.callback_mode c.execution_callee a)
                 [Repetition.Once; Iteration]
             then Some (Repetition.callback_arity c.execution_callee)
             else None )
    in
    let value =
      match direct @ forwarded with
      | [] -> None
      | counts -> Some (List.fold_left max 0 counts)
    in
    if visited = [] then Hashtbl.replace t.arities key value ;
    value

let rec possible_targets t visiting symbol =
  match parameter symbol with
  | None -> if symbol = "" then None else Some [symbol]
  | Some (owner, position) ->
      if List.mem symbol visiting
      then Some []
      else
        let calls = Option.value ~default:[] (Hashtbl.find_opt t.calls owner) in
        let sources =
          Option.value ~default:[] (Hashtbl.find_opt t.callback_sources owner)
          |> List.filter (fun (api, _) -> not (Hashtbl.mem t.bodies api))
        in
        let initial =
          List.fold_left
            (fun result (api, arg) ->
              match
                ( result
                , t.supplied_parameter
                    api
                    arg
                    position
                    (Canonical.parameter_field symbol) )
              with
              | Some old, Some next ->
                  Some (List.sort_uniq compare (old @ next))
              | _ -> None )
            (Some [])
            sources
        in
        if calls = [] && sources = []
        then None
        else
          List.fold_left
            (fun result (call : Observation.execution_call) ->
              let arg =
                List.find_opt
                  (fun (arg : Observation.execution_arg) ->
                    arg.position = position
                    && ( arg.field = Canonical.parameter_field symbol
                       || arg.field = "" ) )
                  call.execution_args
              in
              match
                ( result
                , match arg with
                  | None when List.mem position call.execution_defaults ->
                      Option.bind
                        (List.assoc_opt symbol t.defaults)
                        (possible_targets t (symbol :: visiting))
                  | None -> None
                  | Some arg ->
                      let field = Canonical.parameter_field symbol in
                      let target =
                        if
                          field <> ""
                          && arg.field = ""
                          && parameter arg.target <> None
                        then arg.target ^ "." ^ field
                        else arg.target
                      in
                      possible_targets t (symbol :: visiting) target )
              with
              | Some old, Some next ->
                  Some (List.sort_uniq compare (old @ next))
              | _ -> None )
            initial
            calls

let bind_calls t (execution : Observation.execution) =
  let rec round remaining =
    if remaining > 0
    then begin
      let changed = ref false in
      List.iter
        (fun (call : Observation.execution_call) ->
          List.iter
            (fun (argument : Observation.execution_arg) ->
              if parameter argument.target <> None
              then
                match possible_targets t [] argument.target with
                | None -> ()
                | Some targets ->
                    List.iter
                      (fun target ->
                        let source =
                          (call.execution_callee, {argument with target})
                        in
                        let previous =
                          Option.value
                            ~default:[]
                            (Hashtbl.find_opt t.callback_sources target)
                        in
                        if not (List.mem source previous)
                        then (
                          Hashtbl.replace
                            t.callback_sources
                            target
                            (source :: previous) ;
                          changed := true ) )
                      targets )
            call.execution_args ;
          if
            parameter call.execution_callee <> None
            && not call.execution_partial
          then
            match possible_targets t [] call.execution_callee with
            | Some targets ->
                List.iter
                  (fun target ->
                    if parameter target = None
                    then
                      let mapped =
                        { call with
                          execution_callee= target
                        ; execution_resolution= Observation.Resolved }
                      in
                      let previous =
                        Option.value
                          ~default:[]
                          (Hashtbl.find_opt t.calls target)
                      in
                      if not (List.mem mapped previous)
                      then (
                        Hashtbl.replace t.calls target (mapped :: previous) ;
                        changed := true ) )
                  targets
            | None -> () )
        execution.invocations ;
      if !changed
      then (
        Hashtbl.clear t.summaries ;
        Hashtbl.clear t.arities ;
        round (remaining - 1) )
    end
  in
  round 16

(* A literal closure supplied only to unused helper inputs never executes.
   This also accounts for the type-witness closures emitted by JS PPX. *)
let inert_callback t symbol =
  let sources =
    Option.value ~default:[] (Hashtbl.find_opt t.callback_sources symbol)
  in
  sources <> []
  && (not (Hashtbl.mem t.calls symbol))
  && List.for_all
       (fun (api, (argument : Observation.execution_arg)) ->
         Hashtbl.mem t.bodies api
         && Option.fold
              ~none:false
              ~some:(fun groups ->
                List.for_all
                  (fun group ->
                    not
                      (List.exists
                         (fun (position, _) -> position = argument.position)
                         group ) )
                  groups )
              (summary t [] api) )
       sources
