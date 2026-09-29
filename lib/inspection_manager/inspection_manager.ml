(* InspectionManager: coordinates policy resolution, observation,
   interpretation and evaluation, and assembles the report. *)

open Szaniec_model

type request =
  { project_root: string
  ; policy_path: string
  ; approval_path: string option
  ; rebuild: bool }

exception Policy_error of string

(* When szaniec itself is invoked from inside a dune process (e.g. `dune
   exec` or a dune action), the injected variables point at the outer
   workspace and break the nested build of the inspected project: toolchain
   paths (DUNE_OCAML_*, OCAMLPATH), root detection (DUNE_SOURCEROOT,
   INSIDE_DUNE) and path rewriting (BUILD_PATH_PREFIX_MAP). Strip them so
   the nested dune resolves its own toolchain and roots. *)
let env_unsets_for_nested_dune : string list =
  Unix.environment ()
  |> Array.to_list
  |> List.filter_map (fun entry ->
      let k =
        match String.index_opt entry '=' with
        | Some i -> String.sub entry 0 i
        | None -> entry
      in
      let starts prefix =
        String.length k >= String.length prefix
        && String.sub k 0 (String.length prefix) = prefix
      in
      if
        starts "DUNE_"
        || starts "OCAML"
        || starts "CAML_"
        || starts "BUILD_PATH_PREFIX_MAP"
        || k = "INSIDE_DUNE"
      then Some k
      else None )
  |> List.sort_uniq compare

let run_dune_build (project_root : string) : int =
  let old_cwd = Sys.getcwd () in
  ( try Unix.chdir project_root with
  | Sys_error _ -> () ) ;
  (* Incremental rebuild. Byte .cmt artifacts (which the adapter prefers)
     survive no-op dune runs; changed sources force their rebuild, so this
     restores freshness for mutated trees. *)
  let unsets = String.concat " " env_unsets_for_nested_dune in
  let code = Sys.command ("unset " ^ unsets ^ "; dune build") in
  ( try Unix.chdir old_cwd with
  | Sys_error _ -> () ) ;
  code

let check (req : request) : Finding.report =
  (* 1. resolve the approved policy *)
  let resolution, approval_gap =
    match
      Szaniec_architecture_access.Architecture_access.resolve
        ~policy_path:req.policy_path
        ~approval_path:req.approval_path
    with
    | Error e -> raise (Policy_error e)
    | Ok (r, gap) -> (r, gap)
  in
  let policy =
    resolution.Szaniec_architecture_access.Architecture_access.policy
  in
  (* paths recorded in findings are relative to the project root when the
     policy lives under it *)
  let policy_display_path =
    let root = req.project_root in
    let p = req.policy_path in
    if
      String.length p > String.length root + 1
      && String.sub p 0 (String.length root + 1) = root ^ "/"
    then
      String.sub
        p
        (String.length root + 1)
        (String.length p - String.length root - 1)
    else Filename.basename p
  in
  (* 2. observe the program *)
  if req.rebuild then ignore (run_dune_build req.project_root) ;
  let observation =
    Szaniec_program_access.Ocaml_adapter.observe
      ~project_root:req.project_root
      ~program_roots:policy.Policy.program_roots
      ()
  in
  (* 3. interpret *)
  let interpretation =
    Szaniec_interpretation_engine.Well_adapter.interpret ~policy observation
  in
  (* 4. evaluate *)
  let violations =
    Szaniec_conformance_engine.Conformance_engine.evaluate
      ~policy
      ~observation
      ~interpretation
  in
  let obs_gaps =
    List.map
      Szaniec_conformance_engine.Conformance_engine.gap_finding
      observation.Observation.gaps
  in
  let interp_gaps =
    List.map
      Szaniec_conformance_engine.Conformance_engine.gap_finding
      interpretation.Interpretation.gaps
  in
  let approval_gap_findings =
    match approval_gap with
    | Some g ->
        [ Szaniec_conformance_engine.Conformance_engine.gap_finding
            {g with Observation.gap_path= policy_display_path} ]
    | None -> []
  in
  let all_findings =
    List.sort
      Finding.compare
      (Finding.dedupe
         (violations @ obs_gaps @ interp_gaps @ approval_gap_findings) )
  in
  let n_violations =
    List.length
      (List.filter
         (fun f -> f.Finding.severity = Finding.Violation)
         all_findings )
  in
  let n_gaps =
    List.length
      (List.filter
         (fun f -> f.Finding.severity = Finding.GapFinding)
         all_findings )
  in
  let status =
    if n_gaps > 0
    then Finding.Incomplete
    else if n_violations > 0
    then Finding.Violations
    else Finding.Ok
  in
  let compiler =
    if String.equal observation.Observation.compiler_series "unknown"
    then "unknown"
    else observation.Observation.compiler_series
  in
  { Finding.status
  ; inputs=
      { Finding.policy=
          { Finding.policy_name= policy.Policy.name
          ; policy_digest=
              resolution
                .Szaniec_architecture_access.Architecture_access.policy_digest
          ; approved=
              resolution
                .Szaniec_architecture_access.Architecture_access.approved
          ; approved_digest=
              resolution
                .Szaniec_architecture_access.Architecture_access.approved_digest
          }
      ; profile= policy.Policy.profile
      ; program_roots= policy.Policy.program_roots
      ; snapshot_digest= observation.Observation.snapshot_digest
      ; compiler
      ; exclusions= Szaniec_interpretation_engine.Well_adapter.exclusions }
  ; findings= all_findings
  ; summary=
      { Finding.violations= n_violations
      ; gaps= n_gaps
      ; units= List.length observation.Observation.units
      ; calls= List.length observation.Observation.calls
      ; type_refs= List.length observation.Observation.type_refs } }
