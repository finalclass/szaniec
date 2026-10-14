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
  List.iter
    (fun (source, target) ->
      Hashtbl.replace
        targets
        source
        (target :: Option.value ~default:[] (Hashtbl.find_opt targets source)) )
    obs.execution.returned_functions ;
  let projection symbol = List.mem "<result>" (Canonical.split_dots symbol) in
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
  let rec resolve visited symbol =
    if List.mem symbol visited || List.length visited >= 64
    then None
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
        | [target] when target <> "" -> resolve (symbol :: visited) target
        | _ -> None )
      | None -> None
  in
  let bindings = Hashtbl.create 32 in
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
    { call with
      execution_callee= target call.execution_callee
    ; execution_resolution=
        resolution call.execution_callee call.execution_resolution
    ; execution_args=
        List.map
          (fun (a : Observation.execution_arg) ->
            {a with target= target a.target} )
          call.execution_args }
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
          invocations= List.map invocation obs.execution.invocations
        ; ordered=
            List.map
              (fun (symbol, body) -> (symbol, steps body))
              obs.execution.ordered } }
  in
  (observation, Hashtbl.to_seq bindings |> List.of_seq |> List.sort compare)
