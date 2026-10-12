type step = Observation.path_step

let local_symbol symbol =
  match String.rindex_opt symbol '@' with
  | Some i when i + 1 < String.length symbol ->
      symbol.[i + 1] >= '0' && symbol.[i + 1] <= '9'
  | _ -> false

let key (step : step) =
  ( step.step_callee
  , step.step_resolution
  , step.step_args
  , step.step_resumed
  , step.step_exit )

let normalize steps = steps

let summarize alternatives =
  let alternatives = List.map normalize alternatives in
  let alternatives =
    List.sort
      (fun a b -> compare (List.map key a, a) (List.map key b, b))
      alternatives
  in
  let alternatives =
    List.fold_left
      (fun acc alt ->
        match acc with
        | previous :: _ when List.map key previous = List.map key alt -> acc
        | _ -> alt :: acc )
      []
      alternatives
    |> List.rev
  in
  if List.length alternatives > 256
  then Error "more than 256 distinct execution target summaries"
  else Ok alternatives

let union a b = summarize (a @ b)

let sequence a b =
  if List.length a * List.length b > 4096
  then Error "execution summary composition exceeds 4096 combinations"
  else
    summarize
      (List.concat_map
         (fun left ->
           if List.exists (fun (step : step) -> step.step_exit) left
           then [left]
           else List.map (fun right -> left @ right) b )
         a )
