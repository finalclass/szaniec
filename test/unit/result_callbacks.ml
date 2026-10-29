open Szaniec_model

let () =
  let rec body depth =
    if depth = 0
    then []
    else
      let shared = body (depth - 1) in
      [Observation.Choose [("left", shared); ("right", shared)]]
  in
  let observation =
    { Observation.project_root= "."
    ; program_roots= []
    ; compiler_series= "5.4"
    ; units= []
    ; calls= []
    ; exec_paths= []
    ; value_refs= []
    ; module_aliases= []
    ; alias_only_units= []
    ; defined_values= []
    ; type_refs= []
    ; functions= []
    ; coverage= []
    ; source_files= []
    ; snapshot_digest= ""
    ; gaps= []
    ; measure_gaps= []
    ; execution= {Observation.empty_execution with ordered= [("run", body 30)]}
    }
  in
  let before = Gc.allocated_bytes () in
  let mapped, _ =
    Szaniec_interpretation_engine.Result_callbacks.bind observation
  in
  let allocated = Gc.allocated_bytes () -. before in
  let rec check = function
    | [] -> ()
    | [Observation.Choose [("left", left); ("right", right)]] ->
        assert (left == right) ;
        check left
    | _ -> failwith "ordered DAG shape changed"
  in
  check (List.assoc "run" mapped.execution.ordered) ;
  assert (allocated < 100_000.) ;
  print_endline "callable result binding preserves shared ordered DAGs: ok" ;
  let call callee target =
    { Observation.execution_caller= "App.Codec.decode"
    ; execution_callee= callee
    ; execution_resolution= Observation.Resolved
    ; execution_site= {site_path= "codec.ml"; line= 10; col= 2}
    ; execution_loops= []
    ; execution_partial= false
    ; execution_resumed= false
    ; execution_supplied= 2
    ; execution_defaults= []
    ; execution_values= []
    ; execution_result= "App.Codec.<call@10:2>.<result>"
    ; execution_args=
        [ { Observation.position= 0
          ; label= ""
          ; target
          ; field= ""
          ; embedded= false } ] }
  in
  let invocations =
    [ call "Ppx_deriving_yojson_runtime.safe_map" "App.Codec.decode_item"
    ; call "Unknown.accept" "App.Codec.print_item" ]
  in
  let policy =
    { Policy.name= "callback-identity"
    ; program_roots= []
    ; approved_shared_modules= []
    ; contract_bindings= []
    ; public_contracts= []
    ; local_services= []
    ; resources= [] }
  in
  let interpreted =
    Szaniec_interpretation_engine.Well_adapter.interpret
      ~policy
      ~cy:{services= []; contracts= []}
      { observation with
        execution= {Observation.empty_execution with invocations} }
  in
  let callbacks =
    List.map
      (fun (c : Interpretation.callback_evidence) ->
        (c.callback_callee, c.callback_target, c.callback_phase) )
      interpreted.callbacks
    |> List.sort compare
  in
  assert (
    callbacks
    = [ ( "Ppx_deriving_yojson_runtime.safe_map"
        , "App.Codec.decode_item"
        , Interpretation.Same_path )
      ; ( "Unknown.accept"
        , "App.Codec.print_item"
        , Interpretation.Unknown_callback ) ] ) ;
  print_endline
    "same-caller calls sharing all location identities retain their own \
     callbacks: ok" ;
  let source = "Well.open_http_stream.<result>.<tuple@2>" in
  let invocation = call source "App.Codec.decode.<parameter@0>" in
  let interpreted =
    Szaniec_interpretation_engine.Well_adapter.interpret
      ~policy
      ~cy:{services= []; contracts= []}
      { observation with
        execution= {Observation.empty_execution with invocations= [invocation]}
      }
  in
  assert (
    List.map
      (fun (c : Interpretation.callback_evidence) ->
        (c.callback_callee, c.callback_target, c.callback_phase) )
      interpreted.callbacks
    = [(source, "App.Codec.decode.<parameter@0>", Interpretation.Same_path)] ) ;
  print_endline "callable result rewriting retains the compiler callee: ok"
