# Fixture: owned public contracts

This redistributable OCaml 5.4.1 application exercises source-to-diagnostic
contract ownership with an empty shared implementation whitelist. It uses
the compiler lock from the suggestions fixture. `test/fixtures/dune` marks
this tree as data so its package does not change Szaniec's dependency scope.

The generated modules are small stand-ins for the public shapes verified in
[Well's Contract_build](https://github.com/finalclass/well/blob/276baf8cffa0db5f849196194083ca4726a0a326/lib/well_cli/contract_build.ml)
and [Contract_adapters](https://github.com/finalclass/well/blob/276baf8cffa0db5f849196194083ca4726a0a326/lib/well_cli/contract_adapters.ml):
data libraries, message `make`/`to_drut`/`from_drut`, service `make_spec`, and
browser `Proxy.method`. Wire transport, HTTP and serializer implementations
are reduced to plain strings and callbacks. This fixture proves compiler
binding and conformance behavior, not runtime interoperability with Well or
a browser. The framework stub supplies registration and a context type only.

Common declares data and no RPC. Task_access constructs its own Result;
Task_manager and Web_client consume Common through native/browser projections,
library aggregators, nested modules and module aliases. Task_manager also
calls Task_access's declared in-process `Api.Public.read`. The `.mli` exposes
`internal` deliberately: compiler visibility alone must not grant a public
architectural facet. Store and Lock remain service-private.

Run from the Szaniec root:

```sh
dune build bin/szaniec.exe
deno test --allow-read --allow-write --allow-run --allow-env test/acceptance/public_contracts.ts
```

The Deno runner copies the fixture into a temporary directory, approves its
base policy, builds it and checks deterministic reports. Controlled mutations
verify the acceptance cases in
[the interpretation contract](../../../docs/contracts/interpretation-schema.md#owned-public-surfaces).
Temporary sources and reports are deleted after the test.
