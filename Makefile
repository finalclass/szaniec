.PHONY: build install release verify

VERSION ?= dev

# The Deno helper invokes well build and packages its patched Linux bundle.
build:
	deno run --allow-read --allow-write --allow-run scripts/release.ts dev

install: build
	deno run --allow-env=HOME --allow-read --allow-write scripts/install.ts

release:
	deno run --allow-read --allow-write --allow-run scripts/release.ts "$(VERSION)"

verify:
	dune exec ocamlformat -- --check $$(git ls-files '*.ml')
	dune build @test/unit/runtest test/acceptance/contract_bindings_probe.exe test/performance/evaluation.exe test/performance/acquisition.exe
	dune exec test/performance/rendering.exe
	dune build @test/coaching/runtest bin/szaniec.exe
	deno fmt --check test/coaching/run.ts
	deno check test/coaching/run.ts
	deno test --allow-read --allow-write --allow-run --allow-env=SZANIEC_COACHING_BINARY test/coaching/run.ts
	deno fmt --check test/performance/acquisition.ts
	deno check test/performance/acquisition.ts
	deno fmt --check test/performance/complexity.ts
	deno check test/performance/complexity.ts
	deno test --allow-read --allow-write --allow-run --allow-env test/performance/acquisition.ts
	deno fmt --check test/performance/conformance.ts
	deno check test/performance/conformance.ts
	deno fmt --check test/config/run.ts
	deno test --allow-read --allow-write --allow-run test/config/run.ts
	deno fmt --check test/loops/run.ts
	deno test --allow-read --allow-write --allow-run test/loops/run.ts
	deno fmt --check test/loops/token-admission.ts
	deno check test/loops/token-admission.ts
	deno test --allow-read --allow-write --allow-run test/loops/token-admission.ts
	deno fmt --check test/flows/run.ts
	deno test --allow-read --allow-write --allow-run test/flows/run.ts
	deno fmt --check test/acceptance/public_contracts.ts
	dune build test/acceptance/contract_observation.exe
	deno test --allow-read --allow-write --allow-run --allow-env test/acceptance/public_contracts.ts
	deno fmt --check test/acceptance/application_contracts.ts
	deno test --allow-read --allow-write --allow-run --allow-env test/acceptance/application_contracts.ts
	deno fmt --check test/acceptance/service_callbacks.ts
	deno check test/acceptance/service_callbacks.ts
	deno test --allow-read --allow-write --allow-run --allow-env=SZANIEC_CALLBACK_BINARY test/acceptance/service_callbacks.ts
	deno fmt --check test/acceptance/capabilities.ts
	deno check test/acceptance/capabilities.ts
	deno test --allow-read --allow-write --allow-run --allow-env test/acceptance/capabilities.ts
	deno fmt --check test/complexity/run.ts
	deno check test/complexity/run.ts
	deno test --allow-read --allow-write --allow-run --allow-env=SZANIEC_COMPLEXITY_BINARY test/complexity/run.ts
	test/acceptance/run.sh
	test/acceptance/suggestions.sh
	test/coverage/run.sh
