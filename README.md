# prompty

A terminal prompt obsessed with one number: the time between pressing Enter and
seeing the next prompt.

```
  badwatt   ~/Projects/code/prompty   main    zig 0.17.0   14:32   1.2s ❯
```

One line. Three powerline surfaces that fade into your terminal's own
background, then dim detail, then the chevron. Zero configuration.

| | median | p95 | binary |
|---|---|---|---|
| **prompty** | **0.97 ms** | 1.10 ms | 70 KiB |
| a prompt that shells out for git and toolchain versions | 10.56 ms | 11.63 ms | 12 MiB |

Measured on the same repository with `zig build bench` (300 forks, fork and exec
included; see `tools/bench.zig`). The second row is the same measurement of
`starship prompt` on this machine.

## Why it is fast

- **No subprocesses.** Not one. The branch comes from `.git/HEAD`, the project
  type from a single `getdents64`, the versions from the files the project
  already has (`.zigversion`, `go.mod`, `rust-toolchain.toml`, `.nvmrc`), and
  the clock from `CLOCK_REALTIME` plus the TZif file. Shelling out to `git` or
  `node --version` costs more than the entire render.
- **No allocation.** Every buffer is a fixed-size stack array; the whole program
  is a static binary with six syscalls on the happy path.
- **No configuration.** The palette is derived from your terminal background in
  Oklab, so the surfaces are subtle variations of the colour you already chose.
  The background is detected once, over OSC 11, and cached.
- **One write.** The prompt is assembled in one buffer and handed to the tty in
  a single `write` syscall.

## Install

```sh
zig build -Drelease=true          # 70 KiB static binary in zig-out/bin
install -m755 zig-out/bin/prompty ~/.local/bin/prompty
```

Then add one line to your shell:

```zsh
# ~/.zshrc
eval "$(prompty init zsh)"
```

```bash
# ~/.bashrc
eval "$(prompty init bash)"
```

That is the entire setup. The first interactive shell asks the terminal for its
background colour, remembers it, and every prompt after that is a fork plus a
few hundred microseconds.

You need a Nerd Font for the glyphs (the powerline separators, the language
icons and the clock come from the same range).

## Commands

```
prompty render [--shell=zsh|bash|plain] [--no-color]   print the prompt
prompty init zsh|bash                                  print the shell integration
prompty theme [detect [--force]]                       print (or redetect) the palette
prompty version                                        print name and version
```

## What it shows

| segment | source | cost |
|---|---|---|
| user | `$USER`, coloured for root | — |
| directory | `$PWD`, `~` for home, last three components where `~` counts as one | — |
| branch | `.git/HEAD`, `.git` gitfiles for worktrees, detached heads | ~4 reads |
| operation | `rebase-merge`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `BISECT_LOG` | 5 stat-only opens |
| languages | one directory listing, then a version file per project | 1 read + 1 per language |
| direnv | `$DIRENV_DIFF` | — |
| exit status | `$PROMTY_LAST_EXIT` | — |
| duration | `$PROMTY_LAST_DURATION_MS` | — |
| clock | `CLOCK_REALTIME` + `/etc/localtime` | 1 read |

### Path truncation

The same rules as starship with `truncation_length = 3`, verified side by side
over eighteen paths:

| working directory | label |
|---|---|
| `~/plain/a` | `~/plain/a` |
| `~/plain/a/b` | `…/plain/a/b` (the `~` counts as a component) |
| `/usr/share/doc` | `/usr/share/doc` (the root slash does not count) |
| `/usr/share/doc/x` | `…/share/doc/x` |
| repo at `~/Projects/code/prompty`, cwd = repo root | `…/prompty` |
| … cwd = `src/domain` | `…/prompty/src/domain` |
| … cwd = `src/domain/deep/er` | `…/domain/deep/er` |

Inside a repository the label is anchored on the repository name — that is
starship's `truncate_to_repo`, which is on by default — so the ancestors above
the repository are replaced by `…/`.

### What it deliberately does not do

- **No `git status`.** Counting modified files means stat-ing the whole index or
  spawning `git`; both cost more than everything else combined. The branch and
  the operation are cheap, so those stay.
- **No ahead/behind counts.** That needs a commit-graph walk.
- **No version numbers from toolchains.** prompty shows what the project pins,
  never what happens to be installed.

## Environment

| variable | meaning |
|---|---|
| `PROMTY_BACKGROUND` | `#rrggbb`, overrides the detected terminal background |
| `NO_COLOR` | set to anything to disable colour entirely |
| `PROMTY_LAST_EXIT` | exit status of the previous command, set by the integration |
| `PROMTY_LAST_DURATION_MS` | duration of the previous command, set by the integration |

## Development

```sh
zig build test        # 142 unit and integration tests
zig build coverage    # the same tests under kcov, gate at 100% lines
zig build bench       # measure a real render, fork included
zig build run -- render --no-color
```

`zig build coverage` needs `kcov` (override its path with `-Dkcov=...`).

## Requirements

Linux, Zig 0.17, and a terminal that answers OSC 11 (or `PROMTY_BACKGROUND`).

## Layout

```
src/domain/       pure: colours, path shortening, durations, TZif, rendering
src/ports/        the four interfaces the outside world is reduced to
src/adapters/     Linux syscalls behind those interfaces
src/application/  the use case, the command line and the shell scripts
src/main.zig      composition root: the only file that knows both sides
tools/            coverage gate and benchmark
```

See [DESIGN.md](DESIGN.md) for the reasoning, the budget and the invariants.
