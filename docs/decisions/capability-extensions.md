# Compiler-backed capability extensions

Issues #35–#41 extend acquisition and interpretation within the existing
component boundaries. ProgramAccess owns compiler identities, source mappings,
local target provenance, path summaries and build receipts. ArchitectureAccess
validates approved local roots; InterpretationEngine binds ownership and
interprets SQLite, public facets and interactions. ConformanceEngine receives
those facts and applies the existing structural rules.

The approved local-service declaration is separate from a public facet: it
establishes a boundary, while the facet selects exact members and consumers.
A Client already recognized by compiler/layout evidence needs only its facet.
Neither form approves the implementation of another family. SQLite conversions
are identified by a closed inventory of documented operations; project resource
declarations keep their authority.

Build receipts use artifact and input content, compiler arguments, transformation
executables, project source/build files and declared preprocessing dependencies.
They are local build evidence, not policy approvals. Successful requested Dune
builds establish the receipt; unknown/missing commands, inputs or changed
dependencies cannot reuse it. All extraction cache modes revalidate receipts,
interfaces, imports and authored MLX mappings. This supports declared deterministic
Dune transformations; dependencies hidden from Dune and environment-sensitive
preprocessors still require a rebuild and are outside the reusable proof.

Execution summaries merge equal ordered target/argument identities with
representative source witnesses and retain occurrence multiplicity. This avoids
combinatorial duplication without merging mutually exclusive service targets.
Bounds apply to distinct summaries,
composition and helper traversal. Explicit nullary exceptions have typed handler
selection; effect handlers, guarded exception selection and unknown throwing
points retain explicit uncertainty. Recursion may prove a safe single-target
fan-out bound without proving termination. Multiple possible recursive Manager
targets remain incomplete, with no fabricated co-occurrence finding.

The same bound can discharge fan-out checks for ordinary `try/with` bodies
and handlers whose entire reachable call union is resolved and has at most
one Manager of each relevant interaction kind. Multiple possible Managers,
unresolved calls, unknown callbacks, effect handlers and guarded explicit
exception selection retain gaps. Structural checks still inspect every
observed call, and ordered graphs keep exception uncertainty.

Program acquisition excludes build/distribution directories (`_build`,
`_release`, `_artifacts`, `dist`) and `node_modules`. Dune dependency constructors
`file` and `source_tree` identify real inputs; `universe` and aliases are build
scheduling dependencies. Workspace-root expansions resolve to the selected
project. Build-only OCaml inputs require an explicit authored Dune target;
their generated content contributes to the snapshot and stays subject to
compiler-input and transformation freshness checks. Copied release Dune
files do not become independent authored transformations.

## Acceptance

Callable results retain compiler projection paths rather than approving a field
by its name or record type. ProgramAccess owns tuple/variant/immutable-field
provenance; InterpretationEngine alone knows the Well HTTP iterator contract.
The producer is verified against [Well's pinned HTTP stream implementation](https://github.com/finalclass/well/blob/12dd3cea7565641f14191b8460cf93567495f554/lib/well/fetch.ml):
the third result is the body iterator and its argument receives each body chunk.
Known partial scalar predicates (`List.mem`, `min`, `max`) retain their remaining
argument instead of being mistaken for factories returning unknown closures.
The capability scenarios cover actual typed result projections, a retained
Client-to-Access violation, conflicting providers and an unknown return branch.

`test/acceptance/capabilities.ts` copies the public owned-contract fixture,
builds it before mutations, and runs the packaged CLI. Synthetic SQLite stand-ins
have the documented binding signatures; they test classification, not SQLite's
runtime. The real `well-mlx-pp` executable supplies MLX compiler AST mappings.
CI installs it from the same pinned Well revision as the build CLI.

The scenarios verify:

- Pure SQLite values, actual connection/query operations and handle diagnostics;
  explicit resource policy precedence.
- Local functions/aliases, immutable record closures, exactly passed callbacks,
  prohibited Access targets, and dynamic/mutable uncertainty.
- Eighty mutually exclusive Manager alternatives, a real two-Manager path,
  the distinct-summary bound, explicit and unresolved exceptions, and safe versus
  unresolved recursive target bounds. Structural findings survive uncertainty.
- An RPC-free ReplayUtility owning private Store/database operations, Manager
  replay and Access maintenance facets; exact Client initialization facets,
  private/undeclared access, foreign dependencies, approval and missing members.
- Authored MLX locations, rendering and executable calls; receipt reuse,
  changed authored sources/dependencies, missing transformed inputs, compiler
  PP/PPX, explicit interfaces and failed builds.
- Rebuilt, repeated cached and uncached reports for each complete scenario.

Reproducible commands are `make build`, `make verify` and the targeted
`deno test --allow-read --allow-write --allow-run --allow-env
test/acceptance/capabilities.ts`. Development verification can select the
development executable with `SZANIEC_TEST_BINARY`; release acceptance defaults
to `_release/szaniec`. No private downstream source or credentials are required.

The conservative fan-out bound traverses retained typed invocation trees rather
than flattening raw calls from nested closure declarations into their creator.
Only constructs whose observation retains every executable branch may use this
bound; extraction failures and unsupported operand summaries remain gaps.
Public RPC members of a verified contract are service-boundary calls, including
self calls; their generated mutable dispatcher is not application helper code.
Registered implementations are checked separately.

Callback-provider facts propagate through typed helper arguments, including
framework-produced database rows. A literal closure supplied exclusively to
compiler-known helper inputs that never invoke or forward it is inert. This
covers JS PPX method type witnesses without an exemption for browser transports:
the raw unresolved method evidence remains, while activated or escaping unknown
closures still make the check incomplete.

When contextual path expansion reaches a callable input with several closed,
compiler-proven providers, the fan-out upper bound traverses all those providers.
It never picks one provider to make a path pass. The union can prove a single
Manager bound; multiple Manager targets keep the uncertainty gap. Anonymous
closures are excluded from their creator's call union and entered only through
proven invocation/callback evidence. This preserves recursive storage helpers
without claiming their termination or exception completion.

Compiler-declared `external` values retain their exact OCaml symbol and the named
native primitive as an external dependency. Native implementation bodies are
outside the OCaml adapter's scope. They have no invented OCaml helper body or
callback contract; function-valued inputs to an unmodeled native primitive retain
unknown callback semantics. Regular-expression `Str.global_substitute` and
`Str.substitute_first` use their documented one-argument replacement callbacks;
the former retains iteration context and the latter is a single possible call.

A helper's complete retained call tree may establish one callback input despite
unknown exception completion or guard selection. The projection keeps possible
invocation and non-invocation branches. It rejects this recovery when distinct
callback inputs could be confused; their co-execution remains unproven. Unknown
APIs, missing bodies and unsupported constructs still prevent the recovery.
