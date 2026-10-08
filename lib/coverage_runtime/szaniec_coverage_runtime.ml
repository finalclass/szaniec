let installed = ref false

let mkdir_p path =
  try Unix.mkdir path 0o755 with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let install () =
  if !installed
  then ()
  else (
    installed := true ;
    match Sys.getenv_opt "SZANIEC_COVERAGE_CONTEXT" with
    | None -> ()
    | Some dir ->
        let data = Filename.concat dir "data" in
        mkdir_p dir ;
        mkdir_p data ;
        ( match Sys.getenv_opt "BISECT_FILE" with
        | Some _ -> ()
        | None ->
            let prefix =
              Filename.concat data (string_of_int (Unix.getpid ()) ^ "-")
            in
            Unix.putenv "BISECT_FILE" prefix ) ;
        if Sys.getenv_opt "BISECT_SILENT" = None
        then Unix.putenv "BISECT_SILENT" "YES" )
