open Szaniec_model
module Engine = Szaniec_conformance_engine.Conformance_engine

let check condition message = if not condition then failwith message

let site line = {Observation.site_path= "lib/web_client/page.ml"; line; col= 2}

let step site =
  { Observation.step_callee= "Task_manager.list"
  ; step_resolution= Observation.Resolved
  ; step_site= site
  ; step_args= [] }

let interaction method_name sites : Interpretation.interaction =
  { kind= Interpretation.ServiceRequest
  ; from_owner= "Web_client"
  ; to_service= "Task_manager"
  ; to_method= method_name
  ; target_module= "Task_manager"
  ; resource= ""
  ; api= "Task_manager." ^ method_name
  ; evidence_path= ["App.Web_client.Page.show"; "Task_manager." ^ method_name]
  ; sites }

let () =
  let first = interaction "list" [site 10; site 20; site 10] in
  let second = interaction "add" [site 20] in
  let absent = interaction "remove" [site 30] in
  let index = Engine.index_interaction_sites [first; absent; second; first] in
  check (Engine.interactions_on index [] = []) "empty path" ;
  check
    ( Engine.interactions_on
        index
        [step (site 20); step (site 10); step (site 20)]
    = [first; second; first] )
    "matching must preserve interaction order and distinct entries, without \
     duplicating multisite matches" ;
  check
    ( Engine.interactions_on index [step {(site 20) with site_path= "other.ml"}]
    = [] )
    "same line and column in another file must not match" ;
  check
    (Engine.interactions_on index [step {(site 20) with col= 3}] = [])
    "same line with another column must not match" ;
  check
    (Engine.interactions_on index [step (site 99)] = [])
    "an unobserved site must not match" ;
  let count = 20_000 in
  let inputs = List.init count (fun n -> interaction "list" [site n]) in
  let index = Engine.index_interaction_sites inputs in
  let before = Gc.allocated_bytes () in
  List.iteri
    (fun n i ->
      check
        (Engine.interactions_on index [step (site n)] = [i])
        "each large-observation path must contain only its own interaction" )
    inputs ;
  let allocated = Gc.allocated_bytes () -. before in
  check
    (allocated < float_of_int count *. 8192.)
    "path lookup must not allocate a scan of the entire observation per path" ;
  Printf.printf
    "path interactions: %d indexed lookups, %.0f allocated bytes: ok\n"
    count
    allocated
