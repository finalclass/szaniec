# Contract: local Cognitive Complexity

Default metric identifier: `szaniec-cognitive/1`.
Legacy cyclomatic metric identifier: `szaniec-cc/1` (`--metric cyclomatic`).
Report identifier: `szaniec-complexity/1`.

The default metric estimates the difficulty of understanding one OCaml
function body. It is an explicitly versioned OCaml adaptation of
[SonarSource Cognitive Complexity](https://www.sonarsource.com/blog/cognitive-complexity-because-testability-understandability/),
not a claim of identical scores across language analyzers. It is not a
service integration graph metric or a conformance rule. Thresholds are deliberately
absent: ConformanceEngine does not judge this number.

ProgramAccess extracts definitions and counts decisions from the typed
tree of a fresh, supported `.cmt`. CheckClient renders the inventory.
A definition the metric cannot measure is a gap with null complexity.
A measured straight-line cognitive score of 0 is valid.

## What is a definition

A definition is one syntactic function:

- `let f x y = e`, `let rec`, and `fun x y -> e` are each one definition.
  Curried parameters of that single construct stay one definition.
- `let f x = fun y -> e` is two definitions. The inner `fun` is anonymous.
- Local `let` functions, mutually recursive groups, nested functions,
  and callbacks are each their own definition.
- A function with no call in its body, and a function nothing calls, are
  still definitions. The inventory is not built from observed call edges.
- `let g = f` is an alias. `let g = f x` is a partial application. Neither
  has a body of its own, so neither is invented a complexity.
- A binding-operator continuation (`let+`, `and+`, `let*`) is part of the
  enclosing function, not a new definition.
- Toplevel `let () = e` is not a function. Anonymous functions inside it
  are definitions; decisions in `e` itself belong to no function.
- External library symbols are references, not definitions discovered here.
- `.mli` interfaces and `.mlx` views have no implementation body in this
  profile and are exclusions, not silent omissions.

Nested bodies are not added to the function that contains them. The
parent counts the binding or the closure expression as straight-line
code.

## Identity

Named definitions use the compiler identifier, qualified by the module
path and any enclosing functions: `Metric.Samples.outer.nested`. The
compilation unit is the canonical module path from the observation
schema. The source span is stored beside the identity.

The same qualified name in one unit more than once (shadowing) gets
`@line:col` appended to every copy, in source order.

Anonymous definitions are source-based:
`{unit}.{enclosing}#anon@{line}:{col}`. At the top of a unit, `{enclosing}`
is the module qualifier, or the unit itself when there is none.

## Cognitive Complexity: szaniec-cognitive/1

A straight-line function starts at **0**. Control-flow nesting starts at 0
for each inventoried function. Nested functions and callbacks are measured
independently, without adding their bodies or lexical nesting to the parent.
This function-local convention is deliberate for OCaml; it differs from
analyzers that include lambda bodies in their enclosing method's score.

Only authored flow constructs contribute. Compiler ghost wrappers neither
increment the score nor increase nesting; their children are still visited
so authored optional defaults and decisions are retained. Unmeasurable
constructs remain null with a gap, never 0.

| Construct | Cognitive increment and traversal |
|---|---|
| `if` | +1 + current depth; then/else bodies at depth +1 |
| `else if` | +1, without another nesting penalty; body at the chain's depth +1 |
| Final `else` | +1, without a nesting penalty |
| `match` or `function` | +1 + depth once for the whole choice, including a single-arm match; number of arms and or-patterns add nothing |
| Match scrutinee | Evaluated at the incoming depth; it is not inside an arm |
| Match arm bodies | Walked at depth +1 |
| `when` | +1 + arm depth, then its expression is walked at that depth |
| Primitive `&&` / `||` | +1 per homogeneous sequence; switching operator starts another sequence; no nesting penalty |
| `for` / `while` | +1 + depth; children at depth +1 |
| Each exception/effect `try` handler | +1 + depth; handler body/guard at depth +1 |
| `try` body | No increment and no extra nesting |
| Direct recursion cycle | +1 per participating function, once per body |
| Sequential `let*`, `let+`, `and+` | No increment and no new nesting; operands and continuation stay in the enclosing function |

A logical sequence flattens adjacent primitive boolean expressions in source
order, across parentheses: `a && b && c` costs 1; `a && b || c && d`
costs 3. An intervening call such as `not (...)` starts an independent
expression. User-defined operators with these spellings remain ordinary calls.

Recursion uses compiler identifiers and direct calls within a lexical
`let rec ... and ...` binding group. A function must actually participate
in a call cycle; an unused `rec`, acyclic sibling call, or shadowed name
adds nothing. Calls through aliases, returned functions or higher-order
values are not resolved into recursion by this local metric. Nested function
bodies do not establish recursion for an enclosing function.

Calls, function declarations, ordinary bindings, return/raise, assertions,
records, tuples and sequential composition add nothing themselves. Expressions
inside them are visited. A refutable parameter's implicit match failure adds
nothing. No source-length penalty or project threshold is built into the metric.

Executable examples in `test/complexity/run.ts` prove the intended distinction:
a flat 20-arm dispatcher scores **1** (cyclomatic 20), seven nested binary
matches score **28** (cyclomatic 8), and three sequential Result bindings
score **0** (cyclomatic 1). The suite also covers boolean sequences, guards,
else-if chains, defaults, recursion, callbacks and cached metric selection.

## Legacy cyclomatic decision count: szaniec-cc/1

Select with `--metric cyclomatic` or `[complexity].metric = "cyclomatic"`.
This remains available for path-count analysis and CRAP; cognitive scores
must never be substituted into the CRAP formula.

The complexity of a measured body is `1 + decisions`. Only nodes whose
location is not a compiler ghost location contribute. Ghost locations
are how the typed tree marks compiler-inserted branches, including the
implicit `Match_failure` arm of a partial match. User-written
unreachable code is still counted. This metric does not run a
reachability analysis.

| Construct | Added decisions |
|---|---|
| `if` / `then` / `else`, including `if` without `else` | +1 |
| `match` or `function` with n non-ghost arms | +(n − 1), or +0 when n is 0 or 1 |
| `when` guard on a non-ghost arm | +1, then the guard expression is walked |
| primitive `&&` (`%sequand`) or `\|\|` (`%sequor`) | +1 per operator |
| `while` or `for` | +1 |
| `try` exception handler, each non-ghost arm | +1 |
| `try` effect handler, each non-ghost arm | +1 |

`match` arms are the value arms, the exception arms, and the effect
arms of that one match, excluding ghost arms. The first arm continues
the incoming path; each further arm adds one. A `try` is different:
the body is already the incoming path, so every handler adds one.

Or-patterns inside a single arm do not add a decision. `raise`,
`failwith`, and `assert` are not decisions; an `assert` condition is
still walked, so a short-circuit inside it counts. Applications other
than the two short-circuit primitives, including a user-defined `&&`
or `||`, are calls, not decisions. Sequences, records, tuples,
constructors, assignments, and recursive calls add nothing by
themselves.

Optional-argument defaults are walked as part of the function that
declares them. The implicit "argument omitted" branch is
compiler-generated and is not counted. A refutable parameter pattern
(`let f (Some x) =`) does not add a decision for its implicit
`Match_failure`.

Decisions inside a nested function, including one that appears in a
default or a guard, belong to that nested function.

## Constructs that are not measured

An object, a class, or a method send inside a function makes that
function `unmeasurable`. Its complexity is null. The report carries
`GAP-UNMEASURABLE` and status `incomplete`. A class definition at
module scope produces the same gap. These gaps belong to the complexity
report. They are not conformance findings.

## Provenance and ownership

- `authored` — an in-scope implementation file.
- `test` — a path segment `test` or `tests`.
- `generated` — a `.ml-gen` wrapper, or a definition whose own location
  is a ghost location (a compiler- or ppx-inserted function).

Dune wrapper units are inventoried with provenance `generated`. They
stay out of the conformance unit list. A `.ml-gen` path that dune keeps
only under `_build` is not a stale project source: the artifact is
measured, and the coverage row stays `generated` / `measured`.

Module ownership travels with the canonical unit. Service ownership is
joined from the interpretation when the unit has one. A missing class
does not drop the function: `ownership` is `unclassified` and `service`
is null. A direct module-level function whose name is a declared `rpc`
method of that service is reported as `binding: "rpc"`. Every other
definition is `binding: "function"`.

## Report

`szaniec complexity` defaults to Cognitive Complexity and prints the inventory as text or as one JSON
document (`--json`). `--metric cognitive|cyclomatic` overrides the configured
metric. The report and every entry carry the selected metric identifier; the
JSON format stays `szaniec-complexity/1`. Consumers must check `metric` rather
than assume that `complexity` is a path count. Default order is source order
(`path`, `line`, `col`, `id`). `--sort complexity` orders by descending
complexity, then by `id`; unmeasurable entries sort last.

Identical inputs and versions produce byte-identical JSON for a given
sort. Exit status is `0` when every in-scope file was measured and no
measurement gap was recorded, and `2` when analysis is incomplete.
Complexity is not a violation, so the command never exits `1`.

Coverage lists every scanned source and every generated file that was
opened, with status `measured`, `stale`, `unobserved`, `unreadable`,
`unsupported-compiler`, or `unmeasurable`. A stale, missing, or
unreadable artifact contributes no function records. `unmeasurable`
coverage means the typedtree is not a complete implementation (the
source did not type-check) or the walk failed; that file contributes
no function records and a `GAP-UNMEASURABLE` entry. A measured file
may still list individual functions with null complexity when only
those bodies contain an unsupported construct. Policy approval is
recorded on the report and does not by itself make the inventory
incomplete.
