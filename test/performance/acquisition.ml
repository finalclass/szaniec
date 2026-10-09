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
  let artifact = (List.hd all.units).artifact_path in
  let cmt = Cmt_format.read_cmt (Filename.concat root artifact) in
  let metadata = Szaniec_program_access.Ocaml_adapter.strip_tree cmt in
  assert (
    match metadata.cmt_annots with
    | Cmt_format.Implementation structure ->
        structure.str_items = [] && structure.str_type = []
    | _ -> false ) ;
  let without_interface = {cmt with cmt_interface_digest= None} in
  let current metadata =
    Szaniec_program_access.Ocaml_adapter.current_interface
      ~project_root:root
      ~source:(Filename.concat root "no-interface.ml")
      metadata
      artifact
  in
  assert (not (current without_interface)) ;
  assert (
    not
      (current
         (Szaniec_program_access.Ocaml_adapter.strip_tree without_interface) ) ) ;
  let kind = function
    | Cmt_format.Implementation _ -> 0
    | Cmt_format.Interface _ -> 1
    | Cmt_format.Packed _ -> 2
    | Cmt_format.Partial_implementation _ -> 3
    | Cmt_format.Partial_interface _ -> 4
  in
  List.iter
    (fun cmt_annots ->
      let original = {without_interface with cmt_annots} in
      let stripped = Szaniec_program_access.Ocaml_adapter.strip_tree original in
      assert (kind original.cmt_annots = kind stripped.cmt_annots) ;
      assert (current original = current stripped) )
    [ cmt.cmt_annots
    ; Cmt_format.Interface
        {Typedtree.sig_items= []; sig_type= []; sig_final_env= Env.empty}
    ; Cmt_format.Packed ([], [])
    ; Cmt_format.Partial_implementation [||]
    ; Cmt_format.Partial_interface [||] ] ;
  print_endline
    "tree-free metadata preserves annotation kind and interface requirements: \
     ok" ;
  let cmi_path =
    Filename.concat root (Filename.remove_extension artifact ^ ".cmi")
  in
  let cmi = Cmi_format.read_cmi cmi_path in
  let expected = List.assoc cmt.cmt_modname cmi.cmi_crcs in
  assert (expected <> None) ;
  let input = open_in_bin cmi_path in
  let bytes =
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () -> really_input_string input (in_channel_length input))
  in
  let probe = Filename.temp_file "szaniec-import-path-" "" in
  Sys.remove probe ;
  Unix.mkdir probe 0o700 ;
  let first = Filename.concat probe "first" in
  let second = Filename.concat probe "second" in
  Unix.mkdir first 0o700 ;
  Unix.mkdir second 0o700 ;
  let name = String.uncapitalize_ascii cmt.cmt_modname ^ ".cmi" in
  let first_file = Filename.concat first name in
  let second_file = Filename.concat second name in
  let write path bytes =
    let output = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr output)
      (fun () ->
        output_string output bytes ;
        close_out output )
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path ->
          try Sys.remove path with
          | Sys_error _ -> () )
        [first_file; second_file] ;
      List.iter Unix.rmdir [first; second; probe] )
    (fun () ->
      let local_units = Hashtbl.create 1 in
      Hashtbl.add local_units cmt.cmt_modname artifact ;
      let check visible hidden =
        Szaniec_program_access.Ocaml_adapter.current_imports
          ~project_root:root
          ~local_units
          { cmt with
            cmt_imports= [(cmt.cmt_modname, expected)]
          ; cmt_loadpath= {visible; hidden} }
      in
      write first_file "invalid first interface" ;
      write second_file bytes ;
      assert (not (check [first; second] [])) ;
      assert (check [second; first] []) ;
      Sys.remove first_file ;
      assert (check [first; second] []) ;
      assert (check [first] [second]) ;
      Sys.remove second_file ;
      assert (not (check [first; second] [])) ) ;
  print_endline
    "compiler import paths preserve first-match rejection, fallback and \
     missing-local gaps: ok" ;
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
