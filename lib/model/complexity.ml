(* Complexity report. Mirrors docs/contracts/complexity-metric.md.
   Measurement lives in ProgramAccess; this module is the rendered
   inventory, including ownership joined from interpretation. *)

open Observation

type entry =
  { id: string
  ; name: string
  ; qualname: string
  ; kind: string (* "named" | "anonymous" *)
  ; binding: string (* "function" | "rpc" *)
  ; nested: bool
  ; provenance: string
  ; module_path: string
  ; service: string (* "" when the unit has no service *)
  ; ownership: string
  ; path: string
  ; line: int
  ; col: int
  ; end_line: int
  ; end_col: int
  ; complexity: int option
  ; status: string (* "measured" | "unmeasurable" *) }

type t =
  { status: string (* "ok" | "incomplete" *)
  ; policy_name: string
  ; policy_digest: string
  ; approved: bool
  ; snapshot_digest: string
  ; compiler: string
  ; profile: string
  ; program_roots: string list
  ; sort: string
  ; functions: entry list
  ; coverage: file_coverage list
  ; gaps: gap list
  ; exclusions: string list }

let exclusions =
  [ ".mli interfaces (no implementation bodies in this profile)"
  ; ".mlx view files (not implementation bodies in this profile)"
  ; "aliases and partial applications (no function body; not inventoried)"
  ; "external libraries (references, not locally discovered definitions)"
  ; "binding-operator continuations (counted in the enclosing function)"
  ; "compiler-generated branches (ghost locations; not counted)" ]

let provenance_name = function
  | Prov_authored -> "authored"
  | Prov_generated -> "generated"
  | Prov_test -> "test"

let kind_name = function
  | Fn_named -> "named"
  | Fn_anonymous -> "anonymous"

let status_name = function
  | Fn_measured _ -> "measured"
  | Fn_unmeasurable -> "unmeasurable"

let complexity_of = function
  | Fn_measured n -> Some n
  | Fn_unmeasurable -> None

let by_location (a : entry) (b : entry) =
  compare (a.path, a.line, a.col, a.id) (b.path, b.line, b.col, b.id)

(* Unmeasurable entries sort after every measured one. *)
let by_complexity (a : entry) (b : entry) =
  match (a.complexity, b.complexity) with
  | Some x, Some y ->
      let c = compare y x in
      if c <> 0 then c else compare a.id b.id
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> compare a.id b.id

let sort_entries (mode : string) (entries : entry list) : entry list =
  match mode with
  | "complexity" -> List.sort by_complexity entries
  | _ -> List.sort by_location entries

let measured_count (entries : entry list) : int =
  List.length
    (List.filter (fun (e : entry) -> String.equal e.status "measured") entries)

let unmeasurable_count (entries : entry list) : int =
  List.length
    (List.filter
       (fun (e : entry) -> String.equal e.status "unmeasurable")
       entries )

let max_complexity (entries : entry list) : int option =
  List.fold_left
    (fun acc e ->
      match e.complexity with
      | None -> acc
      | Some n -> (
        match acc with
        | None -> Some n
        | Some m -> Some (max m n) ) )
    None
    entries
