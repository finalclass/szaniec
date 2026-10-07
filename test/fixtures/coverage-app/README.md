# Coverage fixture

Public example of the Szaniec coverage hook. The dune files in this
directory name the `szaniec` package's backend and an ordinary ppxlib
rewriter. They do not name the internal points engine.

In this repository the fixture is built by the parent dune project, so
`szaniec/coverage.json` uses paths relative to that dune root. A consumer
whose own `dune-project` is the root uses the same stanza with shorter
paths:

```lisp
(library
 (name app)
 (instrumentation (backend szaniec.instrumentation)))
```

```json
{
  "format": "szaniec-coverage-config/1",
  "scope": ["lib", "bin"],
  "build": ["dune", "build", "bin/server.exe"],
  "server": "_build/default/bin/server.exe",
  "scenario": ["deno", "run", "--allow-run", "--allow-net", "--allow-env", "--allow-read", "--allow-write", "scenarios/http.ts"]
}
```

`lib/core` and `lib/api` are two application libraries. `lib/api` keeps
its own ppx rewriter beside the facade. `bin/server` is the executable the
scenario launches. `lib/views/note.mlx` is present so the report can show
the MLX exclusion; this dune project does not declare an `mlx` dialect.

The scenario is the application's HTTP check. It does not read coverage
files. Sanitized process environments go through `szaniec coverage
supervise`, which is the only runner adapter.

Ordinary `dune build` does not instrument this server. `szaniec coverage`
does, by adding `--instrument-with szaniec.instrumentation` to the build
line above.
