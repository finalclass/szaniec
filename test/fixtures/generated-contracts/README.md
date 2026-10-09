# Generated contract regression fixture

This public overlay is copied into a temporary tasks-app tree by the architecture
acceptance runner. Every scenario rebuilds real OCaml 5.4 compiler artifacts.
The overlay uses the tasks fixture's Dune lock and Well API stub; it does not need
a sibling checkout, a live downstream application, or a generator at test time.

The OCaml sources are minimal generated-code stand-ins. Native `Contract_data`
and browser `Contract_data_browser` modules expose nested `Request` and `Storage`
conversions. `App_server` and `App_browser` contain prefixed `App_service_`
bindings, module aliases, and nested `Proxy` RPC methods. Five existing contract
families cover Managers, Engines, and Access. They are not additional services
and require no additions to `approved_shared_modules`.

The generator headers and native/browser data-library identities follow public
[Well adapter generation](https://github.com/finalclass/well/blob/276baf8cffa0db5f849196194083ca4726a0a326/lib/well_cli/contract_adapters.ml)
and [Cyrograf OCaml generation](https://github.com/finalclass/cyrograf/blob/8f07d974c633054ec44196bedab5e130b454c129/lib/compiler/codegen_ocaml.ml).
The prefixed wrappers are a synthetic reproduction of the shape in #12; this
fixture does not claim that the inspected Well revision emits that prefix or
exercise browser transport. The request and codec bodies are deliberately small
and do not reproduce either generator in full.

`test/acceptance/run.sh` verifies:

- Constructors, codecs, storage conversions, aliases, and codec callbacks retain
  their compiler dependency evidence without service-request edges.
- Native/browser wrappers keep their owning contract identity and deterministic
  repeated reports.
- Client-to-Access through a local helper and browser proxy, Engine-to-Engine
  through a server proxy, and synchronous Manager-to-Manager through a browser
  proxy still produce findings with the original caller and target.
- An undeclared nested contract member is checked against the RPC declaration.
- Removing a wrapper's recognized generator header produces an ownership gap.
- An authored implementation helper named `to_drut` is still implementation access.

The accepted generated shapes require a recognized first-line header and an
unambiguous declared-service identity. Unknown provenance is not inferred from
a codec member name. Broader ownership and sharing behavior is tracked by #13.
