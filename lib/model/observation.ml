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

type call =
  { call_unit: string (* canonical unit path *)
  ; caller: string (* symbol path relative to the unit *)
  ; callee: string (* canonical path; empty for unresolved *)
  ; resolution: resolution
  ; site: site }

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
  ; value_refs: value_ref list (* sorted *)
  ; type_refs: type_ref list (* sorted *)
  ; source_files: (string * string) list (* path, sha256 hex; sorted *)
  ; snapshot_digest: string
  ; gaps: gap list (* sorted *) }
