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
  print_endline "callable result binding preserves shared ordered DAGs: ok"
