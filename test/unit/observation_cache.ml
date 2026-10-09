module Cache = Szaniec_program_access.Observation_cache

let write path value =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () -> output_string output value)

let () =
  let root = Filename.temp_file "szaniec-cache-" "" in
  Sys.remove root ;
  Unix.mkdir root 0o700 ;
  Unix.mkdir (Filename.concat root "_build") 0o700 ;
  let artifact = Filename.concat root "artifact"
  and source = Filename.concat root "source.ml" in
  write artifact "compiled artifact" ;
  write source "source" ;
  let cache = Cache.create ~project_root:root ~evidence:"architecture" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists cache.directory
      then (
        Array.iter
          (fun entry -> Sys.remove (Filename.concat cache.directory entry))
          (Sys.readdir cache.directory) ;
        Unix.rmdir cache.directory ) ;
      Sys.remove artifact ;
      Sys.remove source ;
      Unix.rmdir (Filename.concat root "_build") ;
      Unix.rmdir root )
    (fun () ->
      let key =
        Cache.key cache ~kind:"facts" ~artifact:"artifact" ~source:"source.ml"
      in
      Cache.write cache key [1; 2; 3] ;
      assert (Cache.artifact_current cache ~artifact:"artifact") ;
      assert (Cache.read cache key = Some [1; 2; 3]) ;
      assert (
        (Unix.stat (Filename.concat cache.directory key)).st_perm land 0o077 = 0 ) ;
      let other = Cache.create ~project_root:root ~evidence:"measurement" in
      assert (
        Cache.key other ~kind:"facts" ~artifact:"artifact" ~source:"source.ml"
        <> key ) ;
      let moved =
        Cache.create
          ~project_root:(Filename.concat root ".")
          ~evidence:"architecture"
      in
      assert (
        Cache.key moved ~kind:"facts" ~artifact:"artifact" ~source:"source.ml"
        <> key ) ;
      List.iter
        (fun identity ->
          let upgraded = {cache with Cache.identity} in
          let upgraded_key =
            Cache.key
              upgraded
              ~kind:"facts"
              ~artifact:"artifact"
              ~source:"source.ml"
          in
          assert (upgraded_key <> key) ;
          assert (Cache.read upgraded upgraded_key = None) )
        (List.map
           (fun version -> cache.identity ^ "\n" ^ version)
           [ "cache-format-upgrade"
           ; "adapter-upgrade"
           ; "schema-upgrade"
           ; "compiler-upgrade" ] ) ;
      let metadata =
        Cache.key cache ~kind:"metadata" ~artifact:"artifact" ~source:""
      in
      write
        (Filename.concat cache.directory metadata)
        (Cache.read_file (Filename.concat cache.directory key)) ;
      assert (Cache.read cache metadata = None) ;
      write source "changed source" ;
      assert (
        Cache.key cache ~kind:"facts" ~artifact:"artifact" ~source:"source.ml"
        <> key ) ;
      let fresh = Cache.create ~project_root:root ~evidence:"architecture" in
      write artifact "changed compiler artifact" ;
      assert (not (Cache.artifact_current cache ~artifact:"artifact")) ;
      assert (
        Cache.key fresh ~kind:"facts" ~artifact:"artifact" ~source:"source.ml"
        <> key ) ;
      write (Filename.concat cache.directory key) "corrupt" ;
      assert (Cache.read cache key = None) ;
      Cache.write cache key [4; 5] ;
      assert (Cache.read cache key = Some [4; 5]) ;
      print_endline
        "observation cache: integrity, entry identity, capabilities, content \
         and permissions: ok" )
