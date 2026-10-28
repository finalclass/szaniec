open Szaniec_model

type callback_mode =
  | Iteration
  | Activation
  | Once
  | Ignored
  | Unknown

let collection_arity api =
  if api = "Well.Db.with_conn"
  then Some 2
  else if List.mem api ["Otoml.get_array"; "Otoml.find_opt"]
  then Some 3
  else if List.mem api ["Str.global_substitute"; "Str.substitute_first"]
  then Some 3
  else
    match Canonical.split_dots api with
    | [ "Stdlib"
      ; "Seq"
      ; ("map" | "filter" | "filter_map" | "flat_map" | "append") ] ->
        Some 3
    | ["Stdlib"; ("List" | "String"); "to_seq"] -> Some 2
    | ["Stdlib"; "Seq"; ("return" | "singleton")] -> Some 2
    | [ "Stdlib"
      ; "Set"
      ; ( "mem" | "add" | "remove" | "union" | "inter" | "diff" | "compare"
        | "equal" | "subset" | "disjoint" | "find" | "find_opt" | "split"
        | "iter" | "map" | "filter" | "filter_map" | "partition" | "exists"
        | "for_all" ) ] ->
        Some 2
    | ["Stdlib"; "Set"; "fold"] -> Some 3
    | ["Stdlib"; "Fun"; "flip"] -> Some 3
    | ["Stdlib"; ("=" | "<>" | "<" | ">" | "<=" | ">=" | "min" | "max")] ->
        Some 2
    | ["Stdlib"; "Option"; "value"] -> Some 2
    | ["Stdlib"; "String"; "make"] -> Some 2
    | ["Stdlib"; "Option"; ("map" | "iter" | "bind" | "fold")] -> Some 2
    | [ "Stdlib"
      ; "Result"
      ; ("map" | "map_error" | "bind" | "iter" | "iter_error") ] ->
        Some 2
    | ["Stdlib"; "Hashtbl"; "iter"] -> Some 2
    | ["Stdlib"; "Hashtbl"; "fold"] -> Some 3
    | [ "Stdlib"
      ; "String"
      ; ("iter" | "iteri" | "map" | "mapi" | "for_all" | "exists" | "init") ] ->
        Some 2
    | ["Stdlib"; "String"; ("fold_left" | "fold_right")] -> Some 3
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
       |"mem"
       |"memq"
       |"mem_assoc"
       |"mem_assq"
       |"iter"
       |"rev_map"
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
  if
    List.mem
      api
      ["Stdlib.ref"; "Stdlib.:="; "Stdlib.Atomic.make"; "Stdlib.Atomic.set"]
  then Ignored
  else if
    api = "Well.api_token_auth"
    && List.mem argument.label ["verify"; "applies_to"; "authorize"]
  then Activation
  else if
    List.mem api ["Sqlite3.exec"; "Sqlite3.exec_no_headers"]
    && argument.label = "cb"
  then Iteration
  else if argument.embedded
  then
    if api = "Stdlib.ignore" || collection_arity api <> None
    then Ignored
    else Unknown
  else
    let collection =
      match Canonical.split_dots api with
      | ["Stdlib"; ("List" | "Array" | "String"); method_name] ->
          Some method_name
      | _ -> None
    in
    match collection with
    | _
      when List.mem
             (List.nth_opt (Canonical.split_dots api) 1)
             [Some "Set"; Some "Map"]
           && argument.position = -1 ->
        Iteration
    | _
      when String.starts_with ~prefix:"Stdlib.Set." api
           && argument.position = 0
           && List.mem
                (List.hd (List.rev (Canonical.split_dots api)))
                [ "iter"
                ; "map"
                ; "filter"
                ; "filter_map"
                ; "partition"
                ; "exists"
                ; "for_all"
                ; "fold"
                ; "find_first"
                ; "find_first_opt"
                ; "find_last"
                ; "find_last_opt" ] ->
        Iteration
    | _ when api = "Stdlib.Scanf.sscanf" && argument.position = 2 -> Once
    | _ when api = "Str.global_substitute" && argument.position = 1 -> Iteration
    | _ when api = "Str.substitute_first" && argument.position = 1 -> Once
    | _
      when List.mem
             api
             [ "Stdlib.List.of_seq"
             ; "Stdlib.String.of_seq"
             ; "Stdlib.Hashtbl.of_seq" ]
           && argument.position = 0 ->
        Iteration
    | _
      when List.mem
             api
             [ "Stdlib.Seq.map"
             ; "Stdlib.Seq.filter"
             ; "Stdlib.Seq.filter_map"
             ; "Stdlib.Seq.flat_map"
             ; "Stdlib.Seq.append" ]
           && argument.position < 2 ->
        Iteration
    | _ when api = "Stdlib.Option.fold" && argument.label = "some" -> Once
    | _ when api = "Stdlib.Option.bind" && argument.position = 1 -> Once
    | _ when api = "Stdlib.Result.bind" && argument.position = 1 -> Once
    | _
      when List.mem
             api
             [ "Stdlib.Option.map"
             ; "Stdlib.Option.iter"
             ; "Stdlib.Result.map"
             ; "Stdlib.Result.map_error"
             ; "Stdlib.Result.iter"
             ; "Stdlib.Result.iter_error" ]
           && argument.position = 0 ->
        Once
    | _
      when List.mem api ["Stdlib.Hashtbl.iter"; "Stdlib.Hashtbl.fold"]
           && argument.position = 0 ->
        Iteration
    | Some "init" when argument.position = 1 -> Iteration
    | Some
        ( "iter" | "iteri" | "map" | "mapi" | "iter2" | "map2" | "fold_left"
        | "rev_map" | "fold_right" | "fold_left2" | "fold_right2"
        | "fold_left_map" | "concat_map" | "filter" | "filteri" | "filter_map"
        | "partition" | "partition_map" | "exists" | "exists2" | "for_all"
        | "for_all2" | "find" | "find_opt" | "find_index" | "find_map"
        | "find_mapi" | "sort" | "stable_sort" | "fast_sort" | "sort_uniq"
        | "merge" )
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
    | _ when api = "Well.Db.with_conn" -> Once
    | _ when api = "Stdlib.Fun.protect" -> Once
    | _ when api = "Well.Env.with_timeout" -> Once
    | _ when List.mem api ["Well.Db.query"; "Well.Db.query_one"] -> Iteration
    | _ when api = "Well.api_token_auth" -> Activation
    | _ when api = "Well.use" && argument.position = 0 -> Activation
    | _
      when List.mem
             api
             [ "Stdlib.In_channel.with_open_bin"
             ; "Stdlib.In_channel.with_open_text"
             ; "Stdlib.Out_channel.with_open_bin"
             ; "Stdlib.Out_channel.with_open_text" ]
           && argument.position = 1 ->
        Once
    | _ when List.mem api ["Well.stream_open"; "Well.stream"] -> Activation
    | _ when api = "Well.Stream_accept.iter" -> Activation
    | _ when api = "Well.Http_stream.iter" && argument.position = 0 -> Iteration
    | _ when api = "Js_of_ocaml.Js.Opt.case" && argument.position > 0 -> Once
    | _ when api = "Otoml.get_array" && argument.position = 1 -> Iteration
    | _ when api = "Stdlib.ref" -> Ignored
    | _ when api = "Stdlib.:=" -> Ignored
    | _ when api = "Stdlib.Fun.flip" && argument.position = 0 -> Once
    | _ when List.mem api ["Eio.Cancel.protect"; "Well.Db.with_well_db"] -> Once
    | _ when api = "Eio_main.run" && argument.position = 0 -> Once
    | _ when api = "Eio.Fiber.with_binding" && argument.position = 2 -> Once
    | _ when api = "Eio.Fiber.with_binding" -> Ignored
    | _ when api = "Eio.Mutex.use_rw" && argument.position = 2 -> Once
    | _ when api = "Eio.Time.with_timeout_exn" && argument.position = 2 -> Once
    | _ when api = "Otoml.find_opt" && argument.position = 1 -> Once
    | _ when api = "Stdlib.Printf.ksprintf" && argument.position = 0 -> Once
    | _ when api = "Js_of_ocaml.Js.wrap_callback" -> Ignored
    | _
      when List.mem api ["Sqlite3.exec"; "Sqlite3.exec_no_headers"]
           && argument.label = "cb" ->
        Iteration
    | _ when api = "Stdlib.ignore" -> Ignored
    | _ when api = "Stdlib.@@" && argument.position = 0 -> Once
    | _ when api = "Stdlib.|>" && argument.position = 1 -> Once
    | _ when List.mem api ["Stdlib.@@"; "Stdlib.|>"] -> Ignored
    | _ when collection_arity api <> None -> Ignored
    | _ -> Unknown

let callback_arity api =
  match Canonical.split_dots api with
  | [ "Stdlib"
    ; ("List" | "Array" | "String")
    ; ( "iteri" | "mapi" | "iter2" | "map2" | "fold_left" | "fold_right"
      | "fold_left_map" | "exists2" | "for_all2" | "sort" | "stable_sort"
      | "fast_sort" | "sort_uniq" | "merge" ) ] ->
      2
  | ["Stdlib"; "List"; ("fold_left2" | "fold_right2")] -> 3
  | ["Sqlite3"; "exec"] -> 2
  | ["Stdlib"; "Hashtbl"; "iter"] -> 2
  | ["Stdlib"; "Hashtbl"; "fold"] -> 3
  | ["Stdlib"; "Set"; "fold"] -> 2
  | ["Well"; "use"] -> 2
  | ["Stdlib"; "Fun"; "flip"] -> 2
  | _ -> 1

let argument_arity api (argument : Observation.execution_arg) =
  if api = "Stdlib.Seq.flat_map" && argument.position = 0
  then 2
  else if argument.position = -1 && argument.label = "compare"
  then 2
  else callback_arity api

let project_with_callbacks
    ~callback_mode
    ~execution
    ~owner_of
    ~eligible
    ~entry_point
    ~classify =
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
              && not (Execution_paths.local_symbol d.symbol)
           || Hashtbl.mem recursions d.symbol
              && not (Execution_paths.local_symbol d.symbol) ) )
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
                    if
                      mode <> Ignored
                      && not
                           ( Hashtbl.mem definitions call.execution_callee
                           && eligible call.execution_callee
                           && owner_of call.execution_callee
                              = owner_of origin.symbol )
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
                        let supplied =
                          if call.execution_callee = "Stdlib.Scanf.sscanf"
                          then
                            Option.fold
                              ~none:1
                              ~some:(fun d -> d.Observation.definition_arity)
                              (Hashtbl.find_opt definitions argument.target)
                          else argument_arity call.execution_callee argument
                        in
                        let partial =
                          Option.fold
                            ~none:false
                            ~some:(fun d ->
                              d.Observation.definition_arity > supplied )
                            (Hashtbl.find_opt definitions argument.target)
                        in
                        { call with
                          execution_callee= argument.target
                        ; execution_resolution=
                            ( if argument.target = ""
                              then Observation.Unresolved_dynamic
                              else Observation.Resolved )
                        ; execution_args= []
                        ; execution_defaults= []
                        ; execution_supplied= supplied
                        ; execution_partial= partial
                        ; execution_resumed= false
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

let project ~execution ~owner_of ~eligible ~entry_point ~classify =
  project_with_callbacks
    ~callback_mode
    ~execution
    ~owner_of
    ~eligible
    ~entry_point
    ~classify
