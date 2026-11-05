# Decision: enforce IDesign through dune library structure

Status: accepted (2026-11-05). Supersedes the don'ts-based call-graph rules,
the observation, interpretation, inspection, policy, configuration, coverage,
suggestion and coaching contracts, and the decision records about acquisition
profiling, capability extensions, conformance indexes and interaction
grouping. Those documents were deleted; they remain in Git history.

## Context

Szaniec exists to protect the IDesign architecture of the DG project. The
previous design extracted call graphs from compiler-typed artifacts,
interpreted Well services, proxies, queues and callbacks, and evaluated the
graph against an approved policy in `szaniec.toml`. It needed a full build,
thousands of lines of framework interpretation, and a long tail of evidence
gaps (`GAP-*`) for constructs it could not follow. Every gap was either a
false alarm or a hole an agent could hide a call in.

## Decision

Architecture is enforced by structure, and the compiler does the call
analysis:

1. Every component is its own dune library: one implementation library per
   service, its contract family (`<svc>_contract`, `<svc>_browser`,
   `<svc>_spec`, `<svc>_wire`), optional facets (`<svc>_<anything>`),
   local libraries and composition roots.
2. `dune-project` declares `(implicit_transitive_deps false)` (dune 3.17 or
   newer). The compiler then rejects any reference to a module of a library
   that is not a direct dependency. A call to another service's
   implementation, a resource library or the framework registry cannot
   compile unless the dune file declares that dependency.
3. `szaniec check` reads only the dune files, `dune-project` and the
   `.cyrograf` contracts and checks that every declared dependency is
   allowed by the IDesign closed-architecture rules and the Well profile.
   No build, no compiler artifacts, no `_build`, no configuration file.

The compiler guarantees "code uses only what dune declares"; Szaniec
guarantees "dune declares only what IDesign allows". Together they cover
what the call-graph checker tried to infer, without interpretation gaps.

### Naming conventions are the policy

There is no approved policy file. Services are the `.cyrograf` files that
declare `rpc` methods; their role comes from the name suffix (`manager`,
`client`, `engine`, `access`, otherwise Utility) — the convention used since
the first delivery. Library names bind code to services:

| Library name | Class | Role |
|---|---|---|
| ends with `_root` | composition root (library) | none, exempt |
| key equals a service key | service implementation | service role |
| `<svc>_contract`, `<svc>_browser` | callable contract | service role |
| `<svc>_spec`, `<svc>_wire` | server surface, transport adapter | service role |
| `<svc>_<anything>` (longest service prefix) | facet | service role |
| anything else | local component | its own suffix |
| `executable(s)`, `test(s)` stanzas | root, test | none, exempt |

A key is the name lowercased with non-alphanumerics removed, so `AIAccess`
matches `ai_access`. A **facet** is an in-process surface of a service, such
as `security_api` for the `Security` service or `formula_engine_api` for
`FormulaEngine`. It replaces the old approved `public_contracts` list: other
components reach a facet exactly as they reach `<svc>_contract`, under the
owning service's role, and the facet's own dependencies are judged with that
role.

The same conventions classify dependency **names**, not only defined
stanzas. DG generates contract libraries into a gitignored directory, so a
dependency on `x_access_contract` must be judged as a ResourceAccess contract
even when its stanza is absent from the scanned tree. Only names that match
no service and carry no role suffix (and exact or dotted profile names) are
treated as external libraries.

### Why closed-architecture rules on dune edges are enough

A dune dependency is a superset of the calls that can happen across it. If
`order_manager` may not depend on `billing_manager_contract`, it cannot call
any of its operations, in any branch, through any helper or callback. Rules
that needed path evidence in the old design (use-case scope, queued fan-out)
are not checked; they are design reviews, not structural constraints.

## Consequences

- `init`, `approve`, `coverage` and `suggestions`, `szaniec.toml`,
  `szaniec.json`, the coverage runtime and instrumentation ppx, Jev model
  access, the coaching catalog for old findings, and the OCaml call
  extraction were deleted.
- `szaniec complexity` stays. It still reads compiler artifacts (it measures
  function bodies), but takes its build command and source roots from
  `--build` and `--root` instead of `szaniec.toml`; service ownership fields
  were removed from its report.
- A dune file that cannot be parsed, or a construct that hides dependencies
  (`copy_files` from outside the directory, virtual libraries), is an error
  or a `DUNE-UNSUPPORTED` violation, never a silent pass.
- Missing `(implicit_transitive_deps false)` is reported as
  `DUNE-TRANSITIVE`: without it every other rule is void.
- Renaming a library changes its classification. Coaching tells agents not
  to rename or move code to silence findings; review of dune-file changes
  stays a human responsibility.

## Verification

`test/check/run.ts` runs the binary over fixture projects in
`test/fixtures/check`: a fully conforming project, a directory-walk project
(`dirs`, `data_only_dirs`, `vendored_dirs`, hidden directories, `subdir`,
`include`, `select`, `re_export`, comments), a project whose generated
contracts are absent, and one mutation per rule with the exact
`path:line:col` of the offending atom.
