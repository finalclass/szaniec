open Szaniec_model
module Manager = Szaniec_inspection_manager.Inspection_manager
module Cy = Szaniec_architecture_access.Cyrograf

let observation =
  { Observation.project_root= "."
  ; program_roots= []
  ; compiler_series= "5.4.1"
  ; units= []
  ; calls= []
  ; execution= Observation.empty_execution
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
  ; measure_gaps= [] }

let owner unit service =
  { Interpretation.owner_module= unit
  ; owner_class= Interpretation.Implementation_of service
  ; owner_service= service }

let site line = {Observation.site_path= "fixture.ml"; line; col= 0}

let interaction ?(origin = "App.Impl.run") kind target line =
  { Interpretation.kind
  ; from_owner= "First_manager"
  ; to_service= target
  ; to_method= "run"
  ; target_module= target
  ; resource= target
  ; api= target
  ; evidence_path= [origin]
  ; sites= [site line; site line] }

let service name =
  { Cy.svc_name= name
  ; svc_role= Cy.Manager
  ; svc_methods= [{Cy.m_name= "run"; m_request= "Unit"; m_response= "Unit"}] }

let () =
  let count =
    if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 4000
  in
  let ordinary =
    [ interaction ServiceRequest "Second_manager" 3
    ; interaction ~origin:"App.Impl.Nested.run" ServiceRequest "First_manager" 4
    ; interaction
        ~origin:"App.Impl.private_helper"
        ServiceRequest
        "Second_manager"
        5
    ; interaction ~origin:"Unmapped.run" ServiceRequest "Second_manager" 6
    ; interaction ResourceAccess "database" 7 ]
  in
  let external_calls =
    List.init count (fun n ->
        interaction ExternalCall (Printf.sprintf "Api%05d" n) (n + 10) )
  in
  let interpretation =
    { Interpretation.ownerships=
        [ owner "App.Impl" "First_manager"
        ; owner "App.Impl.Nested" "Second_manager"
        ; owner "App.Impl.Nested" "Ignored_manager" ]
        @ List.init 2000 (fun n ->
            owner ("Unused" ^ string_of_int n) "First_manager" )
    ; bindings= []
    ; interactions= ordinary @ external_calls @ external_calls
    ; execution_interactions= []
    ; execution_flows= []
    ; gaps= [] }
  in
  Gc.full_major () ;
  let started = Sys.time () in
  let allocated = Gc.allocated_bytes () in
  let graph =
    Manager.build_callgraph
      ~cy:
        { services= List.map service ["First_manager"; "Second_manager"]
        ; contracts= [] }
      ~observation
      ~interpretation
  in
  let elapsed = Sys.time () -. started in
  let allocation = Gc.allocated_bytes () -. allocated in
  let method_of name =
    let service =
      List.find
        (fun (s : Callgraph.service_info) -> s.si_name = name)
        graph.services
    in
    List.hd service.si_methods
  in
  let first = method_of "First_manager"
  and second = method_of "Second_manager" in
  assert (List.length first.mi_calls = count + 2) ;
  assert (second.mi_called_by = [("First_manager", "run")]) ;
  assert (first.mi_called_by = [("Second_manager", "run")]) ;
  assert (List.length second.mi_calls = 1) ;
  assert (List.sort Callgraph.compare_edge first.mi_calls = first.mi_calls) ;
  List.iter
    (fun (edge : Callgraph.edge) ->
      match edge.target with
      | External_target _ -> assert (List.length edge.sites = 1)
      | Service_method _ -> assert (edge.sites = [site 3; site 3])
      | Resource_target _ -> assert (edge.sites = [site 7; site 7])
      | _ -> assert false )
    first.mi_calls ;
  if Array.length Sys.argv = 1 then assert (elapsed < 5.) ;
  if Array.length Sys.argv > 1
  then (
    Printf.eprintf
      "SZANIEC_BENCH evaluation=%.9f allocation=%.0f units=%d paths=%d calls=%d\n\
       %!"
      elapsed
      allocation
      2003
      0
      (List.length interpretation.interactions) ;
    let digest =
      Digestif.SHA256.to_hex
        (Digestif.SHA256.digest_string
           (Marshal.to_string graph [Marshal.No_sharing]) )
    in
    Printf.printf
      "{\"format\":\"szaniec-projection-benchmark/1\",\"graphDigest\":\"%s\"}\n"
      digest )
  else
    Printf.printf
      "callgraph indexes: %d targets, %.3f CPU seconds, %.0f allocated bytes: ok\n"
      count
      elapsed
      allocation
