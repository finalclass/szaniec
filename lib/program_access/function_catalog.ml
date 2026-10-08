(* Function catalog for suggestion retrieval.

   Walks the same fresh .cmt implementations as the observation. Definitions
   are source facts only; ownership and judgments are applied later. *)

open Szaniec_model

let ( // ) = Filename.concat

let max_stored = 8000

let read_file (path : string) : string option =
  try
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic ;
    Some s
  with
  | Sys_error _ -> None

let slice (text : string) (loc : Location.t) : string option =
  if loc.Location.loc_ghost
  then None
  else
    let a = loc.Location.loc_start.Lexing.pos_cnum in
    let b = loc.Location.loc_end.Lexing.pos_cnum in
    if a < 0 || b < a || b > String.length text
    then None
    else Some (String.sub text a (b - a))

let cap (text : string) : string * bool =
  if String.length text <= max_stored
  then (text, false)
  else (String.sub text 0 max_stored, true)

let span (loc : Location.t) : int * int * int =
  let s = loc.Location.loc_start in
  let e = loc.Location.loc_end in
  (s.Lexing.pos_lnum, s.Lexing.pos_cnum - s.Lexing.pos_bol, e.Lexing.pos_lnum)

let comments_in (text : string) : (int * int) list =
  let n = String.length text in
  let rec close j depth =
    if j + 1 >= n
    then n
    else if text.[j] = '(' && text.[j + 1] = '*'
    then close (j + 2) (depth + 1)
    else if text.[j] = '*' && text.[j + 1] = ')'
    then if depth = 0 then j + 2 else close (j + 2) (depth - 1)
    else close (j + 1) depth
  in
  let rec go i acc =
    if i >= n
    then List.rev acc
    else if i + 1 < n && text.[i] = '(' && text.[i + 1] = '*'
    then
      let e = close (i + 2) 0 in
      go e ((i, e) :: acc)
    else go (i + 1) acc
  in
  go 0 []

let only_ws (text : string) (a : int) (b : int) : bool =
  let rec go i =
    if i >= b
    then true
    else
      match text.[i] with
      | ' '
       |'\t'
       |'\n'
       |'\r' ->
          go (i + 1)
      | _ -> false
  in
  go a

let comment_before (text : string) (comments : (int * int) list) (cnum : int) :
    string =
  let best =
    List.fold_left
      (fun acc (a, b) ->
        if b <= cnum && cnum - b < 80 && only_ws text b cnum
        then
          match acc with
          | None -> Some (a, b)
          | Some (_, prev) when b >= prev -> Some (a, b)
          | Some _ -> acc
        else acc )
      None
      comments
  in
  match best with
  | None -> ""
  | Some (a, b) ->
      let raw = String.sub text a (b - a) in
      let inner =
        if
          String.length raw >= 4
          && String.sub raw 0 2 = "(*"
          && String.sub raw (String.length raw - 2) 2 = "*)"
        then String.sub raw 2 (String.length raw - 4)
        else raw
      in
      let trimmed = String.trim inner in
      if String.length trimmed <= 400 then trimmed else String.sub trimmed 0 400

let rec pat_names (p : _ Typedtree.general_pattern) (acc : string list) :
    string list =
  match p.Typedtree.pat_desc with
  | Typedtree.Tpat_var (id, _, _) -> Ident.name id :: acc
  | Typedtree.Tpat_alias (q, id, _, _, _) -> Ident.name id :: pat_names q acc
  | Typedtree.Tpat_tuple ps ->
      List.fold_left (fun acc (_l, q) -> pat_names q acc) acc ps
  | Typedtree.Tpat_construct (_, _, ps, _) ->
      List.fold_left (fun acc q -> pat_names q acc) acc ps
  | Typedtree.Tpat_variant (_, q, _) -> (
    match q with
    | Some q -> pat_names q acc
    | None -> acc )
  | Typedtree.Tpat_record (fs, _) ->
      List.fold_left (fun acc (_l, _ld, q) -> pat_names q acc) acc fs
  | Typedtree.Tpat_array (_, ps) ->
      List.fold_left (fun acc q -> pat_names q acc) acc ps
  | Typedtree.Tpat_or (a, b, _) -> pat_names b (pat_names a acc)
  | Typedtree.Tpat_lazy q -> pat_names q acc
  | _ -> acc

let label_prefix (label : Asttypes.arg_label) : string =
  match label with
  | Asttypes.Nolabel -> ""
  | Asttypes.Labelled s -> "~" ^ s ^ ":"
  | Asttypes.Optional s -> "?" ^ s ^ ":"

let param_names
    (params : Typedtree.function_param list)
    (body : Typedtree.function_body) : string list =
  let from_params =
    List.map
      (fun (fp : Typedtree.function_param) ->
        label_prefix fp.Typedtree.fp_arg_label
        ^ Ident.name fp.Typedtree.fp_param )
      params
  in
  let extra =
    match body with
    | Typedtree.Tfunction_body _ -> []
    | Typedtree.Tfunction_cases {param; _} -> [Ident.name param]
  in
  from_params @ extra

let body_loc (body : Typedtree.function_body) : Location.t =
  match body with
  | Typedtree.Tfunction_body e -> e.Typedtree.exp_loc
  | Typedtree.Tfunction_cases {loc; _} -> loc

type acc =
  { mutable fns: Function_def.t list
  ; ids: (string, unit) Hashtbl.t }

let unique_id (acc : acc) (base : string) (line : int) : string =
  if not (Hashtbl.mem acc.ids base)
  then (
    Hashtbl.add acc.ids base () ;
    base )
  else
    let with_line = base ^ ":" ^ string_of_int line in
    let rec go n candidate =
      if not (Hashtbl.mem acc.ids candidate)
      then (
        Hashtbl.add acc.ids candidate () ;
        candidate )
      else go (n + 1) (with_line ^ "#" ^ string_of_int n)
    in
    go 2 with_line

let push
    (acc : acc)
    ~(env_unit : string)
    ~(env_prefix : string)
    ~(source_path : string)
    ~(source : string)
    ~(comments : (int * int) list)
    ~(name : string)
    ~(kind : string)
    ~(binding_loc : Location.t)
    ~(params : Typedtree.function_param list)
    ~(body : Typedtree.function_body) : unit =
  let line, col, end_line = span binding_loc in
  let id_base =
    let head =
      if env_prefix = "" then env_unit else env_unit ^ "." ^ env_prefix
    in
    if kind = "anonymous"
    then Printf.sprintf "%s#anon:%s:%d:%d" head source_path line col
    else head ^ "." ^ name
  in
  let id = unique_id acc id_base line in
  let binding_raw = slice source binding_loc |> Option.value ~default:"" in
  let body_raw = slice source (body_loc body) |> Option.value ~default:"" in
  let binding_text, trunc_b = cap binding_raw in
  let body_text, trunc_d = cap body_raw in
  let cnum = binding_loc.Location.loc_start.Lexing.pos_cnum in
  let vars = ref [] in
  let add_vars (p : _ Typedtree.general_pattern) = vars := pat_names p !vars in
  let rec walk (e : Typedtree.expression) =
    match e.Typedtree.exp_desc with
    | Typedtree.Texp_let (_, vbs, cont) ->
        List.iter
          (fun (vb : Typedtree.value_binding) ->
            add_vars vb.Typedtree.vb_pat ;
            walk vb.Typedtree.vb_expr )
          vbs ;
        walk cont
    | Typedtree.Texp_function (ps, b) ->
        List.iter
          (fun (fp : Typedtree.function_param) ->
            match fp.Typedtree.fp_kind with
            | Typedtree.Tparam_pat p -> add_vars p
            | Typedtree.Tparam_optional_default (p, def) ->
                add_vars p ;
                walk def )
          ps ;
        walk_body b
    | Typedtree.Texp_apply (f, args) ->
        walk f ;
        List.iter
          (fun (_l, arg) ->
            match arg with
            | Typedtree.Arg a -> walk a
            | Typedtree.Omitted _ -> () )
          args
    | Typedtree.Texp_match (e, cs, effs, _) ->
        walk e ;
        List.iter
          (fun c ->
            Option.iter walk c.Typedtree.c_guard ;
            walk c.Typedtree.c_rhs )
          cs ;
        List.iter
          (fun c ->
            add_vars c.Typedtree.c_lhs ;
            Option.iter walk c.Typedtree.c_guard ;
            walk c.Typedtree.c_rhs )
          effs
    | Typedtree.Texp_try (e, cs, effs) ->
        walk e ;
        List.iter
          (fun c ->
            add_vars c.Typedtree.c_lhs ;
            Option.iter walk c.Typedtree.c_guard ;
            walk c.Typedtree.c_rhs )
          cs ;
        List.iter
          (fun c ->
            Option.iter walk c.Typedtree.c_guard ;
            walk c.Typedtree.c_rhs )
          effs
    | Typedtree.Texp_tuple ps -> List.iter (fun (_l, e) -> walk e) ps
    | Typedtree.Texp_construct (_, _, es) -> List.iter walk es
    | Typedtree.Texp_variant (_, e) -> Option.iter walk e
    | Typedtree.Texp_record {fields; extended_expression; _} ->
        Array.iter
          (fun (_ld, def) ->
            match def with
            | Typedtree.Kept _ -> ()
            | Typedtree.Overridden (_, e) -> walk e )
          fields ;
        Option.iter walk extended_expression
    | Typedtree.Texp_field (e, _, _)
     |Typedtree.Texp_atomic_loc (e, _, _) ->
        walk e
    | Typedtree.Texp_setfield (a, _, _, b) ->
        walk a ;
        walk b
    | Typedtree.Texp_array (_, es) -> List.iter walk es
    | Typedtree.Texp_ifthenelse (a, b, c) ->
        walk a ;
        walk b ;
        Option.iter walk c
    | Typedtree.Texp_sequence (a, b)
     |Typedtree.Texp_while (a, b) ->
        walk a ;
        walk b
    | Typedtree.Texp_for (_, _, a, b, _, c) ->
        walk a ;
        walk b ;
        walk c
    | Typedtree.Texp_send (e, _) -> walk e
    | Typedtree.Texp_letmodule (_, _, _, m, e) ->
        walk_mod m ;
        walk e
    | Typedtree.Texp_letexception (_, e)
     |Typedtree.Texp_assert (e, _)
     |Typedtree.Texp_lazy e
     |Typedtree.Texp_open (_, e) ->
        walk e
    | Typedtree.Texp_override (_, bs) ->
        List.iter (fun (_id, _name, e) -> walk e) bs
    | Typedtree.Texp_pack m -> walk_mod m
    | Typedtree.Texp_letop {let_; ands; body; _} ->
        walk let_.Typedtree.bop_exp ;
        List.iter (fun b -> walk b.Typedtree.bop_exp) ands ;
        walk body.Typedtree.c_rhs
    | Typedtree.Texp_ident _
     |Typedtree.Texp_constant _
     |Typedtree.Texp_new _
     |Typedtree.Texp_instvar _
     |Typedtree.Texp_setinstvar _
     |Typedtree.Texp_object _
     |Typedtree.Texp_unreachable
     |Typedtree.Texp_extension_constructor _ ->
        ()
  and walk_body (b : Typedtree.function_body) =
    match b with
    | Typedtree.Tfunction_body e -> walk e
    | Typedtree.Tfunction_cases {cases; _} ->
        List.iter
          (fun c ->
            add_vars c.Typedtree.c_lhs ;
            Option.iter walk c.Typedtree.c_guard ;
            walk c.Typedtree.c_rhs )
          cases
  and walk_mod (m : Typedtree.module_expr) =
    match m.Typedtree.mod_desc with
    | Typedtree.Tmod_structure s ->
        List.iter
          (fun (i : Typedtree.structure_item) ->
            match i.Typedtree.str_desc with
            | Typedtree.Tstr_eval (e, _) -> walk e
            | Typedtree.Tstr_value (_, vbs) ->
                List.iter (fun vb -> walk vb.Typedtree.vb_expr) vbs
            | _ -> () )
          s.Typedtree.str_items
    | Typedtree.Tmod_constraint (m, _, _, _)
     |Typedtree.Tmod_functor (_, m)
     |Typedtree.Tmod_apply_unit m ->
        walk_mod m
    | Typedtree.Tmod_apply (f, a, _) ->
        walk_mod f ;
        walk_mod a
    | Typedtree.Tmod_unpack (e, _) -> walk e
    | Typedtree.Tmod_ident _ -> ()
  in
  walk_body body ;
  let variables =
    !vars |> List.rev |> List.sort_uniq String.compare |> fun names ->
    let names = List.filter (fun n -> not (String.equal n name)) names in
    if List.length names <= 24
    then names
    else List.filteri (fun i _ -> i < 24) names
  in
  let source_status =
    if body_text = "" && binding_text = "" then "unavailable" else "available"
  in
  acc.fns <-
    { Function_def.id
    ; name
    ; unit_canonical= env_unit
    ; source_path
    ; line
    ; col
    ; end_line
    ; parameters= param_names params body
    ; variables
    ; binding_text
    ; body_text
    ; normalized_body= Function_def.normalize body_text
    ; comment_before= comment_before source comments cnum
    ; kind
    ; provenance= Function_def.provenance_of_path source_path
    ; truncated= trunc_b || trunc_d
    ; source_status }
    :: acc.fns

let as_function (e : Typedtree.expression) :
    (Typedtree.function_param list * Typedtree.function_body) option =
  match e.Typedtree.exp_desc with
  | Typedtree.Texp_function (params, body) -> Some (params, body)
  | _ -> None

let extract_unit
    ~(unit_canonical : string)
    ~(source_path : string)
    ~(source : string)
    (structure : Typedtree.structure) : Function_def.t list =
  let acc = {fns= []; ids= Hashtbl.create 32} in
  let comments = comments_in source in
  let rec walk_items prefix nested (items : Typedtree.structure_item list) =
    List.iter
      (fun (i : Typedtree.structure_item) ->
        match i.Typedtree.str_desc with
        | Typedtree.Tstr_value (_, vbs) ->
            List.iter (handle_vb prefix nested) vbs
        | Typedtree.Tstr_module mb ->
            let name =
              match mb.Typedtree.mb_name.Location.txt with
              | Some n -> n
              | None -> ""
            in
            let sub =
              if name = ""
              then prefix
              else if prefix = ""
              then name
              else prefix ^ "." ^ name
            in
            walk_mod sub nested mb.Typedtree.mb_expr
        | Typedtree.Tstr_recmodule mbs ->
            List.iter
              (fun mb ->
                let name =
                  match mb.Typedtree.mb_name.Location.txt with
                  | Some n -> n
                  | None -> ""
                in
                let sub =
                  if name = ""
                  then prefix
                  else if prefix = ""
                  then name
                  else prefix ^ "." ^ name
                in
                walk_mod sub nested mb.Typedtree.mb_expr )
              mbs
        | Typedtree.Tstr_include inc ->
            walk_mod prefix nested inc.Typedtree.incl_mod
        | Typedtree.Tstr_eval (e, _) -> walk_expr prefix true e
        | _ -> () )
      items
  and walk_mod prefix nested (m : Typedtree.module_expr) =
    match m.Typedtree.mod_desc with
    | Typedtree.Tmod_structure s ->
        walk_items prefix nested s.Typedtree.str_items
    | Typedtree.Tmod_functor (_, body) -> walk_mod prefix nested body
    | Typedtree.Tmod_constraint (m, _, _, _) -> walk_mod prefix nested m
    | Typedtree.Tmod_apply (f, a, _) ->
        walk_mod prefix nested f ;
        walk_mod prefix nested a
    | Typedtree.Tmod_apply_unit m -> walk_mod prefix nested m
    | Typedtree.Tmod_unpack (e, _) -> walk_expr prefix nested e
    | Typedtree.Tmod_ident _ -> ()
  and handle_vb prefix nested (vb : Typedtree.value_binding) =
    match as_function vb.Typedtree.vb_expr with
    | Some (params, body) ->
        let name =
          match vb.Typedtree.vb_pat.Typedtree.pat_desc with
          | Typedtree.Tpat_var (id, _, _) -> Ident.name id
          | _ -> "binding"
        in
        let kind = if nested then "local" else "top-level" in
        push
          acc
          ~env_unit:unit_canonical
          ~env_prefix:prefix
          ~source_path
          ~source
          ~comments
          ~name
          ~kind
          ~binding_loc:vb.Typedtree.vb_loc
          ~params
          ~body ;
        let next = if prefix = "" then name else prefix ^ "." ^ name in
        walk_interior next params body
    | None -> walk_expr prefix true vb.Typedtree.vb_expr
  and walk_interior
      prefix
      (params : Typedtree.function_param list)
      (body : Typedtree.function_body) =
    List.iter
      (fun (fp : Typedtree.function_param) ->
        match fp.Typedtree.fp_kind with
        | Typedtree.Tparam_pat _ -> ()
        | Typedtree.Tparam_optional_default (_, e) -> walk_expr prefix true e )
      params ;
    match body with
    | Typedtree.Tfunction_body e -> walk_expr prefix true e
    | Typedtree.Tfunction_cases {cases; _} ->
        List.iter
          (fun (c : _ Typedtree.case) ->
            Option.iter (walk_expr prefix true) c.Typedtree.c_guard ;
            walk_expr prefix true c.Typedtree.c_rhs )
          cases
  and walk_expr prefix nested (e : Typedtree.expression) =
    match e.Typedtree.exp_desc with
    | Typedtree.Texp_let (_, vbs, cont) ->
        List.iter (handle_vb prefix nested) vbs ;
        walk_expr prefix nested cont
    | Typedtree.Texp_function (params, body) ->
        push
          acc
          ~env_unit:unit_canonical
          ~env_prefix:prefix
          ~source_path
          ~source
          ~comments
          ~name:""
          ~kind:"anonymous"
          ~binding_loc:e.Typedtree.exp_loc
          ~params
          ~body ;
        walk_interior prefix params body
    | Typedtree.Texp_apply (f, args) ->
        walk_expr prefix nested f ;
        List.iter
          (fun (_l, arg) ->
            match arg with
            | Typedtree.Arg a -> walk_expr prefix nested a
            | Typedtree.Omitted _ -> () )
          args
    | Typedtree.Texp_match (scrut, cs, effs, _) ->
        walk_expr prefix nested scrut ;
        List.iter
          (fun c ->
            Option.iter (walk_expr prefix nested) c.Typedtree.c_guard ;
            walk_expr prefix nested c.Typedtree.c_rhs )
          cs ;
        List.iter
          (fun c ->
            Option.iter (walk_expr prefix nested) c.Typedtree.c_guard ;
            walk_expr prefix nested c.Typedtree.c_rhs )
          effs
    | Typedtree.Texp_try (scrut, cs, effs) ->
        walk_expr prefix nested scrut ;
        List.iter
          (fun c ->
            Option.iter (walk_expr prefix nested) c.Typedtree.c_guard ;
            walk_expr prefix nested c.Typedtree.c_rhs )
          cs ;
        List.iter
          (fun c ->
            Option.iter (walk_expr prefix nested) c.Typedtree.c_guard ;
            walk_expr prefix nested c.Typedtree.c_rhs )
          effs
    | Typedtree.Texp_tuple ps ->
        List.iter (fun (_l, e) -> walk_expr prefix nested e) ps
    | Typedtree.Texp_construct (_, _, es) ->
        List.iter (walk_expr prefix nested) es
    | Typedtree.Texp_variant (_, e) -> Option.iter (walk_expr prefix nested) e
    | Typedtree.Texp_record {fields; extended_expression; _} ->
        Array.iter
          (fun (_ld, def) ->
            match def with
            | Typedtree.Kept _ -> ()
            | Typedtree.Overridden (_, e) -> walk_expr prefix nested e )
          fields ;
        Option.iter (walk_expr prefix nested) extended_expression
    | Typedtree.Texp_field (e, _, _)
     |Typedtree.Texp_atomic_loc (e, _, _) ->
        walk_expr prefix nested e
    | Typedtree.Texp_setfield (a, _, _, b) ->
        walk_expr prefix nested a ;
        walk_expr prefix nested b
    | Typedtree.Texp_array (_, es) -> List.iter (walk_expr prefix nested) es
    | Typedtree.Texp_ifthenelse (a, b, c) ->
        walk_expr prefix nested a ;
        walk_expr prefix nested b ;
        Option.iter (walk_expr prefix nested) c
    | Typedtree.Texp_sequence (a, b)
     |Typedtree.Texp_while (a, b) ->
        walk_expr prefix nested a ;
        walk_expr prefix nested b
    | Typedtree.Texp_for (_, _, a, b, _, c) ->
        walk_expr prefix nested a ;
        walk_expr prefix nested b ;
        walk_expr prefix nested c
    | Typedtree.Texp_send (e, _)
     |Typedtree.Texp_letexception (_, e)
     |Typedtree.Texp_assert (e, _)
     |Typedtree.Texp_lazy e
     |Typedtree.Texp_open (_, e) ->
        walk_expr prefix nested e
    | Typedtree.Texp_letmodule (_, _, _, m, e) ->
        walk_mod prefix nested m ;
        walk_expr prefix nested e
    | Typedtree.Texp_override (_, bs) ->
        List.iter (fun (_id, _name, e) -> walk_expr prefix nested e) bs
    | Typedtree.Texp_pack m -> walk_mod prefix nested m
    | Typedtree.Texp_letop {let_; ands; body; _} ->
        walk_expr prefix nested let_.Typedtree.bop_exp ;
        List.iter (fun b -> walk_expr prefix nested b.Typedtree.bop_exp) ands ;
        walk_expr prefix nested body.Typedtree.c_rhs
    | Typedtree.Texp_ident _
     |Typedtree.Texp_constant _
     |Typedtree.Texp_new _
     |Typedtree.Texp_instvar _
     |Typedtree.Texp_setinstvar _
     |Typedtree.Texp_object _
     |Typedtree.Texp_unreachable
     |Typedtree.Texp_extension_constructor _ ->
        ()
  in
  walk_items "" false structure.Typedtree.str_items ;
  List.rev acc.fns

let collect
    ~(project_root : string)
    ~(program_roots : string list)
    ~(assume_fresh : bool)
    () : Function_def.catalog =
  let obs =
    Ocaml_adapter.observe ~project_root ~program_roots ~assume_fresh ()
  in
  let gaps =
    List.map
      (fun (g : Observation.gap) ->
        { Function_def.code= g.Observation.gap_code
        ; path= g.Observation.gap_path
        ; detail= g.Observation.gap_detail } )
      obs.Observation.gaps
  in
  let extra = ref gaps in
  let fns = ref [] in
  List.iter
    (fun (u : Observation.unit_info) ->
      if u.Observation.fresh
      then
        let artifact = project_root // u.Observation.artifact_path in
        let source_abs = project_root // u.Observation.source_path in
        match
          ( ( try Some (Cmt_format.read_cmt artifact) with
            | _ -> None )
          , read_file source_abs )
        with
        | None, _
         |_, None ->
            extra :=
              { Function_def.code= "GAP-SUGGESTION-NO-SOURCE"
              ; path= u.Observation.source_path
              ; detail= "implementation source or artifact could not be read" }
              :: !extra
        | Some cmt, Some source -> (
          match cmt.Cmt_format.cmt_annots with
          | Cmt_format.Implementation structure ->
              let found =
                extract_unit
                  ~unit_canonical:u.Observation.canonical
                  ~source_path:u.Observation.source_path
                  ~source
                  structure
              in
              List.iter
                (fun (f : Function_def.t) ->
                  if String.equal f.Function_def.source_status "unavailable"
                  then
                    extra :=
                      { Function_def.code= "GAP-SUGGESTION-NO-SOURCE"
                      ; path= f.Function_def.source_path
                      ; detail=
                          Printf.sprintf
                            "no source slice for %s at line %d"
                            f.Function_def.id
                            f.Function_def.line }
                      :: !extra )
                found ;
              fns := found @ !fns
          | _ -> () ) )
    obs.Observation.units ;
  let uses =
    List.map
      (fun (c : Observation.call) ->
        { Function_def.caller= c.Observation.caller
        ; callee= c.Observation.callee
        ; path= c.Observation.site.Observation.site_path
        ; line= c.Observation.site.Observation.line } )
      obs.Observation.calls
  in
  let by_id (a : Function_def.t) (b : Function_def.t) =
    String.compare a.Function_def.id b.Function_def.id
  in
  let by_gap (a : Function_def.gap) (b : Function_def.gap) =
    compare
      (a.Function_def.code, a.Function_def.path, a.Function_def.detail)
      (b.Function_def.code, b.Function_def.path, b.Function_def.detail)
  in
  { Function_def.snapshot_digest= obs.Observation.snapshot_digest
  ; compiler= obs.Observation.compiler_series
  ; functions= List.sort by_id !fns
  ; uses=
      List.sort
        (fun a b ->
          compare
            (a.Function_def.caller, a.callee, a.path, a.line)
            (b.Function_def.caller, b.callee, b.path, b.line) )
        uses
  ; gaps= List.sort_uniq by_gap !extra }
