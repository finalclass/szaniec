# Cognitive Complexity as the default function metric

## Problem and decision

Cyclomatic complexity answers a path-count question. A flat dispatcher with
20 simple alternatives can score 20 while seven nested binary matches score
8. That ordering does not serve a review concerned with reading nested code.

Make `szaniec complexity` default to `szaniec-cognitive/1`, an OCaml adaptation
of [SonarSource's Cognitive Complexity](https://www.sonarsource.com/blog/cognitive-complexity-because-testability-understandability/).
A whole match costs once, flow nesting increases structural increments, and
straight-line code starts at zero. The exact rules and intentional language
adaptations belong to the [metric contract](../contracts/complexity-metric.md).

Keep syntactic functions as the unit of measurement: named local helpers and
anonymous callbacks have independent entries and start their own depth at zero.
Sequential binding operators retain the enclosing function's depth; typedtree
continuations must not turn a readable Result pipeline into a nesting penalty.
Recursive binding groups use compiler-resolved call cycles rather than spelling
or the presence of the `rec` keyword alone. Higher-order recursion is outside
this local cycle detector's scope.

## Compatibility and evidence

The report shape remains `szaniec-complexity/1`; both the report and its entries
identify their metric. Consumers must validate that identifier. The default
changes the meaning of the numeric field, including allowing measured zeroes.
`--metric cyclomatic` and `[complexity].metric = "cyclomatic"` retain
`szaniec-cc/1` for explicit path-count uses. CRAP still requires cyclomatic
input and rejects cognitive, missing and unknown metric identifiers.

ProgramAccess records both scores in one measurement walk. Observation format
`szaniec-observation/7` and OCaml adapter `1.9.0` invalidate earlier extraction
cache entries; selecting another metric can reuse the new observation safely.

Every acquisition gap that prevents measurement must survive report assembly.
In particular, missing inputs, incomplete typed artifacts and unverifiable
transformations cannot become a successful inventory with absent functions.
The source-to-report regression builds a transformed file outside Szaniec,
requires an incomplete report, then verifies recovery through `--rebuild`.

No project threshold or conformance rule is introduced here. Threshold adoption
is a separate project policy decision.

## Verification

`test/complexity/run.ts` checks hand-derived cognitive and cyclomatic scores
on compiled source, including dispatch, deep nesting, boolean sequences, guards,
else-if chains, exception handling, optional defaults, refutable parameters,
Result operators, callbacks and recursion. It also checks cache determinism,
configuration selection and CLI override. The existing complexity acceptance
suite retains stale/unreadable/unsupported evidence and deterministic reporting.
Coverage unit tests reject the wrong metric before calculating CRAP.

Method sends retain receiver and argument decisions without requiring a resolved
implementation, as ordinary function calls do. The compiled metric examples cover
decisions in either position and separately inventoried callback arguments.
Object/class definitions remain explicit gaps. Adapter `1.9.4` invalidates earlier
extraction entries so previously unmeasurable sends are acquired again.

Run `make verify` and `make build` for the source suites and the relocatable
Linux bundle. Runtime measurements should use the same application revision,
source scope, metric and cache state; compare exit statuses and the full
inventory, including gaps, rather than accepting a faster partial report.
