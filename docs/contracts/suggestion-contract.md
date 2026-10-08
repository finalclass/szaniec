# Contract: code-quality suggestions

Format identifiers:

- machine-readable report: `szaniec-suggestions/1`
- rubric: `szaniec-suggestion-rubric/1`
- cache: `szaniec-suggestion-cache/1`
- decisions: `szaniec-suggestion-decisions/1`
- test fixture: `szaniec-suggestion-fixture/1`

Suggestions are an optional review. They are not conformance findings.
`szaniec check` does not call the judgment provider, does not read the
suggestion cache or decision file, and keeps the exit statuses in the
[inspection contract](inspection-contract.md). A suggestion never changes
a check exit from 0 to 1 or from 1 to 0.

## Commands

```
szaniec suggestions [--config <path>] [--project-root <dir>] [--rebuild]
                    [--json] [--experimental] [--model <id>]
                    [--cache <path>] [--no-cache] [--refresh]
                    [--timeout <seconds>]
                    [--budget-names <n>] [--budget-pairs <n>]
                    [--budget-responsibility <n>] [--budget-complexity <n>]
                    [--provider-fixture <path>] [--decisions <path>]

szaniec suggestions decide --id <suggestion-id>
                    --decision apply|reject|defer
                    --rationale <text> [--decisions <path>]
                    [--project-root <dir>] [--config <path>]
```

- Configuration discovery and defaults follow [project configuration](configuration.md).
  Program roots come from `[policy]`. Suggestions do not validate approval
  or report architectural violations.
- `--rebuild` runs `dune build` before extraction. Without it, stale or
  missing artifacts are gaps and are not used as current evidence.
- `--provider-fixture` answers from a local file. Without it, the command
  sends the selected context to `https://api.typesafe.ai/v1/systemone`
  using the `TYPESAFE_API_KEY` environment variable and the `curl`
  executable. The key is not written to the cache, the report, or
  argv. No other command reads the key or sends source text.
- `--experimental` adds the pilot criteria below. It is off by default.
- `[suggestions].api_candidates` is an inline array of strings, consulted
  only for the experimental idiomatic-alternative criterion.
- `decide` records one agent decision and does not call the provider.
  The rationale is required and must be non-empty. Decisions are not
  automatic edits.

## Exit status

| Exit | Meaning |
|---|---|
| 0 | Review finished and the function catalog has no gaps. Suggestions may be present. They are not a failure. |
| 2 | Provider unavailable, fixture or decision file unusable, rebuild failed, or the catalog has gaps. Suggestions are omitted when the provider fails. |

Exit 1 is reserved for `szaniec check` violations. This command does not
use it.

## Components

CheckClient parses the command and renders the report.
SuggestionManager selects candidates, applies templates, and composes
the report. ProgramAccess supplies the function catalog from compiler
artifacts. ArchitectureAccess supplies service ownership from
`.cyrograf` files. ModelAccess submits typed questions and returns
typed answers.

SuggestionManager does not call InterpretationEngine or
ConformanceEngine. InspectionManager does not call ModelAccess.
Remote calls are not added to the OCaml adapter.

## Function catalog

ProgramAccess returns one catalog for the fresh in-scope
implementations. `szaniec complexity` is a separate inventory of
cyclomatic complexity and does not store bodies, parameters, or
comments. This command does not report complexity numbers. The
suggestion catalog reads source text for the judgments below.

Each definition has:

- `id` — named definitions are
  `<canonical-unit>.<enclosing names>.<binding name>`. A repeated id in
  one unit gains `:<line>`. Anonymous definitions are
  `<canonical-unit>.<enclosing>#anon:<source path>:<line>:<col>`.
- source span, parameter names, and up to 24 let-bound variable names
  in the body
- binding text and body text, each stored up to 8000 characters
- `normalizedBody` — comments removed, whitespace collapsed, case
  preserved. Used only to detect exact duplicates
- provenance `authored` (or `test` when the path contains a `test`
  segment) and kind `top-level`, `local`, or `anonymous`
- source status `available` or `unavailable`

One source definition is one entry. Curried parameters stay on that
entry. `let f = g` and a partial application do not receive an invented
body; a `fun` or `function` that is itself the binding is named. Nested
function bodies are separate entries.

Ownership is the cyrograf service whose stem matches a canonical path
segment, using the same matching rule as the policy contract. No match
is `unclassified`. Two matches are `ambiguous`. Lack of ownership does
not drop the definition.

Gaps use the observation codes for stale, missing, unreadable, and
unsupported-compiler artifacts, plus `GAP-SUGGESTION-NO-SOURCE` when a
definition has no usable source slice. A gap is never reported as a
clean empty review.

## Candidate retrieval

Retrieval is deterministic. The model never sees a global name list as
a substitute for a concrete definition.

Defaults: 12 name subjects, 6 reuse pairs, 6 responsibility candidates,
6 complexity candidates, 1200 characters of body text sent to the
model. Experimental criteria use a budget of 6 subjects each. Truncated
text is marked in the state.

- **Exact duplicate.** Two available named definitions whose normalized
  bodies are equal and at least 40 characters. No model call. The
  suggestion cites both ids. `same-service` may be reused inside that
  service. `distinct-services` must not be merged into an unapproved
  shared module. `unclassified` and `ambiguous` are reported as such.
- **Semantic reuse.** Remaining named pairs with normalized length at
  least 40, at least 4 tokens of length 3 or more on each side, and
  Jaccard similarity at least 0.45. Highest similarity first, then the
  sorted id pair. The model judges that pair from both bodies,
  signatures, and ownership. It is not labeled an exact match.
- **Names.** A function, parameter, or variable name is a candidate
  when its ident is a single character or one of: `tmp`, `temp`,
  `data`, `foo`, `bar`, `baz`, `obj`, `item`, `value`, `result`,
  `flag`, `info`, `thing`, `stuff`, `process`, `handle`, `helper`,
  `util`, `misc`, `arg`, `args`, `lst`, `list`, `res`, `ret`, `ok`,
  `xs`. Function names are taken before parameters, then variables.
  The state includes the body, parameters, ownership, and up to 8
  resolved call sites from the observation (`caller` at `path:line`).
  Unresolved callees are not invented.
- **Responsibility mix.** Normalized body at least 180 characters and
  at least two distinct capitalized module prefixes, or both an effect
  token (`open_out`, `output_string`, `Unix.`, `Sys.`, `send`, `save`,
  `store`, `print_`) and a formatting token (`Printf`, `Format`,
  `string_of`, `^`).
- **Complicated construct.** At least 6 of `match`, `if `, `&&`, and
  `||` in the body, or at least 35 lines.

Clear names and short straight-line functions are not sent. That
exclusion is a retrieval rule, not a model judgment.

## Judgments

Each selected subject produces one question. Questions that share the
same state are sent together. A later request is not used to invent
wording; templates below are the only suggestion text.

The provider is Jev through the System One HTTP API. Question ids are
for the report. Instructions carry the judgment. Primitives:

| Criterion | Primitive | Suggestion when |
|---|---|---|
| `name-quality` | choice `misleading`, `uninformative`, `acceptable`, `insufficient-context` | `misleading` or `uninformative`, confidence ≥ 0.60 |
| `semantic-reuse` | noul | noul ≥ 0.75 |
| `responsibility-mix` | noul | noul ≥ 0.72 |
| `complicated-construct` | score levels 0, 1, 2 | score ≥ 1.40 and confidence ≥ 0.55 |

Uncertain outcomes stay in `judgments` and do not become suggestions:

- choice confidence < 0.60, or `insufficient-context`
- noul in [0.40, 0.75) for reuse and in [0.40, 0.72) for the other nouls
- score confidence < 0.55 while score ≥ 1.00

Anything else is `no-issue`. Noul has no separate confidence field.
Choice and score confidence are the provider's distribution summary,
not a correctness probability. The report stores the returned
probabilities, the pinned response model id, token counts, and the
requested model id.

`exact-duplicate` is `primitive: "static"` and `origin: "static"`.
Model suggestions use `origin: "model"`.

### Templates

- name: `The name '<name>' on '<id>' is judged <misleading|uninformative>. This is not an architectural violation; a coding agent may propose a replacement.`
- exact, same service: `Exact static match: '<a>' and '<b>' have the same normalized body. This is not a model judgment. A coding agent may reuse one definition inside service <service>.`
- exact, distinct services: `Exact static match: '<a>' and '<b>' have the same normalized body. They belong to <s1> and <s2>. Do not merge them into an unapproved shared module.`
- exact, other ownership: `Exact static match: '<a>' and '<b>' have the same normalized body. Ownership is <relation>. This is not a model judgment.`
- semantic, same service: `Model judgment, not an exact static match: '<a>' and '<b>' may implement the same behavior. Reuse must stay inside service <service>.`
- semantic, distinct services: `Model judgment, not an exact static match: '<a>' and '<b>' may implement the same behavior, but they belong to <s1> and <s2>. Do not combine them into a shared business library.`
- responsibility: `The definition '<id>' is judged to mix unrelated responsibilities visible in its body. This does not change architecture policy.`
- complexity: `The definition '<id>' is judged to contain an unnecessarily complicated construct. This is not a complexity gate and not a check failure.`

## Experimental criteria

Every category in this contract, including the four above, has
`scope: "experimental"` and `promotion: "not-evaluated"`. A recorded
live run with cost and latency is required before any category is
described as verified. The corpus under
`test/fixtures/suggestions-corpus` holds smells and counterexamples for
that future run. Routine tests use fixtures and do not call the
provider.

`--experimental` also asks, with the same uncertain band as the other
nouls unless noted:

| Criterion | Question |
|---|---|
| `vocabulary-consistency` | choice `inconsistent`, `consistent`, `insufficient-context`, using the file's own definition names as the vocabulary |
| `predicate-clarity` | noul: a boolean name or `not` makes the supplied call sites hard to read. Names containing `not_`, `disable`, or `no_` are candidates |
| `unexpected-effects` | noul: a lookup, format, convert, or render name hides an effect token present in the body. Unknown callees are not inferred |
| `mode-flags` | noul: two or more labelled parameters select unrelated operations. A legitimate option such as `force` is not a smell by itself |
| `comment-mismatch` | noul: the immediately preceding comment contradicts the binding or only restates it |
| `unnecessary-indirection` | noul: the body is a single short forward and adds no naming, adaptation, ownership, or abstraction role. Declared `rpc` methods are not candidates |
| `idiomatic-alternative` | noul per supplied API candidate, at most 4 questions. Without a candidate file the criterion is listed in `criteriaNotRun` and is not asked |

Experimental suggestion text names the criterion and states that it is
not an architectural violation. `idiomatic-alternative` without a
candidate file is the explicit no-applicable-candidate outcome for that
criterion.

## Cache

The cache key is the SHA-256 of the rubric id, requested model,
experimental flag, budgets, snapshot digest, and the canonical question
states. A hit replays stored answers and the response model id and does
not call the provider. `--refresh` replaces the entry. A changed source
digest, rubric, model id, budget, or question state misses. Failed
provider calls are not cached. The file stores at most 32 entries.
Live inference is not claimed to be deterministic; a fixture replay and
a cache hit are.

## Report

```json
{
  "format": "szaniec-suggestions/1",
  "status": "available",
  "detail": "",
  "rubric": "szaniec-suggestion-rubric/1",
  "inputs": {
    "snapshotDigest": "sha256:...",
    "modelRequested": "jev-latest",
    "modelReturned": "jev-1.13.0",
    "cache": "miss",
    "experimental": false,
    "catalogComplete": true,
    "inputTokens": 0,
    "outputTokens": 0
  },
  "categories": [
    {"id": "name-quality", "scope": "experimental", "promotion": "not-evaluated"}
  ],
  "suggestions": [
    {
      "id": "name-quality:App.Web_client.Names.x:x",
      "criterion": "name-quality",
      "scope": "experimental",
      "origin": "model",
      "message": "...",
      "subjects": ["App.Web_client.Names.x"],
      "locations": [{"path": "lib/web_client/names.ml", "line": 1, "col": 0}],
      "ownershipRelation": null,
      "decision": null,
      "rationale": null
    }
  ],
  "judgments": [],
  "criteriaNotRun": [
    {"id": "idiomatic-alternative", "reason": "no API candidate list supplied"}
  ],
  "gaps": [],
  "summary": {"suggestions": 1, "uncertain": 0, "definitions": 12, "gaps": 0}
}
```

`status` is `unavailable` when the provider, fixture, or decision file
fails. `detail` then explains the failure, and `suggestions` and
`judgments` are empty. `cache` is `hit`, `miss`, `refreshed`,
`disabled`, or `not-used` (no model question was asked).

Judgments are sorted by id. Suggestions follow the same order. JSON
object key order is fixed by the encoder. Identical catalog, fixture
answers, rubric, and decisions produce byte-identical JSON.

The text report renders the same facts. Rendering belongs to
CheckClient's command path; what counts as a suggestion is this
contract.

## Decisions file

```json
{
  "format": "szaniec-suggestion-decisions/1",
  "decisions": [
    {"suggestionId": "name-quality:App.Web_client.Names.x:x",
     "decision": "reject", "rationale": "the binding is a fixture example"}
  ]
}
```

Records are sorted by `suggestionId`. A decision does not edit source
and does not alter policy.

## Fixture file

```json
{
  "format": "szaniec-suggestion-fixture/1",
  "model": "fixture-model-1",
  "fail": null,
  "onMissing": "default",
  "defaults": {
    "noul": {"type": "noul", "noul": 0.05},
    "choice": {
      "type": "choice",
      "choice": "acceptable",
      "probabilities": {
        "acceptable": 0.9,
        "misleading": 0.04,
        "uninformative": 0.03,
        "insufficient-context": 0.03
      },
      "confidence": 0.86
    }
  },
  "answers": {}
}
```

`fail` as a string makes the provider unavailable with that detail.
`onMissing: "error"` is unavailable when an asked id is absent.
Answers are keyed by question id.

## Out of scope

Test-to-specification validation, whole-program correctness, proof of
semantic equivalence, code generation, automatic edits, a required
acceptance rate, and blocking `szaniec check` on a suggestion.
Cyclomatic complexity thresholds are not this rubric.
