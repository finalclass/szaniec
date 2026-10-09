open Szaniec_model
open Typedtree

let observe ~site_of_loc ~invocation expression =
  let unknown e reason =
    [Observation.Unknown_order (reason, site_of_loc e.exp_loc)]
  in
  let rec permutations = function
    | [] -> [[]]
    | head :: tail ->
        let rec insert prefix = function
          | [] -> [List.rev prefix @ [head]]
          | next :: rest as suffix ->
              (List.rev prefix @ (head :: suffix))
              :: insert (next :: prefix) rest
        in
        List.concat_map (insert []) (permutations tail)
  in
  let unordered e groups =
    match List.filter (fun steps -> steps <> []) groups with
    | [] -> []
    | [steps] -> steps
    | groups when List.length groups <= 4 ->
        unknown e "operand evaluation order unspecified"
        @ [ Observation.Choose
              (List.mapi
                 (fun i groups ->
                   (Printf.sprintf "operand-order-%d" i, List.concat groups) )
                 (permutations groups) ) ]
    | _ -> unknown e "operand ordering alternatives exceed limit"
  in
  let rec walk e =
    match e.exp_desc with
    | Texp_ident _
     |Texp_constant _
     |Texp_function _
     |Texp_lazy _ ->
        []
    | Texp_sequence (a, b) -> walk a @ walk b
    | Texp_let (_, bindings, body) ->
        unordered e (List.map (fun vb -> walk vb.vb_expr) bindings) @ walk body
    | Texp_ifthenelse (condition, yes, no) ->
        walk condition
        @ [ Observation.Choose
              [("then", walk yes); ("else", Option.fold ~none:[] ~some:walk no)]
          ]
    | Texp_match (scrutinee, cases, exceptions, _) ->
        walk scrutinee
        @ ( if exceptions = []
            then []
            else unknown e "match exception flow unsupported" )
        @ [Observation.Choose (case_steps cases @ case_steps exceptions)]
    | Texp_try (body, cases, effects) ->
        unknown e "exception flow unsupported"
        @ [ Observation.Choose
              (("body", walk body) :: (case_steps cases @ case_steps effects))
          ]
    | Texp_while (condition, body) ->
        [ Observation.Repeat
            ("while", site_of_loc e.exp_loc, walk condition, walk body) ]
    | Texp_for (_, _, start, stop, _, body) ->
        unordered e [walk start; walk stop]
        @ [Observation.Repeat ("for", site_of_loc e.exp_loc, [], walk body)]
    | Texp_apply (fn, args) -> (
        let rec collapse fn args =
          match fn.exp_desc with
          | Texp_apply (inner, more) -> collapse inner (more @ args)
          | _ -> (fn, args)
        in
        let fn, args = collapse fn args in
        let arguments =
          List.filter_map
            (function
              | _, Arg e -> Some e
              | _ -> None )
            args
        in
        match invocation e with
        | Some call
          when List.mem
                 call.Observation.execution_callee
                 ["Stdlib.&&"; "Stdlib.||"] -> (
          match arguments with
          | [left; right] ->
              walk left
              @ [ Observation.Choose
                    [("short-circuit", []); ("evaluate-right", walk right)] ]
          | _ -> unknown e "short-circuit operands unsupported" )
        | call -> (
            unordered e (walk fn :: List.map walk arguments)
            @
            match call with
            | None -> unknown e "invocation evidence unavailable"
            | Some call ->
                [Observation.Invoke call]
                @
                if
                  List.mem
                    call.execution_callee
                    ["Stdlib.raise"; "Stdlib.raise_notrace"]
                then [Observation.Leave ("raise", site_of_loc e.exp_loc)]
                else [] ) )
    | Texp_construct (_, _, args)
     |Texp_array (_, args) ->
        unordered e (List.map walk args)
    | Texp_tuple args -> unordered e (List.map (fun (_, e) -> walk e) args)
    | Texp_record {fields; extended_expression; _} ->
        unordered
          e
          ( Array.to_list fields
          |> List.filter_map (function
            | _, Overridden (_, e) -> Some (walk e)
            | _ -> None )
          |> fun fields ->
            fields
            @ Option.fold ~none:[] ~some:(fun e -> [walk e]) extended_expression
          )
    | Texp_field (e, _, _)
     |Texp_atomic_loc (e, _, _)
     |Texp_letexception (_, e)
     |Texp_variant (_, Some e) ->
        walk e
    | Texp_variant (_, None) -> []
    | Texp_setfield (a, _, _, b) -> unordered e [walk a; walk b]
    | Texp_assert (condition, _) ->
        walk condition
        @ [ Observation.Choose
              [ ("assertion-passes", [])
              ; ( "assertion-fails"
                , [Observation.Leave ("raise", site_of_loc e.exp_loc)] ) ] ]
    | Texp_open (_, body) ->
        unknown e "local module initialization unsupported" @ walk body
    | Texp_letmodule (_, _, _, _, body) ->
        unknown e "local module initialization unsupported" @ walk body
    | Texp_unreachable -> unknown e "unreachable expression"
    | _ -> unknown e "execution construct unsupported"
  and case_steps : type k.
      k case list -> (string * Observation.ordered_step list) list =
   fun cases ->
    List.mapi
      (fun i c ->
        ( Printf.sprintf "arm-%d" i
        , Option.fold
            ~none:[]
            ~some:(fun guard ->
              unknown guard "guard selection flow unsupported" @ walk guard )
            c.c_guard
          @ walk c.c_rhs ) )
      cases
  in
  match expression.exp_desc with
  | Texp_function (params, body) -> (
      List.concat_map
        (fun p ->
          match p.fp_kind with
          | Tparam_optional_default (_, e) ->
              [ Observation.Choose
                  [("argument-supplied", []); ("default-argument", walk e)] ]
          | _ -> [] )
        params
      @
      match body with
      | Tfunction_body e -> walk e
      | Tfunction_cases {cases; _} -> [Observation.Choose (case_steps cases)] )
  | _ -> walk expression
