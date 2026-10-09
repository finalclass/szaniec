(* InspectionManager: coordinates policy resolution, observation,
   interpretation and evaluation, and assembles the report. *)

open Szaniec_model

type request =
  { project_root: string
  ; config: Szaniec_config.Config.t
  ; rebuild: bool }

exception Policy_error of string

(* When szaniec itself is invoked from inside a dune process (e.g. `dune
   exec` or a dune action), the injected variables point at the outer
   workspace and break the nested build of the inspected project. Strip
   them so the nested dune resolves its own toolchain and roots. *)
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
     survive no-op dune runs; changed sources force their rebuild. *)
  let unsets = String.concat " " env_unsets_for_nested_dune in
  (* DUNE_CACHE=disabled: cache-restored artifacts carry old mtimes, which
     would defeat the mtime-based freshness check *)
  let code =
    Sys.command ("unset " ^ unsets ^ "; DUNE_CACHE=disabled dune build")
  in
  ( try Unix.chdir old_cwd with
  | Sys_error _ -> () ) ;
  code

let observe_program
    ?(evidence = Szaniec_program_access.Ocaml_adapter.All)
    (req : request)
    (policy : Policy.t) =
  let build_code =
    if req.rebuild then Some (run_dune_build req.project_root) else None
  in
  let observation =
    Szaniec_program_access.Ocaml_adapter.observe
      ~evidence
      ~project_root:req.project_root
      ~program_roots:policy.program_roots
      ~assume_fresh:(build_code = Some 0)
      ()
  in
  match build_code with
  | Some code when code <> 0 ->
      { observation with
        Observation.gaps=
          { Observation.gap_code= "GAP-BUILD"
          ; gap_path= "dune-project"
          ; gap_detail= Printf.sprintf "analysis rebuild failed (exit %d)" code
          }
          :: observation.gaps }
  | _ -> observation

(* Project the interpretation onto the per-service/per-method call
   network. *)
let build_callgraph
    ~(cy : Szaniec_architecture_access.Cyrograf.t)
    ~(observation : Observation.t)
    ~(interpretation : Interpretation.t) : Callgraph.t =
  let idx : (string * string, Callgraph.method_info ref) Hashtbl.t =
    Hashtbl.create 32
  in
  let services =
    List.map
      (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
        { Callgraph.si_name= s.Szaniec_architecture_access.Cyrograf.svc_name
        ; si_role=
            Szaniec_architecture_access.Cyrograf.role_to_string
              s.Szaniec_architecture_access.Cyrograf.svc_role
        ; si_methods=
            List.map
              (fun (m : Szaniec_architecture_access.Cyrograf.method_decl) ->
                { Callgraph.mi_name=
                    m.Szaniec_architecture_access.Cyrograf.m_name
                ; mi_request= m.Szaniec_architecture_access.Cyrograf.m_request
                ; mi_response= m.Szaniec_architecture_access.Cyrograf.m_response
                ; mi_calls= []
                ; mi_flow=
                    { Interpretation.complete= false
                    ; steps=
                        [ Interpretation.Flow_unknown
                            ( "execution body unavailable"
                            , {Observation.site_path= ""; line= 0; col= 0} ) ]
                    }
                ; mi_called_by= [] } )
              s.Szaniec_architecture_access.Cyrograf.svc_methods } )
      cy.Szaniec_architecture_access.Cyrograf.services
  in
  List.iter
    (fun (si : Callgraph.service_info) ->
      List.iter
        (fun (mi : Callgraph.method_info) ->
          Hashtbl.replace
            idx
            (si.Callgraph.si_name, mi.Callgraph.mi_name)
            (ref mi) )
        si.Callgraph.si_methods )
    services ;
  (* Attribute a boundary-crossing interaction to the rpc method that
     originated it. The evidence path starts at `Unit.Symbol` (for
     example `Task_manager_impl.Impl.add`); the symbol may contain
     module nesting, so the unit is the longest owned prefix and the
     method is the symbol's last segment. Only a declared rpc method of
     that service is a callgraph node. *)
  let owner_prefixes = Hashtbl.create 64 in
  List.iter
    (fun (own : Interpretation.ownership) ->
      if
        own.owner_service <> ""
        && not (Hashtbl.mem owner_prefixes own.owner_module)
      then Hashtbl.add owner_prefixes own.owner_module own )
    interpretation.ownerships ;
  let origin_cache = Hashtbl.create 128 in
  let method_of_symbol symbol =
    match Hashtbl.find_opt origin_cache symbol with
    | Some result -> result
    | None ->
        let rec owner candidate =
          match Hashtbl.find_opt owner_prefixes candidate with
          | Some own -> Some own
          | None -> (
            match String.rindex_opt candidate '.' with
            | None -> None
            | Some i -> owner (String.sub candidate 0 i) )
        in
        let result =
          Option.bind (owner symbol) (fun own ->
              let method_name =
                if symbol = own.Interpretation.owner_module
                then ""
                else List.hd (List.rev (String.split_on_char '.' symbol))
              in
              let key = (own.owner_service, method_name) in
              if Hashtbl.mem idx key then Some key else None )
        in
        Hashtbl.replace origin_cache symbol result ;
        result
  in
  let method_of_origin (_owner : string) (evidence : string list) :
      (string * string) option =
    match evidence with
    | origin :: _ -> method_of_symbol origin
    | [] -> None
  in
  let edges = Hashtbl.create 128 in
  let reverse = Hashtbl.create 128 in
  let accumulate table key target sites contexts =
    match Hashtbl.find_opt table key with
    | None ->
        Hashtbl.add table key (ref ({Callgraph.target; sites; contexts}, false))
    | Some value ->
        let edge, _ = !value in
        value :=
          ( { edge with
              sites= List.rev_append sites edge.sites
            ; contexts= List.rev_append contexts edge.contexts }
          , true )
  in
  let finish ((edge : Callgraph.edge), merged) =
    if merged
    then
      { edge with
        Callgraph.sites= List.sort_uniq compare edge.sites
      ; contexts= List.sort_uniq compare edge.contexts }
    else edge
  in
  let add_edge src tgt sites contexts =
    if Hashtbl.mem idx src then accumulate edges (src, tgt) tgt sites contexts
  in
  let add_called_by tgt src =
    if Hashtbl.mem idx tgt then Hashtbl.replace reverse (tgt, src) ()
  in
  List.iter
    (fun (i : Interpretation.interaction) ->
      let tgt =
        match i.Interpretation.kind with
        | Interpretation.ServiceRequest when i.Interpretation.to_method <> "" ->
            Some
              (Callgraph.Service_method
                 (i.Interpretation.to_service, i.Interpretation.to_method) )
        | Interpretation.ServiceRequest ->
            Some
              (Callgraph.Service_method
                 (i.Interpretation.to_service, i.Interpretation.api) )
        | Interpretation.ResourceAccess ->
            Some (Callgraph.Resource_target i.Interpretation.resource)
        | Interpretation.ExternalCall ->
            Some (Callgraph.External_target i.Interpretation.api)
        | Interpretation.ImplementationAccess ->
            Some (Callgraph.External_target i.Interpretation.target_module)
        | Interpretation.Registration
         |Interpretation.QueuedCommand
         |Interpretation.Publication
         |Interpretation.Subscription ->
            None
      in
      match
        ( tgt
        , method_of_origin
            i.Interpretation.from_owner
            i.Interpretation.evidence_path )
      with
      | Some tgt, Some src -> (
          add_edge src tgt i.Interpretation.sites [] ;
          (* calledBy is the reverse projection over service methods
             only; a client page is not a cyrograf method *)
          match tgt with
          | Callgraph.Service_method (a, b) when Hashtbl.mem idx src ->
              add_called_by (a, b) src
          | _ -> () )
      | _ -> () )
    interpretation.Interpretation.interactions ;
  let entries = Hashtbl.create 32 in
  let entry_edges = Hashtbl.create 128 in
  List.iter
    (fun (execution : Interpretation.execution_interaction) ->
      let i = execution.execution_interaction in
      let target =
        match i.kind with
        | Interpretation.ServiceRequest ->
            Callgraph.Service_method (i.to_service, i.to_method)
        | ResourceAccess -> Callgraph.Resource_target i.resource
        | _ when i.api = "" ->
            Callgraph.Unresolved_target "unresolved execution target"
        | _ -> Callgraph.External_target i.api
      in
      let contexts = [execution.execution_context] in
      let origin = execution.execution_origin in
      match method_of_symbol origin.symbol with
      | Some source -> (
          add_edge source target i.sites contexts ;
          match target with
          | Callgraph.Service_method (service, name) ->
              add_called_by (service, name) source
          | _ -> () )
      | None ->
          let entry =
            Option.value
              ~default:
                { Callgraph.symbol= origin.symbol
                ; owner= execution.execution_owner
                ; site= origin.definition_site
                ; calls= []
                ; flow=
                    { Interpretation.complete= false
                    ; steps=
                        [ Interpretation.Flow_unknown
                            ( "execution flow unavailable"
                            , origin.definition_site ) ] } }
              (Hashtbl.find_opt entries origin.symbol)
          in
          Hashtbl.replace entries origin.symbol entry ;
          accumulate entry_edges (origin.symbol, target) target i.sites contexts )
    interpretation.execution_interactions ;
  Hashtbl.iter
    (fun (source, _) value ->
      match Hashtbl.find_opt idx source with
      | None -> ()
      | Some r -> r := {!r with Callgraph.mi_calls= finish !value :: !r.mi_calls} )
    edges ;
  Hashtbl.iter
    (fun (target, source) () ->
      match Hashtbl.find_opt idx target with
      | None -> ()
      | Some r ->
          r := {!r with Callgraph.mi_called_by= source :: !r.mi_called_by} )
    reverse ;
  Hashtbl.iter
    (fun _ (r : Callgraph.method_info ref) ->
      r :=
        { !r with
          Callgraph.mi_calls= List.sort Callgraph.compare_edge !r.mi_calls
        ; mi_called_by= List.sort compare !r.mi_called_by } )
    idx ;
  Hashtbl.iter
    (fun (symbol, _) value ->
      let entry = Hashtbl.find entries symbol in
      Hashtbl.replace
        entries
        symbol
        {entry with Callgraph.calls= finish !value :: entry.calls} )
    entry_edges ;
  Hashtbl.iter
    (fun symbol (entry : Callgraph.entry_point) ->
      Hashtbl.replace
        entries
        symbol
        {entry with calls= List.sort Callgraph.compare_edge entry.calls} )
    entries ;
  let flow_sources = Hashtbl.create 32 in
  List.iter
    (fun (execution : Interpretation.execution_flow) ->
      let origin = execution.flow_origin in
      match method_of_symbol origin.symbol with
      | Some source ->
          let previous =
            Option.value ~default:[] (Hashtbl.find_opt flow_sources source)
          in
          Hashtbl.replace flow_sources source (execution.flow :: previous)
      | None ->
          let entry =
            Option.value
              ~default:
                { Callgraph.symbol= origin.symbol
                ; owner= execution.flow_owner
                ; site= origin.definition_site
                ; calls= []
                ; flow= execution.flow }
              (Hashtbl.find_opt entries origin.symbol)
          in
          Hashtbl.replace entries origin.symbol {entry with flow= execution.flow} )
    interpretation.execution_flows ;
  Hashtbl.iter
    (fun source flows ->
      match Hashtbl.find_opt idx source with
      | None -> ()
      | Some r ->
          let mi_flow =
            match flows with
            | [flow] -> flow
            | _ ->
                { Interpretation.complete= false
                ; steps=
                    [ Interpretation.Flow_unknown
                        ( "multiple implementation origins"
                        , {Observation.site_path= ""; line= 0; col= 0} )
                    ; Interpretation.Flow_choice
                        (List.mapi
                           (fun i flow ->
                             ( Printf.sprintf "implementation-%d" i
                             , flow.Interpretation.steps ) )
                           (List.sort compare flows) ) ] }
          in
          r := {!r with mi_flow} )
    flow_sources ;
  let services =
    List.map
      (fun (si : Callgraph.service_info) ->
        { si with
          Callgraph.si_methods=
            List.map
              (fun (mi : Callgraph.method_info) ->
                match
                  Hashtbl.find_opt
                    idx
                    (si.Callgraph.si_name, mi.Callgraph.mi_name)
                with
                | Some r -> !r
                | None -> mi )
              si.Callgraph.si_methods } )
      services
  in
  let unresolved =
    List.filter_map
      (fun (c : Observation.call) ->
        if c.Observation.resolution <> Observation.Resolved
        then
          Some
            (c.Observation.call_unit, c.Observation.caller, c.Observation.site)
        else None )
      observation.Observation.calls
    |> List.sort_uniq compare
  in
  let unclassified =
    List.filter_map
      (fun (o : Interpretation.ownership) ->
        match o.Interpretation.owner_class with
        | Interpretation.Unclassified -> Some o.Interpretation.owner_module
        | _ -> None )
      interpretation.Interpretation.ownerships
  in
  { Callgraph.services
  ; entry_points=
      Hashtbl.fold (fun _ entry entries -> entry :: entries) entries []
      |> List.sort (fun (a : Callgraph.entry_point) b ->
          compare a.symbol b.symbol )
  ; unresolved
  ; unclassified_units= List.sort_uniq compare unclassified }

let check (req : request) : Finding.report =
  (* 1. resolve the approved policy *)
  let resolution, approval_gap =
    match
      Szaniec_architecture_access.Architecture_access.resolve ~config:req.config
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
    let p = req.config.path in
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
  (* services come from the cyrograf contract files *)
  let cy =
    match
      Szaniec_architecture_access.Cyrograf.load
        ~project_root:req.project_root
        ~program_roots:policy.Policy.program_roots
    with
    | Ok cy -> cy
    | Error e -> raise (Policy_error e)
  in
  (* 2. observe the program; a successful rebuild guarantees that dune's
     content-tracked artifacts are current, so freshness is assumed for
     them; without a rebuild freshness is verified by mtimes *)
  let observation =
    observe_program
      ~evidence:Szaniec_program_access.Ocaml_adapter.Architecture
      req
      policy
  in
  (* 3. interpret *)
  let interpretation =
    Szaniec_interpretation_engine.Well_adapter.interpret
      ~approved:
        resolution.Szaniec_architecture_access.Architecture_access.approved
      ~policy
      ~cy
      observation
  in
  (* 4. evaluate *)
  let violations =
    Szaniec_conformance_engine.Conformance_engine.evaluate
      ~approved:
        resolution.Szaniec_architecture_access.Architecture_access.approved
      ~policy
      ~cy
      ~observation
      ~interpretation
  in
  let callgraph = build_callgraph ~cy ~observation ~interpretation in
  let obs_gaps =
    List.map
      Szaniec_conformance_engine.Conformance_engine.gap_finding
      observation.Observation.gaps
  in
  (* SPEC-UNDECLARED-METHOD travels on the gap channel so the
     conformance engine can turn it into a violation. It is not an
     analysis gap and must not force exit 2. *)
  let interp_gaps =
    interpretation.Interpretation.gaps
    |> List.filter (fun (g : Observation.gap) ->
        not (String.equal g.Observation.gap_code "SPEC-UNDECLARED-METHOD") )
    |> List.map Szaniec_conformance_engine.Conformance_engine.gap_finding
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
      ; profile= Version.default_profile
      ; program_roots= policy.Policy.program_roots
      ; snapshot_digest= observation.Observation.snapshot_digest
      ; compiler
      ; exclusions= Szaniec_interpretation_engine.Well_adapter.exclusions }
  ; findings= all_findings
  ; callgraph= Some callgraph
  ; summary=
      { Finding.violations= n_violations
      ; gaps= n_gaps
      ; units= List.length observation.Observation.units
      ; calls= List.length observation.Observation.calls
      ; type_refs= List.length observation.Observation.type_refs } }

(* Evidence gaps that mean a file was not measured. Interpretation gaps
   (unresolved calls, ownership) do not hide a measured function. *)
let evidence_gap (g : Observation.gap) : bool =
  match g.Observation.gap_code with
  | "GAP-STALE-ARTIFACT"
   |"GAP-BUILD"
   |"GAP-UNOBSERVED-SOURCE"
   |"GAP-ARTIFACT-READ"
   |"GAP-UNSUPPORTED-COMPILER"
   |"GAP-UNSUPPORTED-CONSTRUCT" ->
      true
  | _ -> false

let prepare
    ?(evidence = Szaniec_program_access.Ocaml_adapter.All)
    (req : request) :
    Policy.t
    * Szaniec_architecture_access.Architecture_access.resolution
    * Szaniec_architecture_access.Cyrograf.t
    * Observation.t
    * Interpretation.t =
  let resolution, _approval_gap =
    match
      Szaniec_architecture_access.Architecture_access.resolve ~config:req.config
    with
    | Error e -> raise (Policy_error e)
    | Ok (r, gap) -> (r, gap)
  in
  let policy =
    resolution.Szaniec_architecture_access.Architecture_access.policy
  in
  let cy =
    match
      Szaniec_architecture_access.Cyrograf.load
        ~project_root:req.project_root
        ~program_roots:policy.Policy.program_roots
    with
    | Ok cy -> cy
    | Error e -> raise (Policy_error e)
  in
  let observation = observe_program ~evidence req policy in
  let interpretation =
    Szaniec_interpretation_engine.Well_adapter.interpret
      ~approved:
        resolution.Szaniec_architecture_access.Architecture_access.approved
      ~policy
      ~cy
      observation
  in
  (policy, resolution, cy, observation, interpretation)

let complexity (req : request) ~(sort : string) : Complexity.t =
  let policy, resolution, cy, observation, interpretation =
    prepare ~evidence:Szaniec_program_access.Ocaml_adapter.Measurement req
  in
  let owner_of (unit_name : string) : Interpretation.ownership option =
    List.find_opt
      (fun (o : Interpretation.ownership) ->
        String.equal o.Interpretation.owner_module unit_name )
      interpretation.Interpretation.ownerships
  in
  let rpc_name (service : string) (name : string) : bool =
    service <> ""
    && List.exists
         (fun (s : Szaniec_architecture_access.Cyrograf.service) ->
           String.equal s.Szaniec_architecture_access.Cyrograf.svc_name service
           && List.exists
                (fun (m : Szaniec_architecture_access.Cyrograf.method_decl) ->
                  String.equal
                    m.Szaniec_architecture_access.Cyrograf.m_name
                    name )
                s.Szaniec_architecture_access.Cyrograf.svc_methods )
         cy.Szaniec_architecture_access.Cyrograf.services
  in
  let entries =
    List.map
      (fun (f : Observation.function_def) ->
        let service, ownership =
          match owner_of f.Observation.fn_unit with
          | Some o ->
              ( o.Interpretation.owner_service
              , Interpretation.class_name o.Interpretation.owner_class )
          | None ->
              ( ""
              , match f.Observation.fn_provenance with
                | Observation.Prov_generated -> "generated"
                | _ -> "unclassified" )
        in
        let binding =
          if
            (not f.Observation.fn_nested)
            && f.Observation.fn_kind = Observation.Fn_named
            && rpc_name service f.Observation.fn_name
          then "rpc"
          else "function"
        in
        { Complexity.id= f.Observation.fn_id
        ; name= f.Observation.fn_name
        ; qualname= f.Observation.fn_qualname
        ; kind= Complexity.kind_name f.Observation.fn_kind
        ; binding
        ; nested= f.Observation.fn_nested
        ; provenance= Complexity.provenance_name f.Observation.fn_provenance
        ; module_path= f.Observation.fn_unit
        ; service
        ; ownership
        ; path= f.Observation.fn_path
        ; line= f.Observation.fn_line
        ; col= f.Observation.fn_col
        ; end_line= f.Observation.fn_end_line
        ; end_col= f.Observation.fn_end_col
        ; complexity= Complexity.complexity_of f.Observation.fn_measure
        ; status= Complexity.status_name f.Observation.fn_measure } )
      observation.Observation.functions
  in
  let gaps =
    List.sort_uniq
      (fun a b ->
        compare
          ( a.Observation.gap_code
          , a.Observation.gap_path
          , a.Observation.gap_detail )
          ( b.Observation.gap_code
          , b.Observation.gap_path
          , b.Observation.gap_detail ) )
      ( List.filter evidence_gap observation.Observation.gaps
      @ observation.Observation.measure_gaps )
  in
  let functions = Complexity.sort_entries sort entries in
  let incomplete = gaps <> [] || Complexity.unmeasurable_count functions > 0 in
  let compiler =
    if String.equal observation.Observation.compiler_series "unknown"
    then "unknown"
    else observation.Observation.compiler_series
  in
  { Complexity.status= (if incomplete then "incomplete" else "ok")
  ; policy_name= policy.Policy.name
  ; policy_digest=
      resolution.Szaniec_architecture_access.Architecture_access.policy_digest
  ; approved=
      resolution.Szaniec_architecture_access.Architecture_access.approved
  ; snapshot_digest= observation.Observation.snapshot_digest
  ; compiler
  ; profile= Version.default_profile
  ; program_roots= policy.Policy.program_roots
  ; sort
  ; functions
  ; coverage= observation.Observation.coverage
  ; gaps
  ; exclusions= Complexity.exclusions }
