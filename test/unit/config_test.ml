open Szaniec_model
module Config = Szaniec_config.Config
module Architecture = Szaniec_architecture_access.Architecture_access

let check condition message = if not condition then failwith message

let base =
  {|format = "szaniec-config/1"
[policy]
name = "config-test"
roots = ["lib"]
approved_shared_modules = ["App.Clock"]
[[policy.resources]]
name = "database"
api_prefixes = ["Well.Db."]
|}

let decode text =
  Config.decode
    ~project_root:"/project"
    ~path:"/project/szaniec.toml"
    (Otoml.Parser.from_string text)

let rejects text =
  match decode text with
  | _ -> failwith ("accepted invalid configuration: " ^ text)
  | (exception Config.Invalid _)
   |(exception Otoml.Parse_error _)
   |(exception Otoml.Duplicate_key _) ->
      ()

let policy config =
  match Config.require_policy config with
  | Ok p -> p
  | Error e -> failwith e

let () =
  let config =
    decode
      ( base
      ^ {|
[check]
json = true
out = "graph.json"
no_callgraph = true
[complexity]
sort = "complexity"
[coverage]
scope = ["lib"]
build = ["dune", "build", "bin/main.exe"]
server = "_build/default/bin/main.exe"
scenario = ["deno", "run", "scenario.ts"]
function_inventory = "functions.json"
[suggestions]
experimental = true
model = "fixture-model"
timeout = 7
budget_names = 0
api_candidates = ["List.filter_map"]
|}
      )
  in
  check
    ( config.check.json
    && config.check.no_callgraph
    && config.check.out = Some "graph.json" )
    "check section" ;
  check (config.complexity.sort = "complexity") "complexity section" ;
  check
    ( config.suggestions.experimental
    && config.suggestions.timeout = 7
    && config.suggestions.budget_names = 0
    && config.suggestions.api_candidates = ["List.filter_map"] )
    "suggestions section" ;
  check (Option.is_some config.coverage) "coverage section" ;
  let original = policy config in
  let reformatted =
    decode
      {|# comment
format = 'szaniec-config/1'
policy = { roots = ['lib'], approved_shared_modules = ['App.Clock'], name = 'config-test', resources = [{api_prefixes=['Well.Db.'], name='database'}] }
|}
  in
  check
    (Policy.digest original = Policy.digest (policy reformatted))
    "semantic digest" ;
  check
    ( Policy.digest original
    <> Policy.digest {original with program_roots= ["bin"]} )
    "root edit invalidates approval" ;
  check
    ( Policy.digest original
    <> Policy.digest {original with approved_shared_modules= []} )
    "sharing edit invalidates approval" ;
  check
    (Policy.digest original <> Policy.digest {original with resources= []})
    "resource edit invalidates approval" ;
  let defaults = decode base in
  check
    (Policy.digest (policy defaults) = Policy.digest original)
    "measurements excluded from digest" ;
  check
    ( defaults.suggestions.model = Version.suggestion_model
    && defaults.suggestions.timeout = 30 )
    "defaults" ;
  let _, gap = Result.get_ok (Architecture.resolve ~config:defaults) in
  check (Option.is_some gap) "absent approval stays a gap" ;
  List.iter
    rejects
    [ "format = 'other'"
    ; "format = 'szaniec-config/1'\nextra = 1"
    ; "format = 'szaniec-config/1'\nformat = 'szaniec-config/1'"
    ; "format = 'szaniec-config/1'\n[policy]\nname = 'x'\nroots = []"
    ; "format = 'szaniec-config/1'\n[policy]\nname = 'x'\nroots = ['../escape']"
    ; base ^ "[check]\njson = 'true'"
    ; base ^ "[check]\njsno = true"
    ; base ^ "[suggestions]\nbudget_names = -1"
    ; base ^ "[suggestions]\ntimeout = 1.5"
    ; base ^ "[suggestions]\napi_candidates = ['List.map', 1]"
    ; base ^ "[complexity]\nsort = 'other'"
    ; base
      ^ "[coverage]\n\
         scope=['lib']\n\
         build=['make']\n\
         server='a'\n\
         scenario=['true']"
    ; base
      ^ "[coverage]\n\
         scope=['lib']\n\
         build=['dune','build']\n\
         server='a'\n\
         scenario=[]"
    ; base ^ "[approval]\npolicy_name='x'\npolicy_digest='invalid'" ] ;
  let dir = Filename.temp_file "szaniec-config-" "" in
  Sys.remove dir ;
  Unix.mkdir dir 0o700 ;
  let path = Filename.concat dir "szaniec.toml" in
  Fun.protect
    ~finally:(fun () ->
      Sys.remove path ;
      Unix.rmdir dir )
    (fun () ->
      let oc = open_out path in
      output_string oc (Otoml.Printer.to_string config.document) ;
      close_out oc ;
      let config = Result.get_ok (Config.load ~project_root:dir ()) in
      check
        ( Config.write_approval
            config
            ~policy_name:original.name
            ~policy_digest:(Policy.digest original)
        = Ok () )
        "write approval" ;
      let reloaded = Result.get_ok (Config.load ~project_root:dir ()) in
      check (policy reloaded = original) "approval preserves policy" ;
      check
        ( reloaded.check = config.check
        && reloaded.complexity = config.complexity
        && reloaded.coverage = config.coverage
        && reloaded.suggestions = config.suggestions )
        "approval preserves all command settings" ;
      let resolution, gap =
        Result.get_ok (Architecture.resolve ~config:reloaded)
      in
      check (resolution.approved && gap = None) "approval round trip" ;
      let changed =
        {reloaded with policy= Some {original with name= "edited"}}
      in
      let resolution, gap =
        Result.get_ok (Architecture.resolve ~config:changed)
      in
      check
        ((not resolution.approved) && Option.is_some gap)
        "name change invalidates approval" ) ;
  print_endline "config unit tests passed"
