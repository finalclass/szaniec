# Instructions for implementing agents

## Read first

1. [README.md](README.md) — purpose, current status and first target.
2. [ARCHITECTURE.md](ARCHITECTURE.md) — accepted boundaries and behavior.
3. [IMPLEMENTATION.md](IMPLEMENTATION.md) — implementation scope and acceptance scenarios.

These files are the repository's self-contained instructions. No private reference
corpus, machine-specific skill path or external conversation is required.

## Working rules

- Preserve the architectural component boundaries and permitted calls in ARCHITECTURE.md.
- Keep framework knowledge out of ConformanceEngine and policy judgments out of language adapters.
- Preserve unresolved evidence. Never turn extraction failure or unsupported constructs into success.
- Treat the selected approved architecture as input. Do not loosen it to make implementation pass.
- Do not introduce an unowned `common`, `shared` or `utils` implementation library.
  Contracts and approved infrastructure must have explicit ownership and allowed consumers.
- Follow IMPLEMENTATION.md for contract design and acceptance coverage before claiming support.
- Use Deno/TypeScript for new automation scripts. Compiler integration may use the
  language/toolchain it needs; document the choice rather than introducing a second
  scripting runtime for convenience.
- Keep identifiers and repository documentation in English.
- Keep implementation rationale and architectural decisions in documentation.
- Make routine implementation choices within the accepted design autonomously.
  Ask only when a missing decision materially changes scope, boundaries or required behavior.
- Do not publish private source material, credentials, personal paths, or unrelated project data.

## Agent workflow

- Ask questions in ordinary conversation text; never use popup dialogs or request-user-input tools in Codex or T3.
- Number answer options; mark recommendations with "rekomenduję" and provide an example answer.
- Before ending a turn, commit and push all pending repository changes, including instruction edits; leave the worktree clean.
- Use a separate Git worktree for each independent parent issue.
- Keep evidence files and recordings only temporarily; upload them as GitHub issue/PR attachments, then delete local copies; never commit them.

## Completing implementation work

Implement the requested scope fully, verify the applicable acceptance scenarios, and
record the commands actually run. Keep README honest about what works and what does
not. Do not claim a checker exists when only its CLI shell or rule engine exists.
Source-to-diagnostic integration is part of the first delivery.

There are no build or test commands yet. Establish reproducible commands for the
chosen stack and document them instead of assuming an existing setup.
