(* Second client family. It shares the approved Clock module with
   Web_client and does not reach another family's implementation. *)

let show () = Clock.now ()
