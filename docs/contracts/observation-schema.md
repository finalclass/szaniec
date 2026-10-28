# Contract: program observation

Format identifier (conceptual): `szaniec-observation/8`.

ProgramAccess produces one normalized observation per check run. It is an
in-memory contract between the ProgramAccess component and the
InterpretationEngine and ConformanceEngine; the OCaml types in
`lib/model` are the authoritative definition. This document fixes the
meaning of the facts.

## Requested evidence and acquisition

InspectionManager requests `Architecture`, `Measurement`, or `All` evidence.
Architecture retains units, aliases, calls, references and all execution views;
Measurement retains unit, alias, call and reference facts needed for ownership
attribution and measures every in-scope function, including generated wrappers;
it omits execution-context and ordered-flow extraction. `All` retains both. Omitted
measurement fields in Architecture and omitted execution fields in Measurement
are unrequested evidence, not a successful empty inventory. Suggestions request
Architecture for their dependency catalog and perform their own source extraction.
Compiler, source, interface and transformation validation applies in every mode.

ProgramAccess scans all current artifacts on every invocation. It reads metadata
one artifact at a time, retaining metadata without typed trees, then processes
selected artifacts one at a time. Existing deterministic selection and unreadable
artifact gaps remain binding. Filename alone never proves exclusion or provenance.

### Local observation cache

ProgramAccess may reuse normalized per-artifact extraction only after current
freshness validation. The local cache lives at `_build/.szaniec-observations`;
`SZANIEC_OBSERVATION_CACHE=off` disables reads and writes. Deleting that directory
is safe when no check is running. It contains application facts and must not be
committed or published. Source discovery, snapshot construction, alias resolution,
current policy, contract interpretation and conformance evaluation always run.

The entry identity includes artifact bytes, artifact path, project root, source
path and bytes, compiler version, observation schema, adapter version and requested
evidence. Interface/import/transformation freshness is revalidated before every
hit. Only successful complete extraction is stored; failures and incomplete
entries are re-extracted. Corrupt, incompatible or interrupted entries are misses.
Entries use a versioned payload and integrity digest, atomic rename and private
file permissions. Concurrent invocations may duplicate extraction; each publishes
a complete entry through a unique temporary file, without shared mutable state.
Cache I/O failures leave acquisition available and never suppress analysis gaps.

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
  pp targets `x.pp.ml` (from `x.ml`) and `x.mlx.pp.ml`/`x.mlx.ml` (from `x.mlx`);
  compiler-mapped `.mlx` units retain authored locations.
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
  missing local dependencies cannot prove freshness. Preprocessed inputs and
  compiler-applied `-pp`/`-ppx` transformations require a matching local receipt
  from a successful requested build. A transformed digest alone never establishes
  original-source freshness. Unproven transformation evidence requires rebuilding.
- `generated` — dune-generated wrapper units (`.ml-gen` sources); they
  are excluded from rules and diagnostics.

Dune wrapper units (`.ml-gen`) are observed for completeness but carry no
ownership or findings; their aliases are retained. `.mli` interfaces contribute
snapshot and freshness evidence, not executable bodies.
`.mlx` bodies require compiler-backed authored source mapping.

## Symbols, calls, references

Typed function arguments retain their position, label and immutable record-field
selector. A symbolic `<parameter@N>` target identifies the owning function input;
field projections append their selector. Variable patterns, compiler parameter
identifiers and final function-case parameters describe the same input. Mutable
fields and unknown computed values do not acquire a concrete target.
Optional function defaults retain a typed target and invocations retain proven
omitted/None slots. Repeated omitted slots in a curried application replace the
existing slot in place. Reconstructing the compiler's recorded environment and
load path permits function-type aliases to retain the same evidence as arrows.

For a single binding operator, architecture extraction normalizes the typed
`let* pattern = input in body` into an application of the compiler-resolved
operator to the input and a pattern-matching continuation. The operator's
implementation determines whether and how often the continuation runs; merely
constructing it does not execute its body. Operator names do not establish
monadic or callback semantics. Source sites and typed parameter identities are
retained. Callable aliases in structure-level opens retain their target across the
compiler's fresh identifier bindings, matched by declaration UID rather than
name, including shadowed bindings. Unknown or ambiguous callable aliases remain
unresolved. A variable binding and the compiler's alias-of-wildcard form for an
annotated function name retain the same named-definition semantics.
Complexity measures the original tree,
without synthetic callbacks.
Combined `and*` bindings remain unsupported ordered execution and retain gaps
when relevant to required path analysis.

Execution facts include syntactically proven returned function targets and
functor instances (instance module, functor, argument module and source site).
Callable result projections also retain tuple positions, polymorphic-variant
payloads and immutable record selectors. `returned_functions` pairs a factory's
result projection with its compiler-proven callable target. Unsupported return
branches retain an unknown projection; one known branch cannot supply evidence
for an unknown branch. Multiple distinct targets remain unresolved.
Standard `Set.Make` and `Map.Make` applications retain their concrete comparator;
other unsupported functor applications still require a gap. Locally opened
structures contribute their definitions and initialization calls. Typed nodes
are identified by object identity, so different PPX nodes at a ghost location do
not replace one another. Shared ordered-flow nodes remain shared during conversion.

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
  alternatives; a sequence composes bounded target summaries. `limitingReason`
  explains an ambiguous function. Explicit `raise` of a typed nullary exception
  selects the first matching unguarded handler; unknown throwing points or
  effect handlers remain ambiguous. Evaluating a function value does not execute
  its body; the body's alternatives belong to that function. These
  paths are the evidence for use-case and queue fan-out rules. They
  do not replace `calls`.
  Path steps retain resumed-function and terminal-raise facts. Composition
  does not append calls after a proven terminal exit, including helper expansion.
- `valueRefs` — non-call identifier references to module members
  (`M.value` reads and function values passed as callbacks), with site.
  These are executable dependencies: registration evidence,
  implementation access and sharing all see them. A structure-level
  `module Alias = Path` is resolved to `Path` in the recorded callee or
  target. Local aliases and first-class module methods retain their compiler
  targets and input-field selectors. Unbound packages retain unresolved calls;
  computed unpacks and unsupported functor applications retain gaps.
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
The raw call view consumes the matching typed invocation by node identity,
including generated nodes that share a source location. Source coordinates do
not establish invocation identity.
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

## Ordered execution evidence

ProgramAccess additionally retains structured execution evidence for each
definition: ordered execution, separate branch arms, loop condition and
body execution, invocation occurrences, and return or raise exits.
It preserves source sites and compiler-resolved identities without assigning
service or framework meaning. Unsupported ordering and execution constructs
remain explicit unknown evidence. Source position alone does not establish
execution order. This evidence supplements `execPaths` and `execution`;
their existing conformance and repetition semantics remain unchanged.

## Function inventory

`functions` is the syntactic-function inventory measured by
[szaniec-cognitive/1](complexity-metric.md). Each entry has a deterministic id,
a source span, provenance (`authored`, `generated`, or `test`), and
either both cognitive and cyclomatic scores or an unmeasurable status.
The CLI selects which score to render; cached observations retain both. Nested bodies are
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

Transformation diagnostics distinguish missing compiler inputs
(`GAP-MISSING-INPUT`), unverified transformation provenance
(`GAP-UNVERIFIABLE-TRANSFORMATION`), and confirmed content/interface mismatch
(`GAP-STALE-ARTIFACT`). After a successful requested build, ProgramAccess stores
a local transformation receipt keyed by compiler artifact/input bytes, project
source/build/preprocessor dependencies and transformation executable identity.
Receipts are revalidated independently of extraction caches; changed or missing
dependencies invalidate them. No receipt is published after a failed build.

Compiler-mapped MLX units are included when their typed source locations point
to the authored `.mlx` input. ProgramAccess retains the preprocessor command,
input digest and receipt identity in local provenance. Rendering syntax is never
parsed for architectural calls. Unmapped executable locations produce
`GAP-SOURCE-MAPPING`; unavailable transformations remain incomplete. Generated
and authored projections of the same compilation unit are acquired once.

Known immutable local function aliases, closures and record callbacks use typed
binding identities. Locally called higher-order helpers are specialized only
when their observed function arguments establish one exact target; other
callback parameters retain ambiguity. Mutable fields and unknown API callback
semantics never establish execution. Structural references remain visible.

Execution_paths is neutral model infrastructure owned by ProgramAccess, consumed
by ProgramAccess and both Engines for deterministic set composition and local
symbol identity. It
contains no framework or conformance policy.
Execution alternatives are summarized by ordered direct targets and argument
identities, retaining occurrence multiplicity and representative source evidence.
Order is required when an expanded helper exits before later calls. Equivalent alternatives
are merged before bounded composition, with at most 256 distinct summaries and
4096 compositions/traversal steps per operation and helper depth 64. Exceptions
with unknown throwing points and recursive helpers without a safe target bound
retain concrete limiting reasons
and mark Client multi-Manager and queued fan-out checks unverified. Structural
and private-access checks remain independent of this limit.

- A source file in a program root with no artifact →
  `GAP-UNOBSERVED-SOURCE` (the program was not built for analysis).
- Artifact digest ≠ source file digest → `GAP-STALE-ARTIFACT`; the unit is
  never analyzed from stale evidence.
- Artifact compiler series outside the adapter's supported series →
  `GAP-UNSUPPORTED-COMPILER`; the unit is not analyzed.
- Unreadable artifact → `GAP-ARTIFACT-READ`; the unit is not analyzed.
- A partial typed implementation → `GAP-INCOMPLETE-ARTIFACT`; architecture
  checks do not interpret it as an empty complete body. The measurement command
  retains its separate unmeasurable result.
- An unsuccessful requested rebuild → `GAP-BUILD`; any retained findings
  accompany incomplete analysis, never a successful report.

All gaps travel with the observation into the report; they are never
dropped by later stages.

### Callable result provenance (adapter 1.10.0)

Calls retain a stable per-expression `execution_result` identity and
`execution_values` (input position, compiler-resolved immutable value identity,
source site). `value_origins` links named values to their producing result.
These are language facts; they neither authorize an API nor assign execution
semantics to a library. Tuple, ordinary-constructor, polymorphic-variant and
immutable-field projections can compose across known result producers. A
nonreturning `raise` branch does not contribute a returned value. Unknown
returning branches still invalidate their affected projection.

A conditional choice of unit thunks retains a deferred callable with alternative
targets. Constructing the choice evaluates its condition, not the thunk bodies;
invoking it follows one alternative. Other higher-order conditional values
remain unsupported. Recoverable handlers containing only value construction or
reraising preserve the body's success alternatives without concatenating it with
another handler. Handlers with additional calls retain exception uncertainty.
