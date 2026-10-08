open Szaniec_model

let check condition message = if not condition then failwith message

let site line = {Observation.site_path= "lib/web_client/page.ml"; line; col= 2}

let interaction sites : Interpretation.interaction =
  { kind= Interpretation.ServiceRequest
  ; from_owner= "Web_client"
  ; to_service= "Task_manager"
  ; to_method= "list"
  ; target_module= "Task_manager"
  ; resource= ""
  ; api= "Task_manager.list"
  ; evidence_path= ["App.Web_client.Page.show"; "Task_manager.list"]
  ; sites }

let merge = Szaniec_interpretation_engine.Well_adapter.merge_interactions

let () =
  check (merge [] = []) "empty observation" ;
  let first = interaction [site 30; site 10; site 30] in
  let second = interaction [site 20; site 10] in
  check
    (merge [first; second] = [{first with sites= [site 10; site 20; site 30]}])
    "merging must retain every distinct site in source order" ;
  let distinct =
    [ first
    ; {first with kind= Interpretation.QueuedCommand}
    ; {first with from_owner= "Report_client"}
    ; {first with to_service= "Notification_manager"}
    ; {first with to_method= "add"}
    ; {first with target_module= "App.Task_manager.Proxy"}
    ; {first with api= "Task_manager.add"}
    ; { first with
        evidence_path= ["App.Web_client.Page.other"; "Task_manager.list"] } ]
  in
  let result = merge distinct in
  check
    (List.length result = List.length distinct)
    "different participants, methods, APIs and evidence paths must stay \
     distinct" ;
  check
    (result = merge (List.rev distinct))
    "ordering must be independent of insertion order" ;
  let count = 20_000 in
  let inputs =
    List.init count (fun n ->
        let i = {first with api= Printf.sprintf "Task_manager.method_%05d" n} in
        [i; {i with sites= [site 20]}] )
    |> List.concat
  in
  let before = Gc.allocated_bytes () in
  let grouped = merge inputs in
  let allocated = Gc.allocated_bytes () -. before in
  check
    (List.length grouped = count)
    "large observation must retain every group" ;
  check
    (List.for_all
       (fun (i : Interpretation.interaction) ->
         i.sites = [site 10; site 20; site 30] )
       grouped )
    "large observation must retain every site" ;
  (* Bound allocation rather than wall time: the old repeated list scans
     construct identity tuples for every pair of interactions. *)
  check
    (allocated < float_of_int count *. 8192.)
    "large observation must not allocate quadratically" ;
  Printf.printf
    "interaction grouping: %d groups, %.0f allocated bytes: ok\n"
    count
    allocated
