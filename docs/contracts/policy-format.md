# Contract: approved policy format

Format identifier: `szaniec-policy/2` (JSON).

Policy is an approved-architecture input. It declares program roots,
approved sharing, and protected resources. Services, roles and methods are
NOT declared here: they are discovered from cyrograf contract files and
from compiler-resolved evidence (see
[the decision record](../decisions/donts-based-rules.md)).

## File shape

```json
{
  "format": "szaniec-policy/2",
  "policyName": "tasks-app",
  "program": { "roots": ["lib"] },
  "approvedSharedModules": [],
  "resources": [
    { "name": "database", "apiPrefixes": ["Well.Db.", "Sqlite3."] }
  ]
}
```

## Fields

- `format` — must be exactly `szaniec-policy/2`; otherwise the policy is
  rejected as an execution error (exit 2).
- `policyName` — stable identity string, recorded in the report.
- `program.roots` — source directories that constitute the declared
  program, relative to the project root. Only files under these roots are
  in scope. Directories `test`, `static`, `data`, `_build` and hidden
  directories are never in scope, even if listed.
- `approvedSharedModules` — canonical module paths (matched as a full
  path or as a trailing `.name`) that the approved architecture allows
  several families to execute. They are infrastructure exceptions, not
  a second ownership inference. A repository-local module is not on
  this list because its directory is `common`, `shared` or `utils`, or
  because its Dune library was renamed. These entries are honored only
  when the policy digest equals the approved digest. An edited policy
  keeps being checked, but its whitelist does not suppress
  `SHARED-UNAPPROVED`, `IMPL-ACCESS-CROSS-SERVICE`,
  `POLICY-UNCLASSIFIED` or `RESOURCE-BOUNDARY`. Listing a module here
  does not let a Client or any other disallowed role reach a protected
  resource; the rule catalog still decides who may perform that access.
- `resources[]` — protected resources; `apiPrefixes` are resolved-call
  path prefixes that count as access to the resource. Which roles may
  perform access is fixed by the rule catalog (Access-role services and
  shared-approved modules), not by the policy.

## Services and roles (not in the policy)

- A `.cyrograf` file under a program root whose stem is a service name
  and which declares `rpc` methods is a service; the file's stem is the
  service name.
- The role of a service is inferred from its name suffix,
  case-insensitively: `manager` → Manager, `client` → Client,
  `engine` → Engine, `access` → Access, any other name → Utility.
- A service whose contract declares no `rpc` methods is not a service.
- A service never registered in the composition root is a
  `SPEC-UNREGISTERED-SERVICE` violation.

## Module path matching

`approvedSharedModules` entries match canonical module paths: a declared
name matches when it equals the path or the path ends with `.` plus the
declared name. If more than one observed unit matches one entry, that
entry approves nothing and produces `GAP-AMBIGUOUS-OWNERSHIP`.

Service-family membership is not a policy list. The interpretation
contract binds it from the source layout, compiler evidence and the
canonical path. Stem matching is case-insensitive and ignores
underscores. A private file under the service directory belongs to that
family even when the compiled module name does not repeat the stem.

## Approved-policy selection

The approved identity is recorded in a separate approval file
(`szaniec-approval/1`), written by `szaniec approve --policy <path>
[--approval <path>]`:

```json
{
  "format": "szaniec-approval/1",
  "policyName": "tasks-app",
  "policyDigest": "sha256:..."
}
```

`check` selects the policy through its CLI arguments (`--policy`,
`--approval`). Selection is explicit; CI selects it outside the
implementation patch. A modified policy file is not automatically
approved: when the current file digest differs from the recorded one, the
check continues against the file content but adds
`GAP-POLICY-NOT-APPROVED` (exit 2) and records both digests in the report.

Digest: SHA-256 over the raw policy file bytes, rendered as `sha256:<hex>`.