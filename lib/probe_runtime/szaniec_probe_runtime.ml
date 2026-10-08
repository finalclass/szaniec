let record (unit_name : string) =
  match Sys.getenv_opt "SZANIEC_PROBE_DIR" with
  | None -> ()
  | Some dir ->
      let path =
        Filename.concat dir (string_of_int (Unix.getpid ()) ^ ".visits")
      in
      let oc =
        open_out_gen
          [Open_wronly; Open_append; Open_creat; Open_text]
          0o644
          path
      in
      output_string oc (unit_name ^ "\n") ;
      close_out oc
