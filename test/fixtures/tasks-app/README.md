# Fixture: tasks-app

A minimal Well-shaped OCaml application used as the Szaniec acceptance
fixture. Each service is its own library, as in a Well application:

- `lib/contract/*` — `.cyrograf` contracts and the OCaml modules standing
  in for code generated from them (wire codecs, `IMPL` signatures, proxy
  functions). A `.cyrograf` file that declares `rpc` methods is a service.
- `lib/task_access`, `lib/task_manager`, `lib/template_engine`,
  `lib/formatting_engine`, `lib/notification_manager` — service
  implementations. `TaskAccess` uses the private `Json_util` helper in
  `lib/common`.
- `lib/web_client/*` — client layer pages sharing a private `Shared`
  helper, plus the `Audit_client` implementation. That service is a
  Client reached only from scenarios that mutate a caller; the base
  tree registers it and does not call it.
- `lib/app.ml` — composition root (registration + routes).
- `lib/well_stub/` — a documented stub of the Well framework's public API
  surface so the fixture type-checks without the real framework
  dependency. It plays the role of the external `well` library. Typed
  topics (`Well.topic`) live on the contract modules. The base tree does
  not publish, subscribe, or call `Well.request`.
- `szaniec/policy.json` — the approved policy for this application
  (program roots, approved shared modules, protected resources). Services
  and roles are not listed there.

The declared program is `lib` only: dune prunes executable-implementation
`.cmt` artifacts on every subsequent run, so `bin/main.ml` (which only
calls `App.run`) is deliberately outside the checked program. This is an
explicit policy declaration, not a silent skip.

`metric/` and `test/` are outside that program. They are the
`szaniec complexity` fixture (`szaniec/complexity-policy.json`): specimens
for `szaniec-cc/1`, a `Widget_manager` rpc method, and a test-provenance
definition. They are not part of `szaniec check`.

Expected local complexities (`szaniec-cc/1`, one definition each):

| Definition | Complexity |
| --- | --- |
| `straight`, `partial_match`, `outer`, `uses_anon`, `returns_fun`, `unused_plain`, `Local.hidden`, `helper`, `probe`, first `shadow` | 1 |
| `conditional`, `loop_for`, `loop_while`, `recursive`, `even`, `odd`, `exceptional`, `match_exn`, `or_pat`, `outer.nested`, `curried`, `uses_anon` anon, `returns_fun` anon, `if_unit`, `just_raise`, `with_effect`, `ping`, second `shadow` | 2 |
| `multi`, `guarded`, `short`, `if_and`, `two_handlers`, `as_function` | 3 |

`alias_of_straight`, `partial_apply`, and `shadow_kept` are aliases or
a partial application. They have no function body and do not appear.
`outer` does not include the decision inside `outer.nested`. The two
`shadow` definitions share a name; both are inventoried and their ids
carry the source span. `shadow_kept` keeps the first binding in use so
the compiler accepts the redefinition. `probe` is unused and unclassified. `ping` is the
`Widget_manager` rpc method. `metric/recursion.ml` is classified as a
helper of itself because its functions call each other; that ownership
comes from interpretation, and the three functions are still inventoried.

The base tree must pass `szaniec check` with exit 0. Acceptance scenarios
in `test/acceptance` apply controlled source mutations to copies of this
tree.
