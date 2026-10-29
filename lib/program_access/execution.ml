open Szaniec_model
open Typedtree

module Expressions = Hashtbl.Make (struct
  type t = expression

  let equal a b = a == b

  let hash = Hashtbl.hash
end)

module Modules = Hashtbl.Make (struct
  type t = module_expr

  let equal a b = a == b

  let hash = Hashtbl.hash
end)

let binding_id pattern =
  match pattern.pat_desc with
  | Tpat_var (id, _, _)
   |Tpat_alias ({pat_desc= Tpat_any; _}, id, _, _, _) ->
      Some id
  | _ -> None

(* An identifier open changes name lookup, not function construction. Do not
   unwrap structure/application opens: their initialization may execute code. *)
let rec binding_expression expression =
  match expression.exp_desc with
  | Texp_open ({open_expr= {mod_desc= Tmod_ident _; _}; _}, body) ->
      binding_expression body
  | _ -> expression

let observe
    ?(with_ordered = true)
    ~unit_canonical
    ~resolve
    ~site_of_loc
    (structure : structure) =
  let definitions = ref [] in
  let returned_functions = ref [] in
  let returned_constructors = ref [] in
  let value_origins = ref [] in
  let parameter_defaults = ref [] in
  let functor_instances = ref [] in
  let invocations = ref [] in
  let symbols = Hashtbl.create 32 in
  let records = Hashtbl.create 16 in
  let result_sources = Hashtbl.create 16 in
  let record_shapes = Hashtbl.create 16 in
  let module_packages = Modules.create 16 in
  let parameter_symbols = Hashtbl.create 16 in
  let functions = Expressions.create 32 in
  let bodies = Hashtbl.create 32 in
  let applications = Expressions.create 32 in
  let call_results = Expressions.create 32 in
  let expression_owners = Expressions.create 32 in
  let resumed = ref [] in
  let caller = ref (unit_canonical ^ ".<toplevel>") in
  let module_scope = ref unit_canonical in
  let loops = ref [] in
  let enclosing_loc = ref Location.none in
  let mapped_loc loc =
    if loc.Location.loc_start.pos_lnum > 0 then loc else !enclosing_loc
  in
  let position loc =
    let site = site_of_loc loc in
    Printf.sprintf "%d:%d" site.Observation.line site.col
  in
  let synthetic = ref 0 in
  let unique_position loc =
    let site = site_of_loc loc in
    if site.Observation.line > 0
    then position loc
    else (
      incr synthetic ;
      position loc ^ "#" ^ string_of_int !synthetic )
  in
  let anonymous e = !caller ^ ".<callback@" ^ unique_position e.exp_loc ^ ">" in
  let expanded env typ =
    try Ctype.expand_head (Envaux.env_of_only_summary env) typ with
    | _ -> typ
  in
  let rec callable_type env typ =
    match Types.get_desc (expanded env typ) with
    | Types.Tarrow _ -> true
    | Types.Tpoly (body, _) -> callable_type env body
    | Types.Tconstr (path, _, _) when resolve path = "Stdlib.Seq.t" -> true
    | _ -> false
  in
  let function_type e = callable_type e.exp_env e.exp_type in
  let unit_thunk e =
    match Types.get_desc (expanded e.exp_env e.exp_type) with
    | Types.Tarrow (_, argument, result, _) ->
        ( match Types.get_desc (expanded e.exp_env argument) with
          | Types.Tconstr (path, [], _) -> Path.same path Predef.path_unit
          | _ -> false )
        && not (callable_type e.exp_env result)
    | _ -> false
  in
  let type_path e =
    match Types.get_desc e.exp_type with
    | Types.Tconstr (path, _, _) -> Path.name path
    | _ -> ""
  in
  let type_iterator = Tast_iterator.default_iterator in
  let type_iterator =
    { type_iterator with
      expr=
        (fun self e ->
          ( match e.exp_desc with
          | Texp_field (record, _, label) ->
              let fields =
                Array.to_list label.Data_types.lbl_all
                |> List.filter (fun field ->
                    field.Data_types.lbl_mut = Asttypes.Immutable
                    && callable_type e.exp_env field.lbl_arg )
              in
              if fields <> []
              then Hashtbl.replace record_shapes (type_path record) ()
          | _ -> () ) ;
          Tast_iterator.default_iterator.expr self e ) }
  in
  type_iterator.structure type_iterator structure ;
  let rec resolved path =
    match path with
    | Path.Pident id when Hashtbl.mem symbols id -> Hashtbl.find symbols id
    | Path.Pdot (root, field) ->
        let base = resolved root in
        if base <> "" then base ^ "." ^ field else resolve path
    | _ -> resolve path
  in
  let call_result e =
    match Expressions.find_opt call_results e with
    | Some source -> source
    | None ->
        let source =
          unit_canonical ^ ".<call@" ^ unique_position e.exp_loc ^ ">.<result>"
        in
        Expressions.add call_results e source ;
        source
  in
  let result_source e =
    match e.exp_desc with
    | Texp_apply ({exp_desc= Texp_ident (path, _, _); _}, _) ->
        let target = resolved path in
        if target = "" then "" else call_result e
    | Texp_ident (Path.Pident id, _, _) ->
        Option.value ~default:"" (Hashtbl.find_opt result_sources id)
    | _ -> ""
  in
  let rec bind_result : type k. string -> k general_pattern -> unit =
   fun source pattern ->
    if source <> ""
    then
      match pattern.pat_desc with
      | Tpat_var (id, _, _) ->
          let target = resolved (Path.Pident id) in
          if target <> ""
          then value_origins := (target, source) :: !value_origins ;
          Hashtbl.replace result_sources id source ;
          if callable_type pattern.pat_env pattern.pat_type
          then Hashtbl.replace symbols id source
      | Tpat_alias (pattern, id, _, _, _) ->
          let target = resolved (Path.Pident id) in
          if target <> ""
          then value_origins := (target, source) :: !value_origins ;
          Hashtbl.replace result_sources id source ;
          bind_result source pattern
      | Tpat_tuple patterns ->
          List.iteri
            (fun index (_, pattern) ->
              bind_result
                (source ^ ".<tuple@" ^ string_of_int index ^ ">")
                pattern )
            patterns
      | Tpat_variant (name, Some pattern, _) ->
          bind_result (source ^ ".<variant@" ^ name ^ ">") pattern
      | Tpat_construct (_, description, patterns, _) ->
          List.iteri
            (fun index pattern ->
              bind_result
                ( source
                ^ ".<constructor@"
                ^ description.Data_types.cstr_name
                ^ ":"
                ^ string_of_int index
                ^ ">" )
                pattern )
            patterns
      | Tpat_value pattern ->
          bind_result source (pattern :> value general_pattern)
      | _ -> ()
  in
  let rec module_body m =
    match m.mod_desc with
    | Tmod_constraint (m, _, _, _) -> module_body m
    | _ -> m
  in
  let module_path m =
    let m = module_body m in
    match m.mod_desc with
    | Tmod_ident (path, _) -> resolved path
    | Tmod_structure _ -> (
      match Modules.find_opt module_packages m with
      | Some path -> path
      | None ->
          let path = !caller ^ ".<module@" ^ unique_position m.mod_loc ^ ">" in
          Modules.add module_packages m path ;
          path )
    | _ -> ""
  in
  let rec function_symbol e =
    match e.exp_desc with
    | Texp_function _
     |Texp_apply _
      when function_type e -> (
      match Expressions.find_opt functions e with
      | Some symbol -> symbol
      | None ->
          let symbol = anonymous e in
          Expressions.add functions e symbol ;
          symbol )
    | Texp_ifthenelse _ when unit_thunk e -> (
      match Expressions.find_opt functions e with
      | Some symbol -> symbol
      | None ->
          let symbol = anonymous e in
          Expressions.add functions e symbol ;
          symbol )
    | Texp_ident (path, _, _) when function_type e -> resolved path
    | Texp_let (_, bindings, body) when function_type e ->
        List.iter register bindings ;
        function_symbol body
    | Texp_sequence (_, body)
     |Texp_open (_, body)
      when function_type e ->
        function_symbol body
    | Texp_field (record, _, label)
      when function_type e && label.Data_types.lbl_mut = Asttypes.Immutable -> (
      match record.exp_desc with
      | Texp_ident (Path.Pident id, _, _) -> (
        match Hashtbl.find_opt records (id, label.lbl_name) with
        | Some target -> target
        | None -> (
            let base = Option.value ~default:"" (Hashtbl.find_opt symbols id) in
            if Hashtbl.mem parameter_symbols base
            then base ^ "." ^ label.lbl_name
            else
              match Hashtbl.find_opt result_sources id with
              | Some source -> source ^ ".<field@" ^ label.lbl_name ^ ">"
              | None -> "" ) )
      | Texp_record {fields; _} ->
          Array.to_list fields
          |> List.find_map (fun (field, value) ->
              if field.Data_types.lbl_name = label.lbl_name
              then
                match value with
                | Overridden (_, value) -> Some (function_symbol value)
                | _ -> None
              else None )
          |> Option.value ~default:""
      | _ -> "" )
    | _ -> ""
  and register vb =
    bind_result (result_source vb.vb_expr) vb.vb_pat ;
    match binding_id vb.vb_pat with
    | Some id -> (
      match (binding_expression vb.vb_expr).exp_desc with
      | Texp_function _ when not (Hashtbl.mem symbols id) ->
          let symbol =
            match resolve (Path.Pident id) with
            | "" ->
                !caller
                ^ "."
                ^ Ident.name id
                ^ "@"
                ^ string_of_int (site_of_loc vb.vb_loc).Observation.line
            | symbol -> symbol
          in
          Hashtbl.replace symbols id symbol ;
          Expressions.replace functions (binding_expression vb.vb_expr) symbol
      | Texp_ident (path, _, _) when function_type vb.vb_expr ->
          Hashtbl.replace symbols id (resolved path)
      | Texp_apply _
       |Texp_field _
       |Texp_ifthenelse _
        when function_type vb.vb_expr ->
          Hashtbl.replace symbols id (function_symbol vb.vb_expr)
      | Texp_record {fields; extended_expression; _} ->
          ( match extended_expression with
          | Some {exp_desc= Texp_ident (Path.Pident base, _, _); _} ->
              Hashtbl.to_seq records
              |> List.of_seq
              |> List.iter (fun ((record, field), target) ->
                  if Ident.same record base
                  then Hashtbl.replace records (id, field) target )
          | _ -> () ) ;
          Array.iter
            (fun (label, value) ->
              if label.Data_types.lbl_mut = Asttypes.Immutable
              then
                match value with
                | Overridden (_, value) when function_type value ->
                    Hashtbl.replace
                      records
                      (id, label.lbl_name)
                      (function_symbol value)
                | Overridden _
                 |Kept _ ->
                    () )
            fields
      | Texp_ident (Path.Pident base, _, _) ->
          Hashtbl.to_seq records
          |> List.of_seq
          |> List.iter (fun ((record, field), target) ->
              if Ident.same record base
              then Hashtbl.replace records (id, field) target )
      | _ -> () )
    | _ -> ()
  in
  let rec terminal e =
    match e.exp_desc with
    | Texp_let (_, _, body)
     |Texp_sequence (_, body)
     |Texp_open (_, body) ->
        terminal body
    | Texp_function _
     |Texp_apply _
      when function_type e ->
        function_symbol e
    | Texp_ident (path, _, _) when function_type e ->
        let target = resolved path in
        if Canonical.parameter_symbol target = None then target else ""
    | _ -> ""
  in
  let rec returned_members source e =
    match e.exp_desc with
    | Texp_apply ({exp_desc= Texp_ident (path, _, _); _}, _)
      when List.mem (resolved path) ["Stdlib.raise"; "Stdlib.raise_notrace"] ->
        ()
    | Texp_let (_, _, body)
     |Texp_sequence (_, body)
     |Texp_open (_, body) ->
        returned_members source body
    | Texp_try (body, cases, _) ->
        returned_members source body ;
        List.iter (fun case -> returned_members source case.c_rhs) cases
    | Texp_ifthenelse (_, yes, no) ->
        returned_members source yes ;
        Option.iter (returned_members source) no
    | Texp_match (_, computation_cases, value_cases, _) ->
        List.iter
          (fun case -> returned_members source case.c_rhs)
          computation_cases ;
        List.iter (fun case -> returned_members source case.c_rhs) value_cases
    | Texp_variant (_, None)
     |Texp_constant _ ->
        ()
    | Texp_variant (name, Some value) ->
        returned_members (source ^ ".<variant@" ^ name ^ ">") value
    | Texp_construct (_, description, values) ->
        returned_constructors :=
          (source, description.Data_types.cstr_name) :: !returned_constructors ;
        List.iteri
          (fun index value ->
            returned_members
              ( source
              ^ ".<constructor@"
              ^ description.Data_types.cstr_name
              ^ ":"
              ^ string_of_int index
              ^ ">" )
              value )
          values
    | Texp_tuple values ->
        List.iteri
          (fun index (_, value) ->
            returned_members
              (source ^ ".<tuple@" ^ string_of_int index ^ ">")
              value )
          values
    | Texp_record {fields; _} ->
        Array.iter
          (fun (label, value) ->
            if
              label.Data_types.lbl_mut = Asttypes.Immutable
              && callable_type e.exp_env label.lbl_arg
            then
              match value with
              | Overridden (_, value) ->
                  returned_functions :=
                    ( source ^ ".<field@" ^ label.lbl_name ^ ">"
                    , function_symbol value )
                    :: !returned_functions
              | Kept _ ->
                  returned_functions :=
                    (source ^ ".<field@" ^ label.lbl_name ^ ">", "")
                    :: !returned_functions )
          fields
    | Texp_ident (path, _, _)
      when Canonical.parameter_symbol (resolved path) <> None ->
        returned_functions := (source, resolved path) :: !returned_functions
    | _ when function_type e ->
        returned_functions := (source, function_symbol e) :: !returned_functions
    | _ when result_source e <> "" ->
        returned_functions := (source, result_source e) :: !returned_functions
    | _ ->
        returned_functions := (source ^ ".<unknown>", "") :: !returned_functions
  in
  let within symbol regions f =
    let old_caller, old_loops = (!caller, !loops) in
    caller := symbol ;
    loops := regions ;
    Fun.protect f ~finally:(fun () ->
        caller := old_caller ;
        loops := old_loops )
  in
  let define ?(arity = 0) symbol loc is_initializer =
    definitions :=
      { Observation.symbol
      ; definition_site= site_of_loc (mapped_loc loc)
      ; definition_arity= arity
      ; definition_initializer= is_initializer }
      :: !definitions
  in
  let default = Tast_iterator.default_iterator in
  let iterator =
    { default with
      module_expr=
        (fun self m ->
          match Modules.find_opt module_packages m with
          | None -> default.module_expr self m
          | Some scope ->
              let previous = !module_scope in
              module_scope := scope ;
              Fun.protect
                (fun () ->
                  within (scope ^ ".<toplevel>") [] (fun () ->
                      default.module_expr self m ) )
                ~finally:(fun () -> module_scope := previous) )
    ; module_binding=
        (fun self mb ->
          let previous = !module_scope in
          module_scope :=
            previous ^ "." ^ Option.value ~default:"<module>" mb.mb_name.txt ;
          let rec body m =
            match m.mod_desc with
            | Tmod_constraint (m, _, _, _) -> body m
            | _ -> m
          in
          ( match (body mb.mb_expr).mod_desc with
          | Tmod_apply (f, arg, _) -> (
            match ((body f).mod_desc, (body arg).mod_desc) with
            | Tmod_ident (f, _), Tmod_ident (arg, _) ->
                functor_instances :=
                  ( !module_scope
                  , resolved f
                  , resolved arg
                  , site_of_loc mb.mb_loc )
                  :: !functor_instances
            | _ -> () )
          | _ -> () ) ;
          Fun.protect
            (fun () ->
              within (!module_scope ^ ".<toplevel>") [] (fun () ->
                  define !caller mb.mb_loc true ;
                  default.module_binding self mb ) )
            ~finally:(fun () -> module_scope := previous) )
    ; structure_item=
        (fun self item ->
          ( match item.str_desc with
          | Tstr_value (_, bindings) ->
              List.iter
                (fun vb ->
                  let expression = binding_expression vb.vb_expr in
                  match (binding_id vb.vb_pat, expression.exp_desc) with
                  | Some id, Texp_function _ ->
                      let symbol = !module_scope ^ "." ^ Ident.name id in
                      Hashtbl.replace symbols id symbol ;
                      Expressions.replace functions expression symbol
                  | Some id, Texp_apply _ when function_type vb.vb_expr ->
                      let symbol = !module_scope ^ "." ^ Ident.name id in
                      Hashtbl.replace symbols id symbol ;
                      Expressions.replace functions vb.vb_expr symbol
                  | _ -> () )
                bindings
          | _ -> () ) ;
          default.structure_item self item ;
          match item.str_desc with
          | Tstr_open opened -> (
            match (module_body opened.open_expr).mod_desc with
            | Tmod_structure structure ->
                (* Opened values have fresh compiler identifiers. Preserve the
                   target of a callable alias across that renaming, just as for
                   its original structure binding. *)
                let targets =
                  List.filter_map
                    (function
                      | Types.Sig_value (id, description, _)
                        when not
                               (Types.Uid.equal
                                  description.Types.val_uid
                                  Types.Uid.internal_not_actually_unique ) ->
                          Option.map
                            (fun target -> (description.Types.val_uid, target))
                            (Hashtbl.find_opt symbols id)
                      | _ -> None )
                    structure.str_type
                in
                List.iter
                  (function
                    | Types.Sig_value (id, description, _)
                      when callable_type
                             opened.open_env
                             description.Types.val_type ->
                        let candidates =
                          List.filter_map
                            (fun (uid, target) ->
                              if Types.Uid.equal uid description.Types.val_uid
                              then Some target
                              else None )
                            targets
                          |> List.sort_uniq String.compare
                        in
                        Hashtbl.replace
                          symbols
                          id
                          ( match candidates with
                          | [target] -> target
                          | _ -> "" )
                    | _ -> () )
                  opened.open_bound_items
            | _ -> () )
          | _ -> () )
    ; value_binding=
        (fun self vb ->
          register vb ;
          match (binding_expression vb.vb_expr).exp_desc with
          | Texp_function _ -> default.value_binding self vb
          | _ ->
              let symbol =
                !caller ^ ".<init@" ^ unique_position vb.vb_loc ^ ">"
              in
              if !caller = !module_scope ^ ".<toplevel>"
              then (
                define symbol vb.vb_loc true ;
                Hashtbl.replace bodies symbol vb.vb_expr ;
                within symbol [] (fun () -> default.value_binding self vb) )
              else default.value_binding self vb )
    ; expr=
        (fun self e ->
          Expressions.replace expression_owners e !caller ;
          let previous = !enclosing_loc in
          enclosing_loc := mapped_loc e.exp_loc ;
          Fun.protect
            (fun () ->
              match e.exp_desc with
              | Texp_function (params, body) -> (
                  let symbol = function_symbol e in
                  let bind position pattern =
                    match pattern.pat_desc with
                    | Tpat_var (id, _, _)
                     |Tpat_alias (_, id, _, _, _) ->
                        let key =
                          symbol ^ ".<parameter@" ^ string_of_int position ^ ">"
                        in
                        Hashtbl.replace parameter_symbols key (symbol, position) ;
                        Hashtbl.replace symbols id key
                    | _ -> ()
                  in
                  List.iteri
                    (fun position parameter ->
                      let key =
                        symbol ^ ".<parameter@" ^ string_of_int position ^ ">"
                      in
                      Hashtbl.replace parameter_symbols key (symbol, position) ;
                      Hashtbl.replace symbols parameter.fp_param key ;
                      match parameter.fp_kind with
                      | Tparam_optional_default (pattern, value) ->
                          bind position pattern ;
                          if function_type value
                          then
                            parameter_defaults :=
                              (key, function_symbol value)
                              :: !parameter_defaults
                      | Tparam_pat pattern -> bind position pattern )
                    params ;
                  ( match body with
                  | Tfunction_cases {cases; param; _} ->
                      let key =
                        symbol
                        ^ ".<parameter@"
                        ^ string_of_int (List.length params)
                        ^ ">"
                      in
                      Hashtbl.replace
                        parameter_symbols
                        key
                        (symbol, List.length params) ;
                      Hashtbl.replace symbols param key ;
                      List.iter
                        (fun case -> bind (List.length params) case.c_lhs)
                        cases
                  | _ -> () ) ;
                  let arity =
                    List.length params
                    +
                    match body with
                    | Tfunction_cases _ -> 1
                    | Tfunction_body _ -> 0
                  in
                  define ~arity symbol e.exp_loc false ;
                  Hashtbl.replace bodies symbol e ;
                  within symbol [] (fun () -> default.expr self e) ;
                  ( match body with
                  | Tfunction_body body ->
                      returned_members (symbol ^ ".<result>") body
                  | _ -> () ) ;
                  match body with
                  | Tfunction_body e ->
                      let target = terminal e in
                      if target <> ""
                      then
                        returned_functions :=
                          (symbol, target) :: !returned_functions
                  | Tfunction_cases {cases= [{c_guard= None; c_rhs; _}]; _} ->
                      let target = terminal c_rhs in
                      if target <> ""
                      then
                        returned_functions :=
                          (symbol, target) :: !returned_functions
                  | _ -> () )
              | Texp_lazy body ->
                  let symbol = !caller ^ ".<lazy@" ^ position e.exp_loc ^ ">" in
                  define symbol e.exp_loc false ;
                  Hashtbl.replace bodies symbol body ;
                  within symbol [] (fun () -> self.expr self body)
              | Texp_let (_, bindings, _) ->
                  List.iter register bindings ;
                  default.expr self e
              | Texp_match (scrutinee, computation_cases, value_cases, _) ->
                  let source = result_source scrutinee in
                  List.iter
                    (fun case -> bind_result source case.c_lhs)
                    computation_cases ;
                  List.iter
                    (fun case -> bind_result source case.c_lhs)
                    value_cases ;
                  default.expr self e
              | Texp_letmodule (Some id, _, _, m, _) ->
                  ( match (module_body m).mod_desc with
                  | Tmod_unpack (value, _) -> (
                    match value.exp_desc with
                    | Texp_ident (path, _, _) ->
                        let target = resolved path in
                        if target <> "" then Hashtbl.replace symbols id target
                    | _ -> () )
                  | _ ->
                      let target = module_path m in
                      if target <> "" then Hashtbl.replace symbols id target ) ;
                  default.expr self e
              | Texp_while (condition, body) ->
                  let region =
                    { Observation.loop_kind= "while"
                    ; loop_site= site_of_loc e.exp_loc }
                  in
                  within !caller (!loops @ [region]) (fun () ->
                      self.expr self condition ;
                      self.expr self body )
              | Texp_for (_, _, start, stop, _, body) ->
                  self.expr self start ;
                  self.expr self stop ;
                  let region =
                    { Observation.loop_kind= "for"
                    ; loop_site= site_of_loc e.exp_loc }
                  in
                  within !caller (!loops @ [region]) (fun () ->
                      self.expr self body )
              | Texp_ifthenelse (_, yes, Some no) when unit_thunk e ->
                  let symbol = function_symbol e in
                  define ~arity:1 symbol e.exp_loc false ;
                  default.expr self e ;
                  let branch label value =
                    let target = function_symbol value in
                    let call =
                      { Observation.execution_caller= symbol
                      ; execution_callee= target
                      ; execution_resolution=
                          ( if target = ""
                            then Observation.Unresolved_dynamic
                            else Observation.Resolved )
                      ; execution_site= site_of_loc value.exp_loc
                      ; execution_loops= []
                      ; execution_partial= false
                      ; execution_resumed= false
                      ; execution_supplied= 1
                      ; execution_defaults= []
                      ; execution_values= []
                      ; execution_result= ""
                      ; execution_args= [] }
                    in
                    invocations := call :: !invocations ;
                    (label, [Observation.Invoke call])
                  in
                  resumed :=
                    ( symbol
                    , [Observation.Choose [branch "then" yes; branch "else" no]]
                    )
                    :: !resumed
              | Texp_apply (fn, args) ->
                  let original_fn = fn in
                  let rec collapse fn args =
                    match fn.exp_desc with
                    | Texp_apply (inner, more) ->
                        collapse inner (Application_args.merge more args)
                    | _ -> (fn, args)
                  in
                  let fn, args = collapse fn args in
                  let fn, args =
                    match (fn.exp_desc, args) with
                    | Texp_ident (path, _, _), [(_, Arg first); (_, Arg second)]
                      when List.mem (resolved path) ["Stdlib.@@"; "Stdlib.|>"]
                      ->
                        let apply, argument =
                          if resolved path = "Stdlib.@@"
                          then (first, second)
                          else (second, first)
                        in
                        collapse apply [(Asttypes.Nolabel, Arg argument)]
                    | _ -> (fn, args)
                  in
                  let target, resolution =
                    match fn.exp_desc with
                    | Texp_ident (path, _, _) -> (
                      match resolved path with
                      | "" -> ("", Observation.Unresolved_local)
                      | symbol ->
                          ( symbol
                          , if Canonical.parameter_symbol symbol <> None
                            then Observation.Unresolved_local
                            else Observation.Resolved ) )
                    | Texp_field _ ->
                        let target = function_symbol fn in
                        ( target
                        , if target = ""
                          then Observation.Unresolved_field
                          else Observation.Resolved )
                    | Texp_function _ ->
                        (function_symbol fn, Observation.Resolved)
                    | _ when function_type fn ->
                        let target = function_symbol fn in
                        ( target
                        , if target = ""
                          then Observation.Unresolved_dynamic
                          else if Canonical.parameter_symbol target <> None
                          then Observation.Unresolved_local
                          else Observation.Resolved )
                    | _ -> ("", Observation.Unresolved_dynamic)
                  in
                  let rec embedded_functions e =
                    if function_type e
                    then [(function_symbol e, "")]
                    else
                      match e.exp_desc with
                      | Texp_construct (_, _, values)
                       |Texp_array (_, values) ->
                          List.concat_map embedded_functions values
                      | Texp_tuple values ->
                          List.concat_map
                            (fun (_, e) -> embedded_functions e)
                            values
                      | Texp_record {fields; _} ->
                          Array.to_list fields
                          |> List.concat_map (function
                            | label, Overridden (_, e)
                              when label.Data_types.lbl_mut = Asttypes.Immutable
                              ->
                                List.map
                                  (fun (target, field) ->
                                    ( target
                                    , if field = ""
                                      then label.lbl_name
                                      else label.lbl_name ^ "." ^ field ) )
                                  (embedded_functions e)
                            | _ -> [] )
                      | Texp_pack m -> (
                          let base = module_path m in
                          if base = ""
                          then []
                          else
                            match (module_body m).mod_type with
                            | Types.Mty_signature items ->
                                List.filter_map
                                  (function
                                    | Types.Sig_value (id, value, _)
                                      when callable_type
                                             e.exp_env
                                             value.Types.val_type ->
                                        Some
                                          ( base ^ "." ^ Ident.name id
                                          , Ident.name id )
                                    | _ -> None )
                                  items
                            | _ -> [] )
                      | Texp_ident (Path.Pident id, _, _) ->
                          let fields =
                            Hashtbl.to_seq records
                            |> List.of_seq
                            |> List.filter_map (fun ((record, field), target) ->
                                if Ident.same record id
                                then Some (target, field)
                                else None )
                          in
                          if fields <> []
                          then fields
                          else
                            let key =
                              Option.value
                                ~default:""
                                (Hashtbl.find_opt symbols id)
                            in
                            let callable_record =
                              Hashtbl.mem record_shapes (type_path e)
                            in
                            if
                              callable_record
                              && Hashtbl.mem parameter_symbols key
                            then [(key, "")]
                            else []
                      | _ -> []
                  in
                  let arguments =
                    List.mapi
                      (fun position (label, arg) ->
                        match arg with
                        | Omitted _ -> []
                        | Arg e ->
                            let label =
                              match label with
                              | Asttypes.Nolabel -> ""
                              | Asttypes.Labelled s
                               |Asttypes.Optional s ->
                                  s
                            in
                            List.map
                              (fun (target, field) ->
                                { Observation.position
                                ; label
                                ; target
                                ; field
                                ; embedded= not (function_type e) } )
                              (embedded_functions e) )
                      args
                    |> List.concat
                  in
                  let partial = function_type e in
                  let invocation =
                    { Observation.execution_caller= !caller
                    ; execution_callee= target
                    ; execution_resolution= resolution
                    ; execution_site=
                        site_of_loc
                          (let loc =
                             match original_fn.exp_desc with
                             | Texp_ident (_, loc, _) -> loc.loc
                             | _ -> original_fn.exp_loc
                           in
                           if loc.loc_start.pos_lnum > 0
                           then loc
                           else if original_fn.exp_loc.loc_start.pos_lnum > 0
                           then original_fn.exp_loc
                           else mapped_loc e.exp_loc )
                    ; execution_loops= !loops
                    ; execution_partial= partial
                    ; execution_resumed= false
                    ; execution_supplied=
                        List.length
                          (List.filter
                             (function
                               | _, Arg _ -> true
                               | _ -> false )
                             args )
                    ; execution_defaults=
                        List.mapi
                          (fun position (label, arg) ->
                            match arg with
                            | Omitted _ -> Some position
                            | Arg {exp_desc= Texp_construct (_, desc, []); _}
                              when desc.Data_types.cstr_name = "None"
                                   &&
                                   match label with
                                   | Asttypes.Optional _ -> true
                                   | _ -> false ->
                                Some position
                            | _ -> None )
                          args
                        |> List.filter_map Fun.id
                    ; execution_result= call_result e
                    ; execution_values=
                        List.mapi
                          (fun position (_, arg) ->
                            match arg with
                            | Arg {exp_desc= Texp_ident (path, loc, _); _} ->
                                Some
                                  (position, resolved path, site_of_loc loc.loc)
                            | _ -> None )
                          args
                        |> List.filter_map Fun.id
                    ; execution_args= arguments }
                  in
                  invocations := invocation :: !invocations ;
                  Expressions.replace applications e invocation ;
                  if partial
                  then begin
                    let symbol = function_symbol e in
                    define symbol e.exp_loc false ;
                    let call =
                      { invocation with
                        execution_caller= symbol
                      ; execution_loops= []
                      ; execution_resumed= true
                      ; execution_partial= false }
                    in
                    invocations := call :: !invocations ;
                    resumed := (symbol, [Observation.Invoke call]) :: !resumed
                  end ;
                  default.expr self e
              | _ -> default.expr self e )
            ~finally:(fun () -> enclosing_loc := previous) ) }
  in
  define
    !caller
    ( match structure.str_items with
    | item :: _ -> item.str_loc
    | [] -> Location.none )
    true ;
  iterator.structure iterator structure ;
  let ambiguous_parameters = Hashtbl.create 8 in
  let parameter_target symbol =
    match Hashtbl.find_opt parameter_symbols symbol with
    | None -> symbol
    | Some (callee, position) -> (
        let calls =
          List.filter
            (fun (call : Observation.execution_call) ->
              call.execution_callee = callee && not call.execution_partial )
            !invocations
        in
        let targets =
          List.map
            (fun call ->
              List.find_opt
                (fun (arg : Observation.execution_arg) ->
                  arg.position = position && arg.field = "" )
                call.Observation.execution_args
              |> Option.fold ~none:"" ~some:(fun arg -> arg.Observation.target) )
            calls
          |> List.sort_uniq compare
        in
        match targets with
        | [target]
          when target <> "" && not (Hashtbl.mem parameter_symbols target) ->
            target
        | _ -> symbol )
  in
  let resolve_call (call : Observation.execution_call) =
    let target = parameter_target call.execution_callee in
    { call with
      execution_callee= target
    ; execution_resolution=
        ( if Hashtbl.mem parameter_symbols call.execution_callee
          then
            if Hashtbl.mem parameter_symbols target || target = ""
            then
              if Hashtbl.mem ambiguous_parameters call.execution_callee
              then Observation.Unresolved_ambiguous
              else Observation.Unresolved_local
            else Observation.Resolved
          else call.execution_resolution )
    ; execution_args=
        List.map
          (fun (a : Observation.execution_arg) ->
            {a with target= parameter_target a.target} )
          call.execution_args }
  in
  invocations := List.map resolve_call !invocations ;
  Expressions.to_seq applications
  |> List.of_seq
  |> List.iter (fun (location, call) ->
      Expressions.replace applications location (resolve_call call) ) ;
  resumed :=
    List.map
      (fun (symbol, steps) ->
        ( symbol
        , List.map
            (function
              | Observation.Invoke call ->
                  Observation.Invoke (resolve_call call)
              | step -> step )
            steps ) )
      !resumed ;
  let execution =
    { Observation.definitions= List.sort_uniq compare !definitions
    ; returned_functions= List.sort_uniq compare !returned_functions
    ; returned_constructors= List.sort_uniq compare !returned_constructors
    ; value_origins= List.sort_uniq compare !value_origins
    ; parameter_defaults= List.sort_uniq compare !parameter_defaults
    ; functor_instances= List.sort_uniq compare !functor_instances
    ; invocations= List.sort_uniq compare !invocations
    ; ordered=
        ( if not with_ordered
          then []
          else
            Hashtbl.fold
              (fun symbol body acc ->
                ( symbol
                , Ordered_execution.observe
                    ~site_of_loc
                    ~invocation:(fun e -> Expressions.find_opt applications e)
                    body )
                :: acc )
              bodies
              !resumed
            |> List.sort compare ) }
  in
  ( execution
  , (fun expression -> Expressions.find_opt applications expression)
  , fun expression -> Expressions.find_opt expression_owners expression )
