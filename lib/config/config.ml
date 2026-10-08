(* CheckClient-owned project input infrastructure. *)
open Szaniec_model

type approval =
  { policy_name: string
  ; policy_digest: string }

type check =
  { rebuild: bool
  ; json: bool
  ; out: string option
  ; no_callgraph: bool }

type complexity =
  { rebuild: bool
  ; json: bool
  ; sort: string }

type coverage =
  { scope: string list
  ; build: string list
  ; server: string
  ; scenario: string list
  ; json: bool
  ; out: string option
  ; keep_work: bool
  ; function_inventory: string option }

type suggestions =
  { rebuild: bool
  ; json: bool
  ; experimental: bool
  ; model: string
  ; timeout: int
  ; budget_names: int
  ; budget_pairs: int
  ; budget_responsibility: int
  ; budget_complexity: int
  ; cache: string
  ; no_cache: bool
  ; refresh: bool
  ; provider_fixture: string option
  ; decisions: string
  ; api_candidates: string list }

type t =
  { project_root: string
  ; path: string
  ; document: Otoml.t
  ; policy: Policy.t option
  ; approval: approval option
  ; check: check
  ; complexity: complexity
  ; coverage: coverage option
  ; suggestions: suggestions }

exception Invalid of string

let invalid path message = raise (Invalid (path ^ ": " ^ message))

let table path = function
  | Otoml.TomlTable fields
   |Otoml.TomlInlineTable fields ->
      fields
  | _ -> invalid path "expected a table"

let keys path allowed fields =
  List.iter
    (fun (key, _) ->
      if not (List.mem key allowed)
      then invalid (path ^ "." ^ key) "unknown configuration key" )
    fields

let string path = function
  | Otoml.TomlString s when String.trim s <> "" -> s
  | _ -> invalid path "expected a non-empty string"

let strings path = function
  | Otoml.TomlArray items -> List.map (string path) items
  | _ -> invalid path "expected an array of strings"

let nonempty path values =
  if values = [] then invalid path "must not be empty" else values

let bool path = function
  | Otoml.TomlBoolean b -> b
  | _ -> invalid path "expected a boolean"

let integer path = function
  | Otoml.TomlInteger n when n >= 0 -> n
  | _ -> invalid path "expected a non-negative integer"

let required path get key fields =
  match List.assoc_opt key fields with
  | Some v -> get (path ^ "." ^ key) v
  | None -> invalid (path ^ "." ^ key) "required field is missing"

let optional path get key fields =
  Option.map (get (path ^ "." ^ key)) (List.assoc_opt key fields)

let default path get key value fields =
  Option.value ~default:value (optional path get key fields)

let relative path value =
  if
    (not (Filename.is_relative value))
    || List.mem ".." (String.split_on_char '/' value)
  then invalid path "expected a relative path within the project" ;
  value

let paths path values = List.map (relative path) (nonempty path values)

let section name document = optional "config" table name document

let parse_policy fields =
  let p = "policy" in
  keys p ["name"; "roots"; "approved_shared_modules"; "resources"] fields ;
  let resources =
    match List.assoc_opt "resources" fields with
    | None -> []
    | Some (Otoml.TomlTableArray xs | Otoml.TomlArray xs) ->
        List.map
          (fun x ->
            let rf = table "policy.resources" x in
            keys "policy.resources" ["name"; "api_prefixes"] rf ;
            { Policy.resource_name= required "policy.resources" string "name" rf
            ; api_prefixes=
                required "policy.resources" strings "api_prefixes" rf
                |> nonempty "policy.resources.api_prefixes" } )
          xs
    | _ -> invalid "policy.resources" "expected an array of tables"
  in
  { Policy.name= required p string "name" fields
  ; program_roots= required p strings "roots" fields |> paths "policy.roots"
  ; approved_shared_modules=
      default p strings "approved_shared_modules" [] fields
  ; resources }

let decode ~project_root ~path document =
  let top = table "config" document in
  keys
    "config"
    [ "format"
    ; "policy"
    ; "approval"
    ; "check"
    ; "complexity"
    ; "coverage"
    ; "suggestions" ]
    top ;
  if required "config" string "format" top <> Version.config_format
  then invalid "config.format" ("expected " ^ Version.config_format) ;
  let policy = Option.map parse_policy (section "policy" top) in
  let approval =
    Option.map
      (fun fields ->
        keys "approval" ["policy_name"; "policy_digest"] fields ;
        let digest = required "approval" string "policy_digest" fields in
        if
          String.length digest <> 71
          || (not (String.starts_with ~prefix:"sha256:" digest))
          || not
               (String.for_all
                  (function
                    | '0' .. '9'
                     |'a' .. 'f' ->
                        true
                    | _ -> false )
                  (String.sub digest 7 64) )
        then
          invalid
            "approval.policy_digest"
            "expected sha256:<64 lowercase hex digits>" ;
        { policy_name= required "approval" string "policy_name" fields
        ; policy_digest= digest } )
      (section "approval" top)
  in
  let p = "check" in
  let f = Option.value ~default:[] (section p top) in
  keys p ["rebuild"; "json"; "out"; "no_callgraph"] f ;
  let check =
    { rebuild= default p bool "rebuild" false f
    ; json= default p bool "json" false f
    ; out= optional p string "out" f
    ; no_callgraph= default p bool "no_callgraph" false f }
  in
  let p = "complexity" in
  let f = Option.value ~default:[] (section p top) in
  keys p ["rebuild"; "json"; "sort"] f ;
  let sort = default p string "sort" "location" f in
  if sort <> "location" && sort <> "complexity"
  then invalid "complexity.sort" "expected location or complexity" ;
  let complexity =
    { rebuild= default p bool "rebuild" false f
    ; json= default p bool "json" false f
    ; sort }
  in
  let coverage =
    Option.map
      (fun f ->
        let p = "coverage" in
        keys
          p
          [ "scope"
          ; "build"
          ; "server"
          ; "scenario"
          ; "json"
          ; "out"
          ; "keep_work"
          ; "function_inventory" ]
          f ;
        let build = required p strings "build" f |> nonempty "coverage.build" in
        let base = Filename.basename (List.hd build) in
        if base <> "dune" && not (String.starts_with ~prefix:"dune." base)
        then invalid "coverage.build" "command must start with dune" ;
        if List.length build < 2
        then invalid "coverage.build" "requires a Dune subcommand" ;
        { scope= required p strings "scope" f |> paths "coverage.scope"
        ; build
        ; server= required p string "server" f |> relative "coverage.server"
        ; scenario=
            required p strings "scenario" f |> nonempty "coverage.scenario"
        ; json= default p bool "json" false f
        ; out= optional p string "out" f
        ; keep_work= default p bool "keep_work" false f
        ; function_inventory= optional p string "function_inventory" f } )
      (section "coverage" top)
  in
  let p = "suggestions" in
  let f = Option.value ~default:[] (section p top) in
  keys
    p
    [ "rebuild"
    ; "json"
    ; "experimental"
    ; "model"
    ; "timeout"
    ; "budget_names"
    ; "budget_pairs"
    ; "budget_responsibility"
    ; "budget_complexity"
    ; "cache"
    ; "no_cache"
    ; "refresh"
    ; "provider_fixture"
    ; "decisions"
    ; "api_candidates" ]
    f ;
  let suggestions =
    { rebuild= default p bool "rebuild" false f
    ; json= default p bool "json" false f
    ; experimental= default p bool "experimental" false f
    ; model= default p string "model" Version.suggestion_model f
    ; timeout= default p integer "timeout" 30 f
    ; budget_names= default p integer "budget_names" 12 f
    ; budget_pairs= default p integer "budget_pairs" 6 f
    ; budget_responsibility= default p integer "budget_responsibility" 6 f
    ; budget_complexity= default p integer "budget_complexity" 6 f
    ; cache= default p string "cache" "szaniec/suggestion-cache.json" f
    ; no_cache= default p bool "no_cache" false f
    ; refresh= default p bool "refresh" false f
    ; provider_fixture= optional p string "provider_fixture" f
    ; decisions=
        default p string "decisions" "szaniec/suggestion-decisions.json" f
    ; api_candidates= default p strings "api_candidates" [] f }
  in
  { project_root
  ; path
  ; document
  ; policy
  ; approval
  ; check
  ; complexity
  ; coverage
  ; suggestions }

let resolve_path root path =
  if Filename.is_relative path then Filename.concat root path else path

let discover_root start =
  let start = Unix.realpath start in
  let rec walk dir dune =
    if Sys.file_exists (Filename.concat dir ".git")
    then dir
    else
      let dune =
        if dune = None && Sys.file_exists (Filename.concat dir "dune-project")
        then Some dir
        else dune
      in
      let parent = Filename.dirname dir in
      if parent = dir
      then Option.value ~default:start dune
      else walk parent dune
  in
  walk start None

let load ?project_root ?path () =
  try
    let project_root =
      match project_root with
      | Some root -> Unix.realpath root
      | None -> discover_root (Sys.getcwd ())
    in
    let path =
      resolve_path project_root (Option.value ~default:"szaniec.toml" path)
    in
    match Otoml.Parser.from_file_result path with
    | Error e -> Error (path ^ ": " ^ e)
    | Ok document -> Ok (decode ~project_root ~path document)
  with
  | Invalid e
   |Sys_error e ->
      Error e
  | Unix.Unix_error (e, fn, arg) ->
      Error (fn ^ " " ^ arg ^ ": " ^ Unix.error_message e)

let require_policy config =
  match config.policy with
  | Some policy -> Ok policy
  | None -> Error (config.path ^ ": [policy] is required for this command")

let write_approval config ~policy_name ~policy_digest =
  let document =
    Otoml.update
      config.document
      ["approval"]
      (Some
         (Otoml.TomlTable
            [ ("policy_name", Otoml.TomlString policy_name)
            ; ("policy_digest", Otoml.TomlString policy_digest) ] ) )
  in
  let temporary = ref None in
  try
    let path, oc =
      Filename.open_temp_file
        ~temp_dir:(Filename.dirname config.path)
        ".szaniec-"
        ".toml"
    in
    temporary := Some path ;
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () ->
        output_string oc (Otoml.Printer.to_string document) ;
        output_char oc '\n' ;
        flush oc ) ;
    Unix.chmod path (Unix.stat config.path).Unix.st_perm ;
    Unix.rename path config.path ;
    Ok ()
  with
  | Sys_error e ->
      Option.iter
        (fun p ->
          try Sys.remove p with
          | Sys_error _ -> () )
        !temporary ;
      Error e
  | Unix.Unix_error (e, fn, arg) ->
      Option.iter
        (fun p ->
          try Sys.remove p with
          | Sys_error _ -> () )
        !temporary ;
      Error (fn ^ " " ^ arg ^ ": " ^ Unix.error_message e)
