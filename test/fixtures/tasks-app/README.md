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

The base tree must pass `szaniec check` with exit 0. Acceptance scenarios
in `test/acceptance` apply controlled source mutations to copies of this
tree.
