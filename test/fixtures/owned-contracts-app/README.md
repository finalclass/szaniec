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

The projections have no Well/Cyrograf generator headers. Their native
compilation units use `App_service_*` names; the approved configuration binds
short native/browser aliases to exact `.cyrograf` sources. Some aliases use
explicit `module type of` signatures. Declared message members include data,
wire and nested Storage conversions; callback references retain raw compiler
dependency evidence. No generated library or aggregator is whitelisted.

Native/browser `Payload` modules retain the generated struct serializer bodies
from [Cyrograf's OCaml generator](https://github.com/finalclass/cyrograf/blob/8f07d974c633054ec44196bedab5e130b454c129/lib/compiler/codegen_ocaml.ml),
including `encode_value`/`decode_value`, runtime primitives and `Syntax` opens.
The runtime and error representation are reduced to the string-field shape used
here; this is compiler acceptance, not serializer interoperability testing.
The runtime's primitive/Syntax surface and compiler dependencies establish private
serialization ownership alongside the approved message binding. They grant no
public runtime/helper API. Controlled mutations put private calls/callbacks and
protected resource calls inside the actual serializer bodies.

A Deno preprocessing action replaces a source module placeholder with the public
Common binding. Its original and compiler-input contents differ deliberately.
The acceptance suite rewrites unchanged plain contracts, aliases and an interface,
performs an incremental build, and verifies retained identities against older
artifacts without requesting another rebuild. Real edits remain stale. Touching
an original preprocessed source cannot be excused by its transformed digest;
fresh transformation evidence or a successful rebuild is required.

Run from the Szaniec root:

```sh
make build
dune build test/acceptance/contract_observation.exe
deno test --allow-read --allow-write --allow-run --allow-env test/acceptance/public_contracts.ts
```

The Deno runner uses the packaged `_release/szaniec` launcher from a temporary
application directory. `SZANIEC_TEST_BINARY` can select a separate packaged
version for reproduction. It copies the fixture, approves its base policy,
builds fresh compiler artifacts and checks deterministic reports. A compiler
probe verifies the retained constructor/codec/callback paths and exact aliases.
The probe uses OCaml to call ProgramAccess's typed observation API directly;
scenario automation remains Deno/TypeScript. Controlled mutations verify the
acceptance cases in
[the interpretation contract](../../../docs/contracts/interpretation-schema.md#owned-public-surfaces).
They also remove Common bindings, remove contract artifacts, and make native
contract targets or native/browser aggregators stale. Missing evidence retains
gaps and unresolved graph edges instead of guessed implementation access.
Temporary sources and reports are deleted after the test.

Verified with `make build`, `make verify`, and
`deno check scripts/release.ts test/acceptance/public_contracts.ts test/acceptance/application_contracts.ts test/fixtures/owned-contracts-app/lib/generated/preprocessed/transform.ts`.
The packaged base observes **18 units, 78 calls, 4 type references, 0 violations
and 0 gaps**, using OCaml **5.4.1**, Dune **3.24.2**, OCaml adapter **1.5.0**, Well
adapter **3.4.0** and rules **3.1.0**. The full verification also covers the
application-generated fixture with development and packaged executables,
architecture/complexity goldens, repetition, configuration, suggestions and
coverage. Private callbacks, serializer/runtime resources, unsupported
serializer calls, changed compiler interfaces, missing artifacts and stale
targets/aggregators retain their findings or gaps. Compiler-applied `-pp`/`-ppx`
needs a successful rebuild because its transformation dependencies are not
proven by the recorded digest.

The constrained-alias regression was reproduced using a separately packaged
pre-change checker on fresh artifacts before extending this fixture with
serializer and transformation cases. The counts above describe this
redistributable application; they do not predict a reduction in either
incomplete downstream report from #25.
