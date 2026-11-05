(* OCaml ProgramAccess adapter (measurement).

   Reads compiler-typed artifacts (.cmt) produced by dune for the inspected
   project, verifies that each one is current for its source, and measures
   every syntactic function. See docs/contracts/complexity-metric.md and
   docs/decisions/stack.md. Supported artifacts: OCaml
   [Szaniec_model.Version.supported_compiler_series] .cmt files. *)

module Measurement = Complexity
open Szaniec_model

let ( // ) = Filename.concat

(* ── filesystem scanning ─────────────────────────────────────────── *)

let skip_dir_names = ["_build"; "node_modules"; "_release"; "_artifacts"; "dist"]

let rec scan
    (base : string)
    (rel : string)
    (pred : string -> bool)
    (acc : string list ref)
    (hidden : bool) =
  let dir = if rel = "" then base else base // rel in
  try
    let entries = Sys.readdir dir in
    Array.iter
      (fun e ->
        if e = "." || e = ".."
        then ()
        else if (not hidden) && String.length e > 0 && e.[0] = '.'
        then ()
        else if List.mem e skip_dir_names
        then ()
        else if Sys.is_directory (dir // e)
        then scan base (if rel = "" then e else rel // e) pred acc hidden
        else if pred e
        then acc := (if rel = "" then e else rel // e) :: !acc )
      entries
  with
  | Sys_error _ -> ()

let scan_sources (project_root : string) (roots : string list) : string list =
  let acc = ref [] in
  List.iter
    (fun root ->
      if Sys.file_exists (project_root // root)
      then
        scan
          project_root
          root
          (fun e ->
            Filename.check_suffix e ".ml" || Filename.check_suffix e ".mlx" )
          acc
          false )
    roots ;
  List.sort_uniq compare !acc

let scan_artifacts (project_root : string) : string list =
  let acc = ref [] in
  scan project_root "_build" (fun e -> Filename.check_suffix e ".cmt") acc true ;
  List.filter
    (fun p -> String.length p > 15 && String.sub p 0 15 = "_build/default/")
    !acc
  |> List.sort compare

let strip_build_prefix (p : string) : string =
  let prefix = "_build/default/" in
  if
    String.length p > String.length prefix
    && String.sub p 0 (String.length prefix) = prefix
  then
    String.sub p (String.length prefix) (String.length p - String.length prefix)
  else p

(* ── identity helpers ─────────────────────────────────────────────── *)

let obj_lib_name (rel_build_path : string) : string =
  let segs = String.split_on_char '/' rel_build_path in
  let rec go = function
    | [] -> "unknown"
    | seg :: rest ->
        if String.length seg > 2 && String.sub seg 0 1 = "."
        then
          if Filename.check_suffix seg ".objs"
          then String.sub seg 1 (String.length seg - 6)
          else if Filename.check_suffix seg ".eobjs"
          then String.sub seg 1 (String.length seg - 7)
          else go rest
        else go rest
  in
  go segs

let find_substring (s : string) (sub : string) : int option =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n
    then None
    else if String.sub s i m = sub
    then Some i
    else go (i + 1)
  in
  go 0

let compiler_series_of_args (args : string array) : string =
  if Array.length args = 0
  then "unknown"
  else
    match find_substring args.(0) "compiler." with
    | None -> "unknown"
    | Some i -> (
        let rest =
          String.sub args.(0) (i + 9) (String.length args.(0) - i - 9)
        in
        let rec take acc j =
          if j >= String.length rest
          then acc
          else
            let ch = rest.[j] in
            if (ch >= '0' && ch <= '9') || ch = '.'
            then take (acc ^ String.make 1 ch) (j + 1)
            else acc
        in
        let v = take "" 0 in
        match String.split_on_char '.' v with
        | major :: minor :: _ -> major ^ "." ^ minor
        | _ -> "unknown" )

(* Timestamp evidence is needed for transformations whose input digest is
   not the original source digest. Plain inputs are checked by content below. *)
let fresher_or_equal (source : string) (artifact : string) : bool =
  try
    (Unix.stat source).Unix.st_mtime <= (Unix.stat artifact).Unix.st_mtime
  with
  | Unix.Unix_error _ ->
      false (* disappeared mid-scan (e.g. concurrent build) *)

(* Dune preprocessing and dialect compilation retain authored identities. *)
let real_source (sourcefile : string) : string option =
  if Filename.check_suffix sourcefile ".mlx.pp.ml"
  then Some (String.sub sourcefile 0 (String.length sourcefile - 6))
  else if Filename.check_suffix sourcefile ".mlx.ml"
  then Some (String.sub sourcefile 0 (String.length sourcefile - 3))
  else if Filename.check_suffix sourcefile ".pp.ml"
  then Some (String.sub sourcefile 0 (String.length sourcefile - 6) ^ ".ml")
  else Some sourcefile

let relocated_package_path ~file_exists ~project_root path =
  let marker = "/_build/_private/default/.pkg/" in
  match find_substring path marker with
  | None -> path
  | Some offset ->
      let local =
        project_root ^ String.sub path offset (String.length path - offset)
      in
      if file_exists local then local else path

let compiler_path
    ?(file_exists = Sys.file_exists)
    ~project_root
    (cmt : Cmt_format.cmt_infos)
    path =
  let build_root = project_root // "_build/default" in
  if Filename.is_relative path
  then build_root // path
  else if file_exists path
  then path
  else
    let prefix = cmt.cmt_builddir ^ "/" in
    if String.starts_with ~prefix path
    then
      build_root
      // String.sub
           path
           (String.length prefix)
           (String.length path - String.length prefix)
    else relocated_package_path ~file_exists ~project_root path

let digest_matches path expected =
  try Some (Digest.file path) = expected with
  | Sys_error _ -> false

(* A Dune-managed PPX rewrite ([pps]) compiles [x.pp.ml] produced from Dune's
   copy of [x.ml]. The artifact is current when it was compiled from that
   rewrite and the copy still equals the authored source; the rewriter itself
   is a Dune dependency. MLX dialects and compiler-applied transformations are
   excluded and keep receipt evidence. *)
let dune_rewritten ~rewriter_dirs ~artifact (cmt : Cmt_format.cmt_infos) =
  match cmt.cmt_sourcefile with
  | None -> false
  | Some recorded ->
      Hashtbl.mem
        rewriter_dirs
        (Filename.dirname (Filename.dirname (strip_build_prefix artifact)))
      && (not
            (Array.exists (fun arg -> arg = "-pp" || arg = "-ppx") cmt.cmt_args) )
      && (not (Filename.check_suffix recorded ".mlx.pp.ml"))
      && List.exists (Filename.check_suffix recorded) [".pp.ml"; ".pp.mli"]

let rewritten_input_current ~source ~input (cmt : Cmt_format.cmt_infos) =
  let copy =
    if Filename.check_suffix input ".pp.ml"
    then Filename.chop_suffix input ".pp.ml" ^ ".ml"
    else Filename.chop_suffix input ".pp.mli" ^ ".mli"
  in
  digest_matches input cmt.cmt_source_digest
  &&
  try Digest.file copy = Digest.file source with
  | Sys_error _ -> false

let current_input
    ?(rewritten = false)
    ~provenance
    ~project_root
    ~source
    (cmt : Cmt_format.cmt_infos)
    artifact =
  match cmt.cmt_sourcefile with
  | None -> false
  | Some recorded ->
      let input = compiler_path ~project_root cmt recorded in
      let compiler_transform =
        Array.exists (fun arg -> arg = "-pp" || arg = "-ppx") cmt.cmt_args
      in
      let transformed =
        List.exists
          (fun suffix -> Filename.check_suffix recorded suffix)
          [".pp.ml"; ".pp.mli"; ".mlx.ml"]
      in
      if
        rewritten
        && List.exists (Filename.check_suffix recorded) [".pp.ml"; ".pp.mli"]
      then rewritten_input_current ~source ~input cmt
      else if compiler_transform || transformed
      then Provenance.current provenance ~source cmt artifact
      else if cmt.cmt_source_digest = None
      then false
      else
        digest_matches input cmt.cmt_source_digest
        &&
        if transformed
        then fresher_or_equal source input && fresher_or_equal source artifact
        else digest_matches source cmt.cmt_source_digest

let interface_crc path name =
  try
    List.assoc_opt name (Cmi_format.read_cmi path).Cmi_format.cmi_crcs
    |> Option.join
  with
  | _ -> None

type interface_snapshot =
  { read_crc: string -> string -> Digest.t option
  ; file_exists: string -> bool
  ; validate: unit -> unit }

(* Repeated imports share a decoded CRC table for this observation only.
   Metadata changes trigger an immediate reread. Validate every used file's
   content again before returning, even if its metadata did not change. *)
let memoized_interface_crc () =
  let tables = Hashtbl.create 128 in
  let paths = Hashtbl.create 1024 in
  let file_exists path =
    match Hashtbl.find_opt paths path with
    | Some exists -> exists
    | None ->
        let exists = Sys.file_exists path in
        Hashtbl.add paths path exists ;
        exists
  in
  let metadata path =
    let s = Unix.stat path in
    (s.st_dev, s.st_ino, s.st_size, s.st_mtime, s.st_ctime, s.st_perm)
  in
  let read_crc path name =
    try
      let stamp = metadata path in
      let crcs =
        match Hashtbl.find_opt tables path with
        | Some (previous, _, crcs) when previous = stamp -> Some crcs
        | _ ->
            Hashtbl.remove tables path ;
            let digest = Digest.file path in
            let crcs = (Cmi_format.read_cmi path).Cmi_format.cmi_crcs in
            if metadata path <> stamp || Digest.file path <> digest
            then None
            else (
              Hashtbl.replace tables path (stamp, digest, crcs) ;
              Some crcs )
      in
      Option.bind crcs (fun crcs -> List.assoc_opt name crcs |> Option.join)
    with
    | _ -> None
  in
  let validate () =
    Hashtbl.iter
      (fun path existed ->
        if Sys.file_exists path <> existed
        then
          raise
            (Sys_error
               ("compiler import path changed during observation: " ^ path) ) )
      paths ;
    Hashtbl.iter
      (fun path (_, expected, _) ->
        if Digest.file path <> expected
        then
          raise
            (Sys_error ("compiler interface changed during observation: " ^ path)
            ) )
      tables
  in
  {read_crc; file_exists; validate}

let current_interface
    ?(rewritten = false)
    ?provenance
    ?(interface_crc = interface_crc)
    ~project_root
    ~source
    (cmt : Cmt_format.cmt_infos)
    artifact =
  let provenance =
    match provenance with
    | Some provenance -> provenance
    | None -> Provenance.create ~root:project_root ~inputs:[]
  in
  let interface = Filename.remove_extension source ^ ".mli" in
  if not (Sys.file_exists interface)
  then
    match cmt.cmt_annots with
    | Cmt_format.Partial_implementation _ -> true
    | _ -> cmt.cmt_interface_digest <> None
  else
    let base = Filename.remove_extension artifact in
    try
      let cmti = Cmt_format.read_cmt (base ^ ".cmti") in
      (* An implementation with an explicit interface does not embed its
         CMI. Its interface identity is the self import, not the optional
         digest of an embedded interface. *)
      let expected =
        List.assoc_opt cmt.cmt_modname cmt.cmt_imports |> Option.join
      in
      current_input
        ~rewritten
        ~provenance
        ~project_root
        ~source:interface
        cmti
        (base ^ ".cmti")
      && expected <> None
      && cmti.cmt_interface_digest = expected
      && interface_crc (base ^ ".cmi") cmt.cmt_modname = expected
    with
    | _ -> false

let current_imports
    ?(interface_crc = interface_crc)
    ?(file_exists = Sys.file_exists)
    ~project_root
    ~local_units
    (cmt : Cmt_format.cmt_infos) =
  let directories = cmt.cmt_loadpath.visible @ cmt.cmt_loadpath.hidden in
  List.for_all
    (fun (name, expected) ->
      match expected with
      | None -> true
      | Some _ -> (
          let file = String.uncapitalize_ascii name ^ ".cmi" in
          let path =
            List.find_map
              (fun dir ->
                let path =
                  compiler_path ~file_exists ~project_root cmt (dir // file)
                in
                if file_exists path then Some path else None )
              directories
          in
          match path with
          | Some path -> interface_crc path name = expected
          | None -> not (Hashtbl.mem local_units name) ) )
    cmt.cmt_imports

let sha256_hex (s : string) : string =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string s)

let read_file (path : string) : string =
  try
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic ;
    s
  with
  | Sys_error _ -> ""

let strip_tree (cmt : Cmt_format.cmt_infos) =
  let cmt_annots =
    match cmt.cmt_annots with
    | Cmt_format.Implementation _ ->
        Cmt_format.Implementation
          {Typedtree.str_items= []; str_type= []; str_final_env= Env.empty}
    | Cmt_format.Interface _ ->
        Cmt_format.Interface
          {Typedtree.sig_items= []; sig_type= []; sig_final_env= Env.empty}
    | Cmt_format.Packed _ -> Cmt_format.Packed ([], [])
    | Cmt_format.Partial_implementation _ ->
        Cmt_format.Partial_implementation [||]
    | Cmt_format.Partial_interface _ -> Cmt_format.Partial_interface [||]
  in
  { cmt with
    cmt_annots
  ; cmt_initial_env= Env.empty
  ; cmt_comments= []
  ; cmt_declaration_dependencies= []
  ; cmt_uid_to_decl= Shape.Uid.Tbl.create 0
  ; cmt_impl_shape= None
  ; cmt_ident_occurrences= [] }

(* ── observation driver ───────────────────────────────────────────── *)

let in_scope (roots : string list) (path : string) : bool =
  List.exists
    (fun root ->
      path = root
      || String.length path > String.length root + 1
         && String.sub path 0 (String.length root + 1) = root // "" )
    roots

type extracted =
  { functions: Observation.function_def list
  ; measure_gaps: Observation.gap list
  ; measured: bool }

let gap code path detail =
  {Observation.gap_code= code; gap_path= path; gap_detail= detail}

let measure_unit ~project_root ~source_path ~unit_canonical current =
  match current.Cmt_format.cmt_annots with
  | Cmt_format.Implementation structure -> (
    try
      let fns, gaps =
        Measurement.measure ~project_root ~source_path ~unit_canonical structure
      in
      {functions= fns; measure_gaps= gaps; measured= true}
    with
    | exn ->
        { functions= []
        ; measure_gaps=
            [ gap
                "GAP-UNMEASURABLE"
                source_path
                ("complexity walk failed: " ^ Printexc.to_string exn) ]
        ; measured= false } )
  | _ ->
      { functions= []
      ; measure_gaps=
          [ gap
              "GAP-UNMEASURABLE"
              source_path
              "typedtree is not a complete implementation" ]
      ; measured= false }

(* Why an artifact is not current for its source. *)
let staleness
    ~provenance
    ~project_root
    ~source_exists
    ~recorded
    ~recorded_input
    ~transformed
    ~rewritten
    ~source_abs
    ~artifact
    cmt =
  if (not source_exists) || not (Sys.file_exists recorded_input)
  then
    ( "GAP-MISSING-INPUT"
    , "authored or generated compiler input missing: " ^ recorded )
  else if Provenance.source_changed ~source:source_abs (project_root // artifact)
  then
    ( "GAP-STALE-ARTIFACT"
    , "compiler input content or interface identity differs from the current \
       source/build" )
  else if
    transformed
    && (not rewritten)
    && not
         (Provenance.current
            provenance
            ~source:source_abs
            cmt
            (project_root // artifact) )
  then
    ( "GAP-UNVERIFIABLE-TRANSFORMATION"
    , "transformation provenance unavailable or changed for "
      ^ recorded
      ^ ( if provenance.Provenance.unavailable = []
          then ""
          else
            "; unavailable build evidence: "
            ^ String.concat ", " provenance.unavailable )
      ^ "; run complexity --rebuild" )
  else
    ( "GAP-STALE-ARTIFACT"
    , "compiler input content or interface identity differs from the current \
       source/build" )

(* [assume_fresh] marks every existing artifact as current: the caller
   performed a successful rebuild, and dune guarantees content freshness of
   its outputs. Otherwise check compiler input digests, interface CRCs and
   transformation timestamp evidence; an unchanged plain-source rewrite is
   current even if Dune did not rewrite its artifact. *)
let observe
    ~(project_root : string)
    ~(program_roots : string list)
    ~(assume_fresh : bool)
    () : Observation.t =
  let interfaces = memoized_interface_crc () in
  let interface_crc = interfaces.read_crc in
  let cache = Observation_cache.create ~project_root ~evidence:"measurement" in
  let sources = scan_sources project_root program_roots in
  let dependency_inputs = ref [] in
  scan
    project_root
    ""
    (fun file ->
      List.mem file ["dune"; "dune-project"; "dune-workspace"]
      || List.exists
           (Filename.check_suffix file)
           [".ml"; ".mli"; ".mlx"; ".ts"; ".sh"; ".cyrograf"; ".pkg"; ".opam"] )
    dependency_inputs
    false ;
  let provenance =
    Provenance.create
      ~root:project_root
      ~inputs:(List.sort_uniq compare !dependency_inputs)
  in
  let rewriter_dirs =
    Provenance.dune_rewriter_object_dirs ~root:project_root !dependency_inputs
  in
  let artifacts = scan_artifacts project_root in
  let gaps = ref [] in
  let selected = ref 0 in
  let read_infos =
    List.filter_map
      (fun artifact ->
        let rel = strip_build_prefix artifact in
        let lib = obj_lib_name rel in
        match
          try
            let key =
              Observation_cache.key cache ~kind:"metadata" ~artifact ~source:""
            in
            match Observation_cache.read cache key with
            | Some cmt -> Some cmt
            | None ->
                Observation_cache.note_read cache ;
                let cmt =
                  strip_tree (Cmt_format.read_cmt (project_root // artifact))
                in
                Observation_cache.write cache key cmt ;
                Some cmt
          with
          | _ -> None
        with
        | None ->
            gaps :=
              gap "GAP-ARTIFACT-READ" rel "artifact could not be read" :: !gaps ;
            None
        | Some cmt -> Some (lib, cmt.Cmt_format.cmt_modname, artifact, cmt) )
      artifacts
  in
  (* deduplicate units: byte and native artifacts carry the same facts;
     byte artifacts sort first and win *)
  let units_tbl : (string, string) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun (_lib, modname, artifact, _cmt) ->
      match Hashtbl.find_opt units_tbl modname with
      | Some prev ->
          if Filename.check_suffix prev "/byte/"
          then ()
          else if Filename.check_suffix artifact "/byte/"
          then Hashtbl.replace units_tbl modname artifact
      | None -> Hashtbl.add units_tbl modname artifact )
    read_infos ;
  let observed_sources = Hashtbl.create 64 in
  let functions = ref [] in
  let measured_paths = ref [] in
  let compiler_series = ref "unknown" in
  List.iter
    (fun (lib, modname, artifact, cmt) ->
      let recorded =
        match cmt.Cmt_format.cmt_sourcefile with
        | Some f -> f
        | None -> ""
      in
      match real_source recorded with
      | None -> ()
      | Some source_path ->
          let generated = Filename.check_suffix source_path ".ml-gen" in
          if source_path = "" || not (in_scope program_roots source_path)
          then ()
          else if
            Hashtbl.find_opt units_tbl modname
            |> Option.map (fun a -> not (String.equal a artifact))
            |> Option.value ~default:false
          then ()
          else (
            incr selected ;
            if Sys.getenv_opt "SZANIEC_ACQUISITION_TRACE" = Some "1"
            then Printf.eprintf "szaniec acquire: %s\n%!" source_path ;
            if not generated
            then Hashtbl.replace observed_sources source_path () ;
            let series = compiler_series_of_args cmt.Cmt_format.cmt_args in
            if !compiler_series = "unknown" then compiler_series := series ;
            if series <> Version.supported_compiler_series
            then
              gaps :=
                gap
                  "GAP-UNSUPPORTED-COMPILER"
                  source_path
                  (Printf.sprintf
                     "artifact built with compiler series %s, adapter supports \
                      %s"
                     series
                     Version.supported_compiler_series )
                :: !gaps
            else
              let source_abs =
                let authored = project_root // source_path in
                if Sys.file_exists authored
                then authored
                else
                  Option.value
                    ~default:authored
                    (Provenance.generated_source ~root:project_root source_path)
              in
              let source_exists = Sys.file_exists source_abs in
              let recorded_input = compiler_path ~project_root cmt recorded in
              let transformed =
                Array.exists
                  (fun arg -> arg = "-pp" || arg = "-ppx")
                  cmt.cmt_args
                || Filename.check_suffix recorded ".pp.ml"
                || Filename.check_suffix recorded ".mlx.ml"
              in
              let rewritten = dune_rewritten ~rewriter_dirs ~artifact cmt in
              (* Dune's wrapped-library stub is often recorded as
                 [lib/name.ml-gen] but kept only inside [_build]. There is
                 no project source to go stale against, so the artifact is
                 the inventory source. *)
              let fresh =
                (generated && not source_exists)
                || source_exists
                   && Sys.file_exists recorded_input
                   && ( (not transformed)
                      || rewritten
                      || Option.is_some
                           (Provenance.identity
                              provenance
                              ~source:source_abs
                              cmt
                              (project_root // artifact) ) )
                   && ( assume_fresh
                      || current_input
                           ~rewritten
                           ~provenance
                           ~project_root
                           ~source:source_abs
                           cmt
                           (project_root // artifact)
                         && current_interface
                              ~rewritten
                              ~interface_crc
                              ~provenance
                              ~project_root
                              ~source:source_abs
                              cmt
                              (project_root // artifact)
                         && current_imports
                              ~interface_crc
                              ~file_exists:interfaces.file_exists
                              ~project_root
                              ~local_units:units_tbl
                              cmt )
              in
              let unit_canonical =
                Canonical.of_unit_name ~library:lib ~unit_name:modname
              in
              if fresh && assume_fresh
              then (
                Provenance.record
                  provenance
                  ~source:source_abs
                  cmt
                  (project_root // artifact) ;
                let interface = Filename.remove_extension source_abs ^ ".mli" in
                let cmti =
                  Filename.remove_extension (project_root // artifact) ^ ".cmti"
                in
                if Sys.file_exists interface && Sys.file_exists cmti
                then
                  try
                    Provenance.record
                      provenance
                      ~source:interface
                      (Cmt_format.read_cmt cmti)
                      cmti
                  with
                  | _ -> () ) ;
              if not fresh
              then
                let code, detail =
                  staleness
                    ~provenance
                    ~project_root
                    ~source_exists
                    ~recorded
                    ~recorded_input
                    ~transformed
                    ~rewritten
                    ~source_abs
                    ~artifact
                    cmt
                in
                gaps := gap code source_path detail :: !gaps
              else
                let cache_key =
                  Observation_cache.key
                    cache
                    ~kind:"functions"
                    ~artifact
                    ~source:source_path
                in
                let extracted =
                  match Observation_cache.read cache cache_key with
                  | Some extracted -> extracted
                  | None ->
                      Observation_cache.note_read cache ;
                      let current =
                        Cmt_format.read_cmt (project_root // artifact)
                      in
                      let extracted =
                        measure_unit
                          ~project_root
                          ~source_path
                          ~unit_canonical
                          current
                      in
                      if
                        extracted.measure_gaps = []
                        && Observation_cache.artifact_current cache ~artifact
                        && Observation_cache.key
                             cache
                             ~kind:"functions"
                             ~artifact
                             ~source:source_path
                           = cache_key
                      then Observation_cache.write cache cache_key extracted ;
                      extracted
                in
                if not (Observation_cache.artifact_current cache ~artifact)
                then
                  raise
                    (Sys_error "compiler artifact changed during observation") ;
                if
                  Observation_cache.key
                    cache
                    ~kind:"functions"
                    ~artifact
                    ~source:source_path
                  <> cache_key
                then raise (Sys_error "source changed during observation") ;
                functions := List.rev_append extracted.functions !functions ;
                gaps := List.rev_append extracted.measure_gaps !gaps ;
                if extracted.measured
                then measured_paths := source_path :: !measured_paths ) )
    read_infos ;
  Observation_cache.finish
    cache
    ~scanned:(List.length artifacts)
    ~selected:!selected ;
  (* sources without artifacts *)
  List.iter
    (fun source ->
      if not (Hashtbl.mem observed_sources source)
      then
        gaps :=
          gap
            "GAP-UNOBSERVED-SOURCE"
            source
            "no build artifact found for this source file"
          :: !gaps )
    sources ;
  let inputs = ref sources in
  List.iter
    (fun root ->
      scan
        project_root
        root
        (fun e -> Filename.check_suffix e ".mli")
        inputs
        false )
    program_roots ;
  let source_files =
    List.sort_uniq compare !inputs
    |> List.map (fun s -> (s, sha256_hex (read_file (project_root // s))))
  in
  let snapshot_digest =
    sha256_hex
      (String.concat "\n" (List.map (fun (p, d) -> p ^ ":" ^ d) source_files))
  in
  let by_gap a b =
    compare
      (a.Observation.gap_code, a.Observation.gap_path, a.Observation.gap_detail)
      (b.Observation.gap_code, b.Observation.gap_path, b.Observation.gap_detail)
  in
  let by_fn a b =
    compare
      ( a.Observation.fn_path
      , a.Observation.fn_line
      , a.Observation.fn_col
      , a.Observation.fn_id )
      ( b.Observation.fn_path
      , b.Observation.fn_line
      , b.Observation.fn_col
      , b.Observation.fn_id )
  in
  let functions = List.sort by_fn !functions in
  let gap_status (path : string) : string option =
    let for_path =
      List.filter (fun g -> String.equal g.Observation.gap_path path) !gaps
    in
    let has codes =
      List.exists (fun g -> List.mem g.Observation.gap_code codes) for_path
    in
    if has ["GAP-UNOBSERVED-SOURCE"]
    then Some "unobserved"
    else if
      has
        [ "GAP-STALE-ARTIFACT"
        ; "GAP-MISSING-INPUT"
        ; "GAP-UNVERIFIABLE-TRANSFORMATION" ]
    then Some "stale"
    else if has ["GAP-ARTIFACT-READ"]
    then Some "unreadable"
    else if has ["GAP-UNSUPPORTED-COMPILER"]
    then Some "unsupported-compiler"
    else None
  in
  let function_counts = Hashtbl.create 128 in
  List.iter
    (fun (f : Observation.function_def) ->
      let count =
        Option.value ~default:0 (Hashtbl.find_opt function_counts f.fn_path)
      in
      Hashtbl.replace function_counts f.fn_path (count + 1) )
    functions ;
  let count_fns path =
    Option.value ~default:0 (Hashtbl.find_opt function_counts path)
  in
  (* Whole-file measurement failures. A function that contains an
     unmeasurable construct stays on a [measured] file and is listed
     with null complexity; these details mean the file itself has no
     inventory. *)
  let file_unmeasured path =
    List.exists
      (fun g ->
        String.equal g.Observation.gap_path path
        && String.equal g.Observation.gap_code "GAP-UNMEASURABLE"
        && ( String.starts_with ~prefix:"typedtree " g.Observation.gap_detail
           || String.starts_with
                ~prefix:"complexity walk failed"
                g.Observation.gap_detail ) )
      !gaps
  in
  let coverage_of path =
    let status =
      match gap_status path with
      | Some s -> s
      | None when file_unmeasured path -> "unmeasurable"
      | None -> "measured"
    in
    { Observation.cov_path= path
    ; cov_provenance= Measurement.file_provenance path
    ; cov_status= status
    ; cov_functions= (if status = "measured" then count_fns path else 0) }
  in
  (* Generated wrappers and other measured inputs that are not authored
     sources under the roots still get a coverage record. *)
  let extra_paths =
    List.sort_uniq
      compare
      ( !measured_paths
      @ List.filter_map
          (fun g ->
            if
              List.mem
                g.Observation.gap_code
                [ "GAP-UNMEASURABLE"
                ; "GAP-STALE-ARTIFACT"
                ; "GAP-MISSING-INPUT"
                ; "GAP-UNVERIFIABLE-TRANSFORMATION"
                ; "GAP-UNSUPPORTED-COMPILER" ]
            then Some g.Observation.gap_path
            else None )
          !gaps )
    |> List.filter (fun path -> not (List.mem path sources))
  in
  interfaces.validate () ;
  { Observation.project_root
  ; program_roots
  ; compiler_series= !compiler_series
  ; functions
  ; coverage=
      List.sort
        (fun a b -> compare a.Observation.cov_path b.Observation.cov_path)
        (List.map coverage_of (sources @ extra_paths))
  ; snapshot_digest
  ; gaps= List.sort_uniq by_gap !gaps }
