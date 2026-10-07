# Contract: inspection request, result and CLI

Format identifiers: request is CLI-only; machine-readable report is
`szaniec-report/1` (JSON).

## Commands

```
szaniec approve --policy <path> [--approval <path>]
szaniec check   --policy <path> [--approval <path>] [--project-root <dir>]
                [--rebuild] [--json] [--out <path>] [--no-callgraph]
szaniec complexity --policy <path> [--approval <path>] [--project-root <dir>]
                   [--rebuild] [--json] [--sort location|complexity]
```

- `approve` writes the approval file recording the policy name and
  SHA-256 digest of the current policy content (see
  [policy format](policy-format.md)).
- `check` runs the full inspection. Paths default to the working
  directory (`--project-root`), `szaniec/policy.json` next to it
  (`--policy`), `szaniec/approval.json` (`--approval`).
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

## Profile

First delivery profile: `well-ocaml-core` — OCaml 5.4.x artifacts
extracted from a dune `_build` tree, interpreted by the Well adapter
(services from cyrograf contract files).

Declared exclusions of the profile (reported in the report, never gaps):

- `.mlx` view files (MLX preprocessor not in profile),
- `.mli` interfaces (implementation facts only),
- dune wrapper units (`.ml-gen`),
- resource access beyond policy-declared `apiPrefixes` (e.g. direct
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
      "programAccess": "szaniec-ocaml-adapter/1.2.0",
      "interpretation": "szaniec-well-adapter/3.1.0",
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

Format identifier: `szaniec-callgraph/1`. A deterministic projection of
one check run: per service and per method, the call edges observed in
the program. Intended as the base for future diagram tooling.

```json
{
  "format": "szaniec-callgraph/1",
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
                           "line": 277, "col": 4 } ] },
            { "to": { "kind": "resource", "name": "database" },
              "sites": [] }
          ],
          "calledBy": [ { "service": "WorkflowManager",
                          "method": "perform_user_action" } ]
        }
      ]
    }
  ],
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
- Determinism rules of the report apply here too: identical inputs and
  versions produce byte-identical `szaniec.json`.

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