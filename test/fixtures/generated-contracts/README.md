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

The automatic generated shapes require a recognized first-line header and an
unambiguous declared-service identity. Unknown provenance is not inferred from
a codec member name. Explicit approved declarations also support the shape below.

## Application-generated bindings without headers

[application_contracts.ts](../../acceptance/application_contracts.ts) builds a
second compiled fixture from these public sources and tasks-app. Its preparation
is deterministic: remove generator headers and the unrelated `Request.unknown`
member, rename wrapper files to `project_service_*`, use `Project_native` and
`Project_browser` libraries, and add pure `Nested` alias aggregators. The
`Request` message is explicitly declared in each original service's `.cyrograf`
source. Constructors, conversion bodies, nested `Storage` modules and proxy
bodies remain the compiled stand-ins above. The proxy bodies actually call the
original native contract RPC, rather than only completing a callback.

The exact configuration is [application.toml](application.toml):

| Contract source stem | Explicitly bound projections |
|---|---|
| `Task_manager` | native/browser data and native/browser wrappers |
| `Task_access` | native/browser data and native/browser wrappers |
| `Notification_manager` | native/browser data and native/browser wrappers |
| `Template_engine` | native/browser data and native/browser wrappers |
| `Formatting_engine` | native/browser data and native/browser wrappers |

Data module paths are `Contract_data.<stem>` and
`Contract_data_browser.<stem>`. Wrapper declarations use
`Project_native.Nested.<stem>` and `Project_browser.Nested.<stem>`;
compiler aliases resolve them to `Project_service_<stem>` units in those
libraries. All generated directories remain in `roots = ["lib"]`.
`App.Clock` is the tasks application's existing approved infrastructure;
no generated unit is added to the shared whitelist.

After review, `approve` records this exact policy. The current checkout uses
OCaml adapter **1.5.0**, Well adapter **3.4.0** and rules **3.1.0**. The original
unconstrained-alias scenarios were also verified with adapters 1.4.0/3.3.0.
The runner checks these identities against the checkout so an older packaged
binary cannot pass unnoticed. It prints the approved digest and source snapshot.
The compiler is the tasks fixture's pinned OCaml **5.4.1** (artifact series
**5.4**); this run uses Dune **3.24.2**. A fresh run observes 45 compiler units
with no violations or gaps.
This does not predict counts for either incomplete downstream report in #24.

Run from the Szaniec root:

```sh
make build
dune build test/acceptance/contract_bindings_probe.exe
deno fmt --check test/acceptance/application_contracts.ts
deno test --allow-read --allow-write --allow-run --allow-env test/acceptance/application_contracts.ts
```

The suite invokes both `_build/default/bin/szaniec.exe` and `_release/szaniec`
from the temporary application's directory. Each has its own fresh fixture.
The OCaml probe is test infrastructure: it uses the compiler adapter and
interpretation contracts to verify source/artifact freshness **without** the
successful-rebuild assumption, exact ownership, retained conversion/forwarding
calls and codec callback references. Deno owns preparation and automation.
Reports, call graphs and fixture copies are deleted after each test.

Acceptance includes deterministic reports and graphs, the original caller's
real RPC, Client-to-Access through a helper/browser proxy, synchronous
Manager-to-Manager through a browser proxy, and Engine-to-Engine through a
native proxy. Negative mutations retain policy approval gaps, missing binding
units, missing provenance, stale artifacts and conflicting contract identity.
An unbound arbitrary-prefix wrapper has ownership findings instead of a
name-based contract exemption. Ordinary private executable members inside an
approved wrapper, undeclared nested `Store.to_drut`, and an authored
implementation helper named `to_drut` retain implementation-access findings.

For an application using this shape, follow the
[binding declaration workflow](../../../docs/contracts/policy-format.md#application-generated-binding-workflow).
The fixture proves the configured compiler-to-diagnostic path, not automatic
recognition of arbitrary generators or browser transport interoperability.
