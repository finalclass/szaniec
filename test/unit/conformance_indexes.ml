open Szaniec_model
module Engine = Szaniec_conformance_engine.Conformance_engine

let check condition message = if not condition then failwith message

let site line = {Observation.site_path= "lib/web_client/page.ml"; line; col= 2}

let step ?(resolution = Observation.Resolved) callee line =
  { Observation.step_callee= callee
  ; step_resolution= resolution
  ; step_site= site line
  ; step_args= [] }

let paths ?(unit = "App.Page") ?(ambiguous = false) caller alternatives =
  {Observation.paths_unit= unit; paths_caller= caller; alternatives; ambiguous}

let unit_info ?(fresh = true) canonical =
  { Observation.unit_id= canonical
  ; canonical
  ; source_path= "lib/" ^ canonical ^ ".ml"
  ; source_header= ""
  ; source_digest= ""
  ; artifact_path= ""
  ; fresh }

let owner ?(service = "Web_client") canonical =
  { Interpretation.owner_module= canonical
  ; owner_class= Interpretation.Helper_of service
  ; owner_service= service }

let observation exec_paths units =
  { Observation.project_root= "."
  ; program_roots= ["lib"]
  ; compiler_series= "5.4.1"
  ; units
  ; calls=
      List.concat_map
        (fun (p : Observation.exec_paths) ->
          List.concat_map
            (List.map (fun (s : Observation.path_step) ->
                 { Observation.call_unit= p.paths_unit
                 ; caller= p.paths_caller
                 ; callee= s.step_callee
                 ; resolution= s.step_resolution
                 ; site= s.step_site
                 ; args= s.step_args } ) )
            p.alternatives )
        exec_paths
  ; execution= Observation.empty_execution
  ; exec_paths
  ; value_refs= []
  ; module_aliases= []
  ; alias_only_units= []
  ; defined_values= []
  ; type_refs= []
  ; functions= []
  ; coverage= []
  ; source_files= []
  ; snapshot_digest= "fixture"
  ; gaps= []
  ; measure_gaps= [] }

let interaction kind target line =
  { Interpretation.kind
  ; from_owner= "Web_client"
  ; to_service= target
  ; to_method= "run"
  ; target_module= target
  ; resource= ""
  ; api= target ^ ".run"
  ; evidence_path= ["App.Page.entry"; "App.Helper.leaf"; target ^ ".run"]
  ; sites= [site line] }

let policy =
  { Policy.name= "indexes"
  ; program_roots= ["lib"]
  ; approved_shared_modules= []
  ; contract_bindings= []
  ; public_contracts= []
  ; resources= [] }

let evaluate ?units ?ownerships ?(gaps = []) exec_paths interactions =
  let canonical_units =
    List.map (fun (p : Observation.exec_paths) -> p.paths_unit) exec_paths
    |> List.sort_uniq compare
  in
  let units =
    Option.value units ~default:(List.map unit_info canonical_units)
  in
  let ownerships =
    Option.value ownerships ~default:(List.map owner canonical_units)
  in
  Engine.evaluate
    ~approved:true
    ~policy
    ~cy:{services= []; contracts= []}
    ~observation:(observation exec_paths units)
    ~interpretation:
      { ownerships
      ; bindings= []
      ; interactions
      ; execution_interactions= []
      ; execution_flows= []
      ; gaps }

let rules findings = List.map (fun (f : Finding.t) -> f.rule) findings

let requests =
  [ interaction Interpretation.ServiceRequest "First_manager" 10
  ; interaction Interpretation.ServiceRequest "Second_manager" 20 ]

let queued =
  [ interaction Interpretation.QueuedCommand "First_manager" 10
  ; interaction Interpretation.QueuedCommand "Second_manager" 20 ]

let both = [step "First_manager.run" 10; step "Second_manager.run" 20]

let () =
  let nested =
    [ paths "entry" [[step "App.Helper.middle" 1]]
    ; paths ~unit:"App.Helper" "middle" [[step "App.Helper.leaf" 2]]
    ; paths ~unit:"App.Helper" "leaf" [both] ]
  in
  List.iter
    (fun (interactions, rule) ->
      let findings = evaluate nested interactions in
      check (rules findings = [rule]) "nested helpers retain fan-out" ;
      let f = List.hd findings in
      check
        (f.participants = ["Web_client"; "First_manager"; "Second_manager"])
        "fan-out participants" ;
      check
        (f.locations = Engine.sites_locations [site 10; site 20])
        "terminal locations remain in input order" ;
      check
        ( f.evidence_path
        = List.concat_map (fun i -> i.Interpretation.evidence_path) interactions
        )
        "helper evidence remains intact" )
    [(requests, "UC-CLIENT-MULTI-MANAGER"); (queued, "Q-MULTI-MANAGER")] ;
  let alternatives =
    [ paths "entry" [[step "App.Helper.leaf" 1]]
    ; paths ~unit:"App.Helper" "leaf" (List.map (fun s -> [s]) both) ]
  in
  check
    (evaluate alternatives (requests @ queued) = [])
    "mutually exclusive alternatives do not combine" ;
  let separated =
    [paths "left" [[List.hd both]]; paths "right" [[List.nth both 1]]]
  in
  check
    (evaluate separated (requests @ queued) = [])
    "separate entries do not combine" ;
  let failures =
    [ [ paths "entry" [[step "App.Helper.missing" 1]]
      ; paths ~unit:"App.Helper" "other" [[]] ]
    ; [ paths "entry" [[step "App.Helper.leaf" 1]]
      ; paths ~unit:"App.Helper" ~ambiguous:true "leaf" [both] ]
    ; [ paths "entry" [[step "App.Helper.a" 1]]
      ; paths ~unit:"App.Helper" "a" [[step "App.Helper.b" 2]]
      ; paths ~unit:"App.Helper" "b" [[step "App.Helper.a" 3]] ] ]
  in
  List.iter
    (fun ps ->
      let fs = evaluate ps (requests @ queued) in
      check
        (rules fs = ["GAP-AMBIGUOUS-PATH"])
        "missing, ambiguous or recursive helper is a gap" ;
      check
        ( (List.hd fs).locations
        = [{Finding.loc_path= "lib/App.Page.ml"; loc_line= 0; loc_col= 0}] )
        "gap source uses unit metadata" )
    failures ;
  let chain count =
    List.init count (fun n ->
        paths
          ("node" ^ string_of_int n)
          [ ( if n = count - 1
              then both
              else [step ("App.Page.node" ^ string_of_int (n + 1)) (100 + n)] )
          ] )
  in
  check
    (rules (evaluate (chain 9) requests) = ["UC-CLIENT-MULTI-MANAGER"])
    "depth eight remains supported" ;
  check
    (rules (evaluate (chain 10) requests) = ["GAP-AMBIGUOUS-PATH"])
    "depth nine stays incomplete" ;
  let context =
    paths "short" [[step "App.Page.leaf" 1]]
    :: paths "leaf" [both]
    :: List.init 9 (fun n ->
        paths
          ("long" ^ string_of_int n)
          [ [ step
                ( if n = 8
                  then "App.Page.leaf"
                  else "App.Page.long" ^ string_of_int (n + 1) )
                (100 + n) ] ] )
  in
  check
    ( rules (evaluate context requests)
    = ["GAP-AMBIGUOUS-PATH"; "UC-CLIENT-MULTI-MANAGER"] )
    "one helper can succeed at shallow depth and fail at deeper depth" ;
  let wide count =
    [ paths "entry" [[step "App.Helper.leaf" 1; step "App.Helper.leaf" 2]]
    ; paths ~unit:"App.Helper" "leaf" (List.init count (fun _ -> both)) ]
  in
  check
    (rules (evaluate (wide 6) requests) = ["UC-CLIENT-MULTI-MANAGER"])
    "36 expanded alternatives are supported" ;
  check
    (rules (evaluate (wide 7) requests) = ["GAP-AMBIGUOUS-PATH"])
    "49 expanded alternatives exceed the existing cap" ;
  let duplicates = [paths "entry" [both]; paths ~ambiguous:true "entry" []] in
  check
    (rules (evaluate duplicates requests) = ["UC-CLIENT-MULTI-MANAGER"])
    "first duplicate path wins" ;
  check
    (rules (evaluate (List.rev duplicates) requests) = ["GAP-AMBIGUOUS-PATH"])
    "first ambiguous duplicate remains ambiguous" ;
  let same_caller =
    [ paths "entry" [[step "App.Helper.entry" 1]]
    ; paths ~unit:"App.Helper" "entry" [both] ]
  in
  check
    (rules (evaluate same_caller requests) = ["UC-CLIENT-MULTI-MANAGER"])
    "path identity includes the unit as well as the caller" ;
  let foreign = owner ~service:"Other_manager" "App.Helper" in
  let ownerships = [owner "App.Page"; foreign; owner "App.Helper"] in
  check
    (evaluate ~ownerships nested requests = [])
    "first duplicate ownership stops traversal at its boundary" ;
  check
    ( rules (evaluate ~ownerships:(List.rev ownerships) nested requests)
    = ["UC-CLIENT-MULTI-MANAGER"] )
    "first same-family ownership allows helper expansion" ;
  let unclassified =
    {foreign with owner_class= Interpretation.Unclassified; owner_service= ""}
  in
  let first = unit_info ~fresh:false "App.Helper" in
  let second = {(unit_info "App.Helper") with source_path= "second.ml"} in
  check
    (evaluate ~units:[first; second] ~ownerships:[unclassified] [] [] = [])
    "first duplicate metadata controls freshness" ;
  let fs = evaluate ~units:[second; first] ~ownerships:[unclassified] [] [] in
  check
    (rules fs = ["POLICY-UNCLASSIFIED"])
    "fresh first duplicate remains unclassified" ;
  check
    ( (List.hd fs).locations
    = [{Finding.loc_path= "second.ml"; loc_line= 0; loc_col= 0}] )
    "first duplicate metadata supplies the source location" ;
  let fs = evaluate ~units:[] ~ownerships:[unclassified] [] [] in
  check
    (rules fs = ["POLICY-UNCLASSIFIED"] && (List.hd fs).locations = [])
    "missing unit metadata retains the original default" ;
  let unknown =
    paths "entry" [[step ~resolution:Observation.Unresolved_dynamic "" 1]]
  in
  check
    (evaluate [unknown] [] = [])
    "unresolved steps are retained without invented fan-out" ;
  let units = List.map unit_info ["App"; "App.Helper"; "App.Helper.Nested"] in
  let index =
    Engine.index_first (fun (u : Observation.unit_info) -> u.canonical) units
  in
  List.iter
    (fun path ->
      check
        ( Engine.unit_prefix index path
        = Canonical.unit_prefix
            (List.map (fun u -> u.Observation.canonical) units)
            path )
        "indexed prefix preserves longest normalized unit match" )
    [ "App.Helper.Nested.run"
    ; "App.Helper.run"
    ; "App.run"
    ; "App.Helper"
    ; "..App..Helper..run.."
    ; "App.Helpers.run"
    ; "External.run"
    ; ""
    ; "." ] ;
  check
    (evaluate [paths "entry" [[]]] requests = [])
    "indexes are scoped to one evaluation" ;
  let count = 40_000 in
  let large_paths = List.init count (fun n -> paths (string_of_int n) [[]]) in
  let large_units =
    List.init count (fun n -> unit_info ~fresh:false ("Unit" ^ string_of_int n))
  in
  let ownerships =
    List.map
      (fun u -> {unclassified with owner_module= u.Observation.canonical})
      large_units
  in
  Gc.full_major () ;
  let started = Sys.time () in
  let before = Gc.allocated_bytes () in
  let fs =
    evaluate
      ~units:(unit_info "App.Page" :: large_units)
      ~ownerships:(ownerships @ [owner "App.Page"])
      large_paths
      []
  in
  let elapsed = Sys.time () -. started in
  let allocated = Gc.allocated_bytes () -. before in
  check (fs = []) "large inventory retains all paths and stale metadata" ;
  check
    (elapsed < 5.)
    "large inventory must not repeatedly scan paths or metadata" ;
  check
    (allocated < float_of_int count *. 8192.)
    "evaluation allocation remains bounded" ;
  Printf.printf
    "conformance indexes: %d paths and units, %.3f CPU seconds, %.0f allocated \
     bytes: ok\n"
    count
    elapsed
    allocated
