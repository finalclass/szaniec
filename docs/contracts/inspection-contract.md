# Contract: inspection request, result and CLI

Format identifiers: request is CLI-only; machine-readable report is
`szaniec-report/1` (JSON).

## Commands

`szaniec --help` and `szaniec -h` print command syntax and descriptions to
stdout and exit 0 without loading project configuration or running an inspection.
The flags also work after a command or subcommand. Arguments after the `--`
separator in `coverage supervise` belong to the child command.

```
szaniec init    [--config <path>] [--project-root <dir>]
szaniec approve [--config <path>] [--project-root <dir>]
szaniec check   [--config <path>] [--project-root <dir>]
                [--rebuild] [--json] [--out <path>] [--no-callgraph]
szaniec complexity [--config <path>] [--project-root <dir>]
                   [--rebuild] [--json] [--sort location|complexity]
szaniec coverage [--project-root <dir>] [--config <path>] [--json] [--out <path>]
                 [--keep-work] [--function-inventory <path>]
szaniec coverage supervise --port <int> [--pass-env <name>]... -- <command>...
```

`coverage` is specified in [the coverage contract](coverage.md). It does not
run conformance rules and it does not require an approved policy.

- `init` creates minimal analysis configuration as specified in
  [project configuration](configuration.md); it does not approve the policy.
- `approve` accepts the configured analysis scope and policy exceptions by
  updating `[approval]` with the policy name and
  SHA-256 digest of the current policy content (see
  [policy format](policy-format.md)).
- `check` runs the full inspection. Configuration discovery and CLI precedence
  follow [project configuration](configuration.md).
- Every successful `check` writes the call network artifact
  (`szaniec.json`, see below) into the project root; `--out <path>`
  moves it, `--no-callgraph` disables writing it.
- `--rebuild` runs `dune build` in the project root before observation.
  Without it, stale or missing artifacts are reported as gaps, never used
  as current evidence.
- `--json` emits the machine-readable report instead of the text report.
- Exit status for `check`: `0` no violations and no gaps; `1` violations
  with complete required analysis; `2` incomplete analysis, execution
  failure, or unapproved policy — including when violations were also found.
- `complexity` inventories every syntactic function and reports
  [szaniec-cc/1](complexity-metric.md). It does not write `szaniec.json`
  and it does not judge thresholds. `--sort location` (the default) lists
  definitions in source order; `--sort complexity` lists them by
  descending complexity with `id` as the tie-break. Exit status: `0` when
  coverage is complete, `2` when a file or construct could not be
  measured. Policy approval is recorded and does not by itself change
  that status.
- `szaniec suggestions` is specified separately in the
  [suggestion contract](suggestion-contract.md). It does not change the
  check exit status and does not add findings to the check report.

## Profile

First delivery profile: `well-ocaml-core` — OCaml 5.4.x artifacts
extracted from a dune `_build` tree, interpreted by the Well adapter
(services from cyrograf contract files).

Declared exclusions of the profile (reported in the report, never gaps):

- `.mlx` view files (MLX preprocessor not in profile),
- `.mli` interfaces (implementation facts only),
- dune wrapper units (`.ml-gen`),
- resource access beyond policy-declared `api_prefixes` (e.g. direct
  `Sqlite3.*` calls) — recorded as external calls, not resource
  interactions.

Queued commands, publications, subscriptions and Client use-case paths
are in the profile. Their evidence requirements and gaps are the rule
catalog and the interpretation contract. A publication is not reported
as a request edge in `szaniec.json`.

## Report JSON

```json
{
  "format": "szaniec-report/1",
  "status": "ok" | "violations" | "incomplete",
  "inputs": {
    "policy": { "name": "...", "digest": "sha256:...", "approved": true,
                 "approvedDigest": "sha256:..." },
    "profile": "well-ocaml-core",
    "programRoots": ["bin", "lib"],
    "snapshotDigest": "sha256:...",
    "compiler": "5.4.1",
    "adapters": {
      "programAccess": "szaniec-ocaml-adapter/1.5.0",
      "interpretation": "szaniec-well-adapter/3.4.0",
      "rules": "szaniec-rules/3.1.0"
    },
    "exclusions": ["...", "..."]
  },
  "findings": [
    {
      "rule": "ID-CLIENT-ACCESS",
      "severity": "violation" | "gap",
      "message": "human-readable one-line",
      "participants": ["WebClient", "TaskAccess"],
      "locations": [ { "path": "lib/pages/tasks_page.ml", "line": 7, "col": 12 } ],
      "evidencePath": ["App.Pages.Tasks_page.tasks_handler", "App.Pages.Page_shared.to_wire", "TaskAccess"]
    }
  ],
  "summary": { "violations": 1, "gaps": 0, "units": 14, "calls": 42, "typeRefs": 19 }
}
```

## Call network artifact (`szaniec.json`)

Format identifier: `szaniec-callgraph/3`. A deterministic projection of
one check run: per service and per method, the call edges observed in
the program. Intended as the base for future diagram tooling.

```json
{
  "format": "szaniec-callgraph/3",
  "inputs": { "policyName": "...", "policyDigest": "sha256:...",
              "snapshotDigest": "sha256:...",
              "programAccess": "...", "interpretation": "...", "rules": "..." },
  "services": [
    {
      "name": "Security",
      "role": "utility",
      "methods": [
        {
          "name": "check_access",
          "request": "Security.CheckAccessRequest",
          "response": "Security.CheckAccessResponse",
          "calls": [
            { "to": { "service": "OrgModelAccess", "method": "store" },
              "sites": [ { "path": "lib/security/auth_handler.ml",
                           "line": 277, "col": 4 } ],
              "contexts": [ {
                "origin": "Security_impl.Impl.check_access",
                "site": { "path": "lib/security/auth_handler.ml", "line": 277, "col": 4 },
                "evidencePath": ["Security_impl.Impl.check_access", "OrgModelAccess.store"],
                "loops": [ { "kind": "for", "api": "",
                             "site": { "path": "lib/security/auth_handler.ml", "line": 276, "col": 2 } } ],
                "activations": [], "unknownReasons": []
              } ] },
            { "to": { "kind": "resource", "name": "database" },
              "sites": [], "contexts": [] }
          ],
          "calledBy": [ { "service": "WorkflowManager",
                          "method": "perform_user_action" } ]
        }
      ]
    }
  ],
  "entryPoints": [],
  "unresolved": [ { "unit": "App.Web_client.Tasks_page",
                    "caller": "tasks_handler",
                    "site": { "path": "...", "line": 8, "col": 14 } } ],
  "unclassifiedUnits": ["App.Asset_rev"]
}
```

- `services` lists every cyrograf service with its inferred role, its
  declared methods (name, request, response from the cyrograf `rpc`
  lines) and the observed call edges.
- Edges whose target is another service carry the target service and
  method; resource accesses carry the resource name; unobserved targets
  (external packages) carry `kind: "external"` with the resolved API
  path; calls that could not be resolved appear in `unresolved`.
- `calledBy` is the reverse projection over all methods of all services.
- Each edge additionally carries `contexts`: distinct invocation contexts with
  `origin`, `site`, `evidencePath`, `loops`, `activations`, and `unknownReasons`.
  Loop and activation records carry `kind`, `site`, and `api` (empty for syntax).
  Metadata belongs to each invocation, not to the merged target: the same helper
  or service can be called both inside and outside a loop. Nested contexts are
  retained. Empty lists with no unknown reasons mean no repetition was observed
  on that supported path, not proof of a runtime execution count.
  An edge with `contexts: []` has no execution-context evidence; it may still
  retain a dependency from the existing interaction projection.
- `entryPoints` retains non-RPC boundary entries, including module initializers
  and callbacks registered outside service methods. Entries have `symbol`,
  `owner`, `site`, and `calls` using the same edge format. They are not invented
  RPC methods and do not become entries in `calledBy`.
- Syntactic loops and recognized collection iterators are `loops`. A supported
  `Well.every` or subscription callback is a repeated `activation`, which starts
  independent work. Activation metadata stops at the next service boundary;
  another service's method is analyzed under its own origin.
- Unknown callback invocation semantics, unresolved execution targets and bounded
  traversal limits stay visible in `unknownReasons`. Existing findings and gaps
  remain authoritative. Repetition annotations alone do not change check exit
  status; enforcement and TOML exclusions are separate future work.
- Determinism rules of the report apply here too: identical inputs and
  versions produce byte-identical `szaniec.json`.

### Ordered execution flow

Each service method and non-RPC entry point additionally has a `flow`:
`{ "status": "complete" | "incomplete", "steps": [...] }`.
Existing `calls`, `sites`, `contexts`, and `calledBy` retain their meaning.
The flow describes possible execution from static evidence, not a recorded
request or a guarantee that every listed call completes successfully.

For StoreManager.place_order, a straight-line flow is:

```json
{
  "status": "complete",
  "steps": [
    { "kind": "call", "interaction": "service-request",
      "to": { "service": "WarehouseAccess", "method": "validate" } },
    { "kind": "call", "interaction": "service-request",
      "to": { "service": "PaymentEngine", "method": "ensure_paid" } },
    { "kind": "call", "interaction": "service-request",
      "to": { "service": "CartAccess", "method": "check" } },
    { "kind": "call", "interaction": "service-request",
      "to": { "service": "OrdersAccess", "method": "place_order" } },
    { "kind": "call", "interaction": "service-request",
      "to": { "service": "WarehouseAccess", "method": "deduce_items" } }
  ]
}
```

PaymentEngine.ensure_paid has its own flow containing PaymentAccess.check.
A WebClient entry point has a call to StoreManager.place_order.
The example omits source evidence for brevity.

- Arrays of `steps` preserve proven execution order, never target-name
  sorting or an order guessed from source line numbers.
- Each `call` occurrence carries `to`, `interaction`, `site`, and
  `evidencePath`. Targets use the existing edge target representation.
  Repeated calls remain separate occurrences, even with the same target
  or terminal helper site. Their enclosing step positions distinguish them.
- Private helper execution is expanded at its invocation position within
  the owning boundary; deferred function bodies are expanded only when
  supported evidence establishes invocation.
- A service call references the target service and method's separate flow.
  Renderers may expand it beneath the call. For a synchronous request,
  reaching the normal end of the target flow returns to the next caller
  step. This does not assert that the call cannot fail.
- A `choice` has `branches`, each with `label` and `steps`. Its branches
  are alternatives, not consecutive execution. Labels identify source
  arms without asserting runtime predicate values.
- A `loop` has `loopKind`, `site`, `api`, `conditionSteps`, and
  `bodySteps`. These retain the construct's execution semantics;
  iteration counts are unknown. For-bound evaluation stays outside
  the loop; while-condition evaluation remains inside it.
- An `exit` has `outcome`: `return` or `raise`, and `site`. It terminates
  its containing method or entry-point execution path.
- An `unknown` has `reason` and `site`. Unsupported ordering, callback
  semantics, exception flow, or traversal limits remain explicit;
  known surrounding steps are retained. No arbitrary order is invented.
- A flow is `complete` only when all relevant execution and ordering
  evidence for that origin is represented. An unavailable body has an
  incomplete flow, not an empty complete flow.
- Independent activations remain separate entry-point flows. Queued
  commands and publications do not imply synchronous target execution
  or a return. Unknown ordering does not become sequential execution.
- Recursive references are retained without infinite expansion.
  A renderer must mark recursion or unavailable target flows explicitly.
- Flow completeness is additional diagram evidence. It neither clears
  existing findings and gaps nor independently changes check exit status.
  Flow serialization is deterministic while preserving semantic order.

## Determinism

- Findings are sorted by `(rule, participants, first location, remaining
  locations)`.
- JSON object key order is fixed by the encoder; no map iteration leaks.
- Identical inputs, policy identity and adapter/rule versions produce
  byte-identical reports.

## Text report

Human-readable rendering of the same data: input identities, findings
grouped by rule with locations and evidence paths, exclusions, summary
and exit status. Rendering belongs to the CheckClient; diagnostic meaning
stays in this contract.
