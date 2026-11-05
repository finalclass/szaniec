(* Measurement observation produced by ProgramAccess for the complexity
   inventory. Mirrors docs/contracts/complexity-metric.md. *)

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
  | Fn_measured of
      { cognitive: int
      ; cyclomatic: int }
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
  ; functions: function_def list (* sorted by source, then id *)
  ; coverage: file_coverage list (* sorted by path *)
  ; snapshot_digest: string
  ; gaps: gap list (* sorted *) }
