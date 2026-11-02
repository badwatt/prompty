# Project Rules

## Workflow

- **TDD mandatory**: every change requires failing test first, then passing code, then refactor.
- **Commit freely**: commit anytime without asking.
- **Conventional Commits, always**: every message starts with `type(scope): summary`
  in the imperative, lowercase, no full stop. Never a bare sentence.
- **Push requires approval**: never push. always ask first.
- **Coverage**: 100% line coverage via kcov. no exceptions.

## Verification Steps

1. Write failing test.
2. Make test pass with minimal code.
3. Refactor.
4. Run `zig build test` → all pass (unit + integration).
5. Run `zig build coverage` → 100.00%.
6. Commit.

## Commits

Every commit message is a [Conventional Commit](https://www.conventionalcommits.org):

```
type(scope): summary in the imperative, lower case, no trailing full stop

Body: why it is right, not what the diff does. Wrapped at 80 columns. The
reasoning a future reader cannot see from the code belongs here.
```

- **Types**: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`,
  `chore`, `style`. Nothing else.
- **Scopes** name the layer or module, lower case, one word: `clock`, `command`,
  `git-status`, `path`, `prompt`, `compose`, `cli`, `shell`, `theme`, `store`,
  `canvas`, `ports`, `deps`, `ci`, `release`, `agents`.
- **`feat` and `fix` are for behaviour a user can see.** A change to how the
  code is written is `refactor`; a change to a measurement is `perf`; a change
  to a test that proves the same behaviour is `test`.
- **Breaking changes** get `!` after the scope (`feat(cli)!:`) and a
  `BREAKING CHANGE:` footer. Renaming a flag is breaking.
- **One commit, one idea.** If the summary needs an "and", it is two commits.
- The body may mention the version it ships as (`0.6.1`), never the branch.

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
