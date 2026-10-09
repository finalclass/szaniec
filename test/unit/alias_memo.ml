open Szaniec_model

let () =
  let aliases =
    [ ("App", "Public")
    ; ("App.Private", "Store")
    ; ("Store", "Final")
    ; ("App.Private", "Wrong")
    ; ("Cycle", "Other")
    ; ("Other", "Cycle")
    ; ("Self", "Self") ]
  in
  let old = Canonical.alias_resolver aliases in
  let changed =
    Canonical.alias_resolver [("App.Private", "Changed"); ("Cycle", "Resolved")]
  in
  let cases =
    [ ("", Some "")
    ; ("Unknown.x", Some "Unknown.x")
    ; ("App.get", Some "Public.get")
    ; ("App.Private.get", Some "Final.get")
    ; ("App.Private", Some "Final")
    ; ("App.Privately.get", Some "Public.Privately.get")
    ; ("Cycle.get", None)
    ; ("Other.get", None)
    ; ("Self", None) ]
  in
  let verify () =
    for _ = 1 to 100 do
      List.iter (fun (path, expected) -> assert (old path = expected)) cases ;
      assert (changed "App.Private.get" = Some "Changed.get") ;
      assert (changed "Cycle.get" = Some "Resolved.get") ;
      assert (old "Cycle.get" = None) ;
      assert (old "App.Private.get" = Some "Final.get")
    done
  in
  verify () ;
  let workers = List.init 4 (fun _ -> Domain.spawn verify) in
  List.iter Domain.join workers ;
  let chain =
    List.init 200 (fun i ->
        ( "Chain" ^ string_of_int i
        , if i = 199 then "Destination" else "Chain" ^ string_of_int (i + 1) ) )
  in
  let chain = Canonical.alias_resolver chain in
  assert (chain "Chain0.call" = Some "Destination.call") ;
  assert (chain "Chain100.call" = Some "Destination.call") ;
  assert (chain "Chain0.call" = Some "Destination.call") ;
  assert (old "App.Private.get" = Some "Final.get") ;
  print_endline
    "alias memo: longest prefixes, duplicates, misses, cycles, changed \
     inventories and domains: ok"
