# Szaniec

**Check that an implementation respects its approved architecture.**

Szaniec is a planned architecture conformance checker for code written by people
and coding agents. Given a codebase and an approved architecture, it will extract
code dependencies and service interactions, then check them against structural
IDesign rules and project-specific boundaries.

The name is Polish for a defensive earthwork: Szaniec protects established boundaries.

## Status

**Design and implementation brief only. No executable or working adapter exists yet.**

The first implementation will target **OCaml applications built with
[Well](https://github.com/finalclass/well)**. Well is the first framework adapter
target, not an existing implementation of Szaniec. Language and framework adapters
will feed a common model so that rule evaluation stays independent of the toolchain.

## Intended use

After an agent implements a change, run one command in a configured project:

```sh
szaniec check
```

This is the intended interface, not an installation or usage instruction for a
released program. The check will report violations, their source locations, and
analysis gaps. Unresolved calls must not silently produce a passing result.

Examples of intended findings:

- A Client calls ResourceAccess directly, including through a helper or proxy.
- An Engine calls another Engine, or a service accesses another service's internals.
- A new shared implementation library bypasses approved service boundaries.
- An otherwise valid layered dependency is absent from the approved project policy.
- An unsupported dynamic call prevents verification of a required rule.

The checker will preserve legitimate boundaries: `Client -> Manager -> Access`
must not be misreported as a direct `Client -> Access` call. Shared contracts,
approved infrastructure, and private helpers have distinct policies.

Szaniec checks implementation conformance. It does not judge whether the approved
architecture was correctly decomposed around volatility, and it does not infer
architectural roles from class or file names.

## Design

- [Architecture](ARCHITECTURE.md): volatility analysis, components, adapters, evidence,
  policy, and the check workflow.
- [Implementation brief](IMPLEMENTATION.md): first delivery, acceptance scenarios,
  unresolved implementation decisions, and verification expectations.
- [Agent instructions](AGENTS.md): repository rules for an implementing agent.

The initial design is a local command-line program. It needs no server or database.
IDesign-inspired checks and project-specific policy checks remain distinguishable
in diagnostics. This project is not an official IDesign product.
