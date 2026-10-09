open Szaniec_model

let finding (f : Finding.t) =
  let strings xs = `List (List.map (fun s -> `String s) xs) in
  `Assoc
    [ ("rule", `String f.rule)
    ; ( "severity"
      , `String (if f.severity = Finding.Violation then "violation" else "gap")
      )
    ; ("message", `String f.message)
    ; ("participants", strings f.participants)
    ; ( "locations"
      , `List
          (List.map
             (fun (l : Finding.location) ->
               `Assoc
                 [ ("path", `String l.loc_path)
                 ; ("line", `Int l.loc_line)
                 ; ("col", `Int l.loc_col) ] )
             f.locations ) )
    ; ("evidencePath", strings f.evidence_path) ]

let digest s = Digestif.SHA256.to_hex (Digestif.SHA256.digest_string s)

let () =
  let project_root = Sys.argv.(1) in
  let config =
    match Szaniec_config.Config.load ~project_root ~path:Sys.argv.(2) () with
    | Ok config -> config
    | Error message -> failwith message
  in
  let policy, resolution, cy, observation, interpretation =
    Szaniec_inspection_manager.Inspection_manager.prepare
      {project_root; config; rebuild= false}
  in
  Gc.full_major () ;
  let started = Unix.gettimeofday () in
  let allocated = Gc.allocated_bytes () in
  let findings =
    Szaniec_conformance_engine.Conformance_engine.evaluate
      ~approved:resolution.approved
      ~policy
      ~cy
      ~observation
      ~interpretation
  in
  Printf.eprintf
    "SZANIEC_BENCH evaluation=%.9f allocation=%.0f units=%d paths=%d calls=%d\n\
     %!"
    (Unix.gettimeofday () -. started)
    (Gc.allocated_bytes () -. allocated)
    (List.length observation.units)
    (List.length observation.exec_paths)
    (List.length observation.calls) ;
  let output =
    `Assoc
      [ ("format", `String "szaniec-evaluation-benchmark/1")
      ; ("snapshotDigest", `String observation.snapshot_digest)
      ; ( "observationDigest"
        , `String
            (digest
               (Marshal.to_string
                  { observation with
                    execution= Observation.empty_execution
                  ; functions= []
                  ; coverage= [] }
                  [] ) ) )
      ; ( "interpretationDigest"
        , `String
            (digest
               (Marshal.to_string
                  { interpretation with
                    execution_interactions= []
                  ; execution_flows= [] }
                  [] ) ) )
      ; ( "findingsDigest"
        , `String
            (digest (Yojson.Safe.to_string (`List (List.map finding findings))))
        )
      ; ("findings", `Int (List.length findings)) ]
  in
  print_endline (Yojson.Safe.to_string output)
