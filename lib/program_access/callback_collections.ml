open Typedtree

(* Conservative element provenance for locally observed callback lists. Empty
   writes clear a queue; all other writes contribute possible targets. Unknown
   producers remain explicit empty-string targets, never successful evidence. *)
let observe ~known ~resolve ~symbol ~result_source ~call_result ~site structure
    =
  let edges = ref [] in
  let locals = Hashtbl.create 32 in
  let add key values =
    List.iter (fun value -> edges := (key, value) :: !edges) values
  in
  let expanded env typ =
    try Ctype.expand_head (Envaux.env_of_only_summary env) typ with
    | _ -> typ
  in
  let callback_list env typ =
    match Types.get_desc (expanded env typ) with
    | Types.Tconstr (path, [element], _) when Path.same path Predef.path_list
      -> (
      match Types.get_desc (expanded env element) with
      | Types.Tarrow _ -> true
      | _ -> false )
    | _ -> false
  in
  let list e = callback_list e.exp_env e.exp_type in
  let field_key label =
    "<callback-store@"
    ^ Format.asprintf "%a" Types.Uid.print label.Data_types.lbl_uid
    ^ ">"
  in
  let element source = source ^ ".<elements>" in
  let key e =
    let at = site e.exp_loc in
    Printf.sprintf
      "<callback-list@%s:%d:%d>"
      at.Szaniec_model.Observation.site_path
      at.line
      at.col
  in
  let rec sources e =
    match e.exp_desc with
    | Texp_construct (_, description, [])
      when description.Data_types.cstr_name = "[]" ->
        []
    | Texp_construct (_, description, [head; tail])
      when description.Data_types.cstr_name = "::" ->
        symbol head :: sources tail
    | Texp_field (_, _, label) when list e -> [field_key label]
    | Texp_ident (Path.Pident id, _, _) when Hashtbl.mem locals id ->
        [Hashtbl.find locals id]
    | Texp_ident (path, _, _) ->
        let source = result_source e in
        [element (if source = "" then resolve path else source)]
    | Texp_apply ({exp_desc= Texp_ident (path, _, _); _}, [(_, Arg value)])
      when resolve path = "Stdlib.List.rev" ->
        sources value
    | Texp_apply _ -> [element (call_result e)]
    | Texp_ifthenelse (_, yes, no) ->
        sources yes @ Option.fold ~none:[] ~some:sources no
    | Texp_let (_, _, body)
     |Texp_sequence (_, body)
     |Texp_open (_, body) ->
        sources body
    | _ -> [""]
  in
  let rec returned source e =
    if list e
    then add (element source) (sources e)
    else
      match e.exp_desc with
      | Texp_let (_, _, body)
       |Texp_sequence (_, body)
       |Texp_open (_, body) ->
          returned source body
      | Texp_try (body, cases, _) ->
          returned source body ;
          List.iter (fun c -> returned source c.c_rhs) cases
      | Texp_ifthenelse (_, yes, no) ->
          returned source yes ;
          Option.iter (returned source) no
      | Texp_match (_, cases, values, _) ->
          List.iter (fun c -> returned source c.c_rhs) cases ;
          List.iter (fun c -> returned source c.c_rhs) values
      | Texp_tuple values ->
          List.iteri
            (fun i (_, value) ->
              returned (source ^ ".<tuple@" ^ string_of_int i ^ ">") value )
            values
      | _ -> ()
  in
  let iterator = Tast_iterator.default_iterator in
  let iterator =
    { iterator with
      value_binding=
        (fun self binding ->
          Tast_iterator.default_iterator.value_binding self binding ;
          match binding.vb_pat.pat_desc with
          | Tpat_var (id, _, _) when list binding.vb_expr ->
              let local = key binding.vb_expr in
              add local (sources binding.vb_expr) ;
              Hashtbl.replace locals id local
          | _ -> () )
    ; expr=
        (fun self e ->
          Tast_iterator.default_iterator.expr self e ;
          ( match e.exp_desc with
          | Texp_function (_, Tfunction_body body) ->
              returned (symbol e ^ ".<result>") body
          | Texp_record {fields; _} ->
              Array.iter
                (fun (label, value) ->
                  if callback_list e.exp_env label.Data_types.lbl_arg
                  then
                    match value with
                    | Overridden (_, value) ->
                        add (field_key label) (sources value)
                    | Kept _ -> () )
                fields
          | Texp_setfield (_, _, label, value) when list value ->
              add (field_key label) (sources value)
          | Texp_apply ({exp_desc= Texp_ident (path, _, _); _}, arguments) ->
              let target = resolve path in
              let arguments =
                List.filter_map
                  (function
                    | _, Arg value -> Some value
                    | _ -> None )
                  arguments
              in
              ( match (target, arguments) with
              | ( ( "Stdlib.List.iter" | "Stdlib.List.map"
                  | "Stdlib.List.filter_map" )
                , [callback; values] )
                when list values ->
                  add (symbol callback ^ ".<parameter@0>") (sources values)
              | _ -> () ) ;
              (* Call-result projection aliases are independent of the return shape. *)
              if target <> "" then add (call_result e) [target ^ ".<result>"]
          | _ -> () ) ;
          if list e then add (key e) (sources e) ) }
  in
  iterator.structure iterator structure ;
  (* A foreign operation receiving or producing a queue-bearing record may
     mutate it. Preserve unknown writers rather than closing that target set. *)
  let shapes = Hashtbl.create 8 in
  let type_key env typ =
    match Types.get_desc (expanded env typ) with
    | Types.Tconstr (path, _, _) -> resolve path
    | _ -> ""
  in
  let note_label env label =
    if callback_list env label.Data_types.lbl_arg
    then
      let key = type_key env label.lbl_res in
      if key <> ""
      then
        Hashtbl.replace
          shapes
          key
          ( field_key label
          :: Option.value ~default:[] (Hashtbl.find_opt shapes key) )
  in
  let labels =
    { Tast_iterator.default_iterator with
      expr=
        (fun self e ->
          ( match e.exp_desc with
          | Texp_field (_, _, label)
           |Texp_setfield (_, _, label, _) ->
              note_label e.exp_env label
          | Texp_record {fields; _} ->
              Array.iter (fun (label, _) -> note_label e.exp_env label) fields
          | _ -> () ) ;
          Tast_iterator.default_iterator.expr self e ) }
  in
  labels.structure labels structure ;
  let rec record_fields env typ =
    let typ = expanded env typ in
    match Types.get_desc typ with
    | Types.Tconstr (path, arguments, _) ->
        Option.value ~default:[] (Hashtbl.find_opt shapes (resolve path))
        @ List.concat_map (record_fields env) arguments
    | Types.Ttuple values ->
        List.concat_map (fun (_, typ) -> record_fields env typ) values
    | _ -> []
  in
  let escapes =
    { Tast_iterator.default_iterator with
      expr=
        (fun self e ->
          ( match e.exp_desc with
          | Texp_apply (fn, args) ->
              let target = symbol fn in
              let primitive =
                List.exists
                  (fun prefix -> String.starts_with ~prefix target)
                  ["Stdlib.List."; "Stdlib.Option."; "Stdlib.Hashtbl."]
              in
              if (not primitive) && not (List.mem target known)
              then
                List.iter
                  (fun key -> add key [""])
                  ( record_fields e.exp_env e.exp_type
                  @ List.concat_map
                      (function
                        | _, Arg value ->
                            record_fields value.exp_env value.exp_type
                        | _ -> [] )
                      args )
          | _ -> () ) ;
          Tast_iterator.default_iterator.expr self e ) }
  in
  escapes.structure escapes structure ;
  List.sort_uniq compare !edges
