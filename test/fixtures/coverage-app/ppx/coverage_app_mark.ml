open Ppxlib

let extension =
  Extension.declare
    "coverage_mark"
    Extension.Context.expression
    Ast_pattern.(pstr nil)
    (fun ~loc ~path:_ -> Ast_builder.Default.estring ~loc "marked-by-ppx")

let () =
  Driver.register_transformation
    "coverage_app_mark"
    ~rules:[Context_free.Rule.extension extension]
