let handle_task title path =
  let channel = open_out path in
  output_string channel title ;
  close_out channel ;
  Printf.printf "stored %s\n" title
