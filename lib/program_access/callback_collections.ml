open Typedtree

(* Conservative element provenance for locally observed callback lists. Empty
   writes clear a queue; all other writes contribute possible targets. Unknown
   producers remain explicit empty-string targets, never successful evidence. *)
let observe
    ~unit_canonical
    ~known
    ~resolve
    ~symbol
    ~result_source
    ~call_result
    ~site
    structure =
  let edges = ref [] in
  let locals = Hashtbl.create 32 in
  let add key values =
    List.iter (fun value -> edges := (key, value) :: !edges) values
  in
  let expanded env typ =
    Ctype.expand_head (Envaux.env_of_only_summary env) typ
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
  let type_name path =
    match resolve path with
    | "" -> unit_canonical ^ "." ^ Path.name path
    | name -> name
  in
  let field_key env label =
    let identity =
      match Types.get_desc (expanded env label.Data_types.lbl_res) with
      | Types.Tconstr (path, _, _) -> type_name path ^ "/" ^ label.lbl_name
      | _ -> Format.asprintf "%a" Types.Uid.print label.lbl_uid
    in
    "<callback-store@" ^ identity ^ ">"
  in
  let element source = source ^ ".<elements>" in
  let never_returns e =
    match e.exp_desc with
    | Texp_apply ({exp_desc= Texp_ident (path, _, _); _}, _) ->
        List.mem
          (resolve path)
          [ "Stdlib.raise"
          ; "Stdlib.raise_notrace"
          ; "Stdlib.failwith"
          ; "Stdlib.invalid_arg" ]
    | _ -> false
  in
  let key e =
    let at = site e.exp_loc in
    Printf.sprintf
      "<callback-list@%s:%d:%d>"
      at.Szaniec_model.Observation.site_path
      at.line
      at.col
  in
  let rec sources e =
    if never_returns e
    then []
    else
      match e.exp_desc with
      | Texp_construct (_, description, [])
        when description.Data_types.cstr_name = "[]" ->
          []
      | Texp_construct (_, description, [head; tail])
        when description.Data_types.cstr_name = "::" ->
          symbol head :: sources tail
      | Texp_field (_, _, label) when list e -> [field_key e.exp_env label]
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
    if never_returns e
    then ()
    else if list e
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
      | _ ->
          let base = result_source e in
          let rec forward source projection typ =
            match Types.get_desc (expanded e.exp_env typ) with
            | Types.Ttuple values ->
                List.iteri
                  (fun i (_, typ) ->
                    let suffix = ".<tuple@" ^ string_of_int i ^ ">" in
                    forward (source ^ suffix) (projection ^ suffix) typ )
                  values
            | _ when callback_list e.exp_env typ ->
                add
                  (element source)
                  [(if base = "" then "" else element (base ^ projection))]
            | _ -> ()
          in
          forward source "" e.exp_type
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
                        add (field_key e.exp_env label) (sources value)
                    | Kept _ -> () )
                fields
          | Texp_setfield (_, _, label, value) when list value ->
              add (field_key e.exp_env label) (sources value)
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
    | Types.Tconstr (path, _, _) -> type_name path
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
          ( field_key env label
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
  let rec record_fields visiting env typ =
    let typ = expanded env typ in
    let full_env = Envaux.env_of_only_summary env in
    if
      List.exists
        (fun previous -> Ctype.is_equal full_env false [typ] [previous])
        visiting
    then []
    else begin
      if List.length visiting >= 32
      then failwith "Callback-store type traversal exceeds supported depth" ;
      let visiting = typ :: visiting in
      match Types.get_desc typ with
      | Types.Tconstr (path, arguments, _) ->
          let key = type_name path in
          let nested =
            let declaration = Env.find_type path full_env in
            let payload typ =
              Ctype.apply full_env declaration.type_params typ arguments
              |> record_fields visiting env
            in
            let fields fields =
              List.concat_map (fun field -> payload field.Types.ld_type) fields
            in
            match declaration.Types.type_kind with
            | Types.Type_record (fields, _) ->
                List.concat_map
                  (fun field ->
                    let typ =
                      Ctype.apply
                        full_env
                        declaration.type_params
                        field.Types.ld_type
                        arguments
                    in
                    ( if callback_list env typ
                      then
                        [ "<callback-store@"
                          ^ key
                          ^ "/"
                          ^ Ident.name field.ld_id
                          ^ ">" ]
                      else [] )
                    @ record_fields visiting env typ )
                  fields
            | Types.Type_variant (constructors, _) ->
                List.concat_map
                  (fun constructor ->
                    match constructor.Types.cd_args with
                    | Types.Cstr_tuple values -> List.concat_map payload values
                    | Types.Cstr_record values -> fields values )
                  constructors
            | _ -> []
          in
          Option.value ~default:[] (Hashtbl.find_opt shapes key)
          @ nested
          @ List.concat_map (record_fields visiting env) arguments
      | Types.Ttuple values ->
          List.concat_map
            (fun (_, typ) -> record_fields visiting env typ)
            values
      | Types.Tvariant row ->
          Types.row_fields row
          |> List.concat_map (fun (_, field) ->
              match Types.row_field_repr field with
              | Types.Rpresent (Some payload) ->
                  record_fields visiting env payload
              | Types.Reither (_, payloads, _) ->
                  List.concat_map (record_fields visiting env) payloads
              | _ -> [] )
      | _ -> []
    end
  in
  Opaque_transfers.observe
    ~known
    ~resolve
    ~symbol
    ~result_seed:(fun owner ->
      add (owner ^ ".<generic-result>") ["<closed-result>"] )
    ~result_dependency:(fun owner target ->
      add (owner ^ ".<generic-result>") [target ^ ".<opaque-result>"] )
    ~emit:(fun ~target ~result e ->
      let fields = record_fields [] e.exp_env e.exp_type in
      List.iter
        (fun key ->
          add key [(if result then target ^ ".<opaque-result>" else "")] )
        fields )
    structure ;
  List.sort_uniq compare !edges
