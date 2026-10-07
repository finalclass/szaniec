(* Client layer — second page, shares the WebClient helper *)

let help_handler req =
  ignore req ;
  let _s = Shared.render_title "help" in
  ignore _s ;
  0
