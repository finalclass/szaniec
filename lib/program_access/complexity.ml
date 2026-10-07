(* Local cyclomatic complexity, szaniec-cc/1.

   Walks one typed structure and returns every syntactic function plus
   GAP-UNMEASURABLE records. See docs/contracts/complexity-metric.md.
   The walker reports facts only; it does not judge architecture. *)

open Szaniec_model

type raw =
  { name: string
  ; qualname: string
  ; enclosing: string
  ; kind: Observation.fn_kind
  ; nested: bool
  ; provenance: Observation.fn_provenance
  ; path: string
  ; line: int
  ; col: int
  ; end_line: int
  ; end_col: int
  ; measure: Observation.fn_measure }

type st =
  { project_root: string
  ; source_path: string
  ; unit_canonical: string
  ; mutable raws: raw list
  ; mutable gaps: Observation.gap list }

let qualify (scope : string) (name : string) : string =
  if scope = "" then name else scope ^ "." ^ name

let ghost (loc : Location.t) : bool = loc.Location.loc_ghost

let pos_col (p : Lexing.position) : int = p.Lexing.pos_cnum - p.Lexing.pos_bol

let normalize ~(project_root : string) (fname : string) : string =
  if fname = "" || Filename.is_relative fname
  then fname
  else
    let root = String.length project_root in
    if
      String.length fname > root
      && String.sub fname 0 root = project_root
      && fname.[root] = '/'
    then String.sub fname (root + 1) (String.length fname - root - 1)
    else fname

let path_segment (path : string) (seg : string) : bool =
  List.mem seg (String.split_on_char '/' path)

let file_provenance (path : string) : Observation.fn_provenance =
  if Filename.check_suffix path ".ml-gen"
  then Observation.Prov_generated
  else if path_segment path "test" || path_segment path "tests"
  then Observation.Prov_test
  else Observation.Prov_authored

let provenance_of (st : st) (loc : Location.t) : Observation.fn_provenance =
  if ghost loc
  then Observation.Prov_generated
  else file_provenance st.source_path

let span_of (st : st) (loc : Location.t) : string * int * int * int * int =
  let start = loc.Location.loc_start in
  let endp = loc.Location.loc_end in
  let path = normalize ~project_root:st.project_root start.Lexing.pos_fname in
  let path = if path = "" then st.source_path else path in
  ( path
  , start.Lexing.pos_lnum
  , pos_col start
  , endp.Lexing.pos_lnum
  , pos_col endp )

let add_gap (st : st) (detail : string) (loc : Location.t) =
  let path, line, col, _, _ = span_of st loc in
  st.gaps <-
    { Observation.gap_code= "GAP-UNMEASURABLE"
    ; gap_path= path
    ; gap_detail= Printf.sprintf "%s at %d:%d" detail line col }
    :: st.gaps

let simple_name (p : Typedtree.pattern) : string option =
  match p.Typedtree.pat_desc with
  | Tpat_var (id, _, _) -> Some (Ident.name id)
  | Tpat_alias (_, id, _, _, _) -> Some (Ident.name id)
  | _ -> None

let ( ++ ) (n, u) (m, v) = (n + m, u || v)

let authored_case (c : _ Typedtree.case) : bool =
  not (ghost c.Typedtree.c_lhs.Typedtree.pat_loc)

let guard_extra (c : _ Typedtree.case) : int =
  match c.Typedtree.c_guard with
  | Some e when not (ghost e.Typedtree.exp_loc) -> 1
  | _ -> 0

let rec applied_desc (e : Typedtree.expression) : Types.value_description option
    =
  match e.Typedtree.exp_desc with
  | Texp_apply (f, _) -> applied_desc f
  | Texp_ident (_, _, vd) -> Some vd
  | _ -> None

let is_short_circuit (fn : Typedtree.expression) : bool =
  match applied_desc fn with
  | Some vd -> (
    match vd.Types.val_kind with
    | Types.Val_prim prim ->
        let n = prim.Primitive.prim_name in
        String.equal n "%sequand" || String.equal n "%sequor"
    | _ -> false )
  | None -> false

let rec define
    (st : st)
    ~(scope : string)
    ~(inside : bool)
    ~(name : string)
    ~(kind : Observation.fn_kind)
    ~(loc : Location.t)
    (params : Typedtree.function_param list)
    (body : Typedtree.function_body) =
  let qualname =
    match kind with
    | Observation.Fn_named -> qualify scope name
    | Observation.Fn_anonymous -> qualify scope "anon"
  in
  let path, line, col, end_line, end_col = span_of st loc in
  let d, unmeasurable = measure_body st qualname params body in
  if unmeasurable
  then
    add_gap
      st
      (Printf.sprintf
         "function %s contains a construct szaniec-cc/1 does not measure"
         qualname )
      loc ;
  st.raws <-
    { name
    ; qualname
    ; enclosing= scope
    ; kind
    ; nested= inside
    ; provenance= provenance_of st loc
    ; path
    ; line
    ; col
    ; end_line
    ; end_col
    ; measure=
        ( if unmeasurable
          then Observation.Fn_unmeasurable
          else Observation.Fn_measured (1 + d) ) }
    :: st.raws

and measure_body
    (st : st)
    (scope : string)
    (params : Typedtree.function_param list)
    (body : Typedtree.function_body) : int * bool =
  let acc =
    List.fold_left
      (fun acc (fp : Typedtree.function_param) ->
        match fp.Typedtree.fp_kind with
        | Typedtree.Tparam_optional_default (_, expr) ->
            acc ++ decisions st scope true expr
        | Typedtree.Tparam_pat _ -> acc )
      (0, false)
      params
  in
  match body with
  | Typedtree.Tfunction_body expr -> acc ++ decisions st scope true expr
  | Typedtree.Tfunction_cases {cases; _} ->
      acc ++ case_split st scope true cases

and case_parts :
    'k. st -> string -> bool -> 'k Typedtree.case list -> int * int * bool =
 fun st scope inside cases ->
  let authored = List.filter authored_case cases in
  let guards = List.fold_left (fun n c -> n + guard_extra c) 0 authored in
  let d, u =
    List.fold_left
      (fun acc (c : _ Typedtree.case) ->
        let acc =
          match c.Typedtree.c_guard with
          | Some e when not (ghost e.Typedtree.exp_loc) ->
              acc ++ decisions st scope inside e
          | _ -> acc
        in
        acc ++ decisions st scope inside c.Typedtree.c_rhs )
      (0, false)
      authored
  in
  (List.length authored, guards + d, u)

and case_split
    (st : st)
    (scope : string)
    (inside : bool)
    (cases : _ Typedtree.case list) : int * bool =
  let n, rest, u = case_parts st scope inside cases in
  let split = if n <= 1 then 0 else n - 1 in
  (split + rest, u)

and case_handlers
    (st : st)
    (scope : string)
    (inside : bool)
    (cases : _ Typedtree.case list) : int * bool =
  let n, rest, u = case_parts st scope inside cases in
  (* The tried body is already the incoming path, so every handler adds
     one. This differs from match, whose first arm is that incoming path. *)
  (n + rest, u)

and bind_expr
    (st : st)
    (scope : string)
    (inside : bool)
    (vb : Typedtree.value_binding) : int * bool =
  match vb.Typedtree.vb_expr.Typedtree.exp_desc with
  | Texp_function (params, body) ->
      let name, kind =
        match simple_name vb.Typedtree.vb_pat with
        | Some n -> (n, Observation.Fn_named)
        | None -> ("anon", Observation.Fn_anonymous)
      in
      define st ~scope ~inside ~name ~kind ~loc:vb.Typedtree.vb_loc params body ;
      (0, false)
  | _ -> decisions st scope inside vb.Typedtree.vb_expr

and decisions
    (st : st)
    (scope : string)
    (inside : bool)
    (e : Typedtree.expression) : int * bool =
  match e.Typedtree.exp_desc with
  | Texp_function (params, body) ->
      define
        st
        ~scope
        ~inside
        ~name:"anon"
        ~kind:Observation.Fn_anonymous
        ~loc:e.Typedtree.exp_loc
        params
        body ;
      (0, false)
  | Texp_let (_, vbs, body) ->
      List.fold_left
        (fun acc vb -> acc ++ bind_expr st scope inside vb)
        (0, false)
        vbs
      ++ decisions st scope inside body
  | Texp_apply (fn, args) ->
      let extra =
        if ghost e.Typedtree.exp_loc || not (is_short_circuit fn) then 0 else 1
      in
      let acc = (extra, false) ++ decisions st scope inside fn in
      List.fold_left
        (fun acc (_lbl, arg) ->
          match arg with
          | Typedtree.Arg a -> acc ++ decisions st scope inside a
          | Typedtree.Omitted _ -> acc )
        acc
        args
  | Texp_match (scrut, comp_cases, effect_cases, _) ->
      let n1, rest1, u1 = case_parts st scope inside comp_cases in
      let n2, rest2, u2 = case_parts st scope inside effect_cases in
      let n = n1 + n2 in
      let split = if n <= 1 then 0 else n - 1 in
      (split + rest1 + rest2, u1 || u2) ++ decisions st scope inside scrut
  | Texp_try (body, exn_cases, eff_cases) ->
      let h1, u1 = case_handlers st scope inside exn_cases in
      let h2, u2 = case_handlers st scope inside eff_cases in
      (h1 + h2, u1 || u2) ++ decisions st scope inside body
  | Texp_ifthenelse (a, b, opt) -> (
      let extra = if ghost e.Typedtree.exp_loc then 0 else 1 in
      let acc =
        (extra, false)
        ++ decisions st scope inside a
        ++ decisions st scope inside b
      in
      match opt with
      | Some c -> acc ++ decisions st scope inside c
      | None -> acc )
  | Texp_while (cond, body) ->
      let extra = if ghost e.Typedtree.exp_loc then 0 else 1 in
      (extra, false)
      ++ decisions st scope inside cond
      ++ decisions st scope inside body
  | Texp_for (_, _, start, stop, _, body) ->
      let extra = if ghost e.Typedtree.exp_loc then 0 else 1 in
      (extra, false)
      ++ decisions st scope inside start
      ++ decisions st scope inside stop
      ++ decisions st scope inside body
  | Texp_sequence (a, b) ->
      decisions st scope inside a ++ decisions st scope inside b
  | Texp_construct (_, _, args) ->
      List.fold_left
        (fun acc a -> acc ++ decisions st scope inside a)
        (0, false)
        args
  | Texp_tuple el ->
      List.fold_left
        (fun acc (_l, a) -> acc ++ decisions st scope inside a)
        (0, false)
        el
  | Texp_array (_, el) ->
      List.fold_left
        (fun acc a -> acc ++ decisions st scope inside a)
        (0, false)
        el
  | Texp_variant (_, eo) -> (
    match eo with
    | Some a -> decisions st scope inside a
    | None -> (0, false) )
  | Texp_record {fields; extended_expression; _} -> (
      let acc =
        Array.fold_left
          (fun acc (_lbl, def) ->
            match def with
            | Typedtree.Overridden (_, a) -> acc ++ decisions st scope inside a
            | Typedtree.Kept _ -> acc )
          (0, false)
          fields
      in
      match extended_expression with
      | Some a -> acc ++ decisions st scope inside a
      | None -> acc )
  | Texp_field (a, _, _) -> decisions st scope inside a
  | Texp_setfield (a, _, _, b) ->
      decisions st scope inside a ++ decisions st scope inside b
  | Texp_atomic_loc (a, _, _) -> decisions st scope inside a
  | Texp_assert (a, _) -> decisions st scope inside a
  | Texp_lazy a -> decisions st scope inside a
  | Texp_pack m ->
      walk_module st scope inside m ;
      (0, false)
  | Texp_open (od, body) ->
      walk_module st scope inside od.Typedtree.open_expr ;
      decisions st scope inside body
  | Texp_letmodule (_, name, _, m, body) ->
      let n =
        match name.Asttypes.txt with
        | Some s -> s
        | None -> ""
      in
      let scope' = if n = "" then scope else qualify scope n in
      walk_module st scope' inside m ;
      decisions st scope inside body
  | Texp_letexception (_, body) -> decisions st scope inside body
  | Texp_letop {let_; ands; body; _} ->
      let acc = decisions st scope inside let_.Typedtree.bop_exp in
      let acc =
        List.fold_left
          (fun acc b -> acc ++ decisions st scope inside b.Typedtree.bop_exp)
          acc
          ands
      in
      let acc =
        match body.Typedtree.c_guard with
        | Some g when not (ghost g.Typedtree.exp_loc) ->
            acc ++ (1, false) ++ decisions st scope inside g
        | _ -> acc
      in
      acc ++ decisions st scope inside body.Typedtree.c_rhs
  | Texp_ident _
   |Texp_constant _
   |Texp_unreachable
   |Texp_extension_constructor _ ->
      (0, false)
  | Texp_object _
   |Texp_send _
   |Texp_new _
   |Texp_instvar _
   |Texp_setinstvar _
   |Texp_override _ ->
      (0, true)

and walk_module
    (st : st)
    (scope : string)
    (inside : bool)
    (m : Typedtree.module_expr) =
  match m.Typedtree.mod_desc with
  | Tmod_structure s -> walk_items st scope inside s.Typedtree.str_items
  | Tmod_functor (_, body) -> walk_module st scope inside body
  | Tmod_constraint (m, _, _, _) -> walk_module st scope inside m
  | Tmod_apply (a, b, _) ->
      walk_module st scope inside a ;
      walk_module st scope inside b
  | Tmod_apply_unit m -> walk_module st scope inside m
  | Tmod_unpack (e, _) ->
      let _, u = decisions st scope inside e in
      if u
      then
        add_gap
          st
          "packed module contains a construct szaniec-cc/1 does not measure"
          e.Typedtree.exp_loc
  | Tmod_ident _ -> ()

and walk_items
    (st : st)
    (scope : string)
    (inside : bool)
    (items : Typedtree.structure_item list) =
  List.iter
    (fun (i : Typedtree.structure_item) ->
      match i.Typedtree.str_desc with
      | Tstr_value (_, vbs) ->
          List.iter
            (fun vb ->
              let _, u = bind_expr st scope inside vb in
              if u
              then
                add_gap
                  st
                  "expression contains a construct szaniec-cc/1 does not \
                   measure"
                  vb.Typedtree.vb_loc )
            vbs
      | Tstr_module mb ->
          let name =
            match mb.Typedtree.mb_name.Asttypes.txt with
            | Some n -> n
            | None -> ""
          in
          let scope' = if name = "" then scope else qualify scope name in
          walk_module st scope' inside mb.Typedtree.mb_expr
      | Tstr_recmodule mbs ->
          List.iter
            (fun mb ->
              let name =
                match mb.Typedtree.mb_name.Asttypes.txt with
                | Some n -> n
                | None -> ""
              in
              let scope' = if name = "" then scope else qualify scope name in
              walk_module st scope' inside mb.Typedtree.mb_expr )
            mbs
      | Tstr_include inc -> walk_module st scope inside inc.Typedtree.incl_mod
      | Tstr_eval (e, _) ->
          let _, u = decisions st scope inside e in
          if u
          then
            add_gap
              st
              "toplevel expression contains a construct szaniec-cc/1 does not \
               measure"
              e.Typedtree.exp_loc
      | Tstr_class _
       |Tstr_class_type _ ->
          add_gap
            st
            "class definitions are outside szaniec-cc/1"
            i.Typedtree.str_loc
      | Tstr_primitive _
       |Tstr_type _
       |Tstr_typext _
       |Tstr_exception _
       |Tstr_modtype _
       |Tstr_open _
       |Tstr_attribute _ ->
          () )
    items

let prelim_id (unit_name : string) (r : raw) : string =
  match r.kind with
  | Observation.Fn_named ->
      if r.qualname = "" then unit_name else unit_name ^ "." ^ r.qualname
  | Observation.Fn_anonymous ->
      let enc =
        if r.enclosing = "" then unit_name else unit_name ^ "." ^ r.enclosing
      in
      Printf.sprintf "%s#anon@%d:%d" enc r.line r.col

let assign_ids (unit_name : string) (raws : raw list) :
    Observation.function_def list =
  let ordered =
    List.sort
      (fun a b ->
        compare
          (a.path, a.line, a.col, a.qualname)
          (b.path, b.line, b.col, b.qualname) )
      raws
  in
  let groups : (string, int) Hashtbl.t = Hashtbl.create 32 in
  List.iter
    (fun r ->
      let id = prelim_id unit_name r in
      let n =
        match Hashtbl.find_opt groups id with
        | Some k -> k
        | None -> 0
      in
      Hashtbl.replace groups id (n + 1) )
    ordered ;
  let seen : (string, int) Hashtbl.t = Hashtbl.create 32 in
  List.map
    (fun r ->
      let base = prelim_id unit_name r in
      let total = Hashtbl.find groups base in
      let id =
        if total <= 1
        then base
        else
          let n =
            match Hashtbl.find_opt seen base with
            | Some k -> k
            | None -> 0
          in
          Hashtbl.replace seen base (n + 1) ;
          (* Named collisions share a qualifier; the span tells them apart.
             Anonymous identities already contain a span, so a second copy
             gets a stable ordinal. *)
          match r.kind with
          | Observation.Fn_named -> Printf.sprintf "%s@%d:%d" base r.line r.col
          | Observation.Fn_anonymous -> Printf.sprintf "%s~%d" base (n + 1)
      in
      { Observation.fn_id= id
      ; fn_name= r.name
      ; fn_qualname= r.qualname
      ; fn_enclosing= r.enclosing
      ; fn_kind= r.kind
      ; fn_unit= unit_name
      ; fn_provenance= r.provenance
      ; fn_nested= r.nested
      ; fn_path= r.path
      ; fn_line= r.line
      ; fn_col= r.col
      ; fn_end_line= r.end_line
      ; fn_end_col= r.end_col
      ; fn_measure= r.measure } )
    ordered

let measure
    ~(project_root : string)
    ~(source_path : string)
    ~(unit_canonical : string)
    (structure : Typedtree.structure) :
    Observation.function_def list * Observation.gap list =
  let st = {project_root; source_path; unit_canonical; raws= []; gaps= []} in
  walk_items st "" false structure.Typedtree.str_items ;
  let by_gap a b =
    compare
      (a.Observation.gap_code, a.Observation.gap_path, a.Observation.gap_detail)
      (b.Observation.gap_code, b.Observation.gap_path, b.Observation.gap_detail)
  in
  (assign_ids unit_canonical st.raws, List.sort_uniq by_gap st.gaps)
