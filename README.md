# prompty

A terminal prompt obsessed with one number: the time between pressing Enter and
seeing the next prompt.

```
  badwatt   ~/Projects/code/prompty    main ✘!+?   zig 0.17.0   14:32   1.2s ❯
```

One line. Three powerline surfaces that fade into your terminal's own
background, then dim detail, then the chevron. Zero configuration.

| | median | p95 | binary |
|---|---|---|---|
| **prompty, no repository** | **0.7 ms** | 0.9 ms | 70 KiB |
| **prompty, repository (git status on)** | **5.0 ms** | 6.4 ms | 70 KiB |
| **prompty, `--no-git-status`** | **1.1 ms** | 1.4 ms | 70 KiB |
| a prompt that shells out for everything | 10.56 ms | 11.63 ms | 12 MiB |

Measured with `zig build bench` (300 forks, fork and exec included; see
`tools/bench.zig`). The last row is the same measurement of `starship prompt` on
this machine, in the same repository, with the same `git status` it also runs.

## Why it is fast

- **One subprocess in total**, and only inside a repository: a single
  `git status --porcelain=v2 --branch` for the branch state, the change counts
  and the upstream divergence. Everything else is file reads: the project type
  from one `getdents64`, the versions from files the project already carries
  (`.zigversion`, `go.mod`, `rust-toolchain.toml`, `.nvmrc`), the clock from
  `CLOCK_REALTIME` plus the TZif file, the stash from `refs/stash`. No
  `node --version`, no `go version`, no second fork.
- **A way out of even that.** `--no-git-status` (or `PROMTY_GIT_STATUS=0`) drops
  the git call and renders the branch from `.git/HEAD` alone, for 1.1 ms.
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
               [--no-git-status]                       skip the git call
prompty init zsh|bash                                  print the shell integration
prompty theme [detect [--force]]                       print (or redetect) the palette
prompty version                                        print name and version
```

## What it shows

| segment | source | cost |
|---|---|---|
| user | `$USER`, coloured for root | — |
| directory | `$PWD`, `~` for home, last three components where `~` counts as one | — |
| branch | `git status --branch`, or `.git/HEAD` with `--no-git-status` | one process |
| status | `$all_status`: `= $ ✘ » ! + ?` and `⇡ ⇣ ⇕`, with no counts | (same call) |
| operation | `rebase-merge`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `BISECT_LOG` | 5 stat-only opens |
| stash | `.git/refs/stash` or its reflog | 2 opens |
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

### Git

The branch, the working tree state and the upstream divergence are exactly what
`git status --porcelain=v2 --branch` reports, rendered with the same symbols and
in the same order as the prompt this replaces: `=` conflict, `$` stash, `✘`
deleted, `»` renamed, `!` modified, `+` staged, `?` untracked, then `⇕` diverged
or `⇡`/`⇣`.

That is one process, and it is the only one prompty ever runs: it costs about
4 ms, which is the bulk of the 5 ms repository figure above. Parsing the index
directly instead would be faster but wrong (ignore rules, submodules, sparse
checkouts), and being subtly wrong about git status is worse than being slow.
When it is not worth 4 ms, turn it off:

```sh
PROMTY_GIT_STATUS=0        # or: prompty render --no-git-status
```

### What it deliberately does not do

- **No version numbers from toolchains.** prompty shows what the project pins,
  never what happens to be installed.
- **No commit-graph walk beyond what git reports** for ahead/behind.

## Environment

| variable | meaning |
|---|---|
| `PROMTY_BACKGROUND` | `#rrggbb`, overrides the detected terminal background |
| `NO_COLOR` | set to anything to disable colour entirely |
| `PROMTY_GIT_STATUS` | `0`/`false` to skip the `git status` call entirely |
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
