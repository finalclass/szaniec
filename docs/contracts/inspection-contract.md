# Contract: inspection request, result and CLI

Format identifiers: request is CLI-only; machine-readable report is
`szaniec-report/1` (JSON).

## Commands

```
szaniec approve --policy <path> [--approval <path>]
szaniec check   --policy <path> [--approval <path>] [--project-root <dir>]
                [--rebuild] [--json]
```

- `approve` writes the approval file recording the policy name and
  SHA-256 digest of the current policy content (see
  [policy format](policy-format.md)).
- `check` runs the full inspection. Paths default to the working
  directory (`--project-root`), `szaniec/policy.json` next to it
  (`--policy`), `szaniec/approval.json` (`--approval`).
- `--rebuild` runs `dune build` in the project root before observation.
  Without it, stale or missing artifacts are reported as gaps, never used
  as current evidence.
- `--json` emits the machine-readable report instead of the text report.
- Exit status: `0` no violations and no gaps; `1` violations with
  complete required analysis; `2` incomplete analysis, execution failure,
  or unapproved policy — including when violations were also found.

## Profile

First delivery profile: `well-ocaml-core` — OCaml 5.4.x artifacts
extracted from a dune `_build` tree, interpreted by the Well adapter.

Declared exclusions of the profile (reported in the report, never gaps):

- `.mlx` view files (MLX preprocessor not in profile),
- `.mli` interfaces (implementation facts only),
- dune wrapper units (`.ml-gen`),
- queued-command, publish/subscribe and use-case rules (messaging APIs
  are recorded as evidence only),
- resource access beyond policy-declared `apiPrefixes` (e.g. direct
  `Sqlite3.*` calls) — recorded as external calls, not resource
  interactions.

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
      "programAccess": "szaniec-ocaml-adapter/1.0.0",
      "interpretation": "szaniec-well-adapter/1.0.0",
      "rules": "szaniec-rules/1.0.0"
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