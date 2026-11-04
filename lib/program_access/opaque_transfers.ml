open Typedtree
open Szaniec_model

(* Follow data parameters through local aliases and helpers before declaring a
   queue-bearing record closed. An unresolved callback's data effects are opaque. *)
let observe
    ~known
    ~resolve
    ~symbol
    ~result_seed
    ~result_dependency
    ~emit
    structure =
  let aliases = Hashtbl.create 32 in
  let roots expression =
    let found = ref [] in
    let iterator =
      { Tast_iterator.default_iterator with
        expr=
          (fun self e ->
            ( match e.exp_desc with
            | Texp_ident (Path.Pident id, _, _) -> (
                found :=
                  Option.value ~default:[] (Hashtbl.find_opt aliases id)
                  @ !found ;
                match Canonical.parameter_symbol (resolve (Path.Pident id)) with
                | Some (owner, position) ->
                    found :=
                      (owner ^ ".<parameter@" ^ string_of_int position ^ ">")
                      :: !found
                | None -> () )
            | _ -> () ) ;
            Tast_iterator.default_iterator.expr self e ) }
    in
    iterator.expr iterator expression ;
    List.sort_uniq String.compare !found
  in
  let bind pattern values =
    let iterator =
      { Tast_iterator.default_iterator with
        pat=
          (fun (type k) self (p : k general_pattern) ->
            ( match p.pat_desc with
            | Tpat_var (id, _, _)
             |Tpat_alias (_, id, _, _, _) ->
                Hashtbl.replace aliases id values
            | _ -> () ) ;
            Tast_iterator.default_iterator.pat self p ) }
    in
    iterator.pat iterator pattern
  in
  let calls = ref [] and reads = ref [] and owner = ref "" in
  let top_values = Hashtbl.create 16 in
  (* Pattern-bound locals are not opaque module values. Match aliases retain
     their scrutinee's parameter roots for conservative escape propagation. *)
  let iterator =
    { Tast_iterator.default_iterator with
      pat=
        (fun (type k) self (p : k general_pattern) ->
          ( match p.pat_desc with
          | Tpat_var (id, _, _)
           |Tpat_alias (_, id, _, _, _) ->
              if not (Hashtbl.mem aliases id) then Hashtbl.add aliases id []
          | _ -> () ) ;
          Tast_iterator.default_iterator.pat self p )
    ; value_binding=
        (fun self binding ->
          let previous_owner = !owner in
          if previous_owner = ""
          then begin
            let ids = ref [] in
            let patterns =
              { Tast_iterator.default_iterator with
                pat=
                  (fun (type k) self (p : k general_pattern) ->
                    ( match p.pat_desc with
                    | Tpat_var (id, _, _)
                     |Tpat_alias (_, id, _, _, _) ->
                        ids := id :: !ids
                    | _ -> () ) ;
                    Tast_iterator.default_iterator.pat self p ) }
            in
            patterns.pat patterns binding.vb_pat ;
            List.iter
              (fun id ->
                Hashtbl.replace top_values id () ;
                let value = resolve (Path.Pident id) in
                result_seed value ;
                if !owner = ""
                then owner := value
                else if value <> !owner
                then result_dependency value !owner )
              !ids
          end ;
          Tast_iterator.default_iterator.value_binding self binding ;
          bind binding.vb_pat (roots binding.vb_expr) ;
          owner := previous_owner )
    ; expr=
        (fun self e ->
          let previous_owner = !owner in
          ( match e.exp_desc with
          | Texp_match (value, cases, value_cases, _) ->
              let values = roots value in
              List.iter (fun case -> bind case.c_lhs values) cases ;
              List.iter (fun case -> bind case.c_lhs values) value_cases
          | Texp_function (parameters, body) -> (
              owner := symbol e ;
              List.iteri
                (fun position parameter ->
                  let key =
                    symbol e ^ ".<parameter@" ^ string_of_int position ^ ">"
                  in
                  Hashtbl.replace aliases parameter.fp_param [key] ;
                  match parameter.fp_kind with
                  | Tparam_pat p
                   |Tparam_optional_default (p, _) ->
                      bind p [key] )
                parameters ;
              match body with
              | Tfunction_cases {cases; _} ->
                  List.iter
                    (fun c ->
                      bind
                        c.c_lhs
                        [ symbol e
                          ^ ".<parameter@"
                          ^ string_of_int (List.length parameters)
                          ^ ">" ] )
                    cases
              | _ -> () )
          | _ -> () ) ;
          Tast_iterator.default_iterator.expr self e ;
          ( match e.exp_desc with
          | Texp_apply (fn, args) ->
              calls := (!owner, e, symbol fn, args) :: !calls
          | Texp_ident (path, _, _) ->
              let static_value =
                match path with
                | Path.Pident id ->
                    Hashtbl.mem top_values id || not (Hashtbl.mem aliases id)
                | Path.Pdot _ -> true
                | _ -> false
              in
              if static_value then reads := (!owner, e, resolve path) :: !reads
          | _ -> () ) ;
          owner := previous_owner ) }
  in
  iterator.structure iterator structure ;
  let expanded e =
    Ctype.expand_head (Envaux.env_of_only_summary e.exp_env) e.exp_type
  in
  let generic e =
    match Types.get_desc (expanded e) with
    | Types.Tarrow _ -> false
    | _ ->
        let seen = Hashtbl.create 8 and found = ref false in
        let rec scan typ =
          if not (Hashtbl.mem seen (Types.get_id typ))
          then begin
            Hashtbl.add seen (Types.get_id typ) () ;
            match Types.get_desc typ with
            | Types.Tvar _
             |Types.Tunivar _ ->
                found := true
            | _ -> Btype.iter_type_expr scan typ
          end
        in
        scan (expanded e) ;
        !found
  in
  let escaped = Hashtbl.create 16 and owners = Hashtbl.create 16 in
  let primitive target args =
    List.exists
      (fun prefix -> String.starts_with ~prefix target)
      ["Stdlib.List."; "Stdlib.Option."; "Stdlib.Hashtbl."]
    && List.for_all
         (function
           | _, Arg value -> (
             match Types.get_desc (expanded value) with
             | Types.Tarrow _ ->
                 let target = symbol value in
                 List.mem target known && not (Hashtbl.mem owners target)
             | _ -> true )
           | _ -> true )
         args
  in
  let selected target args =
    List.mapi
      (fun position arg ->
        if primitive target args
        then None
        else
          match arg with
          | _, Arg value
            when (not (List.mem target known))
                 || Hashtbl.mem
                      escaped
                      (target ^ ".<parameter@" ^ string_of_int position ^ ">")
            ->
              Some value
          | _ -> None )
      args
    |> List.filter_map Fun.id
  in
  let rec close remaining =
    let changed = ref false in
    List.iter
      (fun (_, _, target, args) ->
        List.iter
          (fun value ->
            if generic value
            then
              List.iter
                (fun key ->
                  if not (Hashtbl.mem escaped key)
                  then begin
                    Hashtbl.replace escaped key () ;
                    Option.iter
                      (fun (owner, _) -> Hashtbl.replace owners owner ())
                      (Canonical.parameter_symbol key) ;
                    changed := true
                  end )
                (roots value) )
          (selected target args) )
      !calls ;
    if !changed
    then
      if remaining = 0
      then
        failwith "Opaque callback-store parameter flow exceeds supported depth"
      else close (remaining - 1)
  in
  close 64 ;
  List.iter
    (fun (owner, e, target) ->
      if owner <> "" && generic e then result_dependency owner target ;
      emit ~target ~result:true e )
    !reads ;
  List.iter
    (fun (owner, e, target, args) ->
      (* A generic result can acquire a queue-bearing type at another callsite.
         Retain its possible opaque producers even without concrete fields here.
         Callback arguments may produce that result through a protected scope. *)
      if owner <> "" && generic e
      then begin
        result_dependency owner target ;
        List.iter
          (function
            | _, Arg value -> (
              match Types.get_desc (expanded value) with
              | Types.Tarrow _ -> result_dependency owner (symbol value)
              | _ -> () )
            | _ -> () )
          args
      end ;
      List.iter (emit ~target ~result:false) (selected target args) ;
      if not (primitive target args) then emit ~target ~result:true e )
    !calls
