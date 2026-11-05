# Scope transformation receipts to their own inputs

Status: accepted (adapter `szaniec-ocaml-adapter/1.13.0`).

## Context

After [Dune-managed PPX rewrites](ppx-rewriter-trust.md) were trusted, the `dg`
application still reported 25 `GAP-UNVERIFIABLE-TRANSFORMATION` gaps for its
MLX client pages after every ordinary `make build`, even when nothing related had
changed. Three independent causes were found:

1. Receipts were written beside their artifacts in `_build/default/...`. Dune
   deletes files it did not produce from its build directories, so every
   ordinary build removed all receipts (26 → 0 on the capability fixture).
2. A receipt identity hashed every project input (all `.ml`, `.mli`, `.mlx`,
   `.ts`, Dune files and their dependencies) plus the artifact bytes, so any
   edit anywhere, or a recompilation caused by an imported interface,
   invalidated every receipt.
3. The identity included the bytes of Dune PPX drivers under
   `_build/default/.ppx`. On `dg` these drivers are relinked with different
   bytes by each build although the rewritten output is identical.

MLX must stay checked: it is the client layer, where direct calls to Access
services must be detected. The receipt model itself is kept.

## Decision

- Receipts are stored in `_build/.szaniec-provenance`, named by the artifact
  path below `_build/default`, next to the observation cache Dune leaves alone.
- A receipt identity covers the authored source, the transformed compiler input,
  compiler arguments, the compiler and `-pp`/`-ppx` executables, and the
  governing Dune files: `dune-project`, `dune-workspace` and each `dune` file
  from the source directory to the root, with their declared dependencies and
  run-command executables (for example the MLX dialect preprocessor).
- The artifact must have been compiled from the receipted input, but its bytes
  are not part of the identity; imported interfaces are checked separately.
- Dune PPX driver bytes are excluded: Dune reruns a rewrite when its driver
  changes, and the rewritten input digest is part of the identity.

## Verification

`test/acceptance/capabilities.ts` edits an unrelated source and an unrelated Dune
file, runs an ordinary `dune build`, and requires the real MLX unit to stay
current. The existing scenarios still require a new receipt when the authored MLX,
a preprocessor dependency or a compiler-applied transformation changes.

On `dg`: `check --rebuild` (0 gaps), then an edit of
`lib/document_access/db.ml` and an ordinary `make build`, then `check` without
`--rebuild`: 0 gaps and 0 violations.
