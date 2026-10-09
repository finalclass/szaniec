# Decision: product stack and supported toolchain versions

Status: accepted for the first delivery.

## Product language: OCaml on dune

The core extraction problem is reading compiler-typed artifacts (`.cmt`)
from the inspected program. OCaml `.cmt` files are marshaled typed trees;
reading them safely requires linking `compiler-libs` of a compatible
compiler version. Implementing Szaniec itself in OCaml on dune:

- gives first-class access to `compiler-libs` for the ProgramAccess adapter,
- keeps a single runtime and build system, so the adapter and the checked
  program can share the same toolchain resolution story,
- produces a single self-contained binary, which fits the intended
  `szaniec check` local CLI.

[Deno/TypeScript](../../AGENTS.md) remains the tool for repository
automation scripts if they appear; no product code is TypeScript. Python
and Node.js were rejected for the product per IMPLEMENTATION.md.

## Compiler version coupling

The OCaml adapter is built against `compiler-libs` of a specific compiler
minor series. Typed trees are unversioned marshaled values, so the adapter
declares the compiler series it can read and refuses others with an
explicit gap (`GAP-UNSUPPORTED-COMPILER`), never a guessed interpretation.

Adapter `szaniec-ocaml-adapter/1.5.0`, supporting artifacts compiled
with **OCaml 5.4.x**. That adapter records path alternatives,
call-argument identities, the `szaniec-cc/1` function inventory,
structure-level module aliases across compilation units and Dune wrappers,
scoped compiler identities, exact defined values, interface freshness,
source-header provenance evidence, and unsupported module constructs.
It also supplies a separate invocation graph with syntactic loop regions,
deferred function bodies and function-valued arguments. Iterator and activation
semantics belong to InterpretationEngine.
Generator-specific interpretation stays in the Well adapter.
Szaniec itself is built with the same series (the dune-managed toolchain
resolves this).

## Investigation evidence

Investigation was done against a real Well checkout and a real Well-shaped
application:

- Well revision inspected:
  `5c573753367f10d7226f5eaedf1adbeacab2c09d` (2026, `finalclass/well`).
- Toolchain used for probes and fixtures: OCaml **5.4.1** (dune pkg
  `relocatable-compiler.5.4.1.20251109.1`), dune **3.24.2**.
- Verified by reading actual `.cmt` files produced by dune:
  - dune emits `.cmt` for library modules by default; executables emit
    implementation `.cmt` only with `(flags (:standard -bin-annot))`.
  - `Cmt_format.cmt_source_digest` equals the MD5 digest of the source
    file; this is used for staleness detection.
  - Applications are typed with resolved paths: contract proxy calls
    (`Task_access.list`), framework calls (`Well.Db.with_conn`,
    `Well.Service.register`), and implementation references
    (`Services.Task_access_impl.spec`) all appear as concrete `Path.t`
    values with source locations.
  - Well's contract mechanism: generated contract modules expose
    `module type IMPL`, `make_spec (module I : IMPL) : Well.Service.spec`,
    a `_service_ref` dispatcher, and per-method proxy functions; callers
    go through the contract module, implementations are registered from
    their own unit via `make_spec`, and `Well.Service.register` binds the
    spec in the composition root.
  - Applications inside a wrapped library with
    `(include_subdirs qualified)` reference submodules through generated
    wrapper units (`App__.Services.Task_access_impl`); outside the
    library they appear as `App.Services.Task_access_impl` style paths.
    The adapter canonicalizes both to one identity (see
    [observation schema](../contracts/observation-schema.md)).
  - Contract proxy internals dispatch through a local variable
    (`(match !_service_ref with Some f -> f ...)`) which is genuinely
    unresolved at the type level; interpretation suppresses this known
    generated-proxy pattern inside policy-declared contract modules.

## Coverage instrumentation

`szaniec coverage` was verified on the same lock: OCaml **5.4.1**
(`5.4.1+relocatable`), dune **3.24.2**, ppxlib **0.38.0**. The points
engine inside the `szaniec.instrumentation` facade is `bisect_ppx_ng`
**3.0.0**. Released `bisect_ppx` 2.8.3 does not solve against this
toolchain: it requires ppxlib older than 0.36 and cmdliner older than
2. The facade's public backend name stays `szaniec.instrumentation`.
MLX is not instrumented. A dune project that does not declare an `mlx`
dialect records that as an exclusion; a declared `mlx` dialect with an
in-scope `.mlx` file is an instrumentation gap.
## Project configuration parser

The native CLI uses OTOML for TOML parsing and serialization. Menhir is
constrained below 20260209: OTOML 1.0.5 uses the incremental parser stack API
removed in that release. The lock pins the compatible 20250912 toolchain.
Configuration syntax and typed input loading belong to CheckClient Config
infrastructure, separate from compiler extraction and conformance judgments.
