# Contract: approved policy format

Format identifier: `szaniec-policy/1` (JSON).

Policy is an approved-architecture input. It declares components, roles,
ownership, approved interactions, resources and external libraries. Szaniec
never infers these from code.

## File shape

```json
{
  "format": "szaniec-policy/1",
  "policyName": "tasks-app",
  "profile": "well-ocaml-core",
  "program": { "roots": ["bin", "lib"] },
  "compositionRoots": ["App", "Main"],
  "services": [
    {
      "name": "TaskAccess",
      "role": "access",
      "contractModules": ["Task_access"],
      "implementationModules": ["App.Services.Task_access_impl"],
      "helperModules": ["App.Common.Json_util"]
    }
  ],
  "approvedCalls": [
    { "from": "WebClient", "to": "TaskManager" }
  ],
  "approvedSharedModules": [],
  "resources": [
    { "name": "database", "apiPrefixes": ["Well.Db."], "accessors": ["TaskAccess"] }
  ],
  "externalLibraries": [
    { "name": "well", "unitPrefixes": ["Well"] }
  ]
}
```

## Fields

- `format` — must be exactly `szaniec-policy/1`; otherwise the policy is
  rejected as an execution error (exit 2).
- `policyName` — stable identity string, recorded in the report.
- `profile` — optional; defaults to `well-ocaml-core`. Any other value
  produces `GAP-PROFILE-UNSUPPORTED`.
- `program.roots` — source directories that constitute the declared
  program. Only files under these roots (relative to the project root)
  are in scope. Directories `test`, `static`, `data`, `_build` and hidden
  directories are never in scope, even if listed.
- `compositionRoots` — modules permitted to reference service
  implementations for registration/wiring.
- `services[].role` — one of `client`, `manager`, `engine`, `access`.
  Declared by the architect; never inferred.
- `services[].contractModules` — generated or hand-maintained public
  contract modules of the service. Their internal code is treated as
  framework-generated proxy mechanics.
- `services[].implementationModules` — units implementing the service.
- `services[].helperModules` — private helpers inside the service
  boundary. A helper consumed by another boundary stops being private and
  becomes an unapproved shared module finding.
- `approvedCalls` — the complete set of allowed service-to-service call
  edges (owner to owner). A layer-correct edge absent from this list is a
  `POLICY-UNAPPROVED-CALL` violation.
- `approvedSharedModules` — modules that may be consumed (called) by
  multiple boundaries.
- `resources[]` — protected resources; `apiPrefixes` are resolved-call
  path prefixes that count as access to the resource; `accessors` are the
  owners allowed to perform the access.
- `externalLibraries[]` — `unitPrefixes` are canonical module path
  prefixes treated as external library code (out of app scope, usable by
  anyone per their own permissions; a library approval does not grant
  resource access).

## Module path matching

Module names in the policy are matched against canonical module paths from
the observation. A declared name matches when it equals the canonical path
or the canonical path ends with `.` + declared name. If more than one
observed unit matches a declared name, ownership of those units is
ambiguous and produces `GAP-AMBIGUOUS-OWNERSHIP` instead of a guess.

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