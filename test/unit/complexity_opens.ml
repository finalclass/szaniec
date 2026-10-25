open Szaniec_model
module Complexity = Szaniec_program_access.Complexity

let check condition message = if not condition then failwith message

let structure ~opened count =
  let source = Buffer.create (count * 80) in
  for i = 1 to count do
    Buffer.add_string
      source
      (if opened then "open struct\nopen struct\n" else "\n\n") ;
    Printf.bprintf source "let f%d flag = if flag then 1 else 0\n" i ;
    Buffer.add_string source (if opened then "end\nend\n" else "\n\n")
  done ;
  let lexbuf = Lexing.from_string (Buffer.contents source) in
  Location.init lexbuf "lib/metric.ml" ;
  let parsed = Parse.implementation lexbuf in
  let typed, _, _, _, _ =
    Typemod.type_structure (Compmisc.initial_env ()) parsed
  in
  typed

let measure label count structure =
  Gc.full_major () ;
  let before = Gc.allocated_bytes () in
  let started = Sys.time () in
  let functions, gaps =
    Complexity.measure
      ~project_root:"."
      ~source_path:"lib/metric.ml"
      ~unit_canonical:"Metric"
      structure
  in
  let seconds = Sys.time () -. started in
  let allocated = Gc.allocated_bytes () -. before in
  check
    (List.length functions = count && gaps = [])
    "incomplete large inventory" ;
  List.iteri
    (fun i (f : Observation.function_def) ->
      check
        ( f.fn_id = Printf.sprintf "Metric.f%d" (i + 1)
        && f.fn_line = (i * 5) + 3
        && f.fn_col = 0
        && f.fn_measure = Observation.Fn_measured {cognitive= 2; cyclomatic= 2}
        )
        "large inventory lost an identity, source span or score" )
    functions ;
  Printf.printf
    "complexity %s: %d functions, %.6f CPU seconds, %.0f allocated bytes\n%!"
    label
    count
    seconds
    allocated ;
  check (seconds < 5.) "complexity walk exceeded the CPU budget" ;
  (functions, allocated)

let () =
  Compmisc.init_path () ;
  Warnings.parse_options false "-32-33" |> ignore ;
  let allocations =
    List.map
      (fun count ->
        let flat, flat_bytes =
          measure "flat" count (structure ~opened:false count)
        in
        let opened, open_bytes =
          measure "opened" count (structure ~opened:true count)
        in
        check
          (flat = opened)
          "open wrappers changed the full function inventory" ;
        check
          (open_bytes < (flat_bytes *. 1.25) +. 4096.)
          "open traversal allocated disproportionately to the flat control" ;
        open_bytes )
      [4000; 8000]
  in
  match allocations with
  | [small; large] ->
      check
        (large < small *. 2.5)
        "doubling open bodies caused superlinear allocation"
  | _ -> assert false
