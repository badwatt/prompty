# Project Rules

## Workflow

- **TDD mandatory**: every change requires failing test first, then passing code, then refactor.
- **Commit freely**: commit anytime without asking.
- **Push requires approval**: never push. always ask first.
- **Coverage**: 100% line coverage via kcov. no exceptions.

## Verification Steps

1. Write failing test.
2. Make test pass with minimal code.
3. Refactor.
4. Run `zig build test` → all pass (unit + integration).
5. Run `zig build coverage` → 100.00%.
6. Commit.

## Comments

- **Plain comments are forbidden.** No `//`, no `////` banners, no trailing
  `// ...` at the end of a line. Not for explanation, not for rationale, not for
  "this is subtle".
- Documentation in the code is `//!` (module) and `///` (declaration) only, and
  it says what a thing is for its caller, not how it is written.
- Reasoning, measurements and trade-offs belong in `DESIGN.md`; the README says
  what a user sees. If code needs a paragraph to be understood, rename it and
  put the paragraph in `DESIGN.md`.
- Enforced: `zig build comments` fails on a plain comment.

## Technical Constraints

- Zig 0.17.0+
- Dependency injection via the `Deps` struct (CommandRunner + UserIo ports).
- External commands run as argv lists, never through a shell.
- No hardcoded stdout/stdin.
- `use_llvm = true` on test binary for kcov.

## Questions?

Ask before uncertain decisions.

## Style Guide

See [`docs/TIGER_STYLE.md`](docs/TIGER_STYLE.md) for TigerBeetle coding style guidelines.
