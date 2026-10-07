# Fixture: tasks-app

A minimal Well-shaped OCaml application used as the Szaniec acceptance
fixture. Each service is its own library, as in a Well application:

- `lib/contract/*` — `.cyrograf` contracts and the OCaml modules standing
  in for code generated from them (wire codecs, `IMPL` signatures, proxy
  functions). A `.cyrograf` file that declares `rpc` methods is a service.
- `lib/task_access`, `lib/task_manager`, `lib/template_engine`,
  `lib/formatting_engine`, `lib/notification_manager` — service
  implementations. `Task_access` keeps `Json_util` and `codec/Rows` in
  its own directory tree; those helpers are the family, not a shared
  library.
- `lib/web_client/*` — client layer pages. `Shared` and
  `format/Titles` are private to that directory.
- `lib/report_client/page.ml` — a second client family.
- `lib/clock.ml` — approved infrastructure (`App.Clock` in the policy).
  Web_client and Report_client both call it.
- `lib/app.ml` — composition root (registration + routes).
- `lib/well_stub/` — a documented stub of the Well framework's public API
  surface so the fixture type-checks without the real framework
  dependency. It plays the role of the external `well` library.
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
