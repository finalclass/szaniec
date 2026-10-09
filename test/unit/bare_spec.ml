open Szaniec_model

let () =
  let observation =
    { Observation.project_root= "."
    ; program_roots= []
    ; compiler_series= "5.4.1"
    ; units= []
    ; calls= []
    ; execution=
        { Observation.empty_execution with
          definitions=
            [ { Observation.symbol= ""
              ; definition_site= {site_path= "fixture.ml"; line= 1; col= 0}
              ; definition_arity= 0
              ; definition_initializer= false } ] }
    ; exec_paths= []
    ; value_refs=
        [ { Observation.ref_unit= "App.Impl"
          ; ref_caller= "run"
          ; ref_target= "spec"
          ; ref_site= {site_path= "fixture.ml"; line= 1; col= 0} } ]
    ; module_aliases= []
    ; alias_only_units= []
    ; defined_values= []
    ; type_refs= []
    ; functions= []
    ; coverage= []
    ; source_files= []
    ; snapshot_digest= ""
    ; gaps= []
    ; measure_gaps= [] }
  in
  let policy =
    { Policy.name= "bare-spec"
    ; program_roots= []
    ; approved_shared_modules= []
    ; contract_bindings= []
    ; public_contracts= []
    ; resources= [] }
  in
  let interpretation =
    Szaniec_interpretation_engine.Well_adapter.interpret
      ~policy
      ~cy:{services= []; contracts= []}
      observation
  in
  assert (interpretation.bindings = [] && interpretation.ownerships = []) ;
  print_endline "bare spec reference is not module registration evidence: ok"
