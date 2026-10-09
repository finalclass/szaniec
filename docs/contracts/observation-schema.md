# Contract: program observation

Format identifier (conceptual): `szaniec-observation/4`.

ProgramAccess produces one normalized observation per check run. It is an
in-memory contract between the ProgramAccess component and the
InterpretationEngine and ConformanceEngine; the OCaml types in
`lib/model` are the authoritative definition. This document fixes the
meaning of the facts.

## Snapshot identity

- `projectRoot` — the directory the check ran against.
- `programRoots` — copied from policy.
- `sourceFiles` — every in-scope source file with its SHA-256 digest.
- `snapshotDigest` — SHA-256 over the sorted `path:digest` lines.
- `compiler` — artifact compiler series observed from artifacts, and the
  adapter's supported series.

## Units

One entry per observed compilation unit (implementation module):

- `id` — stable unit identifier (the compiler unit name).
- `canonicalPath` — public module path: for a wrapped library `lib`,
  `Lib.Sub.Module`; for a wrapped-false library, `Module.Sub`; for
  executables, `Main` (the `Dune__exe__` prefix is stripped).
- `sourcePath` — path relative to the project root.
- `sourceHeader` — the first source line, without its line terminator, from a
  fresh unit; empty for an empty source or a stale unit. ProgramAccess preserves
  this text without interpreting generator names. InterpretationEngine uses
  recognized generator headers as provenance evidence.
- `sourcePath` — mapped back from the recorded preprocessed source: dune
  pp targets `x.pp.ml` (from `x.ml`) and `x.mlx.pp.ml` (from `x.mlx`);
  units derived from `.mlx` view files are a declared profile exclusion.
- `sourceDigest` — hexadecimal compiler-recorded input digest (MD5 in OCaml
  5.4). It describes the compiler input, which may be preprocessed; it is
  distinct from the SHA-256 source snapshot.
- `artifactPath` — the `.cmt` file used.
- `fresh` — source file exists and is current. With a successful rebuild
  (`--rebuild`, exit 0) freshness is assumed for all artifacts: dune
  guarantees content freshness of its outputs. Without a rebuild,
  plain sources and their current build inputs must match the compiler digest.
  Rewriting or touching identical content does not invalidate those artifacts.
  Explicit interfaces must match their `.cmti` input digest and the implementation's
  interface CRC. Resolvable imported interface CRCs must also remain current;
  missing local dependencies cannot prove freshness. For preprocessed inputs,
  the adapter additionally requires the original source to precede both the
  transformed input and artifact. A transformed digest alone never establishes
  original-source freshness. Unproven transformation evidence requires rebuilding.
  Compiler-applied `-pp`/`-ppx` transformations require a successful rebuild:
  their transformation dependencies are not proven by the recorded input digest.
- `generated` — dune-generated wrapper units (`.ml-gen` sources); they
  are excluded from rules and diagnostics.

Dune wrapper units (`.ml-gen`) are observed for completeness but carry no
ownership or findings; their aliases are retained. `.mli` interfaces contribute
snapshot and freshness evidence, not executable bodies.
`.mlx` view files are not in the supported profile.

## Symbols, calls, references

`moduleAliases` records each structure-level module alias with its full source
and resolved target path, including Dune wrappers and aliases with explicit
module signatures (`module Alias : Signature = Target`). Alias resolution uses the
longest module prefix across compilation units; cycles remain unsupported
evidence. Alias-only units carry a neutral compiler fact, not an architectural
approval. `definedValues` records full paths of typed structure values for
validating exact owned-contract members. The source snapshot includes in-scope
`.cyrograf` and `.mli` inputs as well as implementation sources. A changed
interface without a matching artifact makes the implementation stale; an
unchanged plain interface rewrite preserves its compiler identity.

- `symbols` — values and modules defined per unit, with kind and
  definition location. Names are relative to the unit (`Impl.list`).
- `calls` — one per application site in a defined value:
  - `caller` — defining symbol, or `LET`-expression context name, or the
    unit root for `let () =` bodies.
  - `callee` — canonical path of the resolved callee (module member), or
    the resolution failure class: `unresolved-local` (application of a
    locally bound variable), `unresolved-field` (record field applied),
    `unresolved-dynamic` (anything else).
  - `site` — source path, line, column of the application's callee
    location.
  - `args` — labeled arguments that are resolved module paths or string
    literals, in spine order (inner application first). The label is
    empty for a positional argument. Local and computed arguments are
    kept with an empty path and empty literal so a missing topic is
    visible. Nested calls inside an argument stay ordinary calls.
  - Call spines are resolved through curried applications (`f a @@ b`
    resolves to `f`), never by name pattern matching.
- `execPaths` — per `(unit, caller)`, the executable alternatives of
  that value when it runs. Each alternative is the list of direct
  calls that co-occur on it. `if` and `match` arms are different
  alternatives; a sequence concatenates alternatives (bounded at 48,
  above which the function is `ambiguous` and its alternatives are
  dropped). A `try`/`with` with calls both in the body and in a
  handler is `ambiguous`. Evaluating a function value does not execute
  its body; the body's alternatives belong to that function. These
  paths are the evidence for use-case and queue fan-out rules. They
  do not replace `calls`.
- `valueRefs` — non-call identifier references to module members
  (`M.value` reads and function values passed as callbacks), with site.
  These are executable dependencies: registration evidence,
  implementation access and sharing all see them. A structure-level
  `module Alias = Path` is resolved to `Path` in the recorded callee or
  target. First-class module unpacks and functor applications are not
  resolved; they are `GAP-UNSUPPORTED-CONSTRUCT`.
- `typeRefs` — type-constructor references with site (`Task_access.ListReq.t`).
  Type-only references are contract or data usage. They do not count as
  executable sharing, implementation access or calls.

Calls, valueRefs and typeRefs are sorted by `(unit, caller, callee, site)`
before the observation is consumed, so downstream stages are deterministic.

## Execution context

`execution` retains a separate invocation graph without changing the executable
alternatives used by conformance rules. Definitions have compiler-resolved symbol
identities and source sites, including local functions, anonymous callbacks and
module initializers. Anonymous identities include their source position.
Definitions retain parameter arity (including the final argument bound by
`function` cases) and whether they are module initializers.

Each invocation retains its caller, resolved target or unresolved status, callee
site, positional/labeled function arguments, and enclosing syntactic `for`/`while`
regions. Both a `while` condition and body repeat; `for` bounds do not. Function
and lazy bodies are deferred: defining them inside a loop does not execute them.
Compiler-resolved aliases are normalized before interpretation. The language
adapter records callback arguments without deciding which library invokes them.
Invocations also retain supplied argument counts, a function-valued result flag,
and whether they represent a later invocation of that result. Interpretation can
distinguish partial application from a fully applied function returning a closure;
an unresolved returned closure must not re-execute its factory in the graph.

This evidence describes possible repetition, not actual execution counts. An
unsupported callback or recursion traversal remains unknown rather than being
classified as a single execution.

## Function inventory

`functions` is the syntactic-function inventory measured by
[szaniec-cc/1](complexity-metric.md). Each entry has a deterministic id,
a source span, provenance (`authored`, `generated`, or `test`), and
either a complexity or an unmeasurable status. Nested bodies are
separate entries. Aliases and partial applications are absent.

`coverage` lists every scanned source file and every generated file the
adapter opened, with a status of `measured`, `stale`, `unobserved`,
`unreadable`, `unsupported-compiler`, or `unmeasurable`.
`unmeasurable` means the artifact's typedtree is not a complete
implementation, or the complexity walk failed; the file contributes no
function rows. A measured file may still contain individual functions
whose complexity is null. `measureGaps` records complexity gaps
(`GAP-UNMEASURABLE`, and staleness of generated wrappers). Those gaps
are not conformance findings: `szaniec check` does not read `functions`,
`coverage`, or `measureGaps`.

Dune `.ml-gen` wrappers are measured for the inventory and still excluded
from the conformance unit list.

## Completeness

- A source file in a program root with no artifact →
  `GAP-UNOBSERVED-SOURCE` (the program was not built for analysis).
- Artifact digest ≠ source file digest → `GAP-STALE-ARTIFACT`; the unit is
  never analyzed from stale evidence.
- Artifact compiler series outside the adapter's supported series →
  `GAP-UNSUPPORTED-COMPILER`; the unit is not analyzed.
- Unreadable artifact → `GAP-ARTIFACT-READ`; the unit is not analyzed.
- An unsuccessful requested rebuild → `GAP-BUILD`; any retained findings
  accompany incomplete analysis, never a successful report.

All gaps travel with the observation into the report; they are never
dropped by later stages.
