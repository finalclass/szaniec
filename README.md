# Szaniec

**Check architecture conformance, measure OCaml code, and review optional
code-quality suggestions.**

Szaniec is a local CLI for people and coding agents. It extracts facts from
compiler-typed OCaml artifacts, interprets [Well](https://github.com/finalclass/well)
services, and checks implementation against approved architecture. It also
inventories function complexity, measures an existing application scenario,
and offers optional Jev judgments about code quality.

The name is Polish for a defensive earthwork: Szaniec protects established
boundaries. It checks implementation conformance; it does not decide whether
an architecture was correctly decomposed around volatility. This is not an
official IDesign product.

## Contents

- [Commands and status](#commands-and-status)
- [Build and run](#build-and-run)
- [Linux releases](#linux-releases)
- [Configure a project](#configure-a-project)
- [Check architecture](#check-architecture)
- [Inspect function complexity](#inspect-function-complexity)
- [Measure coverage and CRAP](#measure-coverage-and-crap)
- [Review code-quality suggestions](#review-code-quality-suggestions)
- [Exit statuses and automation](#exit-statuses-and-automation)
- [Troubleshooting and limits](#troubleshooting-and-limits)
- [Verification and reference documents](#verification-and-reference-documents)

## Commands and status

Run `szaniec --help` (or `-h`) for command syntax and descriptions. These flags
also work after a command or subcommand and do not require project configuration.

The following commands have executable implementations:

| Command | Purpose | Result |
|---|---|---|
| `init` | Create minimal analysis configuration without overwriting an existing file | New `szaniec.toml` |
| `approve` | Record the selected policy's name and SHA-256 digest | `[approval]` in `szaniec.toml` |
| `check` | Check service interactions and project boundaries | Text or `szaniec-report/1` JSON; separate call graph |
| `complexity` | Inventory syntactic functions and local cyclomatic complexity | Text or `szaniec-complexity/1` JSON |
| `coverage` | Build with instrumentation and run an existing scenario | Text or `szaniec-coverage/1` JSON |
| `suggestions` | Review selected source context with Jev or a local fixture | Text or `szaniec-suggestions/1` JSON |

Supported architecture profile: `well-ocaml-core`, OCaml **5.4.x** artifacts
produced by Dune. The locked coverage combination is OCaml 5.4.1
(`5.4.1+relocatable`), Dune 3.24.2, and ppxlib 0.38.0.

Architecture checks, complexity, and coverage run locally. Live suggestions
send selected source context to the provider. All suggestion categories are
**experimental and not evaluated**: routine acceptance uses recorded fixtures;
no live quality evaluation with cost and latency has been recorded.

## Build and run

From this repository's root, with `well`, Dune, Deno 2, `make`, and
`patchelf` available on Linux:

```sh
make build
dune exec szaniec -- complexity \
  --project-root test/fixtures/tasks-app \
  --config complexity.toml --rebuild --sort complexity
```

`make build` calls `well build`: Dune compilation, shared-library discovery,
bundling, and `patchelf`. It then adds a launcher and creates a development
archive with a SHA-256 checksum in `dist/`. Dune resolves the OCaml toolchain
and dependencies through the checked-in `dune.lock`; the first build needs
network access. On Debian/Ubuntu, install `patchelf` with
`sudo apt-get install patchelf`.
The build host needs glibc 2.33 or newer for the bundled loader's `--argv0`
option; CI uses Ubuntu 24.04. That loader is included in the release, so this
requirement applies to the build host rather than the target's glibc.

The resulting layout is:

```text
_release/
  szaniec           # launcher; preserves the application's current directory
  README.md
  bin/szaniec       # Well-packaged ELF executable
  bin/lib/          # bundled loader and shared libraries, including glibc
```

Install the local checkout's launcher before changing to an application directory:

```sh
make install
export PATH="$HOME/.local/bin:$PATH"
szaniec complexity --project-root test/fixtures/tasks-app \
  --config complexity.toml --sort complexity
```

`make install` builds the bundle, then creates or replaces the
`~/.local/bin/szaniec` symbolic link to this checkout's `_release/szaniec`
launcher. Reinstallation is safe; an existing regular file is preserved and
reported as an error. Keep the checkout and its complete `_release` directory
in place. Subsequent builds update the linked bundle automatically. To use the
bundle temporarily without installing, add `$PWD/_release` to `PATH` instead.

Use `_release/szaniec`, rather than `bin/szaniec`, for calls from arbitrary
directories. Well sets a relative ELF interpreter; the launcher explicitly
uses the bundled loader and libraries without changing the working directory.
It also preserves the launcher identity for nested coverage processes.
Its only launcher dependencies are Linux `/bin/sh` and `readlink`/`dirname`.

`well build` itself remains available for the raw bundle; `make build` adds
the CLI launcher and verifies relocation. `_build/default/bin/szaniec.exe`
remains the development executable. Coverage consumers also need the `szaniec`
package's Dune instrumentation backend in their application build; installing
the CLI archive alone does not provide it.

### Try the architecture fixture

From the Szaniec checkout, inspect a temporary copy of the valid application:

```sh
fixture=$(mktemp -d)
cp -R test/fixtures/tasks-app/. "$fixture/"
dune exec szaniec -- approve --project-root "$fixture"
dune exec szaniec -- check --project-root "$fixture" --rebuild --json \
  --out /tmp/tasks-app-callgraph.json > /tmp/tasks-app-findings.json
rm -rf "$fixture"
```

The unmodified fixture should report `status: ok`, zero violations and gaps,
and exit 0. Its generated-code stand-ins and Well API stub are documented in
the [fixture README](test/fixtures/tasks-app/README.md).

## Linux releases

Publishing a GitHub Release triggers [Linux release](.github/workflows/release.yml).
It builds the release's tag on native Linux runners for **x86_64** and
**aarch64 (ARM64)**, verifies the bundle and acceptance suites, and uploads:

```text
szaniec-<tag>-linux-x86_64.tar.gz
szaniec-<tag>-linux-x86_64.tar.gz.sha256
szaniec-<tag>-linux-aarch64.tar.gz
szaniec-<tag>-linux-aarch64.tar.gz.sha256
```

Create and publish a release in GitHub's Releases UI, selecting a tag whose
commit contains the workflow. For example, after selecting the intended
commit, the equivalent CLI command is:

```sh
gh release create v0.1.0 --target main --generate-notes --title "Szaniec v0.1.0"
```

`v0.1.0` is an example tag. The workflow adds binary assets after successful
builds for both architectures; publishing a draft triggers it, saving a draft
does not. For recovery, run the workflow manually with the existing release
tag. It checks out that tag and replaces assets with the same names. It does
not create a release on its own.

To package locally without publishing anything:

```sh
make release VERSION=v0.1.0
```

Download and install a published release, choosing the matching architecture:

```sh
release_tag=v0.1.0  # replace with an available release tag
release_arch=x86_64 # use aarch64 on ARM64 Linux
archive="szaniec-${release_tag}-linux-${release_arch}.tar.gz"
gh release download "$release_tag" --repo finalclass/szaniec \
  --pattern "$archive" --pattern "$archive.sha256"
sha256sum --check "$archive.sha256"
mkdir -p "$HOME/.local/share/szaniec/$release_tag" "$HOME/.local/bin"
tar xzf "$archive" -C "$HOME/.local/share/szaniec/$release_tag"
ln -sfn "$HOME/.local/share/szaniec/$release_tag/szaniec" "$HOME/.local/bin/szaniec"
export PATH="$HOME/.local/bin:$PATH"
```

Keep the extracted directory intact: the executable uses its bundled loader
and libraries. This is a dynamically linked Linux bundle, not a static binary
or a cross-architecture executable. Bundling glibc removes reliance on the
target system's glibc version for Szaniec itself; it does not bundle the
application's compiler/build tools or external commands such as `curl`.

CI installs the Well CLI from the pinned public commit recorded in
[the build setup action](.github/actions/setup-build/action.yml); no sibling
checkout or machine-specific path is required. The packaging helper is
[TypeScript on Deno](scripts/release.ts). Its generated POSIX shell launcher
runs without Deno on the target machine. `bin/dune` provides `main.exe` as a
copy of the existing executable because Well's packager expects that path.

## Configure a project

Initialize `szaniec.toml` in the Git repository root, including when called
from a nested directory:

```sh
szaniec init
```

The file contains `format`, a policy name taken from the project directory,
`roots = ["lib"]`, and an empty `approved_shared_modules` list. Review the
roots to include the intended source directories. Initialization does not
approve the policy and refuses to replace any existing file or symbolic link.
Use `--project-root <dir>` or `--config <path>` to select a different location.

Services and methods continue to come from `.cyrograf` contracts; TOML only
configures analysis scope, approved sharing, protected resources, and command
defaults. It does not duplicate the service architecture.

An example with a protected resource is:

```toml
format = "szaniec-config/1"

[policy]
name = "my-app"
roots = ["lib"]
approved_shared_modules = []

[[policy.resources]]
name = "database"
api_prefixes = ["Well.Db.", "Sqlite3."]
```

Szaniec finds the Git root from the current directory, including nested
subdirectories and worktrees. Outside Git it uses the nearest Dune root.
`--project-root <dir>` explicitly selects an analyzed root; `--config <path>`
selects another TOML document. Relative input and output paths resolve against
the selected root. CLI options override settings from the command's section.
Missing files, malformed TOML, unknown keys and invalid values fail with exit 2.

`[policy].roots` selects source directories relative to that root. Keep tests,
static assets and data outside the roots when they are not application code.
The scanner skips `_build`, `node_modules` and hidden subdirectories. Explicit
test roots can be inventoried, as the complexity fixture demonstrates.

The file also holds optional `[check]`, `[complexity]`, `[coverage]` and
`[suggestions]` defaults, plus the approval recorded by `approve`. See
[the complete configuration reference](docs/contracts/configuration.md).
Reports, provider fixtures, inventories, caches and recorded suggestion decisions
remain JSON artifacts. Existing policy, approval and coverage JSON configuration
files and `--policy`/`--approval`/`--api-candidates` options are no longer read;
move their values into the corresponding TOML sections. Existing JSON-byte
approval digests require a new approval through architecture review after
migration. Credentials stay in the environment.

Do not put a service list or permitted-edge list in the policy. Services are
discovered from `.cyrograf` files declaring `rpc` methods, for example
`lib/contract/Task_manager.cyrograf`:

```text
rpc list(ListReq) -> TaskList
rpc add(AddReq) -> Task
```

Roles follow the filename suffix, case-insensitively:

| Example service | Role |
|---|---|
| `Web_client` | Client |
| `Task_manager` | Manager |
| `Template_engine` | Engine |
| `Task_access` | Access |
| `Clock` | Utility |

A contract without `rpc` methods does not declare a service. Implementations
must be bound and registered through the supported Well mechanics. The
[public tasks fixture](test/fixtures/tasks-app/README.md) includes contracts,
generated-code stand-ins, service libraries, and a composition root.

Private helpers belong in their service's directory tree; nested directories
and modules are supported. Compiler evidence such as `make_spec` also binds
ownership. One observed caller does not adopt an outside helper. Naming a
folder `common`, `shared`, or `utils` does not approve shared implementation.

For infrastructure explicitly approved by the architecture, list its
canonical module path:

```toml
# In [policy]:
approved_shared_modules = ["App.Clock"]
```

Approval applies while the policy digest matches `[approval]`. It does not
make cross-service business implementation reuse acceptable or grant a
disallowed caller access to protected resources.

Record the approved identity after selecting the policy:

```sh
szaniec approve
```

This updates `[approval].policy_name` and `[approval].policy_digest` in the same
TOML file. The command serializes the document atomically and preserves section
values, but drops comments. SHA-256 covers the normalized policy values;
formatting and measurement settings do not change the approved identity.
Policy edits require deliberate approval through the project's review process.
Do not approve automatically on every check. CI selects the approved document
outside the implementation patch.

## Check architecture

Build and inspect the declared program:

```sh
szaniec check \
  --project-root . --rebuild
```

Once artifacts are fresh, omit `--rebuild`:

```sh
szaniec check --json
```

Configuration comes from the selected root's `szaniec.toml`. `--rebuild` runs
`dune build` before extraction.
Missing, stale, unreadable, or unsupported artifacts produce gaps.

### What the checker catches

| Example | Expected interpretation |
|---|---|
| Client calls Manager, which calls Access | Allowed; not collapsed into Client → Access |
| Client calls Access directly or through a private helper/proxy | `ID-CLIENT-ACCESS` |
| Client calls Engine | `ID-CLIENT-ENGINE` |
| Engine calls another Engine | `ID-ENGINE-ENGINE` |
| Access calls another Access | `ID-ACCESS-ACCESS` |
| Access calls Manager or Engine | `ID-ACCESS-OUTBOUND` |
| Manager, Engine, or Access calls a Client | Corresponding `ID-*-CLIENT` violation |
| Manager synchronously calls another Manager | `ID-MANAGER-MANAGER` |
| One Client path calls two distinct Managers | `UC-CLIENT-MULTI-MANAGER` |
| One queued path targets several Managers | `Q-MULTI-MANAGER` |
| A queued command targets Engine or Access | `Q-TARGET-ROLE` |
| A non-Manager publishes an event | `EVT-PUBLISH-ROLE` |
| A role other than Client or Manager subscribes | `EVT-SUBSCRIBE-ROLE` |
| Code reaches another service's implementation | `IMPL-ACCESS-CROSS-SERVICE` |
| Several families execute unapproved outside implementation | `SHARED-UNAPPROVED` |
| A disallowed owner directly accesses a protected resource API | `RESOURCE-BOUNDARY` |
| New in-scope implementation has no owner | `POLICY-UNCLASSIFIED` |
| A contract call names a method absent from its `rpc` declarations | `SPEC-UNDECLARED-METHOD` |
| A declared service is not bound/registered | `SPEC-UNREGISTERED-SERVICE` |

Separate handlers and mutually exclusive branches do not count as one path.
For example, these conceptual Client paths have different results:

```text
handler: Task_manager.list; Notification_manager.list  -> two Managers: violation
handler: if condition then Task_manager.list
         else Notification_manager.list               -> one per alternative
```

These illustrate analysis behavior, not complete OCaml applications.
`Well.request` is a queued command; a Manager may delegate to another Manager
this way. Targets come from subscribers to the same topic. `Well.publish`
and `Well.subscribe`, including supported keyed and MessageBus variants,
are events. Publishing does not create a synchronous call to each subscriber.
An unresolved topic or a request with no observed subscriber is a gap.

Calls, aliases, value references, and callbacks can expose implementation
access. One consumer is enough for an implementation-access violation;
type-only references do not count as executable sharing. The
[rule catalog](docs/contracts/rule-catalog.md) defines the full criteria.

### Reports and call graph

Save diagnostic JSON separately from the graph:

```sh
szaniec check --json --out /tmp/my-app-callgraph.json \
  > /tmp/my-app-findings.json
```

**`check --out` selects the call-graph file**, not the diagnostic report.
By default the graph is written to `szaniec.json` in the project root, including
runs with findings or gaps. To avoid writing it:

```sh
szaniec check --json --no-callgraph > /tmp/my-app-findings.json
```

Diagnostic JSON includes `status` (`ok`, `violations`, or `incomplete`),
`inputs`, `findings`, and `summary`. Each finding keeps its rule identifier,
severity, participants, locations, and evidence path. Inputs identify the
policy and approved digest, source snapshot, compiler, adapters, and rules.
A report can contain both confirmed violations and analysis gaps.

The separate `szaniec-callgraph/1` artifact lists services, declared methods,
observed outgoing/incoming calls, unresolved calls, and unclassified units.
It is a projection of this run, not a hand-maintained architecture allowlist.

## Inspect function complexity

List functions in source order, or review the most complex first:

```sh
szaniec complexity --rebuild
szaniec complexity --sort complexity
szaniec complexity --json \
  > /tmp/my-app-functions.json
```

The metric is local cyclomatic complexity `szaniec-cc/1`. Straight-line code
starts at 1; decisions add to the count. Simple examples:

```ocaml
let increment x = x + 1                         (* complexity 1 *)
let absolute x = if x < 0 then -x else x         (* complexity 2 *)
let sign x =                                   (* complexity 3 *)
  if x < 0 then -1 else if x = 0 then 0 else 1
```

Matches, guards, short-circuit operators, loops, and exception/effect handlers
have metric-specific counting rules. Nested functions are separate entries;
the outer function does not absorb their decisions. Unused functions and
anonymous callbacks are inventoried. A curried syntactic function is one
entry; aliases and partial applications do not receive invented bodies.

The JSON report includes source spans, names/ids, ownership when known,
provenance, file coverage, gaps, complexity values, and summary statistics.
Here, file **coverage** means completeness of static inventory, not execution
coverage. Unmeasurable definitions retain a gap and a null complexity.

There is no complexity threshold. `--sort complexity` sorts descending,
then by id, with unmeasurable definitions last. `[approval]` records the
policy's approval status; lack of approval alone does not fail this inventory.
The command does not write `szaniec.json`. See the
[metric specification](docs/contracts/complexity-metric.md) for exact counts.

## Measure coverage and CRAP

Coverage runs an existing scenario against an instrumented build. It measures
**executed source points**, not branch/path/assertion coverage. The measurement
window is the server process, including startup before the first request.

### Add the Dune hook

Every in-scope application library and executable needs the backend:

```lisp
(library
 (name app)
 (instrumentation (backend szaniec.instrumentation)))

(executable
 (name server)
 (libraries app)
 (instrumentation (backend szaniec.instrumentation)))
```

Keep existing `(preprocess (pps ...))` rewriters in their own stanzas.
Ordinary `dune build` does not activate instrumentation; `szaniec coverage`
adds `--instrument-with szaniec.instrumentation`. Consumers use this one
backend; the internal points and probe engines are composed behind it.
PPX rewriter libraries and test-directory stanzas are outside application scope.

### Configure and run a scenario

Add the scenario to `szaniec.toml` (adjust the executable and scenario paths):

```toml
[coverage]
scope = ["lib", "bin"]
build = ["dune", "build", "bin/server.exe"]
server = "_build/default/bin/server.exe"
scenario = [
  "deno", "run", "--allow-run", "--allow-net", "--allow-env",
  "--allow-read", "--allow-write", "scenarios/http.ts"
]
```

All configuration paths are relative to the discovered Dune root, found by
walking parents from `--project-root` to `dune-project`. The build command
must start with `dune`. The scenario is your application's existing scenario,
not a new assertion language. Coverage supplies `COVERAGE_SERVER`,
`SZANIEC_BIN`, and `SZANIEC_COVERAGE_CONTEXT` for launching the built server.

```sh
szaniec coverage --project-root .
szaniec coverage --json --out /tmp/my-app-coverage.json
```

Unlike `check --out`, **`coverage --out` writes the coverage report JSON**.
The report is also printed (as text unless `--json` is present). Raw point
files and the temporary collection context are removed after reporting.
`--keep-work` retains that context and prints its path for investigation;
remove it after use. Coverage requires no policy approval.

For a scenario that sanitizes its environment, launch each server through
`supervise`, preserving `SZANIEC_COVERAGE_CONTEXT` and passing required
application variables explicitly:

```sh
szaniec coverage supervise --port 8080 --pass-env PORT -- "$COVERAGE_SERVER"
```

Run that inside the scenario, with `PORT=8080` in its environment and the
coverage context inherited. The adapter prints `pid <n>` and `ready`, then
waits for the server. In Deno, the same launch can be expressed as:

```typescript
const child = new Deno.Command(Deno.env.get("SZANIEC_BIN")!, {
  args: ["coverage", "supervise", "--port", "8080", "--pass-env", "PORT",
    "--", Deno.env.get("COVERAGE_SERVER")!],
  env: { PORT: "8080" },
  stdout: "piped",
}).spawn();
// Consume readiness, run your assertions, then stop the server gracefully.
```

This is a launch excerpt. The [complete public HTTP scenario](test/fixtures/coverage-app/scenarios/http.ts)
shows readiness, assertions, sanitized environments, shutdown, restarts, and
concurrent processes. Graceful application exit must run its flush handlers;
`supervise` does not install an application signal handler. `SIGKILL` or a
signal that prevents flushing yields incomplete coverage. Compatible records
from restarts and concurrent nodes are merged only for the same source snapshot.

### Interpret coverage and add CRAP

A function with points but no visits is **measured and unexecuted**. A function
with no instrumented points is **uninstrumented**, not measured at 0%.
Summary counts distinguish these states. Scenario failure and collection gaps
are reported separately and can coexist.

Supply the complexity inventory to calculate per-function CRAP:

```sh
szaniec complexity --rebuild --json \
  > /tmp/my-app-functions.json
szaniec coverage --function-inventory /tmp/my-app-functions.json \
  --json --out /tmp/my-app-coverage.json
```

For point coverage fraction `c` and local complexity `cc`:

```text
CRAP = cc^2 * (1 - c)^3 + cc
```

For example, complexity 3 gives CRAP 3.00 at full point coverage and 12.00 at
zero point coverage. Inventory joining uses source path, local name, and line;
regenerate it after source changes. Missing complexity or missing points
makes the score unavailable with a reason. There is no coverage or CRAP gate.
The [coverage contract](docs/contracts/coverage.md) defines all report fields.

## Review code-quality suggestions

Suggestions review selected definitions for naming, exact duplication,
possible semantic reuse, a local mix of responsibilities, and complicated
constructs. They do not edit source or change `check` results, exit status,
policy, or call graph. Architecture checking remains usable without Jev.

### Live review

With `curl` installed and `TYPESAFE_API_KEY` supplied through your environment:

```sh
szaniec suggestions --rebuild
szaniec suggestions --json \
  > /tmp/my-app-suggestions.json
```

The policy selects program roots; suggestions do not validate its approval. Only a live
suggestions command sends selected source context to
`https://api.typesafe.ai/v1/systemone`. Do not put a credential in a command,
configuration file, cache, or report.

All categories remain experimental, including those enabled by default.
`--experimental` adds pilot criteria for vocabulary consistency, predicate
clarity, unexpected effects, mode flags, comment mismatch, unnecessary
indirection, and idiomatic alternatives.

```sh
szaniec suggestions --experimental \
  --budget-names 4 --budget-pairs 2 \
  --budget-responsibility 2 --budget-complexity 2 --timeout 30
```

Default budgets are 12 name subjects, 6 reuse pairs, 6 responsibility
candidates, and 6 complexity candidates. Budgets limit candidates, not money.
Default timeout is 30 seconds. `--model <id>` selects the requested model
(default `jev-latest`). Each model state contains bounded source context;
truncation is marked. Retrieval does not send every function automatically.

Configure project-relevant API candidates inline for the experimental
idiomatic-alternative review:

```toml
[suggestions]
api_candidates = ["List.filter_map", "Option.map"]
# Optional command defaults:
model = "jev-latest"
timeout = 30
budget_names = 12
```

```sh
szaniec suggestions --experimental
```

Without a candidate list, that criterion is explicitly listed as not run.

### Cache and offline replay

The default cache is `szaniec/suggestion-cache.json`. A matching source
snapshot, rubric, model, budgets, and question state replays cached answers.
Changed inputs miss the cache. Live inference is not claimed to be
deterministic; fixture replay and cache hits are.

```sh
szaniec suggestions --cache /tmp/my-app-suggestion-cache.json
szaniec suggestions --refresh
szaniec suggestions --no-cache
```

For an offline example using the public corpus, run from this repository:

```sh
dune exec szaniec -- suggestions \
  --project-root test/fixtures/suggestions-corpus \
  --rebuild --json --no-cache \
  --provider-fixture szaniec/provider-fixture.json
```

`--provider-fixture` replaces the network call; no key is needed. The
[corpus README](test/fixtures/suggestions-corpus/README.md) explains the
smells and counterexamples. Missing credentials, provider failure, invalid
fixtures, or catalog gaps are unavailable/incomplete review, not empty success.

### Interpret results and record decisions

The report includes suggestions, uncertain judgments, source locations,
subjects, ownership relations, category status, provider/model information,
cache state, gaps, and summary counts. Exact duplicates are static matches;
semantic reuse is a model judgment, not proof of equivalent behavior.
Duplicate code across services must not be merged into an unapproved shared
business library. Uncertainty stays visible and does not become a suggestion.

Copy an actual suggestion id from the report and record your decision:

```sh
szaniec suggestions decide --id 'name-quality:App.Web_client.Names.x:x' \
  --decision reject --rationale "This short binding is clear in its local context."

szaniec suggestions decide --id 'name-quality:App.Web_client.Names.x:x' \
  --decision defer --rationale "Review after the handler refactor."
```

The id above illustrates a report id; use the one from your own run.
Decisions are `apply`, `reject`, or `defer`, with a required non-empty rationale.
`apply` records a decision; it does not perform the edit. The default file is
`szaniec/suggestion-decisions.json`; `--decisions <path>` selects another.
Subsequent reviews join decisions by suggestion id. See the
[suggestion contract](docs/contracts/suggestion-contract.md) for the rubric,
provider fixtures, cache, and decision formats.

## Exit statuses and automation

| Command | Exit 0 | Exit 1 | Exit 2 |
|---|---|---|---|
| `approve` | Approval written | Unused | Execution failure |
| `check` | No violations or gaps | Violations, complete analysis | Gaps, unapproved policy, or execution failure; violations retained |
| `complexity` | Inventory complete | Unused | Incomplete inventory or execution failure |
| `coverage` | Scenario passed, collection complete | Scenario failed, collection complete | Incomplete collection or execution failure |
| `suggestions` | Review complete; suggestions may exist | Unused | Unavailable provider/review, catalog gaps, or execution failure |
| `suggestions decide` | Decision recorded | Unused | Invalid decision or file/error |

A CI architecture gate can preserve JSON and the command's status:

```sh
if szaniec check \
    --rebuild --json --no-callgraph \
    > /tmp/my-app-findings.json; then
  echo "Architecture check passed"
else
  check_status=$?
  cat /tmp/my-app-findings.json
  exit "$check_status"
fi
```

Use separate runs for measurements and optional review. A suggestion count,
high complexity, or low point coverage is not an architecture-check failure.
Reports in these examples go to `/tmp`; handle them as temporary artifacts,
not source files.

## Troubleshooting and limits

| Symptom | What to check |
|---|---|
| `GAP-UNOBSERVED-SOURCE` / `GAP-STALE-ARTIFACT` | Run the appropriate Dune build or `--rebuild`; verify every declared source has a fresh `.cmt` |
| `GAP-UNSUPPORTED-COMPILER` | Build with OCaml 5.4.x; artifacts from another compiler series are unsupported |
| `GAP-POLICY-NOT-APPROVED` | Compare policy to its approved identity; reapprove only through the intended architecture review |
| `POLICY-UNCLASSIFIED` | Check contracts, family layout, binding evidence, or an explicit infrastructure approval |
| `GAP-AMBIGUOUS-OWNERSHIP` | Resolve conflicting ownership evidence or ambiguous module matching |
| `GAP-UNRESOLVED-CALL` | A dynamic/local function target is unsupported; the report preserves the site |
| `GAP-AMBIGUOUS-PATH` | Path alternatives exceed support, such as recursive helper inlining or mixed calling `try`/`with` paths |
| `GAP-UNRESOLVED-TARGET` | Resolve the queue topic and ensure its subscriber is observed |
| `COVERAGE-MISSING-HOOK` | Add the backend to every in-scope library/executable |
| `COVERAGE-NO-EVIDENCE` / `COVERAGE-MISSING-OUTPUT` | Verify instrumented server launch, context propagation, and normal flush |
| `COVERAGE-FORCED-TERMINATION` | Make the application exit gracefully; a killed process is not measured as zero |
| `COVERAGE-STALE-SNAPSHOT` | Avoid source changes while the build and scenario run |
| CRAP unavailable | Supply a matching complexity inventory and verify the function has points |
| Suggestions unavailable | Check credentials, `curl`, timeout, fixture/decision files, and fresh compiler artifacts |

Declared architecture exclusions are `.mlx` views, `.mli` interfaces, Dune
wrapper units, and resource access beyond policy-declared API prefixes.
Unresolved locally bound calls are gaps, not exclusions that permit a pass.
Commands/events and Client use-case paths are supported with explicit evidence
limits; the path builder caps executable alternatives at 48.

Coverage excludes `.mli`, branch/path/assertion coverage, and undeclared MLX
view files. An in-scope `.mlx` under a declared `mlx` dialect is a gap.
Action preprocessors and class/object methods are unsupported and produce
gaps. The facade's internal points engine is `bisect_ppx_ng` 3.0.0; consumers
do not configure that package's backend or measurement environment directly.

Suggestions do not validate tests against specifications, prove equivalence,
judge whole-program correctness, or generate/apply code changes. Local
complexity measurements are separate from model judgments about complicated
constructs. Preserve unresolved evidence in every workflow.

## Verification and reference documents

From this repository's root:

```sh
dune pkg lock                       # resolve/verify dependency lock
make build                          # well build, bundle, launcher, archive
deno check scripts/release.ts
make verify                         # formatter, unit tests, integration suites

# Individual verification entry points:
dune exec ocamlformat -- --check $(git ls-files '*.ml')
dune build @test/unit/runtest
deno test --allow-read --allow-write --allow-run test/config/run.ts
test/acceptance/run.sh               # architecture and complexity
test/acceptance/suggestions.sh       # fixture replay; check stays unchanged
test/coverage/run.sh                 # instrumentation and HTTP scenarios
```

Architecture acceptance mutates copies of
[test/fixtures/tasks-app](test/fixtures/tasks-app/README.md), rebuilds real
compiler artifacts, and compares reports with golden files. Complexity cases
cover nested/anonymous functions, shadowing, recursion, branches, handlers,
and incomplete artifacts. The fixture documents its Well API stub; it is not
an undocumented dependency on a sibling checkout.

The [coverage fixture](test/fixtures/coverage-app/README.md) exercises a normal
uninstrumented build, application PPX, sanitized environments, restarts,
concurrent nodes, graceful/forced termination, missing hooks, and stale source.
Suggestion acceptance replays local answers and verifies that a review changes
neither `check` output nor its call graph. No routine test calls the provider.
[CI](.github/workflows/ci.yml) packages through Well, checks formatting and the
Deno helper, and runs `make verify`. That target runs integration suites
sequentially, outside the parent Dune alias: coverage builds the same project
and needs its own Dune lock. CI and releases also run
the HTTP coverage fixture through the packaged launcher, exercising its nested
`supervise` launches from outside the bundle directory.

This README is the usage guide. Detailed formats and accepted design live in:

- [Architecture](ARCHITECTURE.md) and [implementation brief](IMPLEMENTATION.md).
- [Project configuration](docs/contracts/configuration.md).
- [Policy and approval format](docs/contracts/policy-format.md).
- [CLI, diagnostics, and call graph](docs/contracts/inspection-contract.md).
- [Rule catalog](docs/contracts/rule-catalog.md).
- [Complexity metric](docs/contracts/complexity-metric.md).
- [Coverage workflow and gaps](docs/contracts/coverage.md).
- [Suggestion rubric, cache, fixtures, and decisions](docs/contracts/suggestion-contract.md).
- [Observation](docs/contracts/observation-schema.md) and
  [interpretation](docs/contracts/interpretation-schema.md) schemas.
- [Stack decision](docs/decisions/stack.md),
  [don'ts-based rules decision](docs/decisions/donts-based-rules.md), and
  [agent instructions](AGENTS.md).
