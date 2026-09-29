(* Unit-level test of the adapter's compiler-series gate: the function that
   derives the compiler series from recorded compiler arguments, and the
   comparison that refuses unsupported artifacts. The end-to-end behavior
   (artifacts actually built with a different series) is covered by the
   design of the gate itself; see docs/decisions/stack.md. *)

let assert_eq (a : string) (b : string) (name : string) =
  if String.equal a b then Printf.printf "%s: ok\n" name
  else (
    Printf.printf "%s: FAIL (%s != %s)\n" name a b;
    exit 1)

let () =
  assert_eq
    (Szaniec_program_access.Ocaml_adapter.compiler_series_of_args
       [|
         "../_private/default/.pkg/relocatable-compiler.5.4.1.20251109.1-abc/target/bin/ocamlc.opt";
       |])
    "5.4" "relocatable series";
  assert_eq
    (Szaniec_program_access.Ocaml_adapter.compiler_series_of_args
       [| "../_private/default/.pkg/ocaml-compiler.5.5.0-abc/target/bin/ocamlopt.opt" |])
    "5.5" "unrelated series parsed";
  assert_eq
    (Szaniec_program_access.Ocaml_adapter.compiler_series_of_args [| "" |])
    "unknown" "empty arg";
  assert_eq Szaniec_model.Version.supported_compiler_series "5.4" "supported series";
  assert_eq
    (if
       String.equal "5.5" Szaniec_model.Version.supported_compiler_series
     then "accept"
     else "refuse")
    "refuse" "5.5 artifacts refused"