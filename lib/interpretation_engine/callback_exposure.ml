open Szaniec_model

(* Passing private code to a service is implementation exposure even when the
   receiver stores it and its later invocation cannot yet be resolved. This is
   distinct from treating registration as execution of the callback body. *)
let collect ~receiver_of ~provider_of ~targets ~public_target calls =
  List.concat_map
    (fun (call : Observation.execution_call) ->
      match receiver_of call with
      | None -> []
      | Some receiver ->
          List.concat_map
            (fun (argument : Observation.execution_arg) ->
              Option.value ~default:[] (targets argument.target)
              |> List.filter_map (fun target ->
                  match provider_of target with
                  | Some (provider, unit)
                    when receiver <> provider
                         && not (public_target ~consumer:receiver target) ->
                      Some
                        { Interpretation.kind= ImplementationAccess
                        ; from_owner= receiver
                        ; to_service= provider
                        ; to_method= ""
                        ; target_module= unit
                        ; resource= ""
                        ; api= target
                        ; evidence_path= [call.execution_callee; target]
                        ; sites= [call.execution_site] }
                  | _ -> None ) )
            call.execution_args )
    calls
  |> List.sort_uniq compare
