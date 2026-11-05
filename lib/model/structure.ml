(* Structural facts of a dune project, supplied by ProjectAccess and
   ArchitectureAccess and evaluated by ConformanceEngine. Mirrors
   docs/contracts/check-contract.md. Facts only: no roles, no rules. *)

(* A position inside a project file. [line] and [col] are 1-based. *)
type position =
  { path: string (* relative to the project root *)
  ; line: int
  ; col: int }

type stanza_kind =
  | Library
  | Executable
  | Test

let stanza_kind_name = function
  | Library -> "library"
  | Executable -> "executable"
  | Test -> "test"

(* Which field of the stanza declared the dependency. *)
type dependency_source =
  | Libraries
  | Select (* an alternative of a (select ...) form *)
  | Re_export
  | Pps
  | Ppx_runtime

let dependency_source_name = function
  | Libraries -> "libraries"
  | Select -> "select"
  | Re_export -> "re_export"
  | Pps -> "pps"
  | Ppx_runtime -> "ppx_runtime_libraries"

type dependency =
  { dep_name: string
  ; dep_source: dependency_source
  ; dep_at: position }

(* A construct that can hide or redirect a dependency. [owner] is the
   stanza name, or the directory for directory-level stanzas. *)
type unsupported =
  { construct: string
  ; detail: string
  ; owner: string
  ; owner_kind: string (* "library", "executable", "test", "directory" *)
  ; unsupported_at: position }

(* One library, executable or test name. [executables]/[tests] stanzas
   produce one stanza per name, sharing the dependency list. *)
type stanza =
  { kind: stanza_kind
  ; name: string
  ; public_name: string option
  ; at: position (* position of the name atom *)
  ; deps: dependency list }

type dune_project =
  { project_path: string
  ; lang: (string * position) option (* "3.17" *)
  ; implicit_transitive_deps: (string * position) option }

type project =
  { root: string
  ; dune_projects: dune_project list (* the root project first *)
  ; stanzas: stanza list (* sorted by position *)
  ; unsupported: unsupported list
  ; directories: string list
        (* walked source and data directories, "" is the root *) }

(* A service declared by a .cyrograf contract with rpc methods. *)
type service =
  { service_name: string (* file stem, e.g. "AIAccess" *)
  ; service_source: string (* relative path of the .cyrograf file *)
  ; service_methods: string list }
