open Szaniec_model

let unwrap = function
  | Ok value -> value
  | Error error -> failwith error

let string value = `String value

let list f values = `List (List.map f values)

let () =
  let project_root = Sys.argv.(1) in
  let config = Szaniec_config.Config.load ~project_root () |> unwrap in
  let resolution, _ =
    Szaniec_architecture_access.Architecture_access.resolve ~config |> unwrap
  in
  let policy = resolution.policy in
  let observation =
    Szaniec_program_access.Ocaml_adapter.observe
      ~project_root
      ~program_roots:policy.program_roots
      ~assume_fresh:false
      ()
  in
  let cy =
    Szaniec_architecture_access.Cyrograf.load
      ~project_root
      ~program_roots:policy.program_roots
    |> unwrap
  in
  let interpretation =
    Szaniec_interpretation_engine.Well_adapter.interpret
      ~approved:resolution.approved
      ~policy
      ~cy
      observation
  in
  let gap (g : Observation.gap) =
    `Assoc [("code", string g.gap_code); ("path", string g.gap_path)]
  in
  `Assoc
    [ ( "units"
      , list
          (fun (u : Observation.unit_info) ->
            `Assoc
              [ ("module", string u.canonical)
              ; ("source", string u.source_path)
              ; ("artifact", string u.artifact_path)
              ; ("fresh", `Bool u.fresh)
              ; ("header", string u.source_header) ] )
          observation.units )
    ; ( "calls"
      , list
          (fun (c : Observation.call) ->
            `Assoc
              [ ("caller", string (c.call_unit ^ "." ^ c.caller))
              ; ("callee", string c.callee) ] )
          observation.calls )
    ; ( "references"
      , list
          (fun (v : Observation.value_ref) -> string v.ref_target)
          observation.value_refs )
    ; ( "owners"
      , list
          (fun (o : Interpretation.ownership) ->
            `Assoc
              [ ("module", string o.owner_module)
              ; ("class", string (Interpretation.class_name o.owner_class))
              ; ("service", string o.owner_service) ] )
          interpretation.ownerships )
    ; ( "interactions"
      , list
          (fun (i : Interpretation.interaction) ->
            `Assoc
              [ ("kind", string (Interpretation.kind_name i.kind))
              ; ("from", string i.from_owner)
              ; ("to", string i.to_service)
              ; ("method", string i.to_method)
              ; ("api", string i.api)
              ; ("path", list string i.evidence_path) ] )
          interpretation.interactions )
    ; ("gaps", list gap (observation.gaps @ interpretation.gaps)) ]
  |> Yojson.Safe.to_string
  |> print_endline
