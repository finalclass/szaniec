open Szaniec_model

type t =
  { directory: string
  ; identity: string
  ; enabled: bool
  ; artifacts: (string, string) Hashtbl.t
  ; mutable hits: int
  ; mutable misses: int
  ; mutable typed_reads: int }

let digest text = Digestif.SHA256.to_hex (Digestif.SHA256.digest_string text)

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let create ~project_root ~evidence =
  { directory= Filename.concat project_root "_build/.szaniec-observations"
  ; identity=
      String.concat
        "\n"
        [ "szaniec-observation-cache/3"
        ; Version.observation_format
        ; Version.adapter_ocaml
        ; Sys.ocaml_version
        ; project_root
        ; evidence ]
  ; enabled= Sys.getenv_opt "SZANIEC_OBSERVATION_CACHE" <> Some "off"
  ; artifacts= Hashtbl.create 64
  ; hits= 0
  ; misses= 0
  ; typed_reads= 0 }

let key cache ~kind ~artifact ~source =
  let project_root = Filename.dirname (Filename.dirname cache.directory) in
  let artifact_digest =
    match Hashtbl.find_opt cache.artifacts artifact with
    | Some value -> value
    | None ->
        let value =
          digest (read_file (Filename.concat project_root artifact))
        in
        Hashtbl.add cache.artifacts artifact value ;
        value
  in
  let source_digest =
    if source = ""
    then ""
    else
      try digest (read_file (Filename.concat project_root source)) with
      | Sys_error _ -> "missing"
  in
  digest
    (String.concat
       "\n"
       [cache.identity; kind; artifact; artifact_digest; source; source_digest] )

let artifact_current cache ~artifact =
  let project_root = Filename.dirname (Filename.dirname cache.directory) in
  Hashtbl.find_opt cache.artifacts artifact
  = Some (digest (read_file (Filename.concat project_root artifact)))

let read cache key =
  let result =
    if not cache.enabled
    then None
    else
      try
        let bytes = read_file (Filename.concat cache.directory key) in
        let boundary = String.index bytes '\n' in
        let expected = String.sub bytes 0 boundary in
        let payload =
          String.sub bytes (boundary + 1) (String.length bytes - boundary - 1)
        in
        if
          expected <> key ^ ":" ^ digest payload
          || Marshal.total_size (Bytes.of_string payload) 0
             <> String.length payload
        then None
        else Some (Marshal.from_string payload 0)
      with
      | _ -> None
  in
  ( match result with
  | Some _ -> cache.hits <- cache.hits + 1
  | None -> cache.misses <- cache.misses + 1 ) ;
  result

let write cache key value =
  if cache.enabled
  then
    try
      ( try Unix.mkdir cache.directory 0o700 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> () ) ;
      let payload = Marshal.to_string value [] in
      let temporary, output =
        Filename.open_temp_file
          ~temp_dir:cache.directory
          ~perms:0o600
          ".pending-"
          ".tmp"
      in
      Fun.protect
        ~finally:(fun () ->
          close_out_noerr output ;
          try Sys.remove temporary with
          | Sys_error _ -> () )
        (fun () ->
          output_string output (key ^ ":" ^ digest payload ^ "\n" ^ payload) ;
          close_out output ;
          Unix.rename temporary (Filename.concat cache.directory key) )
    with
    | _ -> ()

let note_read cache = cache.typed_reads <- cache.typed_reads + 1

let finish cache ~scanned ~selected =
  if Sys.getenv_opt "SZANIEC_ACQUISITION_STATS" = Some "1"
  then
    Printf.eprintf
      "SZANIEC_ACQUISITION artifacts=%d selected=%d typed_reads=%d \
       cache_hits=%d cache_misses=%d\n\
       %!"
      scanned
      selected
      cache.typed_reads
      cache.hits
      cache.misses
