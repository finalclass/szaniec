open Szaniec_model

let () =
  let units =
    "Library.Unit0.Nested"
    :: List.init 2000 (fun i -> Printf.sprintf "Library.Unit%d" i)
  in
  let paths =
    Array.init 6000 (fun i ->
        if i mod 3 = 0
        then Printf.sprintf "Unknown.Unit%d.run" (i mod 2000)
        else Printf.sprintf "Library.Unit%d.Nested.run" (i mod 2000) )
  in
  for run = 1 to 3 do
    let measure label resolve =
      Gc.full_major () ;
      let started = Sys.time () in
      let allocated = Gc.allocated_bytes () in
      let first = Array.map resolve paths in
      let repeated = Array.map resolve paths in
      assert (first = repeated) ;
      Printf.printf
        "%s run=%d lookups=12000 cpu=%.6f allocation=%.0f\n%!"
        label
        run
        (Sys.time () -. started)
        (Gc.allocated_bytes () -. allocated) ;
      first
    in
    let baseline = measure "baseline" (Canonical.unit_prefix units) in
    let indexed = measure "indexed" (Canonical.unit_resolver units) in
    assert (baseline = indexed)
  done
