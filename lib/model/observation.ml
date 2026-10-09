(* Normalized program observation. Mirrors docs/contracts/observation-schema.md. *)

type site =
  { site_path: string (* relative to project root *)
  ; line: int
  ; col: int }

type loop =
  { loop_kind: string
  ; loop_site: site }

type execution_arg =
  { position: int
  ; label: string
  ; target: string }

type execution_definition =
  { symbol: string
  ; definition_site: site
  ; definition_arity: int
  ; definition_initializer: bool }

type resolution =
  | Resolved
  | Unresolved_local
  | Unresolved_field
  | Unresolved_dynamic

type execution_call =
  { execution_caller: string
  ; execution_callee: string
  ; execution_resolution: resolution
  ; execution_site: site
  ; execution_loops: loop list
  ; execution_partial: bool
  ; execution_resumed: bool
  ; execution_supplied: int
  ; execution_args: execution_arg list }

type execution =
  { definitions: execution_definition list
  ; invocations: execution_call list }

let empty_execution = {definitions= []; invocations= []}

type call_arg =
  { arg_label: string (* "" for a positional argument *)
  ; arg_target: string (* canonical path, or "" *)
  ; arg_literal: string (* string literal, or "" *) }

type call =
  { call_unit: string (* canonical unit path *)
  ; caller: string (* symbol path relative to the unit *)
  ; callee: string (* canonical path; empty for unresolved *)
  ; resolution: resolution
  ; site: site
  ; args: call_arg list }

type path_step =
  { step_callee: string
  ; step_resolution: resolution
  ; step_site: site
  ; step_args: call_arg list }

type exec_paths =
  { paths_unit: string
  ; paths_caller: string
  ; alternatives: path_step list list
        (* each inner list co-occurs; empty when ambiguous *)
  ; ambiguous: bool }

type value_ref =
  { ref_unit: string
  ; ref_caller: string
  ; ref_target: string (* canonical path *)
  ; ref_site: site }

type type_ref =
  { tref_unit: string
  ; tref_caller: string
  ; tref_target: string
  ; tref_site: site }

type unit_info =
  { unit_id: string (* compiler unit name *)
  ; canonical: string
  ; source_path: string
  ; source_header: string
  ; source_digest: string (* md5 hex from the artifact *)
  ; artifact_path: string
  ; fresh: bool }

type gap =
  { gap_code: string
  ; gap_path: string
  ; gap_detail: string }

type fn_kind =
  | Fn_named
  | Fn_anonymous

type fn_provenance =
  | Prov_authored
  | Prov_generated
  | Prov_test

type fn_measure =
  | Fn_measured of int
  | Fn_unmeasurable

(* One syntactic function. [fn_qualname] is the name relative to the unit
   (module qualifiers and enclosing functions). Anonymous definitions use
   [fn_name] "anon" and put the parent qualifier in [fn_enclosing]. *)
type function_def =
  { fn_id: string
  ; fn_name: string
  ; fn_qualname: string
  ; fn_enclosing: string
  ; fn_kind: fn_kind
  ; fn_unit: string
  ; fn_provenance: fn_provenance
  ; fn_nested: bool
  ; fn_path: string
  ; fn_line: int
  ; fn_col: int
  ; fn_end_line: int
  ; fn_end_col: int
  ; fn_measure: fn_measure }

(* Per-file inventory coverage. [cov_status] is "measured", "stale",
   "unobserved", "unreadable", "unsupported-compiler", or
   "unmeasurable". [unmeasurable] means the artifact was opened but
   its typedtree is not a complete implementation (or the walk
   failed); individual unmeasurable functions stay on a measured
   file. *)
type file_coverage =
  { cov_path: string
  ; cov_provenance: fn_provenance
  ; cov_status: string
  ; cov_functions: int }

type t =
  { project_root: string
  ; program_roots: string list
  ; compiler_series: string (* "5.4" style, or "unknown" *)
  ; units: unit_info list
        (* sorted by canonical path; generated units excluded *)
  ; calls: call list (* sorted *)
  ; execution: execution
  ; exec_paths: exec_paths list (* sorted by unit, caller *)
  ; value_refs: value_ref list (* sorted *)
  ; module_aliases: (string * string) list
  ; alias_only_units: string list
  ; defined_values: string list
  ; type_refs: type_ref list (* sorted *)
  ; functions: function_def list (* sorted by source, then id *)
  ; coverage: file_coverage list (* sorted by path *)
  ; source_files: (string * string) list (* path, sha256 hex; sorted *)
  ; snapshot_digest: string
  ; gaps: gap list (* sorted; conformance evidence *)
  ; measure_gaps: gap list (* sorted; complexity inventory only *) }
