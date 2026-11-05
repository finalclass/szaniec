# Trust Dune-managed PPX rewrites

Status: accepted (adapter `szaniec-ocaml-adapter/1.12.0`).

## Context

Before this decision every transformed compiler input needed a local receipt
written by `check --rebuild`. A receipt identity covers the digest of all project
build inputs, so any edit followed by an ordinary build turned every transformed
unit into `GAP-UNVERIFIABLE-TRANSFORMATION`. On the `dg` application this produced
548 such gaps from `ppx_deriving` and `well.ppx` alone. A complete
`--rebuild` check took 22 minutes in one measurement taken while another
test suite was running.

PPX rewriters are not used to introduce calls between services. They do emit
calls that matter for architecture: `well.ppx` expands `let%query` into direct
SQLite access.

## Decision

A library, executable or test stanza whose `preprocess` field is exactly
`(pps ...)` or `(staged_pps ...)` is a Dune-managed rewrite. Dune tracks the
rewriter and its `preprocessor_deps` as build dependencies, so the compiled
`x.pp.ml` is trusted like any other Dune target. A unit is current when the
compiler digest matches `x.pp.ml` and Dune's `_build` copy of the source equals
the authored file. No receipt or `--rebuild` is needed.

Generated code is still analyzed. Skipping it would hide `let%query` resource
access, so rewrites are trusted for freshness only, never excluded from evidence.

The trust does not cover:

- MLX (`.mlx.pp.ml`, `.mlx.ml`). MLX is the client layer, where direct calls to
  Access services must be detected; it keeps receipt evidence.
- action preprocessors and `per_module` specifications;
- transformations applied through compiler `-pp`/`-ppx` flags, which Dune does
  not track as rewriter dependencies.

Stanzas are read with a Dune s-expression lexer that handles quoted strings,
line, block and datum comments. A `;` inside a quoted `system` action must not
hide the following stanza.

## Verification

`test/acceptance/ppx_rewriters.ts` builds the tasks-app fixture with a
compiler-libs PPX driver through an ordinary `dune build` and checks that:

- the external build is current without `--rebuild`;
- an unbuilt authored edit is `GAP-STALE-ARTIFACT`;
- a client-to-access call emitted by the rewriter is `ID-CLIENT-ACCESS`;
- compiler-applied `-pp` still requires a receipt.

On `dg` after an ordinary `make build`, the gaps fell from 636 to 33, all from
MLX units and paths through them.
