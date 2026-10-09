(* OCaml ProgramAccess adapter.

   Extracts normalized program facts from compiler-typed artifacts (.cmt)
   produced by dune for the inspected project. See
   docs/contracts/observation-schema.md and docs/decisions/stack.md.

   The adapter reports facts only; architectural meaning is decided by the
   InterpretationEngine. Supported artifacts: OCaml
   [Szaniec_model.Version.supported_compiler_series] .cmt files. *)

module Measurement = Complexity
open Szaniec_model

let ( // ) = Filename.concat

(* ── filesystem scanning ─────────────────────────────────────────── *)

let skip_dir_names = ["_build"; "node_modules"]

let rec scan
    (base : string)
    (rel : string)
    (pred : string -> bool)
    (acc : string list ref)
    (hidden : bool) =
  let dir = if rel = "" then base else base // rel in
  try
    let entries = Sys.readdir dir in
    Array.iter
      (fun e ->
        if e = "." || e = ".."
        then ()
        else if (not hidden) && String.length e > 0 && e.[0] = '.'
        then ()
        else if List.mem e skip_dir_names
        then ()
        else if Sys.is_directory (dir // e)
        then scan base (if rel = "" then e else rel // e) pred acc hidden
        else if pred e
        then acc := (if rel = "" then e else rel // e) :: !acc )
      entries
  with
  | Sys_error _ -> ()

let scan_sources (project_root : string) (roots : string list) : string list =
  let acc = ref [] in
  List.iter
    (fun root ->
      if Sys.file_exists (project_root // root)
      then
        scan
          project_root
          root
          (fun e -> Filename.check_suffix e ".ml")
          acc
          false )
    roots ;
  List.sort_uniq compare !acc

let scan_artifacts (project_root : string) : string list =
  let acc = ref [] in
  scan project_root "_build" (fun e -> Filename.check_suffix e ".cmt") acc true ;
  List.filter
    (fun p -> String.length p > 15 && String.sub p 0 15 = "_build/default/")
    !acc
  |> List.sort compare

let strip_build_prefix (p : string) : string =
  let prefix = "_build/default/" in
  if
    String.length p > String.length prefix
    && String.sub p 0 (String.length prefix) = prefix
  then
    String.sub p (String.length prefix) (String.length p - String.length prefix)
  else p

(* ── identity helpers ─────────────────────────────────────────────── *)

let obj_lib_name (rel_build_path : string) : string =
  let segs = String.split_on_char '/' rel_build_path in
  let rec go = function
    | [] -> "unknown"
    | seg :: rest ->
        if String.length seg > 2 && String.sub seg 0 1 = "."
        then
          if Filename.check_suffix seg ".objs"
          then String.sub seg 1 (String.length seg - 6)
          else if Filename.check_suffix seg ".eobjs"
          then String.sub seg 1 (String.length seg - 7)
          else go rest
        else go rest
  in
  go segs

let find_substring (s : string) (sub : string) : int option =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n
    then None
    else if String.sub s i m = sub
    then Some i
    else go (i + 1)
  in
  go 0

let compiler_series_of_args (args : string array) : string =
  if Array.length args = 0
  then "unknown"
  else
    match find_substring args.(0) "compiler." with
    | None -> "unknown"
    | Some i -> (
        let rest =
          String.sub args.(0) (i + 9) (String.length args.(0) - i - 9)
        in
        let rec take acc j =
          if j >= String.length rest
          then acc
          else
            let ch = rest.[j] in
            if (ch >= '0' && ch <= '9') || ch = '.'
            then take (acc ^ String.make 1 ch) (j + 1)
            else acc
        in
        let v = take "" 0 in
        match String.split_on_char '.' v with
        | major :: minor :: _ -> major ^ "." ^ minor
        | _ -> "unknown" )

(* [true] when the source file is not older than the artifact. The typed
   tree records the preprocessed source (pp.ml), so content digests cannot
   verify freshness against the original source; dune's dependency tracking
   plus an mtime comparison give the safe direction: an artifact older than
   its source is stale, a touch without content change reports stale too
   (rebuild clears it) and stale evidence is never used as current. *)
let fresher_or_equal (source : string) (artifact : string) : bool =
  try
    (Unix.stat source).Unix.st_mtime <= (Unix.stat artifact).Unix.st_mtime
  with
  | Unix.Unix_error _ ->
      false (* disappeared mid-scan (e.g. concurrent build) *)

(* Map the source file recorded in the artifact back to the project source:
   dune pp targets are [x.pp.ml] (from [x.ml]) and [x.mlx.pp.ml] (from
   [x.mlx]). Returns [Some path] for a plain-ML source and [None] for units
   derived from another file type (e.g. .mlx view files, a declared profile
   exclusion). *)
let real_source (sourcefile : string) : string option =
  if Filename.check_suffix sourcefile ".mlx.pp.ml"
  then None
  else if Filename.check_suffix sourcefile ".pp.ml"
  then Some (String.sub sourcefile 0 (String.length sourcefile - 6) ^ ".ml")
  else Some sourcefile

let sha256_hex (s : string) : string =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string s)

let read_file (path : string) : string =
  try
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic ;
    s
  with
  | Sys_error _ -> ""

let normalize_fname ~(project_root : string) (fname : string) : string =
  if Filename.is_relative fname
  then fname
  else
    let root = String.length project_root in
    if
      String.length fname > root
      && String.sub fname 0 root = project_root
      && fname.[root] = '/'
    then String.sub fname (root + 1) (String.length fname - root - 1)
    else fname

let site_of_loc ~(project_root : string) (loc : Location.t) : Observation.site =
  let start = loc.Location.loc_start in
  { Observation.site_path= normalize_fname ~project_root start.Lexing.pos_fname
  ; line= start.Lexing.pos_lnum
  ; col= start.Lexing.pos_cnum - start.Lexing.pos_bol }

(* ── typed tree walk ──────────────────────────────────────────────── *)

type facts =
  { mutable calls: Observation.call list
  ; mutable vrefs: Observation.value_ref list
  ; mutable trefs: Observation.type_ref list
  ; mutable symbols: (string * string) list
  ; mutable unsupported: Observation.site list
  ; mutable flows: Observation.exec_paths list }

(* Executable alternatives of one expression. Above [max_path_alts] the
   function is ambiguous: use-case and queue fan-out rules then gap
   instead of guessing. *)
let max_path_alts = 48

type flow =
  { alts: Observation.path_step list list
  ; ambiguous: bool }

let flow_empty = {alts= [[]]; ambiguous= false}

let flow_ambiguous = {alts= []; ambiguous= true}

let flow_one (step : Observation.path_step) = {alts= [[step]]; ambiguous= false}

let flow_has_call (f : flow) : bool = List.exists (fun alt -> alt <> []) f.alts

let flow_union (a : flow) (b : flow) : flow =
  if a.ambiguous || b.ambiguous
  then flow_ambiguous
  else
    let alts = a.alts @ b.alts in
    if List.length alts > max_path_alts
    then flow_ambiguous
    else {alts; ambiguous= false}

let flow_seq (a : flow) (b : flow) : flow =
  if a.ambiguous || b.ambiguous
  then flow_ambiguous
  else
    let n = List.length a.alts * List.length b.alts in
    if n > max_path_alts
    then flow_ambiguous
    else
      { alts=
          List.concat_map
            (fun left -> List.map (fun right -> left @ right) b.alts)
            a.alts
      ; ambiguous= false }

let flow_seqs (fs : flow list) : flow = List.fold_left flow_seq flow_empty fs

let union_all (fs : flow list) : flow =
  match fs with
  | [] -> flow_empty
  | f :: rest -> List.fold_left flow_union f rest

let step_key (s : Observation.path_step) =
  ( s.Observation.step_callee
  , s.Observation.step_resolution
  , s.Observation.step_site.Observation.site_path
  , s.Observation.step_site.Observation.line
  , s.Observation.step_site.Observation.col )

let normalize_flow (f : flow) : flow =
  if f.ambiguous
  then flow_ambiguous
  else
    let alts =
      List.map
        (fun alt -> List.sort (fun a b -> compare (step_key a) (step_key b)) alt)
        f.alts
      |> List.sort (fun a b ->
          compare (List.map step_key a) (List.map step_key b) )
    in
    {alts; ambiguous= false}

let same_flow (a : Observation.exec_paths) (b : Observation.exec_paths) : bool =
  String.equal a.Observation.paths_unit b.Observation.paths_unit
  && String.equal a.Observation.paths_caller b.Observation.paths_caller

let add_flow
    (unit_canonical : string)
    (facts : facts)
    (caller : string)
    (f : flow) =
  let f = normalize_flow f in
  let fresh =
    { Observation.paths_unit= unit_canonical
    ; paths_caller= caller
    ; alternatives= f.alts
    ; ambiguous= f.ambiguous }
  in
  match List.find_opt (same_flow fresh) facts.flows with
  | None -> facts.flows <- fresh :: facts.flows
  | Some prev ->
      let merged =
        if prev.Observation.ambiguous || fresh.Observation.ambiguous
        then {prev with Observation.alternatives= []; ambiguous= true}
        else
          let alts =
            prev.Observation.alternatives @ fresh.Observation.alternatives
          in
          if List.length alts > max_path_alts
          then {prev with Observation.alternatives= []; ambiguous= true}
          else {prev with Observation.alternatives= alts}
      in
      facts.flows <-
        merged :: List.filter (fun p -> not (same_flow fresh p)) facts.flows

type ctx =
  { project_root: string
  ; unit_canonical: string
  ; lib_cap: string
  ; defined: (Ident.t, unit) Hashtbl.t
  ; aliases: (string, string) Hashtbl.t
  ; mutable def_loc: Location.t }

type resolution =
  [ `Canonical of string
  | `LocalVar
  | `Dynamic ]

let canonicalize (c : ctx) (p : Path.t) : resolution =
  let rec go (acc : string list) (p : Path.t) : (Ident.t * string list) option =
    match p with
    | Pident id -> Some (id, acc)
    | Pdot (p, s) -> go (s :: acc) p
    | Pextra_ty (p, _) -> go acc p
    | Papply _ -> None
  in
  match go [] p with
  | None -> `Dynamic
  | Some (root, rest) ->
      if (not (Ident.persistent root)) && not (Ident.global root)
      then
        if Hashtbl.mem c.defined root
        then
          (* Structure-level [module Alias = Path] resolves to Path.
             A nested alias recorded on a later segment resolves the same
             way. Anything else stays a member of this compilation unit. *)
          let name = Ident.name root in
          let aliased target more =
            if more = []
            then `Canonical target
            else `Canonical (target ^ "." ^ String.concat "." more)
          in
          if Hashtbl.mem c.aliases name
          then aliased (Hashtbl.find c.aliases name) rest
          else
            match rest with
            | name2 :: more when Hashtbl.mem c.aliases name2 ->
                aliased (Hashtbl.find c.aliases name2) more
            | _ ->
                `Canonical
                  (String.concat "." (c.unit_canonical :: name :: rest))
        else `LocalVar
      else
        `Canonical
          (Canonical.of_ref
             ~unit_canonical:c.unit_canonical
             ~lib_cap:c.lib_cap
             (Ident.name root :: rest) )

let add_defined (c : ctx) (id : Ident.t) =
  if (not (Ident.persistent id)) && not (Ident.global id)
  then Hashtbl.replace c.defined id ()

let rec collect_pat_vars
    (p : 'k Typedtree.general_pattern)
    (acc : Ident.t list ref) =
  match p.Typedtree.pat_desc with
  | Tpat_var (id, _, _) -> acc := id :: !acc
  | Tpat_alias (q, id, _, _, _) ->
      collect_pat_vars q acc ;
      acc := id :: !acc
  | Tpat_tuple ps -> List.iter (fun (_l, q) -> collect_pat_vars q acc) ps
  | Tpat_construct (_, _, ps, _) ->
      List.iter (fun q -> collect_pat_vars q acc) ps
  | Tpat_variant (_, q, _) -> (
    match q with
    | Some q -> collect_pat_vars q acc
    | None -> () )
  | Tpat_record (fs, _) ->
      List.iter (fun (_l, _ld, q) -> collect_pat_vars q acc) fs
  | Tpat_array (_, ps) -> List.iter (fun q -> collect_pat_vars q acc) ps
  | Tpat_lazy q -> collect_pat_vars q acc
  | Tpat_or (a, b, _) ->
      collect_pat_vars a acc ;
      collect_pat_vars b acc
  | _ -> ()

let rec pre_collect (c : ctx) (items : Typedtree.structure_item list) =
  List.iter
    (fun (i : Typedtree.structure_item) ->
      match i.str_desc with
      | Tstr_value (_, vbs) ->
          List.iter
            (fun vb ->
              let acc = ref [] in
              collect_pat_vars vb.Typedtree.vb_pat acc ;
              List.iter (add_defined c) !acc )
            vbs
      | Tstr_module mb -> (
          ( match mb.Typedtree.mb_id with
          | Some id -> add_defined c id
          | None -> () ) ;
          match mb.Typedtree.mb_expr.Typedtree.mod_desc with
          | Tmod_ident (p, _) -> (
            match canonicalize c p with
            | `Canonical target -> (
              match mb.Typedtree.mb_id with
              | Some id -> Hashtbl.replace c.aliases (Ident.name id) target
              | None -> () )
            | _ -> () )
          | Tmod_structure s -> (
            match mb.Typedtree.mb_id with
            | Some id ->
                let sub =
                  {c with unit_canonical= c.unit_canonical ^ "." ^ Ident.name id}
                in
                pre_collect sub s.str_items
            | None -> () )
          | _ -> () )
      | Tstr_recmodule mbs ->
          List.iter
            (fun mb ->
              ( match mb.Typedtree.mb_id with
              | Some id -> add_defined c id
              | None -> () ) ;
              match mb.Typedtree.mb_expr.Typedtree.mod_desc with
              | Tmod_structure s -> (
                match mb.Typedtree.mb_id with
                | Some id ->
                    let sub =
                      { c with
                        unit_canonical= c.unit_canonical ^ "." ^ Ident.name id
                      }
                    in
                    pre_collect sub s.str_items
                | None -> () )
              | _ -> () )
            mbs
      | Tstr_include inc -> (
        match inc.incl_mod.Typedtree.mod_desc with
        | Tmod_structure s -> pre_collect c s.str_items
        | _ -> () )
      | _ -> () )
    items

let rec walk_core_type
    (c : ctx)
    (facts : facts)
    (caller : string)
    (t : Typedtree.core_type) =
  match t.Typedtree.ctyp_desc with
  | Ttyp_constr (p, _, args) ->
      ( match canonicalize c p with
      | `Canonical target ->
          facts.trefs <-
            { Observation.tref_unit= c.unit_canonical
            ; tref_caller= caller
            ; tref_target= target
            ; tref_site=
                site_of_loc ~project_root:c.project_root t.Typedtree.ctyp_loc }
            :: facts.trefs
      | _ -> () ) ;
      List.iter (walk_core_type c facts caller) args
  | Ttyp_arrow (_, a, b) ->
      walk_core_type c facts caller a ;
      walk_core_type c facts caller b
  | Ttyp_tuple ts ->
      List.iter (fun (_l, t) -> walk_core_type c facts caller t) ts
  | Ttyp_alias (t, _) -> walk_core_type c facts caller t
  | Ttyp_poly (_, t) -> walk_core_type c facts caller t
  | _ -> ()

let walk_pat
    (type k)
    (c : ctx)
    (facts : facts)
    (caller : string)
    (p : k Typedtree.general_pattern) =
  (* Type references are taken from this pattern node's constraint extra.
     Sub-patterns are not descended (documented coverage). *)
  List.iter
    (fun (extra, _loc, _attrs) ->
      match extra with
      | Typedtree.Tpat_constraint t -> walk_core_type c facts caller t
      | _ -> () )
    p.Typedtree.pat_extra

let fallback_loc (c : ctx) (e : Typedtree.expression) (loc : Location.t) :
    Location.t =
  let pos = loc.Location.loc_start in
  if pos.Lexing.pos_fname = "" || pos.Lexing.pos_lnum <= 0
  then
    let p2 = e.exp_loc.Location.loc_start in
    if p2.Lexing.pos_fname = "" || p2.Lexing.pos_lnum <= 0
    then c.def_loc
    else e.exp_loc
  else loc

let rec record_call
    (c : ctx)
    (facts : facts)
    (caller : string)
    (callee : Path.t)
    (resolution : Observation.resolution)
    (loc : Location.t)
    (args : Observation.call_arg list) : Observation.path_step =
  let site = site_of_loc ~project_root:c.project_root loc in
  match canonicalize c callee with
  | `Canonical target ->
      facts.calls <-
        { Observation.call_unit= c.unit_canonical
        ; caller
        ; callee= target
        ; resolution
        ; site
        ; args }
        :: facts.calls ;
      { step_callee= target
      ; step_resolution= resolution
      ; step_site= site
      ; step_args= args }
  | _ ->
      (* Keep the reason the walker already decided. A local variable is
         not a canonical path, but it is not an arbitrary dynamic
         expression either. *)
      let resolution =
        if resolution = Observation.Resolved
        then Observation.Unresolved_dynamic
        else resolution
      in
      facts.calls <-
        { Observation.call_unit= c.unit_canonical
        ; caller
        ; callee= ""
        ; resolution
        ; site
        ; args }
        :: facts.calls ;
      { step_callee= ""
      ; step_resolution= resolution
      ; step_site= site
      ; step_args= args }

and record_ref
    (c : ctx)
    (facts : facts)
    (caller : string)
    (target : Path.t)
    (loc : Location.t) =
  match canonicalize c target with
  | `Canonical target ->
      facts.vrefs <-
        { Observation.ref_unit= c.unit_canonical
        ; ref_caller= caller
        ; ref_target= target
        ; ref_site= site_of_loc ~project_root:c.project_root loc }
        :: facts.vrefs
  | _ -> ()

and walk_expr
    (c : ctx)
    (facts : facts)
    (caller : string)
    (e : Typedtree.expression) : flow =
  let push_unresolved resolution loc args =
    let site =
      site_of_loc ~project_root:c.project_root (fallback_loc c e loc)
    in
    facts.calls <-
      { Observation.call_unit= c.unit_canonical
      ; caller
      ; callee= ""
      ; resolution
      ; site
      ; args }
      :: facts.calls ;
    { Observation.step_callee= ""
    ; step_resolution= resolution
    ; step_site= site
    ; step_args= args }
  in
  match e.Typedtree.exp_desc with
  | Texp_apply (tfun0, outer_args) ->
      let rec collapse t acc =
        match t.Typedtree.exp_desc with
        | Texp_apply (tfun, inner) -> collapse tfun (inner @ acc)
        | _ -> (t, acc)
      in
      let tfun, args = collapse tfun0 outer_args in
      let label_of = function
        | Asttypes.Nolabel -> ""
        | Asttypes.Labelled name
         |Asttypes.Optional name ->
            name
      in
      let arg_flows = ref [] in
      let metas = ref [] in
      List.iter
        (fun (lbl, arg) ->
          let label = label_of lbl in
          match arg with
          | Typedtree.Omitted _ -> ()
          | Typedtree.Arg a -> (
            match a.Typedtree.exp_desc with
            | Texp_ident (p, loc, _d) -> (
              match canonicalize c p with
              | `Canonical target ->
                  record_ref c facts caller p loc.loc ;
                  metas :=
                    { Observation.arg_label= label
                    ; arg_target= target
                    ; arg_literal= "" }
                    :: !metas
              | `LocalVar
               |`Dynamic ->
                  metas :=
                    { Observation.arg_label= label
                    ; arg_target= ""
                    ; arg_literal= "" }
                    :: !metas )
            | Texp_constant (Const_string (literal, _, _)) ->
                metas :=
                  { Observation.arg_label= label
                  ; arg_target= ""
                  ; arg_literal= literal }
                  :: !metas
            | _ -> arg_flows := walk_expr c facts caller a :: !arg_flows ) )
        args ;
      let args_meta = List.rev !metas in
      let nested = flow_seqs (List.rev !arg_flows) in
      let call_flow =
        match tfun.Typedtree.exp_desc with
        | Texp_ident (p, loc, _d) -> (
          match canonicalize c p with
          | `Canonical _ ->
              flow_one
                (record_call
                   c
                   facts
                   caller
                   p
                   Observation.Resolved
                   loc.loc
                   args_meta )
          | `LocalVar ->
              flow_one
                (record_call
                   c
                   facts
                   caller
                   p
                   Observation.Unresolved_local
                   (fallback_loc c e loc.loc)
                   args_meta )
          | `Dynamic ->
              flow_one
                (record_call
                   c
                   facts
                   caller
                   p
                   Observation.Unresolved_dynamic
                   (fallback_loc c e loc.loc)
                   args_meta ) )
        | Texp_field _ ->
            flow_one
              (push_unresolved
                 Observation.Unresolved_field
                 tfun.Typedtree.exp_loc
                 args_meta )
        | _ ->
            let inner = walk_expr c facts caller tfun in
            flow_seq
              inner
              (flow_one
                 (push_unresolved
                    Observation.Unresolved_dynamic
                    tfun.Typedtree.exp_loc
                    args_meta ) )
      in
      flow_seq nested call_flow
  | Texp_ident (p, loc, _d) -> (
    match canonicalize c p with
    | `Canonical _ ->
        record_ref c facts caller p loc.loc ;
        flow_empty
    | `LocalVar
     |`Dynamic ->
        flow_empty )
  | Texp_pack m ->
      walk_module_expr c facts caller m ;
      flow_empty
  | Texp_function (params, body) ->
      List.iter
        (fun fp ->
          match fp.Typedtree.fp_kind with
          | Tparam_pat p -> walk_pat c facts caller p
          | _ -> () )
        params ;
      ( match body with
      | Tfunction_body b -> ignore (walk_expr c facts caller b)
      | Tfunction_cases {cases; _} ->
          List.iter
            (fun k ->
              walk_pat c facts caller k.Typedtree.c_lhs ;
              ignore (walk_expr c facts caller k.Typedtree.c_rhs) )
            cases ) ;
      flow_empty
  | Texp_construct (_, _, args) ->
      flow_seqs (List.map (walk_expr c facts caller) args)
  | Texp_constant _ -> flow_empty
  | Texp_let (_, vbs, body) ->
      let bindings =
        List.map
          (fun vb ->
            walk_pat c facts caller vb.Typedtree.vb_pat ;
            walk_expr c facts caller vb.Typedtree.vb_expr )
          vbs
      in
      flow_seq (flow_seqs bindings) (walk_expr c facts caller body)
  | Texp_match (scrut, comp_cases, val_cases, _) ->
      let case_flow (type k) (kase : k Typedtree.case) =
        walk_pat c facts caller kase.Typedtree.c_lhs ;
        let guard =
          match kase.Typedtree.c_guard with
          | None -> flow_empty
          | Some guard -> walk_expr c facts caller guard
        in
        flow_seq guard (walk_expr c facts caller kase.Typedtree.c_rhs)
      in
      flow_seq
        (walk_expr c facts caller scrut)
        (union_all
           (List.map case_flow comp_cases @ List.map case_flow val_cases) )
  | Texp_try (body, cases, eff_cases) ->
      let body_flow = walk_expr c facts caller body in
      let handlers =
        union_all
          ( List.map (fun k -> walk_expr c facts caller k.Typedtree.c_rhs) cases
          @ List.map
              (fun k -> walk_expr c facts caller k.Typedtree.c_rhs)
              eff_cases )
      in
      if flow_has_call body_flow && flow_has_call handlers
      then flow_ambiguous
      else if flow_has_call handlers
      then handlers
      else body_flow
  | Texp_ifthenelse (cond, yes, no) ->
      let no_flow =
        match no with
        | Some no -> walk_expr c facts caller no
        | None -> flow_empty
      in
      flow_seq
        (walk_expr c facts caller cond)
        (flow_union (walk_expr c facts caller yes) no_flow)
  | Texp_sequence (a, b) ->
      flow_seq (walk_expr c facts caller a) (walk_expr c facts caller b)
  | Texp_record {fields; extended_expression= rest; _} ->
      let field_flows =
        Array.to_list fields
        |> List.filter_map (fun (_lbl, d) ->
            match d with
            | Typedtree.Overridden (_li, expr) ->
                Some (walk_expr c facts caller expr)
            | Typedtree.Kept _ -> None )
      in
      let rest_flow =
        match rest with
        | Some expr -> walk_expr c facts caller expr
        | None -> flow_empty
      in
      flow_seq (flow_seqs field_flows) rest_flow
  | Texp_field (expr, _, _) -> walk_expr c facts caller expr
  | Texp_setfield (expr, _, _, value) ->
      flow_seq (walk_expr c facts caller expr) (walk_expr c facts caller value)
  | Texp_atomic_loc (expr, _, _) -> walk_expr c facts caller expr
  | Texp_array (_, elements) ->
      flow_seqs (List.map (walk_expr c facts caller) elements)
  | Texp_tuple elements ->
      flow_seqs
        (List.map (fun (_lbl, expr) -> walk_expr c facts caller expr) elements)
  | Texp_open (od, body) ->
      walk_module_expr c facts caller od.open_expr ;
      walk_expr c facts caller body
  | Texp_letmodule (_, _, _, m, body) ->
      walk_module_expr c facts caller m ;
      walk_expr c facts caller body
  | Texp_letexception (_, body) -> walk_expr c facts caller body
  | Texp_letop {let_; ands; body; _} ->
      flow_seq
        (flow_seqs
           ( walk_expr c facts caller let_.Typedtree.bop_exp
           :: List.map
                (fun b -> walk_expr c facts caller b.Typedtree.bop_exp)
                ands ) )
        (walk_expr c facts caller body.Typedtree.c_rhs)
  | Texp_variant (_, payload) -> (
    match payload with
    | Some expr -> walk_expr c facts caller expr
    | None -> flow_empty )
  | Texp_lazy expr -> walk_expr c facts caller expr
  | Texp_send _
   |Texp_object _ ->
      facts.unsupported <-
        site_of_loc ~project_root:c.project_root e.exp_loc :: facts.unsupported ;
      flow_ambiguous
  | Texp_while (cond, body) ->
      flow_seq (walk_expr c facts caller cond) (walk_expr c facts caller body)
  | Texp_for (_i, _p, start, stop, _dir, body) ->
      flow_seqs
        [ walk_expr c facts caller start
        ; walk_expr c facts caller stop
        ; walk_expr c facts caller body ]
  | Texp_assert (expr, _) -> walk_expr c facts caller expr
  | Texp_extension_constructor _
   |Texp_unreachable ->
      flow_empty
  | Texp_new _ -> flow_empty
  | Texp_instvar _
   |Texp_setinstvar _
   |Texp_override _ ->
      flow_empty

and walk_as_binding
    (c : ctx)
    (facts : facts)
    (caller : string)
    (e : Typedtree.expression) : flow =
  match e.Typedtree.exp_desc with
  | Texp_function (params, Tfunction_body body) ->
      List.iter
        (fun fp ->
          match fp.Typedtree.fp_kind with
          | Tparam_pat p -> walk_pat c facts caller p
          | _ -> () )
        params ;
      walk_expr c facts caller body
  | Texp_function (params, Tfunction_cases {cases; _}) ->
      List.iter
        (fun fp ->
          match fp.Typedtree.fp_kind with
          | Tparam_pat p -> walk_pat c facts caller p
          | _ -> () )
        params ;
      union_all
        (List.map
           (fun k ->
             walk_pat c facts caller k.Typedtree.c_lhs ;
             let guard =
               match k.Typedtree.c_guard with
               | None -> flow_empty
               | Some guard -> walk_expr c facts caller guard
             in
             flow_seq guard (walk_expr c facts caller k.Typedtree.c_rhs) )
           cases )
  | _ -> walk_expr c facts caller e

and note_unsupported (c : ctx) (facts : facts) (loc : Location.t) =
  facts.unsupported <-
    site_of_loc ~project_root:c.project_root loc :: facts.unsupported

and walk_module_expr
    (c : ctx)
    (facts : facts)
    (caller : string)
    (m : Typedtree.module_expr) =
  match m.mod_desc with
  | Tmod_ident (p, lid) -> (
    match canonicalize c p with
    | `Canonical _ -> record_ref c facts caller p lid.loc
    | `LocalVar
     |`Dynamic ->
        note_unsupported c facts lid.loc )
  | Tmod_structure s -> walk_structure c facts caller s.str_items
  | Tmod_functor (_, body) -> walk_module_expr c facts caller body
  | Tmod_apply (f, a, _) ->
      note_unsupported c facts m.mod_loc ;
      walk_module_expr c facts caller f ;
      walk_module_expr c facts caller a
  | Tmod_apply_unit m ->
      note_unsupported c facts m.mod_loc ;
      walk_module_expr c facts caller m
  | Tmod_unpack (e, _) ->
      note_unsupported c facts m.mod_loc ;
      ignore (walk_expr c facts caller e)
  | Tmod_constraint (m, _, _, _) -> walk_module_expr c facts caller m

and walk_structure
    (c : ctx)
    (facts : facts)
    (outer : string)
    (items : Typedtree.structure_item list) =
  List.iter
    (fun (i : Typedtree.structure_item) ->
      match i.str_desc with
      | Tstr_value (_, vbs) ->
          List.iter
            (fun vb ->
              let name =
                match vb.Typedtree.vb_pat.Typedtree.pat_desc with
                | Tpat_var (id, _, _) -> Ident.name id
                | _ -> "<toplevel>"
              in
              let caller = if outer = "" then name else outer ^ "." ^ name in
              facts.symbols <- (caller, "value") :: facts.symbols ;
              let old_def = c.def_loc in
              c.def_loc <- vb.Typedtree.vb_loc ;
              walk_pat c facts caller vb.Typedtree.vb_pat ;
              let flow = walk_as_binding c facts caller vb.Typedtree.vb_expr in
              add_flow c.unit_canonical facts caller flow ;
              c.def_loc <- old_def )
            vbs
      | Tstr_module mb ->
          let name =
            match mb.Typedtree.mb_name.txt with
            | Some n -> n
            | None -> "<toplevel>"
          in
          let sub = if outer = "" then name else outer ^ "." ^ name in
          facts.symbols <- (sub, "module") :: facts.symbols ;
          walk_module_expr c facts sub mb.Typedtree.mb_expr
      | Tstr_recmodule mbs ->
          List.iter
            (fun mb ->
              let name =
                match mb.Typedtree.mb_name.txt with
                | Some n -> n
                | None -> "<toplevel>"
              in
              let sub = if outer = "" then name else outer ^ "." ^ name in
              facts.symbols <- (sub, "module") :: facts.symbols ;
              walk_module_expr c facts sub mb.Typedtree.mb_expr )
            mbs
      | Tstr_include inc -> walk_module_expr c facts outer inc.incl_mod
      | Tstr_eval (e, _) ->
          let caller = if outer = "" then "<toplevel>" else outer in
          let flow = walk_expr c facts caller e in
          add_flow c.unit_canonical facts caller flow
      | Tstr_modtype mtd -> (
        match mtd.Typedtree.mtd_type with
        | Some mty -> walk_module_type c facts outer mty
        | None -> () )
      | Tstr_primitive vd -> walk_core_type c facts outer vd.Typedtree.val_desc
      | Tstr_type (_, tds) ->
          List.iter
            (fun td ->
              List.iter
                (fun (ct, _vi) -> walk_core_type c facts outer ct)
                td.Typedtree.typ_params )
            tds
      | Tstr_typext _
       |Tstr_exception _
       |Tstr_attribute _
       |Tstr_class _
       |Tstr_class_type _
       |Tstr_open _ ->
          () )
    items

and walk_module_type
    (c : ctx)
    (facts : facts)
    (caller : string)
    (mty : Typedtree.module_type) =
  match mty.mty_desc with
  | Tmty_signature sig_items ->
      List.iter
        (fun (si : Typedtree.signature_item) ->
          match si.sig_desc with
          | Tsig_value vd -> walk_core_type c facts caller vd.Typedtree.val_desc
          | _ -> () )
        sig_items.Typedtree.sig_items
  | Tmty_functor (_, mty) -> walk_module_type c facts caller mty
  | Tmty_with (mty, _) -> walk_module_type c facts caller mty
  | _ -> ()

let walk_unit
    ~(project_root : string)
    ~(lib : string)
    ~(unit_name : string)
    (cmt : Cmt_format.cmt_infos)
    (facts : facts) =
  match cmt.Cmt_format.cmt_annots with
  | Cmt_format.Implementation s ->
      let unit_canonical = Canonical.of_unit_name ~library:lib ~unit_name in
      let c =
        { project_root
        ; unit_canonical
        ; lib_cap= String.capitalize_ascii lib
        ; defined= Hashtbl.create 64
        ; aliases= Hashtbl.create 8
        ; def_loc= Location.none }
      in
      pre_collect c s.str_items ;
      walk_structure c facts "" s.str_items
  | Cmt_format.Interface _
   |Cmt_format.Packed _
   |Cmt_format.Partial_implementation _
   |Cmt_format.Partial_interface _ ->
      ()

(* ── observation driver ───────────────────────────────────────────── *)

let in_scope (roots : string list) (path : string) : bool =
  List.exists
    (fun root ->
      path = root
      || String.length path > String.length root + 1
         && String.sub path 0 (String.length root + 1) = root // "" )
    roots

(* [assume_fresh] marks every existing artifact as current: the caller
   performed a successful rebuild, and dune guarantees content freshness of
   its outputs. Without it, freshness is verified by comparing mtimes. *)
let observe
    ~(project_root : string)
    ~(program_roots : string list)
    ~(assume_fresh : bool)
    () : Observation.t =
  let sources = scan_sources project_root program_roots in
  let artifacts = scan_artifacts project_root in
  let gaps = ref [] in
  let read_infos =
    List.filter_map
      (fun artifact ->
        let rel = strip_build_prefix artifact in
        let lib = obj_lib_name rel in
        match
          try Some (Cmt_format.read_cmt (project_root // artifact)) with
          | _ -> None
        with
        | None ->
            gaps :=
              { Observation.gap_code= "GAP-ARTIFACT-READ"
              ; gap_path= rel
              ; gap_detail= "artifact could not be read" }
              :: !gaps ;
            None
        | Some cmt -> Some (lib, cmt.Cmt_format.cmt_modname, artifact, cmt) )
      artifacts
  in
  (* deduplicate units: byte and native artifacts carry the same facts;
     byte artifacts sort first and win *)
  let units_tbl : (string, string) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun (_lib, modname, artifact, _cmt) ->
      match Hashtbl.find_opt units_tbl modname with
      | Some prev ->
          if Filename.check_suffix prev "/byte/"
          then ()
          else if Filename.check_suffix artifact "/byte/"
          then Hashtbl.replace units_tbl modname artifact
      | None -> Hashtbl.add units_tbl modname artifact )
    read_infos ;
  let units = ref [] in
  let calls = ref [] in
  let vrefs = ref [] in
  let trefs = ref [] in
  let functions = ref [] in
  let measure_gaps = ref [] in
  let measured_paths = ref [] in
  let flows = ref [] in
  let compiler_series = ref "unknown" in
  List.iter
    (fun (lib, modname, artifact, cmt) ->
      let recorded =
        match cmt.Cmt_format.cmt_sourcefile with
        | Some f -> f
        | None -> ""
      in
      match real_source recorded with
      | None -> () (* .mlx-derived unit: declared profile exclusion *)
      | Some source_path ->
          let generated = Filename.check_suffix source_path ".ml-gen" in
          if source_path = "" || not (in_scope program_roots source_path)
          then ()
          else if
            Hashtbl.find_opt units_tbl modname
            |> Option.map (fun a -> not (String.equal a artifact))
            |> Option.value ~default:false
          then ()
          else
            let series = compiler_series_of_args cmt.Cmt_format.cmt_args in
            if !compiler_series = "unknown" then compiler_series := series ;
            if series <> Version.supported_compiler_series
            then
              gaps :=
                { Observation.gap_code= "GAP-UNSUPPORTED-COMPILER"
                ; gap_path= source_path
                ; gap_detail=
                    Printf.sprintf
                      "artifact built with compiler series %s, adapter \
                       supports %s"
                      series
                      Version.supported_compiler_series }
                :: !gaps
            else
              let source_abs = project_root // source_path in
              let source_exists = Sys.file_exists source_abs in
              (* Dune's wrapped-library stub is often recorded as
                 [lib/name.ml-gen] but kept only inside [_build]. There is
                 no project source to go stale against, so the artifact is
                 the inventory source. A wrapper file that does exist in
                 the tree is held to the same mtime check as other sources. *)
              let fresh =
                (generated && not source_exists)
                || source_exists
                   && ( assume_fresh
                      || fresher_or_equal source_abs (project_root // artifact)
                      )
              in
              let unit_canonical =
                Canonical.of_unit_name ~library:lib ~unit_name:modname
              in
              if not fresh
              then
                let detail =
                  if source_exists
                  then "source changed after the artifact was built"
                  else "source file missing"
                in
                (* Wrapper units stay out of the conformance unit list.
                   Their staleness is a coverage fact for the inventory.
                   Fresh wrappers are still measured below. *)
                if generated
                then
                  measure_gaps :=
                    { Observation.gap_code= "GAP-STALE-ARTIFACT"
                    ; gap_path= source_path
                    ; gap_detail= detail }
                    :: !measure_gaps
                else (
                  gaps :=
                    { Observation.gap_code= "GAP-STALE-ARTIFACT"
                    ; gap_path= source_path
                    ; gap_detail= detail }
                    :: !gaps ;
                  units :=
                    { Observation.unit_id= modname
                    ; canonical= unit_canonical
                    ; source_path
                    ; source_header= ""
                    ; source_digest= ""
                    ; artifact_path= artifact
                    ; fresh= false }
                    :: !units )
              else (
                if not generated
                then (
                  let facts =
                    { calls= []
                    ; vrefs= []
                    ; trefs= []
                    ; symbols= []
                    ; unsupported= []
                    ; flows= [] }
                  in
                  walk_unit ~project_root ~lib ~unit_name:modname cmt facts ;
                  gaps :=
                    List.map
                      (fun site ->
                        { Observation.gap_code= "GAP-UNSUPPORTED-CONSTRUCT"
                        ; gap_path= site.Observation.site_path
                        ; gap_detail=
                            Printf.sprintf
                              "construct at line %d cannot be followed by this \
                               adapter"
                              site.Observation.line } )
                      (List.sort_uniq compare facts.unsupported)
                    @ !gaps ;
                  calls := List.rev_append facts.calls !calls ;
                  vrefs := List.rev_append facts.vrefs !vrefs ;
                  trefs := List.rev_append facts.trefs !trefs ;
                  flows := List.rev_append facts.flows !flows ;
                  units :=
                    { Observation.unit_id= modname
                    ; canonical= unit_canonical
                    ; source_path
                    ; source_header=
                        (let ic = open_in_bin source_abs in
                         Fun.protect
                           ~finally:(fun () -> close_in ic)
                           (fun () ->
                             try input_line ic with
                             | End_of_file -> "" ) )
                    ; source_digest= ""
                    ; artifact_path= artifact
                    ; fresh= true }
                    :: !units ) ;
                match cmt.Cmt_format.cmt_annots with
                | Cmt_format.Implementation structure -> (
                  try
                    let fns, mgaps =
                      Measurement.measure
                        ~project_root
                        ~source_path
                        ~unit_canonical
                        structure
                    in
                    functions := List.rev_append fns !functions ;
                    measure_gaps := List.rev_append mgaps !measure_gaps ;
                    measured_paths := source_path :: !measured_paths
                  with
                  | exn ->
                      measure_gaps :=
                        { Observation.gap_code= "GAP-UNMEASURABLE"
                        ; gap_path= source_path
                        ; gap_detail=
                            "complexity walk failed: " ^ Printexc.to_string exn
                        }
                        :: !measure_gaps )
                | Cmt_format.Interface _
                 |Cmt_format.Partial_implementation _
                 |Cmt_format.Partial_interface _
                 |Cmt_format.Packed _ ->
                    (* A partial typedtree means the source did not
                       type-check. Inventing an empty inventory would
                       report that file as measured. *)
                    measure_gaps :=
                      { Observation.gap_code= "GAP-UNMEASURABLE"
                      ; gap_path= source_path
                      ; gap_detail= "typedtree is not a complete implementation"
                      }
                      :: !measure_gaps ) )
    read_infos ;
  (* sources without artifacts *)
  List.iter
    (fun source ->
      if
        not
          (List.exists
             (fun (u : Observation.unit_info) ->
               String.equal u.Observation.source_path source )
             !units )
      then
        gaps :=
          { Observation.gap_code= "GAP-UNOBSERVED-SOURCE"
          ; gap_path= source
          ; gap_detail= "no build artifact found for this source file" }
          :: !gaps )
    sources ;
  let source_files =
    List.map (fun s -> (s, sha256_hex (read_file (project_root // s)))) sources
  in
  let snapshot_digest =
    sha256_hex
      (String.concat "\n" (List.map (fun (p, d) -> p ^ ":" ^ d) source_files))
  in
  let site_key s =
    (s.Observation.site_path, s.Observation.line, s.Observation.col)
  in
  let by_unit (a : Observation.call) (b : Observation.call) =
    compare
      ( a.Observation.call_unit
      , a.Observation.caller
      , a.Observation.callee
      , site_key a.Observation.site )
      ( b.Observation.call_unit
      , b.Observation.caller
      , b.Observation.callee
      , site_key b.Observation.site )
  in
  let by_ref a b =
    compare
      ( a.Observation.ref_unit
      , a.Observation.ref_caller
      , a.Observation.ref_target
      , site_key a.Observation.ref_site )
      ( b.Observation.ref_unit
      , b.Observation.ref_caller
      , b.Observation.ref_target
      , site_key b.Observation.ref_site )
  in
  let by_tref a b =
    compare
      ( a.Observation.tref_unit
      , a.tref_caller
      , a.tref_target
      , site_key a.tref_site )
      ( b.Observation.tref_unit
      , b.tref_caller
      , b.tref_target
      , site_key b.tref_site )
  in
  let by_gap a b =
    compare
      (a.Observation.gap_code, a.Observation.gap_path, a.Observation.gap_detail)
      (b.Observation.gap_code, b.Observation.gap_path, b.Observation.gap_detail)
  in
  let by_fn a b =
    compare
      ( a.Observation.fn_path
      , a.Observation.fn_line
      , a.Observation.fn_col
      , a.Observation.fn_id )
      ( b.Observation.fn_path
      , b.Observation.fn_line
      , b.Observation.fn_col
      , b.Observation.fn_id )
  in
  let functions = List.sort by_fn !functions in
  let gap_status (path : string) : string option =
    let for_path =
      List.filter (fun g -> String.equal g.Observation.gap_path path) !gaps
    in
    if
      List.exists
        (fun g -> g.Observation.gap_code = "GAP-UNOBSERVED-SOURCE")
        for_path
    then Some "unobserved"
    else if
      List.exists
        (fun g -> g.Observation.gap_code = "GAP-STALE-ARTIFACT")
        for_path
    then Some "stale"
    else if
      List.exists
        (fun g -> g.Observation.gap_code = "GAP-ARTIFACT-READ")
        for_path
    then Some "unreadable"
    else if
      List.exists
        (fun g -> g.Observation.gap_code = "GAP-UNSUPPORTED-COMPILER")
        for_path
    then Some "unsupported-compiler"
    else None
  in
  let count_fns path =
    List.length
      (List.filter (fun f -> String.equal f.Observation.fn_path path) functions)
  in
  (* Whole-file measurement failures. A function that contains an
     unmeasurable construct stays on a [measured] file and is listed
     with null complexity; these details mean the file itself has no
     inventory. *)
  let file_unmeasured path =
    List.exists
      (fun g ->
        String.equal g.Observation.gap_path path
        && String.equal g.Observation.gap_code "GAP-UNMEASURABLE"
        && ( String.starts_with ~prefix:"typedtree " g.Observation.gap_detail
           || String.starts_with
                ~prefix:"complexity walk failed"
                g.Observation.gap_detail ) )
      !measure_gaps
  in
  let coverage_of path status provenance =
    { Observation.cov_path= path
    ; cov_provenance= provenance
    ; cov_status= status
    ; cov_functions= (if status = "measured" then count_fns path else 0) }
  in
  let source_coverage =
    List.map
      (fun (path, _digest) ->
        let status =
          match gap_status path with
          | Some s -> s
          | None when file_unmeasured path -> "unmeasurable"
          | None -> "measured"
        in
        coverage_of path status (Measurement.file_provenance path) )
      source_files
  in
  let extra_coverage =
    List.sort_uniq
      compare
      ( !measured_paths
      @ List.map (fun g -> g.Observation.gap_path) !measure_gaps )
    |> List.filter (fun path ->
        not (List.exists (fun (p, _) -> String.equal p path) source_files) )
    |> List.map (fun path ->
        let stale =
          List.exists
            (fun g ->
              g.Observation.gap_code = "GAP-STALE-ARTIFACT"
              && String.equal g.Observation.gap_path path )
            !measure_gaps
        in
        let status =
          if stale
          then "stale"
          else if file_unmeasured path
          then "unmeasurable"
          else "measured"
        in
        coverage_of path status (Measurement.file_provenance path) )
  in
  { Observation.project_root
  ; program_roots
  ; compiler_series= !compiler_series
  ; units=
      List.sort
        (fun a b -> compare a.Observation.canonical b.Observation.canonical)
        !units
  ; calls= List.sort by_unit !calls
  ; exec_paths=
      List.sort
        (fun a b ->
          compare
            (a.Observation.paths_unit, a.Observation.paths_caller)
            (b.Observation.paths_unit, b.Observation.paths_caller) )
        !flows
  ; value_refs= List.sort by_ref !vrefs
  ; type_refs= List.sort by_tref !trefs
  ; functions
  ; coverage=
      List.sort
        (fun a b -> compare a.Observation.cov_path b.Observation.cov_path)
        (source_coverage @ extra_coverage)
  ; source_files
  ; snapshot_digest
  ; gaps= List.sort_uniq by_gap !gaps
  ; measure_gaps= List.sort_uniq by_gap !measure_gaps }
