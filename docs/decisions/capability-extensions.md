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

## Acceptance

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
