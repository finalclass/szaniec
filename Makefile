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
	dune build bin/szaniec.exe
	deno fmt --check scripts test/check test/complexity
	deno check scripts/release.ts scripts/install.ts test/check/run.ts test/complexity/run.ts test/complexity/fixture.ts
	deno test --allow-read --allow-write --allow-run --allow-env=SZANIEC_CHECK_BINARY test/check/run.ts
	deno test --allow-read --allow-write --allow-run --allow-env=SZANIEC_COMPLEXITY_BINARY test/complexity/run.ts test/complexity/fixture.ts
