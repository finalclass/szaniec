let not_disable_validation enabled = not enabled

let render ~as_email ~as_pdf text =
  if as_email then "email:" ^ text else if as_pdf then "pdf:" ^ text else text

(* Returns the sum of the stored counters. *)
let store_note path text =
  let channel = open_out path in
  output_string channel text ;
  close_out channel

let forward_trim text = String.trim text

let lookup_title path =
  let channel = open_out path in
  output_string channel "lookup" ;
  close_out channel ;
  "lookup"

let list_open req = req
