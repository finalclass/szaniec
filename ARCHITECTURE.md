# Architecture

Szaniec protects an IDesign architecture expressed as dune libraries, and
measures OCaml Cognitive Complexity. Its first and only target is the DG
project. The approach is recorded in
[dune structural enforcement](docs/decisions/dune-structural-enforcement.md).

## Purpose

`szaniec check` verifies that every dependency a dune file declares is
allowed by the IDesign closed-architecture rules and the Well library
profile. Together with `(implicit_transitive_deps false)`, which makes the
compiler reject any use of a library that is not a direct dependency, this
enforces the architecture without analyzing calls. Whether the architecture
was correctly decomposed around volatility is outside the product's scope.

`szaniec complexity` inventories every OCaml function from compiler-typed
artifacts and reports its local Cognitive Complexity. It is a measurement,
not a conformance rule.

## Volatility analysis

| Potential change | Reason for change | Owning component |
|---|---|---|
| Invocation and presentation | Terminal, CI, output formats | CheckClient |
| Use-case sequence | New inputs to a check, build before measuring | InspectionManager |
| Reading the build description | dune syntax, directory rules, stanza forms | ProjectAccess |
| Reading the approved services | `.cyrograf` syntax and location | ArchitectureAccess |
| Reading compiler artifacts | Compiler version, `.cmt` format, preprocessors | ProgramAccess |
| Conformance criteria | Naming conventions, role matrix, library profile, coaching | ConformanceEngine |

Services, libraries and rules are input variability. They do not justify a
component per service, rule or library.

## Components

These are logical components within one local program.

```static-architecture
Szaniec

Who
- [CheckClient]

What
- [InspectionManager]

How
- [ConformanceEngine]

How-to-access -> Where
- [ProjectAccess]->(DuneFiles)
- [ArchitectureAccess]->(CyrografContracts)
- [ProgramAccess]->(CompilerArtifacts)
```

| Component | Library | Responsibility |
|---|---|---|
| CheckClient | `bin/` | Parse arguments, render text/JSON, map results to exit status |
| InspectionManager | `szaniec_inspection_manager` | Run `check` (read, then evaluate) and `complexity` (build, then measure) |
| ProjectAccess | `szaniec_project_access` | Walk the tree like dune; parse `dune-project` and `dune` files into stanzas, dependencies and positions |
| ArchitectureAccess | `szaniec_architecture_access` | Read `.cyrograf` files in the walked directories; return services |
| ProgramAccess | `szaniec_program_access` | Check `.cmt` freshness and measure every syntactic function |
| ConformanceEngine | `szaniec_conformance_engine` | Classify stanzas and dependency names, evaluate rules, attach coaching |

Permitted calls: CheckClient calls InspectionManager. InspectionManager calls
ProjectAccess, ArchitectureAccess, ConformanceEngine and ProgramAccess.
Access components do not call each other: InspectionManager passes the
directories walked by ProjectAccess to ArchitectureAccess. ConformanceEngine
is pure: it receives facts and returns a report, and reads no files.
CheckClient does not call Access components or the Engine.

`szaniec_model` holds the data contracts exchanged between components:
`Structure` (dune and service facts, produced by ProjectAccess and
ArchitectureAccess, consumed by ConformanceEngine), `Conformance` (the check
report, produced by ConformanceEngine, rendered by CheckClient),
`Observation` and `Complexity` (measurement facts from ProgramAccess, the
report assembled by InspectionManager), and `Version`. It contains types and
trivial projections only.

Szaniec's own `dune-project` declares `(implicit_transitive_deps false)`, so
these permitted calls are enforced by the compiler in this repository too.

## Check

1. ProjectAccess walks the tree from the project root. It skips `_` and `.`
   directories by default, honours `dirs`, `data_only_dirs` and
   `vendored_dirs`, follows `subdir` and `include`, and never enters
   `_build`. A file that cannot be parsed fails the check (exit 2).
2. ArchitectureAccess reads the services from `.cyrograf` files with `rpc`
   methods in the walked directories.
3. ConformanceEngine classifies every stanza and every dependency name by
   naming convention (service implementation, contract family, facet,
   composition root, local component), assigns roles, and evaluates each
   declared dependency. Findings carry the rule id, both endpoints, the
   `path:line:col` of the offending atom, a message and coaching.

The rules, conventions and coaching are the
[rule catalog](docs/contracts/rule-catalog.md); the invocation and report
are the [check contract](docs/contracts/check-contract.md).

| Exit status | Meaning |
|---|---|
| 0 | Conforming |
| 1 | Violations |
| 2 | Usage error, unreadable or unparseable input |

## Complexity

InspectionManager optionally runs the project's build command, then asks
ProgramAccess for a measurement of the selected source roots. ProgramAccess
reads only artifacts that are current for their sources (or vouched for by a
successful rebuild); anything stale, missing, unreadable, from another
compiler series or not measurable is a gap, and the report is incomplete
(exit 2). See the [complexity contract](docs/contracts/complexity-metric.md).

## Basis

The rules follow Juval Löwy's *Righting Software*: closed architecture,
Utilities and the design don'ts in chapter 3. The component design above is
original project design. It is not a claim of official IDesign
certification.
