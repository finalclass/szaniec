module Paths = Szaniec_conformance_engine.Parallel_paths

let () =
  let entries = List.init 1024 Fun.id in
  List.iter
    (fun domains ->
      let actual =
        Paths.map
          ~domains
          (fun i ->
            if i mod 31 = 0 then Domain.cpu_relax () ;
            i * i )
          entries
      in
      assert (actual = List.map (fun i -> i * i) entries) )
    [1; 2; 4; 8] ;
  let completed = Atomic.make 0 in
  ( try
      ignore
        (Paths.map
           ~domains:4
           (fun i ->
             if i = 7 then failwith "worker exception" ;
             ignore (Atomic.fetch_and_add completed 1) ;
             i )
           entries ) ;
      failwith "exception must propagate"
    with
  | Failure message when message = "worker exception" -> () ) ;
  assert (Atomic.get completed = List.length entries - 1) ;
  assert (Paths.map ~domains:8 Fun.id [1; 2] = [1; 2]) ;
  ( try
      ignore (Paths.map ~domains:9 Fun.id entries) ;
      assert false
    with
  | Invalid_argument _ -> () ) ;
  print_endline
    "parallel paths: deterministic order, skew, exceptions and cleanup: ok"
