# Fixture: suggestions corpus

A small public OCaml library used to exercise `szaniec suggestions`. It is
not an architecture sample that is expected to pass `szaniec check`, and it
is not a recorded evaluation of Jev. Every suggestion category stays
experimental until a live run records cost and latency.

The fixed answers in `szaniec/provider-fixture.json` are a test double.
They do not claim that the model judged these definitions correctly.

## Smells the retrieval rules can see

- `lib/web_client/names.ml`: `x` and `data` are uninformative names.
- `lib/task_manager/titles.ml` and `lib/notification_manager/titles.ml`:
  `normalize_title` is an exact duplicate across two services. A suggestion
  must cite both definitions and must not propose an unapproved shared
  module.
- `clean_title` is a near-duplicate of `normalize_title` inside
  `Task_manager`. That pair is a model question, not an exact match.
- `handle_task` writes a file and prints a line (responsibility hypothesis).
- `choose_channel` is a local nest of conditions (complexity hypothesis).
- `not_disable_validation`, `render ~as_email ~as_pdf`, the comment above
  `store_note`, `forward_trim`, and `lookup_title` are pilot hypotheses
  used only with `--experimental`.

## Counterexamples

- `format_label` and `format_due_date` use specific names and are not name
  candidates. `format_due_date` binds a local name, so it is not a one-line
  forward. `format_label` is a one-line conversion: `--experimental` may ask
  about that indirection, and the fixture answers no-issue.
- `list_open` forwards its argument, but the name is the declared
  `Task_manager` rpc, so it is not an indirection candidate.
- A fixture answer of `acceptable`, or a noul below the uncertain band, is
  a no-issue outcome. Retrieval of `data` does not by itself create a
  suggestion.

## Build

This directory is its own dune package (`dune-project`, `dune.lock`). The
Szaniec workspace does not build it. The suggestions acceptance script
copies it, builds the copy, and replays the fixture.
