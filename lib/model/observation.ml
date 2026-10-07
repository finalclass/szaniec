(* Normalized program observation. Mirrors docs/contracts/observation-schema.md. *)

type site =
  { site_path: string (* relative to project root *)
  ; line: int
  ; col: int }

type resolution =
  | Resolved
  | Unresolved_local
  | Unresolved_field
  | Unresolved_dynamic

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
  ; source_digest: string (* md5 hex from the artifact *)
  ; artifact_path: string
  ; fresh: bool }

type gap =
  { gap_code: string
  ; gap_path: string
  ; gap_detail: string }

type t =
  { project_root: string
  ; program_roots: string list
  ; compiler_series: string (* "5.4" style, or "unknown" *)
  ; units: unit_info list
        (* sorted by canonical path; generated units excluded *)
  ; calls: call list (* sorted *)
  ; exec_paths: exec_paths list (* sorted by unit, caller *)
  ; value_refs: value_ref list (* sorted *)
  ; type_refs: type_ref list (* sorted *)
  ; source_files: (string * string) list (* path, sha256 hex; sorted *)
  ; snapshot_digest: string
  ; gaps: gap list (* sorted *) }
