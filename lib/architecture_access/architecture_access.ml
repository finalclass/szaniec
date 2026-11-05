(* ArchitectureAccess: supplies the services declared by the project's
   .cyrograf contracts. Reads only the directories it is given (the
   source directories walked by ProjectAccess); never reads _build. *)

open Szaniec_model

let ( // ) a b = if a = "" then b else Filename.concat a b

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let services ~(root : string) ~(directories : string list) :
    (Structure.service list, string) result =
  try
    let files =
      List.concat_map
        (fun dir ->
          ( try Sys.readdir (root // dir) |> Array.to_list with
            | Sys_error _ -> [] )
          |> List.filter (fun e -> Filename.check_suffix e ".cyrograf")
          |> List.map (fun e -> dir // e) )
        directories
      |> List.sort_uniq compare
    in
    Ok
      (List.filter_map
         (fun rel ->
           match Cyrograf.parse_rpcs (read_file (root // rel)) with
           | [] -> None
           | methods ->
               Some
                 { Structure.service_name=
                     Filename.remove_extension (Filename.basename rel)
                 ; service_source= rel
                 ; service_methods=
                     List.map (fun m -> m.Cyrograf.m_name) methods } )
         files )
  with
  | Sys_error e -> Error ("cannot read contract: " ^ e)
