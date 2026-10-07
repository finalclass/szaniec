(* Source-to-report acceptance test for [szaniec complexity].

   Usage: complexity_runner.exe <szaniec-binary> <fixture-dir> <expected-dir>
          [--update]

   The runner copies test/fixtures/tasks-app, rebuilds it through the
   complexity command, and checks the inventory against the szaniec-cc/1
   specimens. --update rewrites the golden files after those checks pass.
*)

type group =
  | Sample
  | Recur
  | Widget
  | Probe

type spec =
  { group: group
  ; qualname: string
  ; cc: int
  ; nested: bool
  ; kind: string
  ; binding: string }

let spec group qualname cc nested kind binding =
  {group; qualname; cc; nested; kind; binding}

let named g q cc = spec g q cc false "named" "function"

let nest g q cc = spec g q cc true "named" "function"

let anon g q cc = spec g q cc true "anonymous" "function"

let specimens =
  [ named Sample "straight" 1
  ; named Sample "conditional" 2
  ; named Sample "multi" 3
  ; named Sample "guarded" 3
  ; named Sample "short" 3
  ; named Sample "if_and" 3
  ; named Sample "loop_for" 2
  ; named Sample "loop_while" 2
  ; named Sample "exceptional" 2
  ; named Sample "two_handlers" 3
  ; named Sample "match_exn" 2
  ; named Sample "or_pat" 2
  ; named Sample "partial_match" 1
  ; named Sample "outer" 1
  ; nest Sample "outer.nested" 2
  ; named Sample "curried" 2
  ; named Sample "uses_anon" 1
  ; anon Sample "uses_anon.anon" 2
  ; named Sample "returns_fun" 1
  ; anon Sample "returns_fun.anon" 2
  ; named Sample "unused_plain" 1
  ; named Sample "as_function" 3
  ; named Sample "if_unit" 2
  ; named Sample "just_raise" 2
  ; named Sample "Local.hidden" 1
  ; named Sample "with_effect" 2
  ; named Recur "recursive" 2
  ; named Recur "even" 2
  ; named Recur "odd" 2
  ; spec Widget "ping" 2 false "named" "rpc"
  ; named Widget "helper" 1
  ; named Probe "probe" 1 ]

let module_of = function
  | Sample -> "Metric.Samples"
  | Recur -> "Metric.Recursion"
  | Widget -> "Metric.Widget_manager_impl"
  | Probe -> "Probe"

let provenance_of = function
  | Probe -> "test"
  | Sample
   |Recur
   |Widget ->
      "authored"

let ownership_of = function
  | Sample
   |Probe ->
      "unclassified"
  | Recur -> "helper of Metric.Recursion"
  | Widget -> "implementation of Widget_manager"

let service_of = function
  | Sample
   |Probe ->
      ""
  | Recur -> "Metric.Recursion"
  | Widget -> "Widget_manager"

let objects_src =
  {|let make () =
  object
    method m = 1
  end

let call o = o#m

class c =
  object
    method n = 2
  end
|}

let broken_src = "let broken x = x + \"no\"\n"

(* ── file helpers ─────────────────────────────────────────────────── *)

let read_file (path : string) : string =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic ;
  s

let write_file (path : string) (content : string) =
  let oc = open_out_bin path in
  output_string oc content ;
  close_out oc

let rec copy_tree (src : string) (dst : string) =
  if Sys.is_directory src
  then (
    ( try Unix.mkdir dst 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
    Array.iter
      (fun e ->
        if
          e = "."
          || e = ".."
          || e = "_build"
          || (String.length e > 0 && e.[0] = '.')
        then ()
        else copy_tree (Filename.concat src e) (Filename.concat dst e) )
      (Sys.readdir src) )
  else (
    ( try Unix.unlink dst with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> () ) ;
    write_file dst (read_file src) )

let remove_tree (path : string) =
  if Sys.file_exists path
  then ignore (Sys.command ("rm -rf " ^ Filename.quote path))

let remove_file (path : string) =
  try Unix.unlink path with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let capture (cmd : string) : string * int =
  let stdout_file = Filename.temp_file "szaniec_cc" ".txt" in
  let code = Sys.command (cmd ^ " > " ^ Filename.quote stdout_file) in
  let out = read_file stdout_file in
  Sys.remove stdout_file ;
  (out, code)

(* ── JSON ─────────────────────────────────────────────────────────── *)

let assoc = function
  | `Assoc l -> l
  | _ -> failwith "expected object"

let member (k : string) (j : Yojson.Safe.t) : Yojson.Safe.t =
  match List.assoc_opt k (assoc j) with
  | Some v -> v
  | None -> failwith ("missing " ^ k)

let jstr (j : Yojson.Safe.t) (k : string) : string =
  match member k j with
  | `String s -> s
  | `Null -> ""
  | other -> failwith ("string " ^ k ^ " " ^ Yojson.Safe.to_string other)

let jint_opt (j : Yojson.Safe.t) (k : string) : int option =
  match member k j with
  | `Int n -> Some n
  | `Null -> None
  | other -> failwith ("int " ^ k ^ " " ^ Yojson.Safe.to_string other)

let jbool (j : Yojson.Safe.t) (k : string) : bool =
  match member k j with
  | `Bool b -> b
  | _ -> failwith ("bool " ^ k)

let jlist (j : Yojson.Safe.t) (k : string) : Yojson.Safe.t list =
  match member k j with
  | `List l -> l
  | _ -> failwith ("list " ^ k)

let parse_report (out : string) : (int * Yojson.Safe.t, string) result =
  match String.index_opt out '\n' with
  | None -> Error "report has no exit line"
  | Some i -> (
      let header = String.sub out 0 i in
      let rest = String.sub out (i + 1) (String.length out - i - 1) in
      match Scanf.sscanf header "exit=%d" (fun n -> n) with
      | code -> (
        try Ok (code, Yojson.Safe.from_string rest) with
        | Yojson.Json_error msg -> Error ("json: " ^ msg) )
      | exception Scanf.Scan_failure _ -> Error ("bad header: " ^ header) )

let fail errors msg = errors := msg :: !errors

let fn_key (j : Yojson.Safe.t) = (jstr j "module", jstr j "qualname")

let functions_of (j : Yojson.Safe.t) = jlist j "functions"

let find_all m q fns = List.filter (fun f -> fn_key f = (m, q)) fns

let expect_one errors label fns m q =
  match find_all m q fns with
  | [f] -> Some f
  | l ->
      fail
        errors
        (Printf.sprintf "%s: %s.%s occurs %d times" label m q (List.length l)) ;
      None

let check_spec errors fns (s : spec) =
  let m = module_of s.group in
  match expect_one errors "specimen" fns m s.qualname with
  | None -> ()
  | Some f ->
      let cc = jint_opt f "complexity" in
      if cc <> Some s.cc
      then
        fail
          errors
          (Printf.sprintf
             "%s.%s complexity %s, expected %d"
             m
             s.qualname
             ( match cc with
             | Some n -> string_of_int n
             | None -> "null" )
             s.cc ) ;
      let eq field expected =
        let got = jstr f field in
        if got <> expected
        then
          fail
            errors
            (Printf.sprintf
               "%s.%s %s %s, expected %s"
               m
               s.qualname
               field
               got
               expected )
      in
      eq "kind" s.kind ;
      eq "binding" s.binding ;
      eq "provenance" (provenance_of s.group) ;
      eq "ownership" (ownership_of s.group) ;
      eq "service" (service_of s.group) ;
      eq "status" "measured" ;
      eq "metric" "szaniec-cc/1" ;
      if jbool f "nested" <> s.nested
      then fail errors (Printf.sprintf "%s.%s nested flag" m s.qualname) ;
      let id = jstr f "id" in
      if String.equal s.kind "named"
      then (
        if id <> m ^ "." ^ s.qualname
        then fail errors (Printf.sprintf "%s.%s id %s" m s.qualname id) )
      else
        let q = s.qualname in
        let suffix = ".anon" in
        let n = String.length suffix in
        if String.length q < n
        then fail errors ("anon qualname " ^ q)
        else
          let parent = String.sub q 0 (String.length q - n) in
          let prefix = m ^ "." ^ parent ^ "#anon@" in
          if
            String.length id < String.length prefix
            || String.sub id 0 (String.length prefix) <> prefix
          then fail errors (Printf.sprintf "anon id %s" id)

let check_shadows errors fns =
  let m = "Metric.Samples" in
  match find_all m "shadow" fns with
  | [a; b] ->
      let pair f = (jint_opt f "complexity", jstr f "id") in
      let ca, ia = pair a in
      let cb, ib = pair b in
      let ccs = List.sort compare [ca; cb] in
      if ccs <> [Some 1; Some 2]
      then fail errors "shadow complexities are not 1 and 2" ;
      List.iter
        (fun id ->
          let prefix = m ^ ".shadow@" in
          if
            not
              ( String.length id > String.length prefix
              && String.sub id 0 (String.length prefix) = prefix )
          then fail errors ("shadow id " ^ id) )
        [ia; ib] ;
      if ia = ib then fail errors "shadow ids are not distinct"
  | l -> fail errors (Printf.sprintf "shadow occurs %d times" (List.length l))

let check_inventory errors (j : Yojson.Safe.t) =
  if jstr j "format" <> "szaniec-complexity/1" then fail errors "format" ;
  if jstr j "metric" <> "szaniec-cc/1" then fail errors "metric" ;
  if jstr j "status" <> "ok" then fail errors "status is not ok" ;
  if jstr j "sort" <> "location" then fail errors "sort" ;
  let inputs = member "inputs" j in
  if jbool inputs "approved"
  then fail errors "approval must stay a recorded flag" ;
  if jstr inputs "programAccess" <> "szaniec-ocaml-adapter/1.2.0"
  then fail errors "adapter version" ;
  ( match member "programRoots" inputs with
  | `List [`String "metric"; `String "test"] -> ()
  | other -> fail errors ("roots " ^ Yojson.Safe.to_string other) ) ;
  let fns = functions_of j in
  List.iter (check_spec errors fns) specimens ;
  check_shadows errors fns ;
  let expected = List.length specimens + 2 in
  if List.length fns <> expected
  then
    fail
      errors
      (Printf.sprintf
         "function count %d, expected %d"
         (List.length fns)
         expected ) ;
  List.iter
    (fun f ->
      let id = jstr f "id" in
      if
        List.exists
          (fun banned ->
            let n = String.length banned in
            let rec contains i =
              if i + n > String.length id
              then false
              else String.sub id i n = banned || contains (i + 1)
            in
            contains 0 )
          ["alias_of_straight"; "partial_apply"; "shadow_kept"]
      then fail errors ("inventoried non-definition " ^ id) )
    fns ;
  let curried = List.filter (fun f -> jstr f "qualname" = "curried") fns in
  if List.length curried <> 1 then fail errors "curried is not one function" ;
  let summary = member "summary" j in
  if jint_opt summary "functions" <> Some expected
  then fail errors "summary.functions" ;
  if jint_opt summary "measured" <> Some expected
  then fail errors "summary.measured" ;
  if jint_opt summary "unmeasurable" <> Some 0
  then fail errors "summary.unmeasurable" ;
  if jint_opt summary "maxComplexity" <> Some 3
  then fail errors "summary.maxComplexity" ;
  if jint_opt summary "gaps" <> Some 0 then fail errors "summary.gaps" ;
  if jlist j "gaps" <> [] then fail errors "gaps is not empty" ;
  let cov = jlist j "coverage" in
  let cov_is path provenance status functions =
    match List.filter (fun c -> jstr c "path" = path) cov with
    | [c] ->
        if
          jstr c "provenance" <> provenance
          || jstr c "status" <> status
          || jint_opt c "functions" <> Some functions
        then
          fail
            errors
            (Printf.sprintf
               "coverage %s is %s %s %s"
               path
               (jstr c "provenance")
               (jstr c "status")
               ( match jint_opt c "functions" with
               | Some n -> string_of_int n
               | None -> "-" ) )
    | l ->
        fail
          errors
          (Printf.sprintf "coverage %s occurs %d times" path (List.length l))
  in
  cov_is "metric/samples.ml" "authored" "measured" 28 ;
  cov_is "metric/recursion.ml" "authored" "measured" 3 ;
  cov_is "metric/widget_manager_impl.ml" "authored" "measured" 2 ;
  cov_is "test/probe.ml" "test" "measured" 1 ;
  cov_is "metric/metric.ml-gen" "generated" "measured" 0

let check_sort errors inventory sorted =
  if jstr sorted "sort" <> "complexity" then fail errors "sort field" ;
  if jstr sorted "status" <> jstr inventory "status"
  then fail errors "sort changed the analysis status" ;
  let ids fns = List.sort compare (List.map (fun f -> jstr f "id") fns) in
  if ids (functions_of inventory) <> ids (functions_of sorted)
  then fail errors "sort changed the function set" ;
  let rec walk prev = function
    | [] -> ()
    | f :: rest ->
        let cc = jint_opt f "complexity" in
        let id = jstr f "id" in
        ( match (prev, cc) with
        | Some (Some a, aid), Some b ->
            if a < b
            then fail errors ("complexity rose at " ^ id)
            else if a = b && aid > id
            then fail errors ("tie break at " ^ id)
        | Some (None, _), Some _ ->
            fail errors ("measured after unmeasurable at " ^ id)
        | Some (None, aid), None when aid > id ->
            fail errors ("null tie break at " ^ id)
        | _ -> () ) ;
        walk (Some (cc, id)) rest
  in
  walk None (functions_of sorted)

let gap_paths code (j : Yojson.Safe.t) =
  List.filter_map
    (fun g ->
      if jstr g "code" = code
      then Some (jstr g "path", jstr g "detail")
      else None )
    (jlist j "gaps")

let has_fn path fns =
  List.exists
    (fun f ->
      match member "location" f with
      | `Assoc _ -> jstr (member "location" f) "path" = path
      | _ -> false )
    fns

let check_stale errors (j : Yojson.Safe.t) =
  if jstr j "status" <> "incomplete" then fail errors "stale status" ;
  if
    not
      (List.exists
         (fun (path, _) -> path = "metric/samples.ml")
         (gap_paths "GAP-STALE-ARTIFACT" j) )
  then fail errors "missing stale gap for samples.ml" ;
  let fns = functions_of j in
  if has_fn "metric/samples.ml" fns
  then fail errors "stale file contributed functions" ;
  if expect_one errors "stale" fns "Metric.Widget_manager_impl" "ping" = None
  then ()

let check_objects errors (j : Yojson.Safe.t) =
  if jstr j "status" <> "incomplete" then fail errors "objects status" ;
  let fns = functions_of j in
  List.iter
    (fun q ->
      match expect_one errors "objects" fns "Metric.Objects" q with
      | None -> ()
      | Some f ->
          if jint_opt f "complexity" <> None
          then fail errors (q ^ " complexity is not null") ;
          if jstr f "status" <> "unmeasurable" then fail errors (q ^ " status") )
    ["make"; "call"] ;
  if List.exists (fun f -> jint_opt f "complexity" = Some 0) fns
  then fail errors "complexity 0 reported" ;
  let gaps = jlist j "gaps" in
  if
    not
      (List.exists
         (fun g ->
           jstr g "path" = "metric/objects.ml"
           &&
           let d = jstr g "detail" in
           let needle = "class definitions" in
           let n = String.length needle in
           let rec has i =
             i + n <= String.length d
             && (String.sub d i n = needle || has (i + 1))
           in
           has 0 )
         gaps )
  then fail errors "missing class gap" ;
  match
    List.filter
      (fun c -> jstr c "path" = "metric/objects.ml")
      (jlist j "coverage")
  with
  | [c] when jstr c "status" = "measured" && jint_opt c "functions" = Some 2 ->
      ()
  | _ -> fail errors "objects coverage"

let check_partial errors (j : Yojson.Safe.t) =
  if jstr j "status" <> "incomplete" then fail errors "partial status" ;
  let path = "metric/broken.ml" in
  if not (List.exists (fun g -> jstr g "path" = path) (jlist j "gaps"))
  then fail errors "missing gap for broken.ml" ;
  if has_fn path (functions_of j)
  then fail errors "partial file contributed functions" ;
  match List.filter (fun c -> jstr c "path" = path) (jlist j "coverage") with
  | [c] when jstr c "status" <> "measured" -> ()
  | _ ->
      fail errors "partial coverage looks measured" ;
      if
        expect_one
          errors
          "partial"
          (functions_of j)
          "Metric.Widget_manager_impl"
          "ping"
        = None
      then ()

(* ── scenarios ────────────────────────────────────────────────────── *)

let temp_root = "/tmp/szaniec-cc-acc-" ^ string_of_int (Unix.getpid ())

let work_dir = Filename.concat temp_root "run"

let () =
  if Sys.getenv_opt "SZANIEC_KEEP" = Some "1"
  then ()
  else at_exit (fun () -> remove_tree temp_root)

let quote_cmd (exe : string) (work : string) (extra : string) : string =
  Printf.sprintf
    "%s complexity --policy %s --approval %s --project-root %s%s --json"
    (Filename.quote exe)
    (Filename.quote (Filename.concat work "szaniec/complexity-policy.json"))
    (Filename.quote (Filename.concat work "szaniec/approval.json"))
    (Filename.quote work)
    (if extra = "" then "" else " " ^ extra)

let invoke (exe : string) (work : string) (extra : string) : string =
  let out, code = capture (quote_cmd exe work extra) in
  Printf.sprintf "exit=%d\n%s" code out

let restore (fixture : string) (work : string) (rel : string) =
  write_file
    (Filename.concat work rel)
    (read_file (Filename.concat fixture rel))

let () =
  match Sys.argv with
  | argv when Array.length argv >= 4 ->
      let exe = argv.(1) in
      let fixture = Unix.realpath argv.(2) in
      let expected_dir = argv.(3) in
      let update = Array.length argv > 4 && argv.(4) = "--update" in
      ( try Unix.mkdir expected_dir 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
      remove_tree temp_root ;
      Unix.mkdir temp_root 0o755 ;
      Unix.mkdir work_dir 0o755 ;
      copy_tree fixture work_dir ;
      let callgraph = Filename.concat work_dir "szaniec.json" in
      let callgraph_before =
        if Sys.file_exists callgraph then read_file callgraph else ""
      in
      let failures = ref [] in
      let record name raw errors =
        if !errors <> []
        then (
          print_endline "SEMANTIC" ;
          List.iter (Printf.printf "  %s\n") (List.rev !errors) ;
          failures := name :: !failures ;
          print_endline raw )
        else
          let path = Filename.concat expected_dir (name ^ ".txt") in
          if update
          then (
            write_file path raw ;
            print_endline "updated" )
          else
            let expected =
              try read_file path with
              | Sys_error _ -> "<missing>"
            in
            if String.equal expected raw
            then print_endline "ok"
            else (
              print_endline "MISMATCH" ;
              failures := name :: !failures ;
              print_endline "--- expected ---" ;
              print_string expected ;
              print_endline "--- actual ---" ;
              print_string raw ;
              print_endline "---" )
      in
      (* Inventory, twice, then the complexity sort and the text report. *)
      Printf.printf "scenario complexity-inventory ... %!" ;
      let raw1 = invoke exe work_dir "--rebuild" in
      let raw2 = invoke exe work_dir "--rebuild" in
      let errors = ref [] in
      if raw1 <> raw2 then fail errors "repeated complexity report differs" ;
      ( match parse_report raw1 with
      | Error msg -> fail errors msg
      | Ok (code, j) ->
          if code <> 0 then fail errors (Printf.sprintf "exit %d" code) ;
          check_inventory errors j ) ;
      let sort_raw = invoke exe work_dir "--sort complexity" in
      ( match (parse_report raw1, parse_report sort_raw) with
      | Ok (_, inventory), Ok (code, sorted) ->
          if code <> 0 then fail errors (Printf.sprintf "sort exit %d" code) ;
          check_sort errors inventory sorted
      | Error msg, _
       |_, Error msg ->
          fail errors msg ) ;
      let text_cmd =
        Printf.sprintf
          "%s complexity --policy %s --approval %s --project-root %s"
          (Filename.quote exe)
          (Filename.quote
             (Filename.concat work_dir "szaniec/complexity-policy.json") )
          (Filename.quote (Filename.concat work_dir "szaniec/approval.json"))
          (Filename.quote work_dir)
      in
      let text, text_code = capture text_cmd in
      if text_code <> 0 then fail errors "text exit" ;
      if
        not
          (let needle = "Metric.Samples.straight  1  function" in
           let n = String.length needle in
           let rec has i =
             i + n <= String.length text
             && (String.sub text i n = needle || has (i + 1))
           in
           has 0 )
      then fail errors "text report missed straight" ;
      let callgraph_after =
        if Sys.file_exists callgraph then read_file callgraph else ""
      in
      if callgraph_before <> callgraph_after
      then fail errors "complexity rewrote szaniec.json" ;
      record
        "complexity-inventory"
        (raw1 ^ Printf.sprintf "exit2=%d\n" 0 ^ raw2)
        errors ;
      (* The determinism marker above embeds both reports. exit2 is the
       second run's comparison, already enforced by raw1 = raw2. *)
      Printf.printf "scenario complexity-sort ... %!" ;
      let errors = ref [] in
      ( match (parse_report raw1, parse_report sort_raw) with
      | Ok (_, inventory), Ok (code, sorted) ->
          if code <> 0 then fail errors (Printf.sprintf "exit %d" code) ;
          check_sort errors inventory sorted
      | _ -> fail errors "sort report did not parse" ) ;
      record "complexity-sort" sort_raw errors ;
      (* Stale artifact: one edited source, no rebuild. *)
      Printf.printf "scenario complexity-stale ... %!" ;
      let samples = Filename.concat work_dir "metric/samples.ml" in
      write_file samples (read_file samples ^ "\n(* edited after the build *)\n") ;
      let stale_raw = invoke exe work_dir "" in
      let errors = ref [] in
      ( match parse_report stale_raw with
      | Error msg -> fail errors msg
      | Ok (code, j) ->
          if code <> 2 then fail errors (Printf.sprintf "exit %d" code) ;
          check_stale errors j ) ;
      record "complexity-stale" stale_raw errors ;
      restore fixture work_dir "metric/samples.ml" ;
      (* A source that does not type-check must not look measured. *)
      Printf.printf "scenario complexity-partial ... %!" ;
      ignore (invoke exe work_dir "--rebuild") ;
      write_file (Filename.concat work_dir "metric/broken.ml") broken_src ;
      let partial_raw = invoke exe work_dir "--rebuild" in
      let errors = ref [] in
      ( match parse_report partial_raw with
      | Error msg -> fail errors msg
      | Ok (code, j) ->
          if code <> 2 then fail errors (Printf.sprintf "exit %d" code) ;
          check_partial errors j ) ;
      record "complexity-partial" partial_raw errors ;
      remove_file (Filename.concat work_dir "metric/broken.ml") ;
      (* Drop the partial artifact before the next successful build. *)
      ignore (invoke exe work_dir "--rebuild") ;
      (* Objects, method sends, and classes are explicit gaps. *)
      Printf.printf "scenario complexity-unmeasurable ... %!" ;
      write_file (Filename.concat work_dir "metric/objects.ml") objects_src ;
      let objects_raw = invoke exe work_dir "--rebuild" in
      let errors = ref [] in
      ( match parse_report objects_raw with
      | Error msg -> fail errors msg
      | Ok (code, j) -> (
          if code <> 2 then fail errors (Printf.sprintf "exit %d" code) ;
          check_objects errors j ;
          let sort_objects = invoke exe work_dir "--sort complexity" in
          match parse_report sort_objects with
          | Ok (sort_code, sorted) ->
              if sort_code <> 2
              then fail errors (Printf.sprintf "sort exit %d" sort_code) ;
              check_sort errors j sorted
          | Error msg -> fail errors msg ) ) ;
      record "complexity-unmeasurable" objects_raw errors ;
      if !failures <> []
      then (
        Printf.printf
          "FAILED scenarios: %s\n"
          (String.concat ", " (List.rev !failures)) ;
        exit 1 )
      else if not update
      then print_endline "all complexity scenarios passed"
  | _ ->
      prerr_endline
        "usage: complexity_runner.exe <szaniec-binary> <fixture-dir> \
         <expected-dir> [--update]" ;
      exit 2
