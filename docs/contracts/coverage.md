# Contract: coverage workflow

Format identifiers:

- configuration `szaniec-coverage-config/1`
- machine-readable report `szaniec-coverage/1`
- function-inventory input `szaniec-complexity/1` (the `szaniec complexity` report; complexity is optional input)
- instrumentation facade `szaniec-instrumentation/1`

Coverage is a measurement workflow. It does not change conformance rules and
it does not read or write the approved architecture. The architecture checker
keeps working when coverage is not configured and when instrumentation is off.

## Responsibilities

| Component | Coverage responsibility |
|---|---|
| CheckClient | `szaniec coverage` and `szaniec coverage supervise`; text and JSON rendering; exit status |
| InspectionManager | Instrumented build, scenario process, collection, snapshot comparison, report assembly |
| ProgramAccess | Dune backend, runtime flush setup, point-file parsing, source snapshot, function spans, hook scan, point-to-function join |
| ConformanceEngine | None. No coverage threshold and no CRAP gate |

Toolchain names stay inside ProgramAccess. The report schema does not embed
the internal point-file layout.

## Consumer hook

A consumer project depends on the `szaniec` package and its lock. It does not
name the internal point engine, that engine's runtime, its command, its
environment variables, or its backend options.

Every in-scope application library and executable requests the facade:

```lisp
(library
 (name app)
 (instrumentation (backend szaniec.instrumentation)))
```

Ordinary `dune build` does not activate the facade. `szaniec coverage` inserts
`--instrument-with szaniec.instrumentation` into the configured Dune build.
Existing `(preprocess (pps ...))` rewriters stay in the consumer stanza and
run together with the facade.

Facade `szaniec-instrumentation/1` composes two internal engines behind that
single backend name:

| Engine | Version | What a visit means |
|---|---|---|
| `points` | `szaniec-points/1` | A source point was executed. This is point coverage. |
| `probe` | `szaniec-probe/1` | A compilation unit's probe fired. A second measurement channel used to prove the facade can host more than one engine. |

A later internal engine is added inside this facade. Consumers do not add a
second `(instrumentation ...)` entry and do not rename the backend. The
report's `facade` field is the composition version. A Dune or compiler
mismatch is an incomplete report, not a silent fallback.

The points engine is Bisect's instrumenter and native runtime: records use
the `BISECT-COVERAGE-4` layout, and the runtime flushes on process exit.
Upstream `bisect_ppx` 2.8.3 does not build on OCaml 5.4, because it requires
ppxlib older than 0.36. The facade therefore links `bisect_ppx_ng` 3, the
maintained fork with the same runtime, file identifier, and environment
variables. That package name is not part of the consumer hook or the report
schema. The workflow never installs Bisect's SIGTERM handler, so the
application keeps its own termination behavior.

PPX rewriter libraries (`(kind ppx_rewriter)` / `(kind ppx_deriver)`) and
stanzas under a `test` or `tests` directory are outside application scope.

## Configuration

`szaniec/coverage.json` under `--project-root`, or the file passed to
`--config`. The command discovers the dune project root by walking parents
from `--project-root` until `dune-project`. Every path in the configuration
is relative to that dune root.

```json
{
  "format": "szaniec-coverage-config/1",
  "scope": ["lib", "bin"],
  "build": ["dune", "build", "bin/server.exe"],
  "server": "_build/default/bin/server.exe",
  "scenario": ["deno", "run", "--allow-run", "--allow-net", "--allow-env", "--allow-read", "--allow-write", "scenarios/http.ts"]
}
```

`build` must start with the `dune` executable. The command refuses a build
line it cannot instrument. `scenario` is the project's existing scenario
command. `server` is the instrumented binary that command launches.

## Commands

```
szaniec coverage [--project-root <dir>] [--config <path>]
                 [--json] [--out <path>] [--keep-work]
                 [--function-inventory <path>]
szaniec coverage supervise --port <int> [--pass-env <name>]... -- <command>...
```

`coverage` creates a fresh temporary context, records the source snapshot,
builds with the facade enabled, runs the scenario, collects measurements,
and prints the report. The context, raw point files, and probe files are
removed after the report is produced. `--keep-work` prints the context path
and leaves it in the system temporary directory. `--out` writes the same
report JSON to a path the caller chooses. Reports are not written into the
project tree.

`supervise` is the runner adapter. A scenario that sanitizes the environment
or deletes per-instance directories launches each server through this command
instead of exec'ing the binary itself. The scenario passes
`SZANIEC_COVERAGE_CONTEXT` through unchanged and does not read coverage
files. `--pass-env` copies named variables (for example `PORT`) into the
child. The adapter adds the internal measurement environment itself.

`supervise` prints `pid <n>` and then `ready` when the port accepts
connections. It waits for the child. On a normal exit it records the node
after the process has flushed. It does not install a termination handler in
the application: a graceful flush happens only when the application exits
and its own `at_exit` handlers run. `SIGKILL`, or any signal that skips
process exit, is recorded as forced termination and yields an incomplete
report. Several `supervise` processes may run at once; each node has its own
output prefix. Restarting a server is another node. Only records from the
same source snapshot and the same point map are merged.

The measurement window is the server process, including startup before the
first scenario request. The report says `process`. It is not scenario-only
coverage.

## Report

```json
{
  "format": "szaniec-coverage/1",
  "status": "complete",
  "scenario": { "status": "passed", "exit": 0 },
  "measurementWindow": "process",
  "coverageKind": "point",
  "denominator": "instrumented-points",
  "facade": "szaniec-instrumentation/1",
  "engines": [
    { "name": "points", "version": "szaniec-points/1", "kind": "point" },
    { "name": "probe", "version": "szaniec-probe/1", "kind": "visit", "visits": 3 }
  ],
  "snapshotDigest": "sha256:...",
  "compiler": "5.4.1",
  "exclusions": ["action-preprocessors", "class-methods", "mli-interfaces", "mlx-dialect", "not-branch-coverage"],
  "summary": {
    "pointsCovered": 0,
    "pointsTotal": 1,
    "functionsMeasured": 1,
    "functionsUnexecuted": 1,
    "functionsUninstrumented": 0,
    "gaps": 0
  },
  "functions": [
    {
      "id": "lib/core.ml:function:unused:3:0",
      "path": "lib/core.ml",
      "name": "unused",
      "kind": "function",
      "provenance": "authored",
      "line": 3,
      "col": 0,
      "measurement": "measured",
      "executed": false,
      "points": { "covered": 0, "total": 1 },
      "complexity": null,
      "crap": { "status": "unavailable", "reason": "complexity-missing" }
    }
  ],
  "gaps": [],
  "nodes": [
    { "id": "n1", "disposition": "exited", "code": 0, "signal": null, "records": 1 }
  ]
}
```

`coverageKind` is `point`. Covered/total counts instrumented points. That
denominator is not branch coverage, path coverage, or assertion coverage.
`not-branch-coverage` is always listed in `exclusions`.

Functions are every definition found in in-scope sources: top-level
`let`/`let rec` functions, nested `let` functions, and anonymous `fun` /
`function` expressions. One curried `let f x y = ...` is one definition.
A nested function is a separate entry. A point belongs to the innermost span
that contains its byte offset, so a nested body is not attributed to its
parent. An unexecuted definition stays in the list with `executed: false`.
A definition with no point inside its span is `uninstrumented`, not a
measured zero. A hooked source file with no point file is gap
`COVERAGE-NO-EVIDENCE`.

`provenance` is `authored`, `generated` (a source header containing
`szaniec-generated`, or a `.ml-gen` file), or `test`.

Ordering is deterministic: functions by `id`, gaps by `code` then `path`
then `message`, nodes by `id`, exclusions alphabetically.

### CRAP

Per-function coverage for CRAP is `covered / total` over the points
attributed to that function. When `total` is 0 the score is unavailable
(`coverage-missing`). Complexity comes only from a `szaniec-complexity/1`
report passed with `--function-inventory`. That report is the output of
`szaniec complexity --json`; its metric is `szaniec-cc/1`. This command
does not compute complexity.

```json
{
  "format": "szaniec-complexity/1",
  "metric": "szaniec-cc/1",
  "functions": [
    {
      "name": "unused",
      "location": { "path": "lib/core.ml", "line": 3 },
      "complexity": 1
    }
  ]
}
```

The join key is path, name, and line. Path and line come from
`location` (a flat `path` and `line` on the function is also accepted).
`name` is the inventory's local name. A coverage span named
`anonymous` also matches an inventory name `anon` on the same line.
A missing inventory, a missing
function, or a missing `complexity` field yields
`crap.status = unavailable` and `reason = complexity-missing`. An unreadable
inventory is gap `COVERAGE-INVENTORY-INVALID`. The score, when both inputs
exist, is:

```
CRAP = complexity^2 * (1 - covered/total)^3 + complexity
```

rendered with two fractional digits. There is no CRAP gate and no coverage
threshold. Complexity remains meaningful in the inventory when this command
is not run; this command does not compute complexity itself.

### Gaps

| Code | When |
|---|---|
| `COVERAGE-BUILD-FAILED` | The instrumented build exits non-zero |
| `COVERAGE-MISSING-HOOK` | An in-scope library or executable has no `szaniec.instrumentation` backend |
| `COVERAGE-NO-EVIDENCE` | A hooked in-scope source has no point file |
| `COVERAGE-FORCED-TERMINATION` | A node was signaled and did not flush point data |
| `COVERAGE-MISSING-OUTPUT` | A node exited normally and did not flush point data |
| `COVERAGE-STALE-SNAPSHOT` | Sources after the scenario differ from the snapshot taken before the build |
| `COVERAGE-INCOMPATIBLE-RECORDS` | Two point files for one source have different point maps |
| `COVERAGE-UNSUPPORTED-DIALECT` | The dune project declares an `mlx` dialect and an `.mlx` file is in scope |
| `COVERAGE-UNSUPPORTED-PREPROCESS` | A stanza uses `(preprocess (action ...))`, which Dune does not instrument |
| `COVERAGE-UNSUPPORTED-CONSTRUCT` | A class or object method is present; methods are not in the function index |
| `COVERAGE-SOURCE-UNPARSED` | An in-scope `.ml` file could not be parsed |
| `COVERAGE-INVENTORY-INVALID` | The function inventory is not a `szaniec-complexity/1` report, or its metric is not `szaniec-cc/1` |
| `COVERAGE-UNMAPPED-FILE` | A point file names a project source that is not in the snapshot |

Scenario failure is `scenario.status = failed` and is independent of these
gaps. Both are retained together.

### Exit status

| Exit | Meaning |
|---|---|
| 0 | Scenario passed and `status` is `complete` |
| 1 | Scenario failed and coverage collection is `complete` |
| 2 | Coverage is `incomplete`, or the command could not run |

## Declared exclusions

Always reported, never treated as measured zeros:

- `.mlx` dialect files. Dune does not instrument them through this facade, and point offsets are OCaml source offsets. An `.mlx` file that is not part of a declared dialect is this exclusion. A declared `mlx` dialect plus an in-scope `.mlx` file is `COVERAGE-UNSUPPORTED-DIALECT`.
- `.mli` interfaces.
- Class and object methods (`COVERAGE-UNSUPPORTED-CONSTRUCT` when any are present).
- Dune action preprocessors.
- Branch, path, and assertion coverage.

Checked combination for this facade: OCaml 5.4.x, the dune version in
[the stack decision](../decisions/stack.md), and an ordinary ppxlib rewriter
in `(preprocess (pps ...))` beside `(instrumentation (backend szaniec.instrumentation))`.
Well view files are the `.mlx` exclusion above; the facade does not rewrite
them and does not change application or generated sources to avoid that.
