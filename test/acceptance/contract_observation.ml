open Szaniec_model

let check condition message = if not condition then failwith message

let () =
  let obs =
    Szaniec_program_access.Ocaml_adapter.observe
      ~project_root:Sys.argv.(1)
      ~program_roots:["lib"]
      ~assume_fresh:false
      ()
  in
  check
    (obs.gaps = [])
    ( "fixture must have fresh compiler evidence: "
    ^ String.concat
        "; "
        (List.map
           (fun (g : Observation.gap) -> g.gap_path ^ ": " ^ g.gap_detail)
           obs.gaps ) ) ;
  List.iter
    (fun target ->
      check
        (List.exists
           (fun (c : Observation.call) -> c.callee = target)
           obs.calls )
        ("contract dependency must remain in compiler evidence: " ^ target) )
    [ "App_contract.App_service_task_access.Result.make"
    ; "App_contract.App_service_task_access.Result.Storage.from_storage_value"
    ; "App_contract.App_service_common.Message.to_data"
    ; "App_browser.App_service_common.Message.Storage.wire_of_storage"
    ; "App_contract.Drut_runtime.enc_string"
    ; "App_browser.Drut_runtime.dec_struct"
    ; "App_browser.App_service_task_manager.Proxy.read" ] ;
  check
    (List.exists
       (fun (v : Observation.value_ref) ->
         v.ref_target = "App_browser.App_service_common.Message.from_drut" )
       obs.value_refs )
    "public codec callbacks must remain executable dependency evidence" ;
  check
    (List.exists
       (fun (v : Observation.value_ref) ->
         v.ref_target = "App_contract.Drut_runtime.Syntax" )
       obs.value_refs )
    "serializer Syntax module dependencies must remain raw evidence" ;
  List.iter
    (fun alias ->
      check
        (List.mem alias obs.module_aliases)
        "explicit-signature aliases must retain exact compiler targets" )
    [ ("App_contract.Common", "App_contract.App_service_common")
    ; ("App_contract.Task_access", "App_contract.App_service_task_access")
    ; ("App_browser.Nested.Common", "App_browser.App_service_common") ] ;
  print_endline "public contract compiler evidence: ok"
