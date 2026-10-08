(* ProgramAccess coverage facts: point-file parsing, merge, CRAP, hook scan,
   and nested span attribution. *)

module F = Szaniec_program_access.Coverage_facts
module C = Szaniec_model.Coverage

let fail name detail =
  Printf.printf "%s: FAIL (%s)\n" name detail ;
  exit 1

let ok name = Printf.printf "%s: ok\n" name

let expect_eq name got expected =
  if got = expected then ok name else fail name (got ^ " <> " ^ expected)

let ( // ) = Filename.concat

let rm_rf path =
  let rec walk p =
    if Sys.file_exists p
    then
      if Sys.is_directory p
      then (
        Array.iter (fun name -> walk (p // name)) (Sys.readdir p) ;
        Unix.rmdir p )
      else Sys.remove p
  in
  walk path

let write path contents =
  let oc = open_out path in
  output_string oc contents ;
  close_out oc

let () =
  let text = "BISECT-COVERAGE-4 1 4 a.ml 2 10 20 2 1 0" in
  let parsed =
    match F.parse_coverage_text text with
    | Error e -> fail "parse points" e
    | Ok files -> files
  in
  ( match parsed with
  | [file]
    when file.F.path = "a.ml"
         && file.points = [|10; 20|]
         && file.counts = [|1; 0|] ->
      ok "parse points"
  | _ -> fail "parse points" "unexpected records" ) ;
  ( match F.parse_coverage_text "not-a-point-file" with
  | Error msg ->
      expect_eq
        "parse rejection"
        msg
        "point file does not start with the facade point marker"
  | Ok _ -> fail "parse rejection" "accepted a foreign file" ) ;
  let second = {F.path= "a.ml"; points= [|10; 20|]; counts= [|3; 4|]} in
  let merged, gaps = F.merge_points (parsed @ [second]) in
  ( match (merged, gaps) with
  | [{counts= [|4; 4|]; _}], [] -> ok "merge compatible"
  | _ -> fail "merge compatible" "counts were not summed" ) ;
  let other = {second with points= [|10; 21|]} in
  let _kept, gaps = F.merge_points (parsed @ [other]) in
  ( match gaps with
  | [{code= "COVERAGE-INCOMPATIBLE-RECORDS"; _}] -> ok "reject incompatible"
  | _ -> fail "reject incompatible" "no gap" ) ;
  let root =
    Filename.get_temp_dir_name ()
    // Printf.sprintf "szaniec-facts-%d" (Unix.getpid ())
  in
  rm_rf root ;
  Unix.mkdir root 0o755 ;
  let rel = "lib/core.ml" in
  Unix.mkdir (root // "lib") 0o755 ;
  write
    (root // rel)
    "let unused () = 1\n\n\
     let greet who =\n\
    \  let suffix () = 1 in\n\
    \  suffix () + who\n" ;
  let spans, parse_gaps = F.index_sources root [rel] in
  if parse_gaps <> [] then fail "index" "parse gap" ;
  let named name =
    match List.filter (fun (s : F.span) -> s.F.name = name) spans with
    | [span] -> span
    | found ->
        fail "index names" (name ^ " count " ^ string_of_int (List.length found))
  in
  let unused = named "unused" in
  let greet = named "greet" in
  let suffix = named "suffix" in
  if unused.kind <> C.Function then fail "unused kind" "not function" ;
  if suffix.kind <> C.Local then fail "suffix kind" "not local" ;
  if greet.kind <> C.Function then fail "greet kind" "not function" ;
  ok "index nested" ;
  let point_at (span : F.span) = span.start in
  let funcs, _, _ =
    F.attribute
      ~spans
      ~measured:
        [ { F.path= rel
          ; points= [|point_at suffix; point_at unused|]
          ; counts= [|1; 0|] } ]
      ~inventory:
        [{F.path= rel; name= "unused"; line= unused.line; complexity= Some 1}]
  in
  let func name =
    match List.filter (fun (f : C.func) -> f.name = name) funcs with
    | [item] -> item
    | found ->
        fail "attribute" (name ^ " count " ^ string_of_int (List.length found))
  in
  let unused_fn = func "unused" in
  let suffix_fn = func "suffix" in
  let greet_fn = func "greet" in
  ( match unused_fn.measurement with
  | C.Measured {covered= 0; total= 1; executed= false} ->
      ok "unused measured zero"
  | _ -> fail "unused measured zero" "wrong measurement" ) ;
  ( match unused_fn.crap with
  | C.Available "2.00" -> ok "crap score"
  | _ -> fail "crap score" "expected 2.00" ) ;
  ( match greet_fn.crap with
  | C.Unavailable "complexity-missing" -> ok "crap without complexity"
  | _ -> fail "crap without complexity" "score was invented" ) ;
  ( match suffix_fn.measurement with
  | C.Measured {covered= 1; total= 1; executed= true} -> ok "inner point"
  | _ -> fail "inner point" "suffix did not receive the point" ) ;
  ( match greet_fn.measurement with
  | C.Uninstrumented -> ok "outer not credited"
  | _ -> fail "outer not credited" "parent absorbed the nested point" ) ;
  write
    (root // "dune")
    "(library (name app) (instrumentation (backend szaniec.instrumentation)))\n\
     (library (name gap))\n\
     (library (name mark) (kind ppx_rewriter))\n\
     (library (name acted) (instrumentation (backend szaniec.instrumentation)) \
     (preprocess (action (run %{bin:echo}))))\n" ;
  write (root // "dune-project") "(lang dune 3.17)\n" ;
  let stanzas, scan_gaps, _mlx = F.scan_stanzas root [""] in
  let hooked name =
    List.exists
      (fun (s : F.stanza_info) -> List.mem name s.names && s.hooked)
      stanzas
  in
  if not (hooked "app") then fail "hook" "app" ;
  if hooked "gap" then fail "hook" "gap was hooked" ;
  if List.exists (fun (s : F.stanza_info) -> List.mem "mark" s.names) stanzas
  then fail "ppx scope" "rewriter was in application scope" ;
  let has code = List.exists (fun (g : C.gap) -> g.code = code) scan_gaps in
  if not (has "COVERAGE-MISSING-HOOK") then fail "missing hook" "no gap" ;
  if not (has "COVERAGE-UNSUPPORTED-PREPROCESS")
  then fail "action preprocess" "no gap" ;
  ok "hook scan" ;
  write (root // "note.mlx") "view\n" ;
  write
    (root // "dune-project")
    "(lang dune 3.17)\n(dialect (name mlx) (implementation (extension mlx)))\n" ;
  let _stanzas, dialect_gaps, mlx_present = F.scan_stanzas root [""] in
  if not mlx_present then fail "mlx present" "file ignored" ;
  if
    not
      (List.exists
         (fun (g : C.gap) -> g.code = "COVERAGE-UNSUPPORTED-DIALECT")
         dialect_gaps )
  then fail "mlx dialect" "no gap" ;
  ok "mlx dialect" ;
  let rel_path =
    F.normalize_path
      ~project_root:root
      ~dune_root:root
      (root // "_build/default/lib/core.ml")
  in
  expect_eq "normalize build path" rel_path "lib/core.ml" ;
  rm_rf root ;
  ok "cleanup"
