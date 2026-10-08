# Contract: approved policy format

Policy is the `[policy]` section of [project configuration](configuration.md).

Policy is an approved-architecture input. It declares program roots,
approved sharing, and protected resources. Services, roles and methods are
NOT declared here: they are discovered from cyrograf contract files and
from compiler-resolved evidence (see
[the decision record](../decisions/donts-based-rules.md)).

## File shape

```toml
[policy]
name = "tasks-app"
roots = ["lib"]
approved_shared_modules = []

[[policy.resources]]
name = "database"
api_prefixes = ["Well.Db.", "Sqlite3."]
```

## Fields

- `name` — stable identity string, recorded in the report.
- `roots` — source directories that constitute the declared
  program, relative to the project root. Only files under these roots are
  in scope. The scanner skips `_build`, `node_modules` and hidden directories.
  Explicit test roots can be inventoried.
- `approved_shared_modules` — canonical module paths (matched as a full
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
- `resources[]` — protected resources; `api_prefixes` are resolved-call
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

`approved_shared_modules` entries match canonical module paths: a declared
name matches when it equals the path or the path ends with `.` plus the
declared name. If more than one observed unit matches one entry, that
entry approves nothing and produces `GAP-AMBIGUOUS-OWNERSHIP`.

Service-family membership is not a policy list. The interpretation
contract binds it from the source layout, compiler evidence and the
canonical path. Stem matching is case-insensitive and ignores
underscores. A private file under the service directory belongs to that
family even when the compiled module name does not repeat the stem.

## Approved-policy selection

The approved identity is embedded in the same TOML document:

```toml
[approval]
policy_name = "tasks-app"
policy_digest = "sha256:..."
```

`szaniec approve [--project-root <dir>] [--config <path>]` records this
identity. It atomically rewrites the parsed document; TOML comments are not
retained by the serializer. Other section values are preserved. CI selects
the approved document outside the implementation patch. Editing policy does
not automatically approve it. Missing approval or a different name/digest
produces `GAP-POLICY-NOT-APPROVED` (exit 2); analysis continues and reports
both digests. Malformed approval is a configuration error.

Digest: SHA-256 over compact UTF-8 JSON encoding of the normalized policy,
with keys in this exact order: `name`, `roots`,
`approved_shared_modules`, `resources`. Each resource has keys `name`
then `api_prefixes`. Arrays retain declared order; optional empty lists
are included. Comments, formatting, key order, approval and other sections
do not affect this identity. Changing any normalized policy value does.
