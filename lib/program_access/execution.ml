open Szaniec_model
open Typedtree

let observe ~unit_canonical ~resolve ~site_of_loc (structure : structure) =
  let definitions = ref [] in
  let invocations = ref [] in
  let symbols = Hashtbl.create 32 in
  let records = Hashtbl.create 16 in
  let parameter_symbols = Hashtbl.create 16 in
  let functions = Hashtbl.create 32 in
  let bodies = Hashtbl.create 32 in
  let applications = Hashtbl.create 32 in
  let resumed = ref [] in
  let caller = ref (unit_canonical ^ ".<toplevel>") in
  let module_scope = ref unit_canonical in
  let loops = ref [] in
  let position loc =
    let site = site_of_loc loc in
    Printf.sprintf "%d:%d" site.Observation.line site.col
  in
  let anonymous e = !caller ^ ".<callback@" ^ position e.exp_loc ^ ">" in
  let function_type e =
    match Types.get_desc e.exp_type with
    | Types.Tarrow _ -> true
    | _ -> false
  in
  let resolved path =
    match path with
    | Path.Pident id when Hashtbl.mem symbols id -> Hashtbl.find symbols id
    | _ -> resolve path
  in
  let rec function_symbol e =
    match e.exp_desc with
    | Texp_function _
     |Texp_apply _
      when function_type e -> (
      match Hashtbl.find_opt functions e.exp_loc with
      | Some symbol -> symbol
      | None ->
          let symbol = anonymous e in
          Hashtbl.add functions e.exp_loc symbol ;
          symbol )
    | Texp_ident (path, _, _) when function_type e -> resolved path
    | Texp_field (record, _, label)
      when function_type e && label.Data_types.lbl_mut = Asttypes.Immutable -> (
      match record.exp_desc with
      | Texp_ident (Path.Pident id, _, _) ->
          Option.value
            ~default:""
            (Hashtbl.find_opt records (id, label.lbl_name))
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
  in
  let register vb =
    match vb.vb_pat.pat_desc with
    | Tpat_var (id, _, _) -> (
      match vb.vb_expr.exp_desc with
      | Texp_function _ when not (Hashtbl.mem symbols id) ->
          let symbol =
            match resolve (Path.Pident id) with
            | "" -> !caller ^ "." ^ Ident.name id ^ "@" ^ position vb.vb_loc
            | symbol -> symbol
          in
          Hashtbl.replace symbols id symbol ;
          Hashtbl.replace functions vb.vb_expr.exp_loc symbol
      | Texp_ident (path, _, _) when function_type vb.vb_expr ->
          Hashtbl.replace symbols id (resolved path)
      | Texp_apply _
       |Texp_field _
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
      ; definition_site= site_of_loc loc
      ; definition_arity= arity
      ; definition_initializer= is_initializer }
      :: !definitions
  in
  let default = Tast_iterator.default_iterator in
  let iterator =
    { default with
      module_binding=
        (fun self mb ->
          let previous = !module_scope in
          module_scope :=
            previous ^ "." ^ Option.value ~default:"<module>" mb.mb_name.txt ;
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
                  match (vb.vb_pat.pat_desc, vb.vb_expr.exp_desc) with
                  | Tpat_var (id, _, _), Texp_function _ ->
                      let symbol = !module_scope ^ "." ^ Ident.name id in
                      Hashtbl.replace symbols id symbol ;
                      Hashtbl.replace functions vb.vb_expr.exp_loc symbol
                  | _ -> () )
                bindings
          | _ -> () ) ;
          default.structure_item self item )
    ; value_binding=
        (fun self vb ->
          register vb ;
          match vb.vb_expr.exp_desc with
          | Texp_function _ -> default.value_binding self vb
          | _ ->
              let symbol = !caller ^ ".<init@" ^ position vb.vb_loc ^ ">" in
              if !caller = !module_scope ^ ".<toplevel>"
              then (
                define symbol vb.vb_loc true ;
                Hashtbl.replace bodies symbol vb.vb_expr ;
                within symbol [] (fun () -> default.value_binding self vb) )
              else default.value_binding self vb )
    ; expr=
        (fun self e ->
          match e.exp_desc with
          | Texp_function (params, body) ->
              let symbol = function_symbol e in
              List.iteri
                (fun position parameter ->
                  match parameter.fp_kind with
                  | Tparam_pat {pat_desc= Tpat_var (id, _, _); _} ->
                      let key =
                        symbol ^ ".<parameter@" ^ string_of_int position ^ ">"
                      in
                      Hashtbl.replace parameter_symbols key (symbol, position) ;
                      Hashtbl.replace symbols id key
                  | _ -> () )
                params ;
              let arity =
                List.length params
                +
                match body with
                | Tfunction_cases _ -> 1
                | Tfunction_body _ -> 0
              in
              define ~arity symbol e.exp_loc false ;
              Hashtbl.replace bodies symbol e ;
              within symbol [] (fun () -> default.expr self e)
          | Texp_lazy body ->
              let symbol = !caller ^ ".<lazy@" ^ position e.exp_loc ^ ">" in
              define symbol e.exp_loc false ;
              Hashtbl.replace bodies symbol body ;
              within symbol [] (fun () -> self.expr self body)
          | Texp_let (_, bindings, _) ->
              List.iter register bindings ;
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
                {Observation.loop_kind= "for"; loop_site= site_of_loc e.exp_loc}
              in
              within !caller (!loops @ [region]) (fun () -> self.expr self body)
          | Texp_apply (fn, args) ->
              let rec collapse fn args =
                match fn.exp_desc with
                | Texp_apply (inner, more) -> collapse inner (more @ args)
                | _ -> (fn, args)
              in
              let fn, args = collapse fn args in
              let target, resolution =
                match fn.exp_desc with
                | Texp_ident (path, _, _) -> (
                  match resolved path with
                  | "" -> ("", Observation.Unresolved_local)
                  | symbol -> (symbol, Observation.Resolved) )
                | Texp_field _ ->
                    let target = function_symbol fn in
                    ( target
                    , if target = ""
                      then Observation.Unresolved_field
                      else Observation.Resolved )
                | _ -> ("", Observation.Unresolved_dynamic)
              in
              let rec embedded_functions e =
                if function_type e
                then [function_symbol e]
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
                        | _, Overridden (_, e) -> embedded_functions e
                        | _ -> [] )
                  | Texp_ident (Path.Pident id, _, _) ->
                      Hashtbl.to_seq records
                      |> List.of_seq
                      |> List.filter_map (fun ((record, _), target) ->
                          if Ident.same record id then Some target else None )
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
                          (fun target ->
                            { Observation.position
                            ; label
                            ; target
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
                ; execution_site= site_of_loc fn.exp_loc
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
                ; execution_args= arguments }
              in
              invocations := invocation :: !invocations ;
              Hashtbl.replace applications e.exp_loc invocation ;
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
              self.expr self fn ;
              List.iter
                (fun (_, arg) ->
                  match arg with
                  | Arg e -> self.expr self e
                  | Omitted _ -> () )
                args
          | _ -> default.expr self e ) }
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
                  arg.position = position )
                call.Observation.execution_args
              |> Option.fold ~none:"" ~some:(fun arg -> arg.Observation.target) )
            calls
          |> List.sort_uniq compare
        in
        match targets with
        | [target]
          when target <> "" && not (Hashtbl.mem parameter_symbols target) ->
            target
        | targets ->
            if List.length targets > 1 && List.for_all (( <> ) "") targets
            then Hashtbl.replace ambiguous_parameters symbol () ;
            "" )
  in
  let resolve_call (call : Observation.execution_call) =
    let target = parameter_target call.execution_callee in
    { call with
      execution_callee= target
    ; execution_resolution=
        ( if Hashtbl.mem parameter_symbols call.execution_callee
          then
            if target = ""
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
  Hashtbl.to_seq applications
  |> List.of_seq
  |> List.iter (fun (location, call) ->
      Hashtbl.replace applications location (resolve_call call) ) ;
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
  { Observation.definitions= List.sort_uniq compare !definitions
  ; invocations= List.sort_uniq compare !invocations
  ; ordered=
      Hashtbl.fold
        (fun symbol body acc ->
          ( symbol
          , Ordered_execution.observe
              ~site_of_loc
              ~invocation:(fun e -> Hashtbl.find_opt applications e.exp_loc)
              body )
          :: acc )
        bodies
        !resumed
      |> List.sort compare }
