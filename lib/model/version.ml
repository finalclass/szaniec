(* Versions of Szaniec's contracts and adapters. Bumped together with the
   contract documents under docs/contracts. *)

let report_format = "szaniec-report/1"

let callgraph_format = "szaniec-callgraph/2"

let complexity_format = "szaniec-complexity/1"

let complexity_metric = "szaniec-cc/1"

let config_format = "szaniec-config/1"

let observation_format = "szaniec-observation/4"

let interpretation_format = "szaniec-interpretation/4"

let adapter_ocaml = "szaniec-ocaml-adapter/1.5.0"

let adapter_well = "szaniec-well-adapter/3.4.0"

let rules = "szaniec-rules/3.1.0"

let coverage_format = "szaniec-coverage/1"

let instrumentation_facade = "szaniec-instrumentation/1"

let coverage_points = "szaniec-points/1"

let coverage_probe = "szaniec-probe/1"

let suggestion_format = "szaniec-suggestions/1"

let suggestion_rubric = "szaniec-suggestion-rubric/1"

let suggestion_cache_format = "szaniec-suggestion-cache/1"

let suggestion_decisions_format = "szaniec-suggestion-decisions/1"

let suggestion_fixture_format = "szaniec-suggestion-fixture/1"

let suggestion_model = "jev-latest"

let default_profile = "well-ocaml-core"

(* The compiler series whose .cmt artifacts this build of the OCaml adapter
   can read. Determined by the compiler-libs linked into szaniec. *)
let supported_compiler_series = "5.4"
