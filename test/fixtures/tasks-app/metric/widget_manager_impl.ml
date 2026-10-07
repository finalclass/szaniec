(* Implementation of Widget_manager. The module name binds the service.
   [ping] is a declared rpc method; [helper] is an ordinary function. *)

let ping on = if on then 1 else 0

let helper () = 1
