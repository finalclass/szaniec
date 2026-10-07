(* Coverage report model (szaniec-coverage/1). Rendering lives in CheckClient. *)

type measurement =
  | Measured of
      { covered: int
      ; total: int
      ; executed: bool }
  | Uninstrumented

type crap =
  | Available of string
  | Unavailable of string

type kind =
  | Function
  | Local
  | Anonymous
  | Toplevel

type func =
  { id: string
  ; path: string
  ; name: string
  ; kind: kind
  ; provenance: string
  ; line: int
  ; col: int
  ; measurement: measurement
  ; complexity: int option
  ; crap: crap }

type gap =
  { code: string
  ; message: string
  ; path: string }

type disposition =
  | Exited of int
  | Signaled of string
  | Unknown

type node =
  { id: string
  ; disposition: disposition
  ; records: int }

type engine =
  { name: string
  ; version: string
  ; kind: string
  ; visits: int option }

type scenario =
  | Passed of int
  | Failed of int
  | Not_run

type status =
  | Complete
  | Incomplete

type report =
  { status: status
  ; scenario: scenario
  ; measurement_window: string
  ; coverage_kind: string
  ; denominator: string
  ; facade: string
  ; engines: engine list
  ; snapshot_digest: string
  ; compiler: string
  ; exclusions: string list
  ; functions: func list
  ; gaps: gap list
  ; nodes: node list
  ; points_covered: int
  ; points_total: int }

let kind_string = function
  | Function -> "function"
  | Local -> "local"
  | Anonymous -> "anonymous"
  | Toplevel -> "toplevel"

let exclusions =
  [ "action-preprocessors"
  ; "class-methods"
  ; "mli-interfaces"
  ; "mlx-dialect"
  ; "not-branch-coverage" ]
