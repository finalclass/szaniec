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
	dune build @test/unit/runtest
	deno fmt --check test/config/run.ts
	deno test --allow-read --allow-write --allow-run test/config/run.ts
	test/acceptance/run.sh
	test/acceptance/suggestions.sh
	test/coverage/run.sh
