(* The compiler executes [let* value = input in body] as an application of
   the resolved operator to [input] and a pattern-matching continuation.
   Normalize that execution view before collecting calls. Complexity keeps
   the original typed tree, so this does not introduce syntactic functions
   into the measurement inventory. *)
open Typedtree

let lower structure =
  let default = Tast_mapper.default in
  let mapper =
    { default with
      expr=
        (fun self expression ->
          let expression = default.expr self expression in
          match expression.exp_desc with
          | Texp_letop {let_; ands= []; param; body; partial} -> (
              let head typ =
                Ctype.expand_head
                  (Envaux.env_of_only_summary expression.exp_env)
                  typ
              in
              match Types.get_desc (head let_.bop_op_type) with
              | Types.Tarrow (_, _, rest, _) -> (
                match Types.get_desc (head rest) with
                | Types.Tarrow (_, continuation_type, _, _) ->
                    let operator =
                      { expression with
                        exp_desc=
                          Texp_ident
                            ( let_.bop_op_path
                            , { let_.bop_op_name with
                                txt= Longident.Lident let_.bop_op_name.txt }
                            , let_.bop_op_val )
                      ; exp_type= let_.bop_op_type
                      ; exp_loc= let_.bop_op_name.loc
                      ; exp_extra= []
                      ; exp_attributes= [] }
                    in
                    let continuation =
                      { expression with
                        exp_desc=
                          Texp_function
                            ( []
                            , Tfunction_cases
                                { cases= [body]
                                ; param
                                ; partial
                                ; loc= body.c_rhs.exp_loc
                                ; exp_extra= None
                                ; attributes= [] } )
                      ; exp_type= continuation_type
                      ; exp_extra= []
                      ; exp_attributes= [] }
                    in
                    { expression with
                      exp_desc=
                        Texp_apply
                          ( operator
                          , [ (Asttypes.Nolabel, Arg let_.bop_exp)
                            ; (Asttypes.Nolabel, Arg continuation) ] ) }
                | _ -> expression )
              | _ -> expression )
          | _ -> expression ) }
  in
  mapper.structure mapper structure
