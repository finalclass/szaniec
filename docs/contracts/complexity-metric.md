# Contract: local cyclomatic complexity

Metric identifier: `szaniec-cc/1`.
Report identifier: `szaniec-complexity/1`.

This metric is the local cyclomatic complexity of one OCaml function
body. It is not the cyclomatic complexity of a service integration
graph, and it is not a conformance rule. Thresholds are deliberately
absent: ConformanceEngine does not judge this number.

ProgramAccess extracts definitions and counts decisions from the typed
tree of a fresh, supported `.cmt`. CheckClient renders the inventory.
A definition the metric cannot measure is a gap, never complexity 0.

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

## Decision count

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

`szaniec complexity` prints the inventory as text or as one JSON
document (`--json`). Default order is source order
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
