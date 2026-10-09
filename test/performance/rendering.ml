let rec defer (value : Yojson.Safe.t) : Callgraph_render.t =
  match value with
  | `String value -> `String value
  | `Int value -> `Int value
  | `Assoc fields ->
      `Assoc (List.map (fun (name, value) -> (name, defer value)) fields)
  | `List values -> `List (fun () -> List.map defer values)
  | _ -> failwith "unexpected graph JSON primitive"

let render value =
  let path, output = Filename.open_temp_file "szaniec-render-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr output ;
      Sys.remove path )
    (fun () ->
      Callgraph_render.to_channel output value ;
      close_out output ;
      let input = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr input)
        (fun () -> really_input_string input (in_channel_length input)) )

let () =
  let random = Random.State.make [|743|] in
  let strings =
    [|""; "quote\"slash\\"; "line\n\t"; "żółć"; String.make 95 'a'|]
  in
  let rec value depth : Yojson.Safe.t =
    if depth = 0
    then
      if Random.State.bool random
      then `Int (Random.State.int random 10000 - 5000)
      else `String strings.(Random.State.int random (Array.length strings))
    else
      match Random.State.int random 4 with
      | 0 -> value 0
      | 1 ->
          `List
            (List.init (Random.State.int random 6) (fun _ -> value (depth - 1)))
      | _ ->
          `Assoc
            (List.init (Random.State.int random 6) (fun i ->
                 (strings.(i mod Array.length strings), value (depth - 1)) ) )
  in
  for _ = 1 to 1000 do
    let original = value 5 in
    assert (render (defer original) = Yojson.Safe.pretty_to_string original)
  done ;
  let deep =
    List.fold_left
      (fun child _ -> `Assoc [("branches", `List [child])])
      (`List [`Int min_int; `Int max_int; `String "\000\b\r"])
      (List.init 100 Fun.id)
  in
  assert (render (defer deep) = Yojson.Safe.pretty_to_string deep) ;
  let forced = ref false in
  let deferred =
    `List
      (fun () ->
        forced := true ;
        [`String "deferred"] )
  in
  assert (not !forced) ;
  ignore (render deferred) ;
  assert !forced ;
  print_endline
    "streaming graph JSON: 1000 layouts, escaping and lazy production agree \
     with Yojson: ok"
