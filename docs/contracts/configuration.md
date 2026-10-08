# Contract: project configuration

Szaniec reads one TOML document, `szaniec.toml`, with
`format = "szaniec-config/1"`. CheckClient owns the Config infrastructure
module. It discovers, parses, validates and loads the entire document once
per invocation; Managers and ArchitectureAccess receive typed values.
Engines and language adapters do not read configuration files.

## Discovery and precedence

Without `--project-root`, walk parents from the working directory to the
nearest Git root (`.git` directory or worktree marker file). Read only that
root's `szaniec.toml`. Outside Git, use the nearest Dune root, or the working
directory if there is none. An explicit `--project-root` selects that directory
as the analyzed root. `--config <path>` selects an alternative TOML document;
relative paths resolve against the selected root, regardless of files in the
working directory. Missing or unreadable files, malformed TOML, unknown keys,
wrong types and invalid values are execution errors (exit 2).

CLI options override their section's defaults. Analysis roots and all relative
configuration/CLI input and output paths resolve against the selected root.
Coverage build, server, scenario and scope paths resolve against the discovered
Dune root, as specified by the coverage contract. JSON policy, approval,
coverage and API-candidate configuration inputs are no longer accepted.
Reports, provider fixtures, inventories, caches and decision records remain JSON.
Credentials remain in the environment and are never configuration fields.

## Document

```toml
format = "szaniec-config/1"

[policy]
name = "my-app"
roots = ["lib"]
approved_shared_modules = []

[[policy.resources]]
name = "database"
api_prefixes = ["Well.Db.", "Sqlite3."]

[check]
rebuild = false
json = false
no_callgraph = false
out = "szaniec.json"

[complexity]
rebuild = false
json = false
sort = "location"

[coverage]
scope = ["lib", "bin"]
build = ["dune", "build", "bin/server.exe"]
server = "_build/default/bin/server.exe"
scenario = ["deno", "run", "--allow-all", "scenarios/http.ts"]
json = false
keep_work = false
# out = "coverage-report.json"
# function_inventory = "functions.json"

[suggestions]
rebuild = false
json = false
experimental = false
model = "jev-latest"
timeout = 30
budget_names = 12
budget_pairs = 6
budget_responsibility = 6
budget_complexity = 6
cache = "szaniec/suggestion-cache.json"
no_cache = false
refresh = false
decisions = "szaniec/suggestion-decisions.json"
api_candidates = ["List.filter_map", "Option.map"]
# provider_fixture = "szaniec/provider-fixture.json"
```

All sections are optional. Commands using program roots require `[policy]`;
it requires a non-empty name and non-empty list of non-empty relative roots.
Sharing and resource lists default to empty. Each resource requires a non-empty
name and non-empty list of non-empty API prefixes. Roots cannot escape the
project with `..`. `[coverage]` requires scope, build, server and scenario;
scope is non-empty and paths stay under the Dune root. Build and scenario are
non-empty argument arrays, and build starts with Dune. Numeric budgets and
timeout are non-negative integers; model and optional paths are non-empty.
Command settings shown use the defaults, except project-specific paths, scope
and API candidates. Omitted `[check].out` defaults to `szaniec.json`.

`[approval]` is specified by [the policy contract](policy-format.md).

## Acceptance

Verify root discovery from nested directories and Git worktrees; explicit
root/config selection; relative paths independent of the caller's directory;
missing/invalid files, duplicate and unknown fields, wrong types and values;
all sections loaded together; CLI overrides; embedded approval round trips;
policy changes invalidate approval while formatting and measurement settings
do not; absent approval remains a gap; shared exemptions are not honored for
an unapproved policy. Exercise all commands against TOML fixtures, preserve
existing source-to-diagnostic acceptance, and keep coverage supervise usable
without project configuration.

## Migrating JSON configuration

| Previous input | TOML destination |
|---|---|
| Policy `policyName` | `policy.name` |
| Policy `program.roots` | `policy.roots` |
| Policy `approvedSharedModules` | `policy.approved_shared_modules` |
| Policy `resources` with `apiPrefixes` | `[[policy.resources]]` with `api_prefixes` |
| Coverage scope, build, server, scenario | Same fields under `[coverage]` |
| API-candidate JSON array | `suggestions.api_candidates` |
| Approval name and digest | `[approval]`, written by `approve` |

Remove the old configuration format fields. Old approvals hash raw JSON bytes
and cannot be reused with the normalized policy digest. Record a new approval
through the architecture review process after moving the policy values.
