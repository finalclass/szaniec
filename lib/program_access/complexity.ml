(* Local Cognitive Complexity and cyclomatic complexity.

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
  ; recursive_functions: (int * int, unit) Hashtbl.t
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

type scores =
  { cognitive: int
  ; cyclomatic: int }

let zero = {cognitive= 0; cyclomatic= 0}

let cost cognitive cyclomatic = ({cognitive; cyclomatic}, false)

let ( ++ ) (n, u) (m, v) =
  ( { cognitive= n.cognitive + m.cognitive
    ; cyclomatic= n.cyclomatic + m.cyclomatic }
  , u || v )

let structural loc depth = if ghost loc then 0 else 1 + depth

let authored_case (c : _ Typedtree.case) : bool =
  not (ghost c.Typedtree.c_lhs.Typedtree.pat_loc)

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

let logical_node (e : Typedtree.expression) =
  if ghost e.Typedtree.exp_loc
  then None
  else
    match e.Typedtree.exp_desc with
    | Texp_apply (fn, [(_, Typedtree.Arg left); (_, Typedtree.Arg right)])
      when is_short_circuit fn ->
        let op =
          match applied_desc fn with
          | Some {Types.val_kind= Types.Val_prim prim; _} ->
              prim.Primitive.prim_name
          | _ -> assert false
        in
        Some (op, left, right)
    | _ -> None

let span_key loc =
  (loc.Location.loc_start.Lexing.pos_cnum, loc.Location.loc_end.Lexing.pos_cnum)

(* Resolve call cycles inside recursive binding groups by compiler identity.
   Merely writing [let rec], or calling a different member once, is not a cycle.
   Nested functions have their own bodies and their own recursion scores. *)
let recursive_functions structure =
  let spans = Hashtbl.create 16 in
  let group vbs =
    let functions =
      List.filter_map
        (fun vb ->
          match
            ( vb.Typedtree.vb_pat.Typedtree.pat_desc
            , vb.Typedtree.vb_expr.Typedtree.exp_desc )
          with
          | Tpat_var (id, _, _), Texp_function _ ->
              Some (id, vb.Typedtree.vb_expr)
          | _ -> None )
        vbs
    in
    let graph = Hashtbl.create (List.length functions) in
    List.iter
      (fun (id, expr) ->
        let calls = ref [] in
        let collector =
          { Tast_iterator.default_iterator with
            module_expr= (fun _ _ -> ())
          ; expr=
              (fun self e ->
                match e.Typedtree.exp_desc with
                | Texp_function _ -> ()
                | Texp_apply
                    ({exp_desc= Texp_ident (Path.Pident target, _, _); _}, _)
                  when not (ghost e.Typedtree.exp_loc) ->
                    calls := target :: !calls ;
                    Tast_iterator.default_iterator.expr self e
                | _ -> Tast_iterator.default_iterator.expr self e ) }
        in
        Tast_iterator.default_iterator.expr collector expr ;
        Hashtbl.add graph id !calls )
      functions ;
    List.iter
      (fun (origin, expr) ->
        let seen = Hashtbl.create 8 in
        let rec reaches = function
          | [] -> false
          | id :: _ when Ident.same id origin -> true
          | id :: rest ->
              if Hashtbl.mem seen id
              then reaches rest
              else (
                Hashtbl.add seen id () ;
                reaches
                  (Option.value ~default:[] (Hashtbl.find_opt graph id) @ rest)
                )
        in
        if reaches (Hashtbl.find graph origin)
        then Hashtbl.replace spans (span_key expr.Typedtree.exp_loc) () )
      functions
  in
  let iterator =
    { Tast_iterator.default_iterator with
      structure_item=
        (fun self item ->
          ( match item.Typedtree.str_desc with
          | Tstr_value (Asttypes.Recursive, vbs) -> group vbs
          | _ -> () ) ;
          Tast_iterator.default_iterator.structure_item self item )
    ; expr=
        (fun self expr ->
          ( match expr.Typedtree.exp_desc with
          | Texp_let (Asttypes.Recursive, vbs, _) -> group vbs
          | _ -> () ) ;
          Tast_iterator.default_iterator.expr self expr ) }
  in
  iterator.structure iterator structure ;
  spans

let rec define
    (st : st)
    ~(scope : string)
    ~(inside : bool)
    ~(name : string)
    ~(kind : Observation.fn_kind)
    ~(loc : Location.t)
    ~(recursive : bool)
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
         "function %s contains a construct the complexity metrics do not \
          measure"
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
          else
            Observation.Fn_measured
              { cognitive= (d.cognitive + if recursive then 1 else 0)
              ; cyclomatic= 1 + d.cyclomatic } ) }
    :: st.raws

and measure_body
    (st : st)
    (scope : string)
    (params : Typedtree.function_param list)
    (body : Typedtree.function_body) : scores * bool =
  let acc =
    List.fold_left
      (fun acc (fp : Typedtree.function_param) ->
        match fp.Typedtree.fp_kind with
        | Typedtree.Tparam_optional_default (_, expr) ->
            acc ++ decisions st scope true 0 expr
        | Typedtree.Tparam_pat _ -> acc )
      (zero, false)
      params
  in
  match body with
  | Typedtree.Tfunction_body expr -> acc ++ decisions st scope true 0 expr
  | Typedtree.Tfunction_cases {cases; _} ->
      acc ++ case_split st scope true 0 cases

and case_parts :
    'k. st -> string -> bool -> int -> 'k Typedtree.case list -> scores * bool =
 fun st scope inside depth cases ->
  List.fold_left
    (fun acc (c : _ Typedtree.case) ->
      let acc =
        match c.Typedtree.c_guard with
        | Some e when authored_case c && not (ghost e.Typedtree.exp_loc) ->
            acc ++ cost (1 + depth) 1 ++ decisions st scope inside depth e
        | Some e -> acc ++ decisions st scope inside depth e
        | None -> acc
      in
      acc ++ decisions st scope inside depth c.Typedtree.c_rhs )
    (zero, false)
    cases

and case_split
    (st : st)
    (scope : string)
    (inside : bool)
    (depth : int)
    (cases : _ Typedtree.case list) : scores * bool =
  let n = List.length (List.filter authored_case cases) in
  let active = n > 0 in
  cost (if active then 1 + depth else 0) (max 0 (n - 1))
  ++ case_parts st scope inside (if active then depth + 1 else depth) cases

and case_handlers
    (st : st)
    (scope : string)
    (inside : bool)
    (depth : int)
    (cases : _ Typedtree.case list) : scores * bool =
  List.fold_left
    (fun acc c ->
      let active = authored_case c in
      acc
      ++ cost (if active then 1 + depth else 0) (if active then 1 else 0)
      ++ case_parts st scope inside (if active then depth + 1 else depth) [c] )
    (zero, false)
    cases

and bind_expr
    (st : st)
    (scope : string)
    (inside : bool)
    (depth : int)
    (vb : Typedtree.value_binding) : scores * bool =
  match vb.Typedtree.vb_expr.Typedtree.exp_desc with
  | Texp_function (params, body) ->
      let name, kind =
        match simple_name vb.Typedtree.vb_pat with
        | Some n -> (n, Observation.Fn_named)
        | None -> ("anon", Observation.Fn_anonymous)
      in
      define
        st
        ~scope
        ~inside
        ~name
        ~kind
        ~loc:vb.Typedtree.vb_loc
        ~recursive:
          (Hashtbl.mem
             st.recursive_functions
             (span_key vb.Typedtree.vb_expr.Typedtree.exp_loc) )
        params
        body ;
      (zero, false)
  | _ -> decisions st scope inside depth vb.Typedtree.vb_expr

and decisions
    (st : st)
    (scope : string)
    (inside : bool)
    (depth : int)
    (e : Typedtree.expression) : scores * bool =
  match e.Typedtree.exp_desc with
  | Texp_function (params, body) ->
      define
        st
        ~scope
        ~inside
        ~name:"anon"
        ~kind:Observation.Fn_anonymous
        ~loc:e.Typedtree.exp_loc
        ~recursive:false
        params
        body ;
      (zero, false)
  | Texp_let (_, vbs, body) ->
      List.fold_left
        (fun acc vb -> acc ++ bind_expr st scope inside depth vb)
        (zero, false)
        vbs
      ++ decisions st scope inside depth body
  | Texp_apply (fn, args) -> (
    match logical_node e with
    | Some _ ->
        let previous = ref None in
        let rec logical expr =
          match logical_node expr with
          | Some (op, left, right) ->
              let left_score = logical left in
              let cognitive = if !previous = Some op then 0 else 1 in
              previous := Some op ;
              let right_score = logical right in
              left_score ++ cost cognitive 1 ++ right_score
          | None -> decisions st scope inside depth expr
        in
        logical e
    | None ->
        let extra =
          if ghost e.Typedtree.exp_loc || not (is_short_circuit fn)
          then 0
          else 1
        in
        (* A partial primitive application does not evaluate a boolean choice.
           Retain its legacy cyclomatic count for existing inventory consumers. *)
        let acc = cost 0 extra ++ decisions st scope inside depth fn in
        List.fold_left
          (fun acc (_lbl, arg) ->
            match arg with
            | Typedtree.Arg a -> acc ++ decisions st scope inside depth a
            | Typedtree.Omitted _ -> acc )
          acc
          args )
  | Texp_match (scrut, comp_cases, effect_cases, _) ->
      let n =
        List.length (List.filter authored_case comp_cases)
        + List.length (List.filter authored_case effect_cases)
      in
      let active = (not (ghost e.Typedtree.exp_loc)) && n > 0 in
      let branch_depth = if active then depth + 1 else depth in
      cost (if active then 1 + depth else 0) (max 0 (n - 1))
      ++ decisions st scope inside depth scrut
      ++ case_parts st scope inside branch_depth comp_cases
      ++ case_parts st scope inside branch_depth effect_cases
  | Texp_try (body, exn_cases, eff_cases) ->
      decisions st scope inside depth body
      ++ case_handlers st scope inside depth exn_cases
      ++ case_handlers st scope inside depth eff_cases
  | Texp_ifthenelse _ -> conditional st scope inside depth false e
  | Texp_while (cond, body) ->
      let active = not (ghost e.Typedtree.exp_loc) in
      let nested = if active then depth + 1 else depth in
      cost (structural e.Typedtree.exp_loc depth) (if active then 1 else 0)
      ++ decisions st scope inside nested cond
      ++ decisions st scope inside nested body
  | Texp_for (_, _, start, stop, _, body) ->
      let active = not (ghost e.Typedtree.exp_loc) in
      let nested = if active then depth + 1 else depth in
      cost (structural e.Typedtree.exp_loc depth) (if active then 1 else 0)
      ++ decisions st scope inside nested start
      ++ decisions st scope inside nested stop
      ++ decisions st scope inside nested body
  | Texp_sequence (a, b) ->
      decisions st scope inside depth a ++ decisions st scope inside depth b
  | Texp_construct (_, _, args) ->
      List.fold_left
        (fun acc a -> acc ++ decisions st scope inside depth a)
        (zero, false)
        args
  | Texp_tuple el ->
      List.fold_left
        (fun acc (_l, a) -> acc ++ decisions st scope inside depth a)
        (zero, false)
        el
  | Texp_array (_, el) ->
      List.fold_left
        (fun acc a -> acc ++ decisions st scope inside depth a)
        (zero, false)
        el
  | Texp_variant (_, eo) -> (
    match eo with
    | Some a -> decisions st scope inside depth a
    | None -> (zero, false) )
  | Texp_record {fields; extended_expression; _} -> (
      let acc =
        Array.fold_left
          (fun acc (_lbl, def) ->
            match def with
            | Typedtree.Overridden (_, a) ->
                acc ++ decisions st scope inside depth a
            | Typedtree.Kept _ -> acc )
          (zero, false)
          fields
      in
      match extended_expression with
      | Some a -> acc ++ decisions st scope inside depth a
      | None -> acc )
  | Texp_field (a, _, _) -> decisions st scope inside depth a
  | Texp_setfield (a, _, _, b) ->
      decisions st scope inside depth a ++ decisions st scope inside depth b
  | Texp_atomic_loc (a, _, _) -> decisions st scope inside depth a
  | Texp_assert (a, _) -> decisions st scope inside depth a
  | Texp_lazy a -> decisions st scope inside depth a
  | Texp_pack m ->
      walk_module st scope inside m ;
      (zero, false)
  | Texp_open (od, body) ->
      walk_module st scope inside od.Typedtree.open_expr ;
      decisions st scope inside depth body
  | Texp_letmodule (_, name, _, m, body) ->
      let n =
        match name.Asttypes.txt with
        | Some s -> s
        | None -> ""
      in
      let scope' = if n = "" then scope else qualify scope n in
      walk_module st scope' inside m ;
      decisions st scope inside depth body
  | Texp_letexception (_, body) -> decisions st scope inside depth body
  | Texp_letop {let_; ands; body; _} ->
      let acc = decisions st scope inside depth let_.Typedtree.bop_exp in
      let acc =
        List.fold_left
          (fun acc b ->
            acc ++ decisions st scope inside depth b.Typedtree.bop_exp )
          acc
          ands
      in
      let acc =
        match body.Typedtree.c_guard with
        | Some g when not (ghost g.Typedtree.exp_loc) ->
            acc ++ cost (1 + depth) 1 ++ decisions st scope inside depth g
        | _ -> acc
      in
      acc ++ decisions st scope inside depth body.Typedtree.c_rhs
  | Texp_ident _
   |Texp_constant _
   |Texp_unreachable
   |Texp_extension_constructor _ ->
      (zero, false)
  | Texp_object _
   |Texp_send _
   |Texp_new _
   |Texp_instvar _
   |Texp_setinstvar _
   |Texp_override _ ->
      (zero, true)

and conditional st scope inside depth chained e =
  match e.Typedtree.exp_desc with
  | Texp_ifthenelse (cond, yes, no) -> (
      let active = not (ghost e.Typedtree.exp_loc) in
      let nested = if active then depth + 1 else depth in
      let own = if active then if chained then 1 else 1 + depth else 0 in
      let acc =
        cost own (if active then 1 else 0)
        ++ decisions st scope inside depth cond
        ++ decisions st scope inside nested yes
      in
      match no with
      | Some ({Typedtree.exp_desc= Texp_ifthenelse _; exp_loc; _} as next)
        when not (ghost exp_loc) ->
          acc ++ conditional st scope inside depth true next
      | Some other ->
          acc
          ++ cost (if active then 1 else 0) 0
          ++ decisions st scope inside nested other
      | None -> acc )
  | _ -> decisions st scope inside depth e

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
      let _, u = decisions st scope inside 0 e in
      if u
      then
        add_gap
          st
          "packed module contains a construct the complexity metrics do not \
           measure"
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
              let _, u = bind_expr st scope inside 0 vb in
              if u
              then
                add_gap
                  st
                  "expression contains a construct the complexity metrics do \
                   not measure"
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
          let _, u = decisions st scope inside 0 e in
          if u
          then
            add_gap
              st
              "toplevel expression contains a construct the complexity metrics \
               do not measure"
              e.Typedtree.exp_loc
      | Tstr_class _
       |Tstr_class_type _ ->
          add_gap
            st
            "class definitions are outside the complexity metrics"
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
  let st =
    { project_root
    ; source_path
    ; unit_canonical
    ; recursive_functions= recursive_functions structure
    ; raws= []
    ; gaps= [] }
  in
  walk_items st "" false structure.Typedtree.str_items ;
  let by_gap a b =
    compare
      (a.Observation.gap_code, a.Observation.gap_path, a.Observation.gap_detail)
      (b.Observation.gap_code, b.Observation.gap_path, b.Observation.gap_detail)
  in
  (assign_ids unit_canonical st.raws, List.sort_uniq by_gap st.gaps)
