# Contract: szaniec check

Report identifier: `szaniec-check/2`. Profile: `well-ocaml`.
Rules: [rule catalog](rule-catalog.md). Rationale:
[dune structural enforcement](../decisions/dune-structural-enforcement.md).

## Invocation

```text
szaniec check [<dir> | --project-root <dir>] [--json]
```

`<dir>` defaults to the current directory and must contain `dune-project`.
There is no configuration file and no build. Output goes to stdout; errors
go to stderr.

| Exit | Meaning |
|---|---|
| 0 | conforming: no findings |
| 1 | violations: at least one finding |
| 2 | usage error, unreadable file, unparseable dune file, missing `dune-project` |

On exit 2 nothing is printed to stdout; stderr carries
`szaniec: path:line:col: message` when a location is known.

## Inputs

ProjectAccess walks the source tree like dune:

- directories starting with `.` or `_` are skipped by default (`:standard`);
  `_build` is never entered;
- `(dirs ...)` is evaluated with dune's predicate language (`:standard`,
  globs with `*`, `?`, `[...]`, `{a,b}`, `\` difference, `or`, `and`, `not`);
  `(ignored_subdirs (...))` is honoured;
- `(data_only_dirs ...)`: dune files inside are not read; `.cyrograf` files
  are still read;
- `(vendored_dirs ...)`: nothing inside is read;
- `(subdir <path> <stanzas>)` applies stanzas to that directory (which may
  not exist on disk), recursively; `(include <file>)` splices a file;
- every `dune-project` met (the root and nested projects) is read.

The S-expression parser supports atoms, quoted strings with escapes, `"\|`
and `"\>` block strings, `;` comments, `#| |#` block comments (nesting) and
`#;` datum comments. Positions are 1-based line and column. OCaml-syntax
dune files are rejected.

Stanzas: `library` (by `name`, also resolvable by `public_name`),
`executable`/`executables`, `test`/`tests` (one component per name),
`copy_files`/`copy_files#`. `(modules ...)` partitions are irrelevant: each
library stanza is its own component. Other stanzas are ignored.

Dependencies of a stanza: atoms of `(libraries ...)` including every
alternative of `(select ... from ...)` (negated `!lib` alternatives are not
dependencies) and `(re_export X)`; `(pps ...)` and `(staged_pps ...)` inside
`(preprocess ...)` up to `--`, skipping flags; `(ppx_runtime_libraries ...)`.
A `%{...}` variable in a dependency position is `DUNE-UNSUPPORTED`.

ArchitectureAccess reads `.cyrograf` files in the walked directories; a file
with at least one `rpc name(Req) -> Res` line is a service named after its
file stem.

## Classification

See the table in the [decision record](../decisions/dune-structural-enforcement.md#naming-conventions-are-the-policy).
Precedence: `_root` suffix, service key, contract family
(`_contract`, `_browser`, `_spec`, `_wire`), facet (longest
`<service>_` prefix on underscore boundaries), local component. Roles come
from the service name or, for local components, the library name suffix.

A dependency name not defined by any scanned stanza is classified with the
same conventions. If it is an exact name of the Well profile table, contains
a dot, or classifies as a plain local Utility, it is an external library.
Otherwise it is evaluated like a project library, and its endpoint kind is
`undefined-library`.

## JSON report

```json
{
  "format": "szaniec-check/2",
  "status": "violations",
  "project": "/abs/path",
  "profile": "well-ocaml",
  "services": [
    {"name": "TaskAccess", "source": "contracts/TaskAccess.cyrograf",
     "methods": ["store"]}
  ],
  "components": [
    {"name": "task_access_api", "kind": "library", "class": "facet",
     "role": "access", "service": "TaskAccess",
     "location": {"path": "lib/task_access/dune", "line": 12, "col": 8}}
  ],
  "findings": [
    {"rule": "ID-CLIENT-ACCESS",
     "from": {"name": "admin_client", "kind": "library", "class": "local",
              "role": "client"},
     "to": {"name": "task_access_api", "kind": "library", "class": "facet",
            "role": "access"},
     "location": {"path": "lib/admin/dune", "line": 3, "col": 13},
     "message": "Client admin_client depends on facet task_access_api of ResourceAccess TaskAccess",
     "coaching": "Clients enter the business layer only through a Manager. …"}
  ]
}
```

- `components[].kind`: `library`, `executable`, `test`.
- `components[].class`: `service`, `contract`, `browser-contract`, `spec`,
  `wire`, `facet`, `local`, `root`, `test`. `role` is `client`, `manager`,
  `engine`, `access`, `utility`, or null for roots and tests; `service` is
  the owning service or null. `location` is the name atom.
- `from`/`to` endpoints: `kind` is a stanza kind, `undefined-library`,
  `external`, `dune-project`, `directory`, `construct` or `setting`;
  `class` is a component class, `external`, `external:<category>`
  (`framework`, `resource`, `publish`, `subscribe`, `presentation`),
  `project` or `dune`.
- `location` is the offending atom: the dependency name, the field name of
  an unsupported construct, the `copy_files` glob, or the
  `implicit_transitive_deps` / `lang` value in `dune-project` (1:1 when
  neither exists).
- Findings are sorted by path, line, column, rule and target; components by
  position. Identical inputs produce identical output.

The text report prints a summary line, then each rule with its findings as
`path:line:col: message` and the rule's coaching once, then a count per rule.
