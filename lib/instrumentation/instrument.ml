open Ppxlib

let ghost = Location.none

let ident name =
  let txt =
    match String.split_on_char '.' name with
    | [] -> Longident.Lident name
    | first :: rest ->
        List.fold_left
          (fun acc lab -> Longident.Ldot (acc, lab))
          (Longident.Lident first)
          rest
  in
  Ast_builder.Default.pexp_ident ~loc:ghost {txt; loc= ghost}

let unit_binding expr =
  Ast_builder.Default.pstr_value
    ~loc:ghost
    Nonrecursive
    [ Ast_builder.Default.value_binding
        ~loc:ghost
        ~pat:(Ast_builder.Default.punit ~loc:ghost)
        ~expr ]

let install_item () =
  unit_binding
    (Ast_builder.Default.pexp_apply
       ~loc:ghost
       (ident "Szaniec_coverage_runtime.install")
       [(Nolabel, Ast_builder.Default.eunit ~loc:ghost)] )

let probe_item filename =
  unit_binding
    (Ast_builder.Default.pexp_apply
       ~loc:ghost
       (ident "Szaniec_probe_runtime.record")
       [(Nolabel, Ast_builder.Default.estring ~loc:ghost filename)] )

let impl ctxt structure =
  let filename = Expansion_context.Base.input_name ctxt in
  install_item () :: probe_item filename :: structure

let () =
  Driver.register_transformation
    "szaniec_instrumentation"
    ~instrument:
      (Driver.Instrument.V2.make impl ~position:Driver.Instrument.Before)
