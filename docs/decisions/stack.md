# Decision: product stack and supported toolchain versions

Status: accepted; revised for the
[dune structural enforcement](dune-structural-enforcement.md) rewrite.

## Product language: OCaml on dune

`szaniec complexity` reads compiler-typed artifacts (`.cmt`) of the inspected
program. They are marshaled typed trees; reading them safely requires linking
`compiler-libs` of a compatible compiler version. Implementing Szaniec in
OCaml on dune gives first-class access to `compiler-libs`, a single runtime
and build system, and a single self-contained binary.

`szaniec check` needs none of this: it reads dune files and `.cyrograf`
contracts with its own small parsers and never runs the compiler. It is in
the same binary because the target project (DG) is OCaml/dune and both
commands are run by the same agents and CI.

[Deno/TypeScript](../../AGENTS.md) is used for repository automation and test
drivers; no product code is TypeScript.

## Compiler version coupling

The measurement adapter is built against `compiler-libs` of one compiler
minor series. Typed trees are unversioned marshaled values, so the adapter
declares the series it can read and refuses others with
`GAP-UNSUPPORTED-COMPILER`, never a guessed measurement.

Adapter `szaniec-ocaml-adapter/2.0.0` reads artifacts compiled with
**OCaml 5.4.x**. Szaniec itself is built with the same series through the
dune-managed toolchain in `dune.lock` (OCaml 5.4.1,
`relocatable-compiler.5.4.1.20251109.1`, dune 3.24.2).

Facts verified on that toolchain and still relied on:

- dune emits `.cmt` for library modules by default; executables emit an
  implementation `.cmt` only with `(flags (:standard -bin-annot))`.
- `Cmt_format.cmt_source_digest` equals the MD5 digest of the compiled input;
  it is used for staleness detection.
- Wrapped libraries name units `Lib__Sub__Module`; the adapter reports them
  as the canonical path `Lib.Sub.Module`.

## Dependencies

Runtime: `compiler-libs.common`, `unix`, `digestif` (SHA-256 for snapshot and
cache identities) and `yojson` (report output). Development: `ocamlformat`
0.29.0, pinned in `dune-project` because formatting is part of `make verify`.

OTOML, Menhir's version constraint, ppxlib and bisect_ppx_ng were removed
with `szaniec.toml` and `szaniec coverage`. `dune.lock` was regenerated with
`dune pkg lock`; the opam-repository revision moved forward, the compiler and
dune versions did not change.
