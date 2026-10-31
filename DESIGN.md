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
2. **Subprocesses.** `git status` is 10-20 ms. `node --version` is 30-60 ms on a
   cold cache. prompty does not spawn anything, ever.
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
   │   Files   Environ   Clock   Terminal   Output  │
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
- **No subprocess.** There is no process port at all, so the property cannot be
  violated by accident.
- **Bounded loops.** The git walk is capped at 64 levels and asserts its bound;
  a directory scan is bounded by the kernel's `getdents64` buffer; path
  shortening keeps at most eight components.
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
costs a shell start nothing, and a second run is a no-op unless forced.

## Shell escaping

Getting this wrong corrupts line editing, so it is one function with a test per
shell:

- zsh wraps non-printing sequences in `%{...%}` and expands `%`, so literal `%`
  is doubled.
- bash wraps them in `\[...\]` and expands `\`, so literal `\` is doubled.
- `--shell=plain` emits neither.

`NO_COLOR` removes the escapes entirely rather than rendering in grey, so the
output is byte-for-byte plain text.

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

## Deliberate omissions

- **`git status`.** The honest implementations are "stat every file in the
  index" (1-3 ms in a large repository) or "spawn git" (10-20 ms). Both break the
  budget for information that is one `git status` away.
- **Ahead/behind.** Requires walking the commit graph.
- **Config files.** Every option is a reason for the prompt to read another file
  and for the user to spend an evening tuning it. The palette comes from the
  terminal; the rest is a judgement call, made once.
- **Cross-platform adapters.** The ports are portable and the domain is pure,
  but the only adapter set is Linux. A macOS adapter is a new file behind the
  same five ports, not a rewrite.
