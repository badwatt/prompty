# Design

## The number

A prompt is executed after every command, so its cost is multiplied by
everything a human does. The budget is therefore set by what the shell already
pays: `fork` + `exec` of an empty static binary measures 0.58 ms on this
machine. Anything prompty adds on top of that is the only thing worth
optimising, and it is currently about 0.14 ms.

The budget, in order of what actually costs:

1. **Process startup.** A 70 KiB static binary, no libc, no allocator, no
   dynamic linking. The 12 MiB debug build costs 0.4 ms more per prompt purely
   in page faults, which is why `zig build` defaults to ReleaseFast and strips.
2. **Subprocesses.** `node --version` is 30-60 ms on a cold cache, and running
   one per language per prompt is the usual way to lose a prompt. prompty
   spawns exactly one process, and
   only inside a repository: `git status --porcelain=v2 --branch`, at about
   4 ms, which is why the repository case is 5 ms and the rest is 0.7 ms.
3. **Syscalls.** 35 on the happy path: one `getdents64` per project root, a
   handful of `openat` for `.git` and the manifests, one `clock_gettime`.
4. **Bytes written.** One `write` per prompt, assembled in a 2 KiB stack buffer.

## The hexagon

```
            ┌───────────────────────────────┐
            │           domain              │  pure, no I/O, no allocation
            │  theme  canvas  path  git     │
            │  language  clock  duration    │
            │  osc  cache  prompt  store    │
            └──────────────┬────────────────┘
                           │
            ┌──────────────▼────────────────┐
            │         application           │  the use case and the CLI
            │  compose  cli  shell_init     │
            └──────────────┬────────────────┘
                           │
   ┌───────────────────────▼───────────────────────┐
   │                   ports                       │
   │ Files  Environ  Clock  Commands  Terminal  Output │
   └───────────────────────┬───────────────────────┘
                           │
   ┌───────────────────────▼───────────────────────┐
   │              adapters (Linux)                 │
   │  fs  env  clock  tty  out  +  tzif parser     │
   └───────────────────────────────────────────────┘
```

`src/main.zig` is the composition root: it is the only file that names both a
port and an adapter. Everything above the ports is tested with in-memory doubles
(`src/test_support/fakes.zig`), so the tests describe behaviour, not syscalls.

The ports are deliberately tiny and lossy. `Files.read` returns `?[]u8`, not an
error union: for a prompt, "cannot read" is a fact of life, not an error to
propagate, and every caller already has a sensible fallback.

## Invariants

These are the rules the code is written to. They are what make the performance
claims checkable rather than aspirational.

- **No allocation.** Every buffer is a fixed-size stack array or the bounded
  `Store`. `Store.dupe` asserts on overflow instead of growing.
- **One process, one port.** `Commands` exists for the git status call and
  nothing else; there is no shell, no `sh -c`, and no other caller. Turning it
  off costs the status and nothing else.
- **The porcelain parser is pure.** The only dependency on another program
  collapses into one port call and one function from bytes to counts, so the
  interesting half is tested without a repository.
- **Bounded loops.** The git walk is capped at 64 levels and asserts its bound;
  a directory scan is bounded by the kernel's `getdents64` buffer and rejects a
  zero-length record instead of spinning; path shortening keeps at most eight
  display components; `~` occupies one of them and, inside a repository, the
  label is anchored on the repository name.
- **Nothing is written past a buffer.** Path shortening clips to the budget on a
  character boundary and marks the cut, because the shipping build has the
  safety checks off: an over-long name must be a shorter prompt, not a stack
  corruption.
- **Untrusted text is sanitised at the boundary.** Control bytes are replaced
  when the text enters the store, and the shell integrations disable the second
  expansion pass, so a name is never interpreted as code.
- **A shared file is replaced, not rewritten.** The cached background is
  written to a sibling and renamed into place, because two shells starting at
  the same moment are the normal case, not a race to design around.
- **Two glyphs that mean different things do not look alike.** `✘` is a deleted
  file in the worktree; a command that failed is `×`.
- **One line, one write.** `prompt.render` returns a slice of one buffer, and
  the CLI hands it to one `write`.
- **Degrade, never fail.** A missing zone file means UTC, a silent terminal
  means the default palette, an unreadable index means no languages. There is no
  path in which a prompt fails to appear.

## The palette

The only input is the terminal background. Everything else is derived in Oklab
(perceptually even lightness, unlike sRGB blending, which turns dark colours
muddy):

```
surface(n) = clamp_luminance(background).mixToward(tint, opacity * weight[n])
```

`weight` is `1.0`, `0.62` and `0.34` for the user, path and git surfaces, so the
pill fades left to right and then the chevron returns to the terminal
background. On a dark terminal the tint is a periwinkle and the surfaces are
*lighter* than the background; on a light terminal the tint is dark and the
surfaces are *darker*. Very dark backgrounds get a luminance floor of `0.15` so
the segments cannot disappear into black.

The result on Catppuccin Mocha (`#1e1e2e`) is `#3c3e52`, `#303144` and
`#28283a`: three visible steps, no loud colour anywhere.

### Detection is not on the prompt path

The background has to be *known*, and asking the terminal is a round trip. So:

1. `prompty init` installs a one-time `prompty theme detect` in the shell's
   startup. It asks the terminal once, derives the palette and writes
   `$XDG_CACHE_HOME/prompty/theme`.
2. Every prompt reads that 8-byte file (or `PROMTY_BACKGROUND`, which wins).
3. If neither exists, the tuned default is used: a prompt never blocks.

`theme detect` has a 100 ms poll timeout, so a terminal that does not answer
costs one pause at shell start, and a second run is a no-op unless forced.

The query itself has to be careful. A tty in its default state echoes the
answer onto the screen and buffers it until a newline that never comes, so the
reply shows up as garbage and, worse, stays in the input queue where the shell
reads it as typed input. The detector therefore saves the terminal state, turns
off echo and canonical input, reads until the reply's terminator so that no byte
is left behind, and restores the state on every path out. It also blocks the
signals a user reaches for when a shell start looks stuck: a `SIGINT` delivered
between those two `tcsetattr` calls would kill the process with the terminal
half-changed, and the shell started afterwards would have no echo, no canonical
input and a `CR` that no longer turns into a newline. The tests use a real
pseudo-terminal for this, because the part that can go wrong is exactly the
terminal state, and a pipe has none.

## Shell escaping

Getting this wrong corrupts line editing, so it is one function with a test per
shell:

- zsh wraps non-printing sequences in `%{...%}` and expands `%`, so literal `%`
  is doubled.
- bash wraps them in `\[...\]` and expands `\`, so literal `\` is doubled.
- `--shell=plain` emits neither.

`NO_COLOR` removes the escapes entirely rather than rendering in grey, so the
output is byte-for-byte plain text.

## Packaging

`build.zig.zon` stays the only place the name and the version are written. The
Nix derivation cannot parse Zig, so `nix/manifest.nix` extracts those two values
from the manifest with a regex over its lines; the flake then exposes the
package, the module and a check that builds and tests the package in a sandbox.

The home-manager module owns exactly three things: the package, the two lines
that wire the prompt into zsh and bash, and the session variables behind the two
documented options. It does not touch any other shell configuration, which is
what makes `programs.prompty.enable = true;` sufficient.

## Testing

- 142 tests: pure domain tests plus integration tests that drive the whole use
  case through the ports against a fake filesystem, clock, terminal and
  environment.
- 100% line coverage, enforced by `zig build coverage`: the test binary runs
  under kcov, the installed binary is traced through ten real CLI invocations,
  and `tools/check_coverage.zig` fails the build if any file in `src/` is below
  100% or missing from the report.
- The Linux adapters are covered by tests that use real pipes, real sockets and
  a real scratch directory, because a fake proves nothing about `getdents64`.
- Tests are always built with LLVM in Debug: kcov reads DWARF that the
  self-hosted backend does not emit for user files.

## Why git is not parsed by hand

Reading `.git/index` and stat-ing every entry would cost 1-3 ms in a large
repository and still be wrong: ignore rules, submodules, sparse checkouts,
`assume-unchanged`, file modes and the commit graph all live in git's head, not
in the index. Ahead/behind needs a revwalk. The trade chosen here is one
subprocess at 4 ms with the real answer, plus a documented way to switch it off,
rather than a fast approximation that lies about a dirty tree.

## Deliberate omissions

- **Toolchain version calls.** `.zigversion`, `go.mod` and friends say what the
  project pins; `node --version` says what is installed and costs 30-60 ms.
- **Config files.** Every option is a reason for the prompt to read another file
  and for the user to spend an evening tuning it. The palette comes from the
  terminal; the rest is a judgement call, made once.
- **Cross-platform adapters.** The ports are portable and the domain is pure,
  but the only adapter set is Linux. A macOS adapter is a new file behind the
  same five ports, not a rewrite.
