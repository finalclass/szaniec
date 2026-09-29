# Contract: program observation

Format identifier (conceptual): `szaniec-observation/1`.

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
- `sourceDigest` — from the artifact (`cmt_source_digest`), verified
  against the file on disk.
- `artifactPath` — the `.cmt` file used.
- `fresh` — digest matches the current source file.
- `generated` — dune-generated wrapper units (`.ml-gen` sources); they
  are excluded from rules and diagnostics.

Dune wrapper units (`.ml-gen`) are observed for completeness but carry no
ownership or findings. `.mli` interfaces are not analyzed in this profile.
`.mlx` view files are not in the supported profile.

## Symbols, calls, references

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
  - Call spines are resolved through curried applications (`f a @@ b`
    resolves to `f`), never by name pattern matching.
- `valueRefs` — non-call identifier references to module members
  (`M.value` reads), with site; used for registration evidence and
  implementation-access by reference.
- `typeRefs` — type-constructor references with site (`Task_access.ListReq.t`).
  Type-only references are contract usage; they do not count as
  executable sharing or calls in this profile.

Calls, valueRefs and typeRefs are sorted by `(unit, caller, callee, site)`
before the observation is consumed, so downstream stages are deterministic.

## Completeness

- A source file in a program root with no artifact →
  `GAP-UNOBSERVED-SOURCE` (the program was not built for analysis).
- Artifact digest ≠ source file digest → `GAP-STALE-ARTIFACT`; the unit is
  never analyzed from stale evidence.
- Artifact compiler series outside the adapter's supported series →
  `GAP-UNSUPPORTED-COMPILER`; the unit is not analyzed.
- Unreadable artifact → `GAP-ARTIFACT-READ`; the unit is not analyzed.

All gaps travel with the observation into the report; they are never
dropped by later stages.