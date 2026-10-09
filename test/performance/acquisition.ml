open Szaniec_model

let () =
  let root = Sys.argv.(1) in
  let observe evidence =
    Szaniec_program_access.Ocaml_adapter.observe
      ~evidence
      ~project_root:root
      ~program_roots:["lib"]
      ~assume_fresh:false
      ()
  in
  let all = observe All in
  let architecture = observe Architecture in
  let measurement = observe Measurement in
  assert (
    architecture.functions = []
    && architecture.coverage = []
    && architecture.measure_gaps = [] ) ;
  assert (
    measurement.execution = Observation.empty_execution
    && measurement.exec_paths = [] ) ;
  assert (architecture = {all with functions= []; coverage= []; measure_gaps= []} ) ;
  assert (
    measurement
    = {all with execution= Observation.empty_execution; exec_paths= []} ) ;
  Printf.printf
    "evidence capabilities: %d units, %d functions, identical requested facts: \
     ok\n"
    (List.length all.units)
    (List.length all.functions)
