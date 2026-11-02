# Design

## The number, measured

A prompt is executed after every command, so its cost is multiplied by
everything a human does. The honest way to budget it is to measure the floor
first, and the floor is not in this program:

| measurement, this machine, fork+exec included | median |
| --- | --- |
| a 4.8 KiB static binary that does nothing but exit | **0.85 ms** |
| prompty, no repository (`render --git=false`) | 0.95 ms |
| prompty, empty directory | 0.92 ms |
| prompty, directory with 20,000 entries | 0.92 ms |
| prompty, this repository, `git status` on | 4.3 ms |
| `git status --porcelain=v2 --branch` alone | 3.5 ms |
| `git rev-parse --abbrev-ref HEAD` alone | 1.9 ms |

So of the millisecond a prompt costs outside a repository, **0.85 ms is the
shell's fork and exec and 0.07 ms is everything prompty does**. There is no
optimisation left in that 7% worth having; the only way to remove the other 93%
is to not be `exec`ed, which means a resident process — see the omissions at the
end.

Inside a repository the picture is different: `git` is 77-90% of the render, and
most of *that* is git's own startup (`rev-parse`, doing nothing else, is 1.9 ms
because it is a dynamically linked binary) plus `refresh index`, which `stat`s
every tracked file. Measured with `GIT_TRACE_PERFORMANCE=1`: 1.0 ms of refresh,
0.09 ms of diff, and 2.1 ms for the command as a whole.

The budget, in order of what actually costs:

1. **Process startup.** A 68 KiB static binary, no libc, no allocator, no
   dynamic linking. The 12 MiB debug build costs 0.4 ms more per prompt purely
   in page faults, which is why `zig build` defaults to ReleaseFast and strips.
2. **The one subprocess.** Only inside a repository. Three of the four flags
   are free to change and one is not: `--untracked-files=no` measured 5.7 ms
   against 8.4 ms in a repository with 5000 files and 500 untracked ones, which
   is why `PROMTY_GIT=fast` exists — and why it is not the default, since
   it also removes the `?` glyph.
3. **Directory listings.** None. A listing costs what the directory holds, not
   what the prompt shows, so the cost of a render must not depend on somebody
   else's file count. The 20,000-entry row above is the proof: same millisecond.
4. **Syscalls.** 22 on the happy path: a handful of `openat` for `.git`, one
   `clock_gettime`, one `write`. Nothing proportional to the directory.
5. **Bytes written.** One `write` per prompt, assembled in a 2 KiB stack buffer.

Memory is part of the budget for the same reason: the prompt runs on the shell's
stack. `zig build stack` renders one under `ulimit -s 64` — the smallest a shell
may hand us — and that number is a test, not a hope. It was 512 KiB until an
audit found that a quarter megabyte of it was a file buffer.

### What was measured and rejected

- **`clone(CLONE_VFORK|CLONE_VM)` instead of `fork`.** 131 µs against 53 µs per
  spawn, measured directly. On a 4.5 ms render that is 78 µs, under two percent,
  and it costs the one invariant that matters most: with a shared address space
  every line of the child is load-bearing, and the child starts at the entry
  function rather than continuing after the call — the first attempt silently
  skipped the `dup2` that points its stdout at the pipe. Worth two percent
  nowhere, least of all here.
- **`git status .` scoped to the working directory.** 4.8 ms against 8.6 ms in a
  monorepo subdirectory, but it changes what the prompt means: the status of
  where you are against the status of the project.
- **A resident status daemon.** The only order-of-magnitude win available (4.5
  ms back to 0.9 ms), and the reason it is rejected is the rest of this document:
  a watcher, an invalidation protocol, a second process to clean up after, and
  two shells disagreeing about which one owns it. The prompt's whole argument is
  that it cannot be in a broken state.
- **Streaming the porcelain through the parser.** Removes the 256 KiB static
  buffer and the ceiling at roughly fifteen thousand changes, and costs a
  callback-shaped hole through the `Command` port for a case that a `git status`
  this size already loses on time. The buffer is BSS: it costs nothing to hold.

## The hexagon

```
            ┌───────────────────────────────┐
            │           domain              │  pure, no I/O, no allocation
            │  theme  canvas  path  git     │
            │  clock  duration  git_status  │
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
  means the default palette, an unreadable status means only the branch. There is no
  path in which a prompt fails to appear.

## Boolean flags

One rule, in one place (`cli.zig`): a boolean flag on its own means true, and
`=false` turns it off, so there is a spelling for both states of every boolean
and no second, negative name to remember. `--no-color` stays because it is the
spelling every other program on the machine uses; it is the same switch.

The value must be `true` or `false`, after an `=`. `--git=maybe` is a usage
error: a prompt that silently guesses what somebody meant is a prompt that
silently shows the wrong thing.

## The right-aligned duration

The one segment that is not part of the line is the last command's duration, and
it is opt-in (`-d`/`--duration`). The first attempt padded the line so the number
ended at the right edge, and it was wrong in a way no pseudo-terminal test could
see: the cursor then sat after the number, and typing continued from there.

What a prompt actually needs is two strings. zsh has a right-hand prompt —
`RPROMPT` — which it draws against the right edge, redraws as the line is edited,
and hides when the line grows into it. The cursor stays after the chevron, which
is where the typing goes, and nothing has to know the terminal's width.

So `render --duration` prints the line, a `0x1f`, and the segment for the right
edge; the generated zsh integration splits on that byte and assigns `PROMPT` and
`RPROMPT`. The separator is a control character no name can contain, and every
name has its control bytes replaced before it reaches the renderer.

bash has no right prompt, and a padded `PS1` breaks readline's redraw, so there
the option wires up only the timing and the number stays inline. That is the
honest split: the shell that can do it does, and the one that cannot keeps what
it had.

Timing is the shell's half, and it had to be fixed to make any of this visible:
zsh computes the difference in floating point, so it was passing
`150.00009536743164` and the prompt, which parses an integer, showed nothing —
the dimmed duration had never appeared either. bash has no `preexec`, only a
`DEBUG` trap, which is generated only for this option; and its `EPOCHREALTIME`
is locale-formatted, so a Spanish shell hands out `1793542627,390303` and the
separator has to be dropped before the subtraction.

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

## Who the first segment is about

Locally, a prompt answers "who am I". Over SSH the question that matters is
"which machine am I on", so the first segment shows the hostname instead — the
same slot, a different fact. The name is the kernel's: `$HOSTNAME` is a shell
variable and zsh keeps it out of the environment, so `uname` is what is asked,
once, in the composition root. Only the first label is shown: `build-01` tells
machines apart where `build-01.example.com` mostly repeats the domain.

Root keeps the red surface over SSH, because that colour is about privileges and
not about where you are.

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

The hexagon is checked, not remembered: `zig build layers` reads every file in
`domain/` and `ports/` and fails if one imports outwards. A domain file that
reached for `std.os.linux` would stop being testable without a machine, and that
is the reason the layers exist.


- 228 tests: pure domain tests, integration tests that drive the whole use case
  through the ports against a fake filesystem, clock, terminal and environment,
  and property tests that drive a seeded generator through the parsers. The
  property tests are the general form of the overflow class an audit found by
  hand: whatever bytes arrive, the label is bounded and valid, the record is
  never indexed past its end, the offset is inside a day.
- 100% line coverage, enforced by `zig build coverage`: the test binary runs
  under kcov, the installed binary is traced through ten real CLI invocations,
  and `tools/check_coverage.zig` fails the build if any file in `src/` is below
  100% or missing from the report.
- The Linux adapters are covered by tests that use real pipes, a real
  pseudo-terminal and a real scratch directory, because a fake proves nothing
  about `tcsetattr` or `getcwd`.
- `zig build smoke` runs every command in the shipping ReleaseFast build, and
  `zig build stack` renders under a 64 KiB stack: the first catches a program
  that only works in Debug, the second catches a buffer that grew back into the
  megabytes. Both run in CI, together with the coverage gate.
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

- **Language detection.** Removed after measuring: recognising a project needs
  a directory listing, a listing costs what the directory holds (178
  `getdents64` calls and 7.9 ms in a directory with twenty thousand entries,
  against 1.06 ms and 22 syscalls without it), and what it bought was an icon
  and a version string. A prompt must cost the same in an empty directory and
  in a build tree.
- **Config files.** Every option is a reason for the prompt to read another file
  and for the user to spend an evening tuning it. The palette comes from the
  terminal; the rest is a judgement call, made once. The one knob that earns its
  place is `PROMTY_GIT`, because it is worth a third of the render in a
  large repository.
- **Cross-platform adapters.** The ports are portable and the domain is pure,
  but the only adapter set is Linux. A macOS adapter is a new file behind the
  same five ports, not a rewrite.
