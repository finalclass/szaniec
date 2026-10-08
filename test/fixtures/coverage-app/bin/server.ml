let port =
  match Sys.getenv_opt "PORT" with
  | Some text -> int_of_string text
  | None -> 8080

let body_of path =
  match path with
  | "/health" -> "ok"
  | "/answer" -> string_of_int (Coverage_app_api.Api.answer ())
  | "/nested" -> Coverage_app_api.Api.nested ()
  | "/marker" -> Coverage_app_api.Api.marker
  | _ -> "missing"

let response body =
  Printf.sprintf
    "HTTP/1.1 200 OK\r\n\
     Content-Type: text/plain\r\n\
     Content-Length: %d\r\n\
     Connection: close\r\n\
     \r\n\
     %s"
    (String.length body)
    body

let stop = ref false

let () = Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun _ -> stop := true))

let () =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt sock Unix.SO_REUSEADDR true ;
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) ;
  Unix.listen sock 16 ;
  let rec loop () =
    if !stop
    then ()
    else
      match Unix.select [sock] [] [] 0.2 with
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
      | [], _, _ -> loop ()
      | _ ->
          let client, _ = Unix.accept sock in
          let buf = Bytes.create 2048 in
          let n =
            try Unix.read client buf 0 (Bytes.length buf) with
            | Unix.Unix_error _ -> 0
          in
          let req = Bytes.sub_string buf 0 n in
          let path =
            match String.split_on_char ' ' req with
            | _method :: path :: _ -> path
            | _ -> "/"
          in
          let msg = response (body_of path) in
          ( try
              ignore (Unix.write_substring client msg 0 (String.length msg))
            with
          | Unix.Unix_error _ -> () ) ;
          ( try Unix.close client with
          | Unix.Unix_error _ -> () ) ;
          loop ()
  in
  loop () ;
  ( try Unix.close sock with
  | Unix.Unix_error _ -> () ) ;
  exit 0
