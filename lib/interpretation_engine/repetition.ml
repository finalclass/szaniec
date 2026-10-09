open Szaniec_model

type callback_mode =
  | Iteration
  | Activation
  | Once
  | Ignored
  | Unknown

let collection_arity api =
  match Canonical.split_dots api with
  | ["Stdlib"; ("List" | "Array"); name] -> (
    match name with
    | "fold_left2"
     |"fold_right2" ->
        Some 4
    | "fold_left"
     |"fold_right"
     |"fold_left_map"
     |"iter2"
     |"map2"
     |"exists2"
     |"for_all2"
     |"merge" ->
        Some 3
    | "init"
     |"iter"
     |"iteri"
     |"map"
     |"mapi"
     |"concat_map"
     |"filter"
     |"filteri"
     |"filter_map"
     |"partition"
     |"partition_map"
     |"exists"
     |"for_all"
     |"find"
     |"find_opt"
     |"find_index"
     |"find_map"
     |"find_mapi"
     |"sort"
     |"stable_sort"
     |"fast_sort"
     |"sort_uniq" ->
        Some 2
    | _ -> None )
  | _ -> None

let callback_mode api (argument : Observation.execution_arg) =
  let collection =
    match Canonical.split_dots api with
    | ["Stdlib"; ("List" | "Array"); method_name] -> Some method_name
    | _ -> None
  in
  match collection with
  | Some "init" when argument.position = 1 -> Iteration
  | Some
      ( "iter" | "iteri" | "map" | "mapi" | "iter2" | "map2" | "fold_left"
      | "fold_right" | "fold_left2" | "fold_right2" | "fold_left_map"
      | "concat_map" | "filter" | "filteri" | "filter_map" | "partition"
      | "partition_map" | "exists" | "exists2" | "for_all" | "for_all2" | "find"
      | "find_opt" | "find_index" | "find_map" | "find_mapi" | "sort"
      | "stable_sort" | "fast_sort" | "sort_uniq" | "merge" )
    when argument.position = 0 ->
      Iteration
  | _ when api = "Well.every" -> Activation
  | _
    when List.mem
           api
           [ "Well.subscribe"
           ; "Well.subscribe_keyed"
           ; "Well.MessageBus.subscribe" ] ->
      Activation
  | _ when List.mem api ["Well.get"; "Well.post"; "Well.live"] -> Activation
  | _ when api = "Well.MessageBus.once" -> Once
  | _ when api = "Stdlib.ignore" -> Ignored
  | _ when api = "Stdlib.@@" && argument.position = 0 -> Once
  | _ when api = "Stdlib.|>" && argument.position = 1 -> Once
  | _ when List.mem api ["Stdlib.@@"; "Stdlib.|>"] -> Ignored
  | _ when collection_arity api <> None -> Ignored
  | _ -> Unknown

let project ~execution ~owner_of ~eligible ~entry_point ~classify =
  let definitions = Hashtbl.create 64 in
  let outgoing = Hashtbl.create 64 in
  let incoming = Hashtbl.create 64 in
  let recursions = Hashtbl.create 16 in
  let results = ref [] in
  List.iter
    (fun (d : Observation.execution_definition) ->
      Hashtbl.replace definitions d.symbol d )
    execution.Observation.definitions ;
  List.iter
    (fun (c : Observation.execution_call) ->
      let calls =
        Option.value ~default:[] (Hashtbl.find_opt outgoing c.execution_caller)
      in
      Hashtbl.replace outgoing c.execution_caller (c :: calls) ;
      List.iter
        (fun target ->
          if
            Hashtbl.mem definitions target
            && owner_of target = owner_of c.execution_caller
          then Hashtbl.replace incoming target () )
        ( c.execution_callee
        :: List.map
             (fun (a : Observation.execution_arg) -> a.target)
             c.execution_args ) )
    execution.invocations ;
  let calls symbol =
    Option.value ~default:[] (Hashtbl.find_opt outgoing symbol)
  in
  let arity (call : Observation.execution_call) =
    match Hashtbl.find_opt definitions call.execution_callee with
    | Some d -> Some d.Observation.definition_arity
    | None -> collection_arity call.execution_callee
  in
  let deferred call =
    call.Observation.execution_partial
    &&
    match arity call with
    | Some arity -> arity > call.execution_supplied
    | None -> false
  in
  let returned_function call =
    call.Observation.execution_resumed
    &&
    match arity call with
    | Some arity -> arity <= call.execution_supplied
    | None -> true
  in
  let children symbol =
    calls symbol
    |> List.filter (fun call -> not (deferred call || returned_function call))
    |> List.concat_map (fun (c : Observation.execution_call) ->
        c.execution_callee
        :: List.filter_map
             (fun a ->
               if
                 List.mem
                   (callback_mode c.execution_callee a)
                   [Unknown; Ignored; Activation]
               then None
               else Some a.Observation.target )
             c.execution_args )
    |> List.filter (fun target ->
        Hashtbl.mem definitions target && owner_of target = owner_of symbol )
    |> List.sort_uniq compare
  in
  (* Strongly connected components include overlapping recursive cycles.
     Activation callbacks start independent work and are not recursion edges. *)
  let indices = Hashtbl.create 64 in
  let lowlinks = Hashtbl.create 64 in
  let stacked = Hashtbl.create 64 in
  let stack = Stack.create () in
  let next_index = ref 0 in
  let rec cycles symbol =
    let index = !next_index in
    incr next_index ;
    Hashtbl.add indices symbol index ;
    Hashtbl.add lowlinks symbol index ;
    Hashtbl.add stacked symbol () ;
    Stack.push symbol stack ;
    List.iter
      (fun target ->
        if not (Hashtbl.mem indices target)
        then begin
          cycles target ;
          Hashtbl.replace
            lowlinks
            symbol
            (min (Hashtbl.find lowlinks symbol) (Hashtbl.find lowlinks target))
        end
        else if Hashtbl.mem stacked target
        then
          Hashtbl.replace
            lowlinks
            symbol
            (min (Hashtbl.find lowlinks symbol) (Hashtbl.find indices target)) )
      (children symbol) ;
    if Hashtbl.find lowlinks symbol = index
    then begin
      let rec pop acc =
        let node = Stack.pop stack in
        Hashtbl.remove stacked node ;
        let acc = node :: acc in
        if node = symbol then acc else pop acc
      in
      let component = pop [] in
      if List.length component > 1 || List.mem symbol (children symbol)
      then List.iter (fun node -> Hashtbl.replace recursions node ()) component
    end
  in
  List.iter
    (fun d ->
      if not (Hashtbl.mem indices d.Observation.symbol) then cycles d.symbol )
    execution.definitions ;
  let roots =
    List.filter
      (fun d ->
        eligible d.Observation.symbol
        && ( entry_point d.symbol
           || d.definition_initializer
           || (not (Hashtbl.mem incoming d.symbol))
           || Hashtbl.mem recursions d.symbol ) )
      execution.definitions
  in
  List.iter
    (fun (origin : Observation.execution_definition) ->
      let visited = Hashtbl.create 32 in
      let budget = ref 4096 in
      let add call path loops activations unknown =
        match classify origin.symbol call with
        | None -> ()
        | Some interaction ->
            let context =
              { Interpretation.origin= origin.symbol
              ; site= call.Observation.execution_site
              ; context_path= path @ [call.execution_callee]
              ; loops
              ; activations
              ; unknown_reasons= List.sort_uniq compare unknown }
            in
            results :=
              { Interpretation.execution_origin= origin
              ; execution_owner= owner_of origin.symbol
              ; execution_interaction=
                  { interaction with
                    evidence_path= context.context_path
                  ; sites= [context.site] }
              ; execution_context= context }
              :: !results
      in
      let rec walk depth symbol path loops activations unknown =
        let recursion =
          if Hashtbl.mem recursions symbol
          then
            [ { Interpretation.kind= "recursion"
              ; site=
                  (Hashtbl.find definitions symbol).Observation.definition_site
              ; api= symbol } ]
          else []
        in
        let loops = List.sort_uniq compare (loops @ recursion) in
        let key = (symbol, path, loops, activations, unknown) in
        if not (Hashtbl.mem visited key)
        then (
          Hashtbl.add visited key () ;
          decr budget ;
          List.iter
            (fun (call : Observation.execution_call) ->
              if not (deferred call)
              then begin
                let unknown =
                  if returned_function call
                  then "returned function target unresolved" :: unknown
                  else unknown
                in
                let call =
                  if returned_function call
                  then
                    { call with
                      execution_callee= ""
                    ; execution_resolution= Observation.Unresolved_dynamic
                    ; execution_args= [] }
                  else call
                in
                let regions =
                  List.map
                    (fun (r : Observation.loop) ->
                      { Interpretation.kind= r.loop_kind
                      ; site= r.loop_site
                      ; api= "" } )
                    call.execution_loops
                in
                let loops = List.sort_uniq compare (loops @ regions) in
                let limited = depth >= 64 || !budget < 0 in
                let unknown =
                  if limited
                  then "execution traversal limit" :: unknown
                  else if call.execution_resolution <> Observation.Resolved
                  then "unresolved execution target" :: unknown
                  else unknown
                in
                let unknown =
                  if call.execution_partial
                  then "partial application execution phase unknown" :: unknown
                  else unknown
                in
                let follow call path loops activations unknown =
                  if
                    (not limited)
                    && Hashtbl.mem definitions call.Observation.execution_callee
                    && owner_of symbol = owner_of call.execution_callee
                    && classify origin.symbol call = None
                    && not (List.mem call.execution_callee path)
                  then
                    walk
                      (depth + 1)
                      call.execution_callee
                      (path @ [call.execution_callee])
                      loops
                      activations
                      unknown
                  else if limited && classify origin.symbol call = None
                  then
                    add
                      { call with
                        execution_callee= ""
                      ; execution_resolution= Observation.Unresolved_dynamic }
                      (path @ [call.execution_callee])
                      loops
                      activations
                      unknown
                  else add call path loops activations unknown
                in
                follow call path loops activations unknown ;
                List.iter
                  (fun (argument : Observation.execution_arg) ->
                    let mode = callback_mode call.execution_callee argument in
                    if mode <> Ignored
                    then begin
                      let context =
                        { Interpretation.kind=
                            ( if call.execution_callee = "Well.every"
                              then "periodic"
                              else if
                                List.mem
                                  call.execution_callee
                                  ["Well.get"; "Well.post"; "Well.live"]
                              then "handler"
                              else if mode = Activation
                              then "subscription"
                              else "iterator" )
                        ; site= call.execution_site
                        ; api= call.execution_callee }
                      in
                      let loops =
                        if mode = Activation
                        then []
                        else if mode = Iteration
                        then loops @ [context]
                        else loops
                      in
                      let activations =
                        if mode = Activation
                        then activations @ [context]
                        else activations
                      in
                      let unknown =
                        if mode = Unknown
                        then
                          ( "unknown callback semantics: "
                          ^ call.execution_callee )
                          :: unknown
                        else unknown
                      in
                      let unknown =
                        if argument.target = ""
                        then "unresolved callback target" :: unknown
                        else unknown
                      in
                      let invocation =
                        { call with
                          execution_callee= argument.target
                        ; execution_resolution=
                            ( if argument.target = ""
                              then Observation.Unresolved_dynamic
                              else Observation.Resolved )
                        ; execution_args= []
                        ; execution_loops= [] }
                      in
                      follow
                        invocation
                        (path @ [call.execution_callee])
                        loops
                        activations
                        unknown
                    end )
                  call.execution_args
              end )
            (calls symbol) )
      in
      walk 0 origin.symbol [origin.symbol] [] [] [] )
    roots ;
  List.sort_uniq compare !results
