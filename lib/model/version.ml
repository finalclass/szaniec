(* Versions of Szaniec's output contracts and the measurement adapter.
   Bumped together with the documents under docs/contracts. *)

let check_format = "szaniec-check/2"

let complexity_format = "szaniec-complexity/1"

let complexity_metric = "szaniec-cognitive/1"

let cyclomatic_metric = "szaniec-cc/1"

let observation_format = "szaniec-measurement/1"

let adapter_ocaml = "szaniec-ocaml-adapter/2.0.0"

let check_profile = "well-ocaml"

let complexity_profile = "ocaml-5.4"

(* The compiler series whose .cmt artifacts this build of the OCaml adapter
   can read. Determined by the compiler-libs linked into szaniec. *)
let supported_compiler_series = "5.4"
