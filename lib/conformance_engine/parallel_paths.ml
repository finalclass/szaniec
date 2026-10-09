let configured_domains () =
  match Sys.getenv_opt "SZANIEC_DOMAINS" with
  | None -> 1
  | Some value -> (
    match int_of_string_opt value with
    | Some n when n >= 1 && n <= 8 -> n
    | _ -> invalid_arg "SZANIEC_DOMAINS must be an integer from 1 to 8" )

let map ?domains f entries =
  let domains =
    match domains with
    | Some value -> value
    | None -> configured_domains ()
  in
  if domains < 1 || domains > 8
  then invalid_arg "evaluation domains must be 1 through 8" ;
  let length = List.length entries in
  if domains = 1 || length < 256
  then List.map f entries
  else
    let input = Array.of_list entries in
    let output = Array.make length None in
    let cursor = Atomic.make 0 in
    let run () =
      let rec loop () =
        let i = Atomic.fetch_and_add cursor 1 in
        if i < length
        then (
          let result =
            try Ok (f input.(i)) with
            | exn -> Error (exn, Printexc.get_raw_backtrace ())
          in
          output.(i) <- Some result ;
          loop () )
      in
      loop ()
    in
    let workers = ref [] in
    let spawned =
      try
        for _ = 2 to min domains length do
          workers := Domain.spawn run :: !workers
        done ;
        true
      with
      | _ -> false
    in
    if spawned then run () ;
    let join_error = ref None in
    List.iter
      (fun worker ->
        try Domain.join worker with
        | exn ->
            if !join_error = None
            then join_error := Some (exn, Printexc.get_raw_backtrace ()) )
      !workers ;
    match !join_error with
    | Some (exn, trace) -> Printexc.raise_with_backtrace exn trace
    | None when not spawned -> List.map f entries
    | None ->
        Array.to_list output
        |> List.map (function
          | Some (Ok value) -> value
          | Some (Error (exn, trace)) -> Printexc.raise_with_backtrace exn trace
          | None -> failwith "evaluation worker omitted an execution path" )
