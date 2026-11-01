# prompty

A terminal prompt that measures itself in microseconds.

```
  badwatt   …/prompty    main ✘!+?   zig 0.17.0   14:32   1.2s ❯
```

One line: three powerline surfaces that fade into your terminal's own
background, then dim detail, then the chevron. Zero configuration.

## Performance

Every number below is a full `fork` + `exec` + render, measured on the same
machine with the same harness, 100-300 runs each, in the same directory, with
the default configuration of each prompt:

| where                                                                        | prompty     | starship 1.25.1 |
| ---------------------------------------------------------------------------- | ----------- | --------------- |
| empty directory                                                              | **1.04 ms** | 3.08 ms         |
| a polyglot project (`package.json`, `go.mod`, `Cargo.toml`, `build.zig.zon`) | **1.05 ms** | 32.13 ms        |
| this repository (36 tracked files)                                           | **4.82 ms** | 13.73 ms        |
| this repository, `--no-git-status`                                           | **1.05 ms** | —               |
| binary size                                                                  | **79 KiB**  | 13.4 MiB        |

The polyglot row is 30× because of what each prompt does when it sees a
project: starship runs `node --version`, `go version`, `cargo --version` and
so on, once per toolchain, on every single command. prompty reads the files the
project already carries — `.nvmrc`, `go.mod`, `rust-toolchain.toml`,
`.zigversion`, `build.zig.zon` — and shows nothing when the project does not pin
a version.

Inside a repository the remaining cost is `git status`: prompty runs it once,
4 ms, and that is the whole difference between the second-to-last row and the
third. Reproduce all of it yourself:

```sh
zig build bench -- 300                 # prompty
zig build bench -- 100 $(command -v starship) prompt   # whatever you have
```

`zig build bench` is in `tools/bench.zig`: it spawns the command N times,
records wall clock per run and prints min / median / mean / p95 / max.

## Install with Nix

Add the flake and set one option. In your home-manager configuration:

```nix
# flake.nix
inputs.prompty.url = "github:badwatt/prompty";
inputs.prompty.inputs.nixpkgs.follows = "nixpkgs";

# home-manager modules
imports = [ inputs.prompty.homeModules.default ];

programs.prompty.enable = true;
```

That is the entire setup: the package is installed, and the prompt is wired
into every shell home-manager manages (zsh and bash), ordered after the rest of
your initialisation and idempotent if it is sourced twice. You do not edit a
shell file.

Optional knobs:

```nix
programs.prompty = {
  enable = true;
  package = inputs.prompty.packages.${system}.default;  # the default
  gitStatus = true;        # false: skip the git call, keep the branch
  background = "#1e1e2e";  # else prompty asks the terminal once and caches it
};
```

Without home-manager:

```sh
nix profile install .#prompty
eval "$(prompty init zsh)"    # or: eval "$(prompty init bash)"
```

## Install without Nix

```sh
zig build                       # 79 KiB static binary in zig-out/bin
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

The first interactive shell asks the terminal for its background colour, derives
the palette and caches it; every prompt after that is a fork and a few hundred
microseconds. A Nerd Font is needed for the glyphs.

## Why it is fast

- **One subprocess in total**, and only inside a repository: a single
  `git status --porcelain=v2 --branch` for the branch, the change counts and the
  upstream divergence. Everything else is file reads: the project type from one
  `getdents64`, versions from files the project already has, the clock from
  `CLOCK_REALTIME` plus the TZif file, the stash from `refs/stash`.
- **No allocation.** Every buffer is a fixed-size stack array; the program is a
  static binary that issues about 35 syscalls per prompt.
- **No configuration file.** The palette is derived from the terminal background
  in Oklab, so the surfaces are subtle variations of the colour you already
  chose.
- **One write.** The prompt is assembled in one buffer and handed to the tty in
  a single `write` syscall.
- **A way out of even the git call.** `--no-git-status` or
  `PROMTY_GIT_STATUS=0` renders the branch from `.git/HEAD` alone, for 1.05 ms.

## Commands

```
prompty render [--shell=zsh|bash|plain] [--no-color]   print the prompt
               [--no-git-status]                       skip the git call
prompty init zsh|bash                                  print the shell integration
prompty theme [detect [--force]]                       print (or redetect) the palette
prompty version                                        print name and version
```

## What it shows

| segment     | source                                                         | cost                    |
| ----------- | -------------------------------------------------------------- | ----------------------- |
| user        | `$USER`, bold, coloured for root                               | —                       |
| directory   | `$PWD`, `~` for home, anchored on the repository name          | —                       |
| branch      | `git status --branch`, or `.git/HEAD` without the git call     | one process             |
| status      | `= $ ✘ » ! + ?` and `⇡ ⇣ ⇕`, no counts                         | (same call)             |
| operation   | `rebase-merge`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `BISECT_LOG` | 5 stat-only opens       |
| stash       | `.git/refs/stash` or its reflog                                | 2 opens                 |
| languages   | one directory listing, then a version file per project         | 1 read + 1 per language |
| direnv      | `$DIRENV_DIFF`                                                 | —                       |
| duration    | `$PROMTY_LAST_DURATION_MS`                                     | —                       |
| clock       | `CLOCK_REALTIME` + `/etc/localtime`                            | 1 read                  |
| exit status | `$PROMTY_LAST_EXIT`: a red `×` when the last command failed, last of all | —                  |

### Robustness

This program runs on every command, so it is built to degrade rather than to
fail:

- **Nothing overflows.** A directory name longer than the whole prompt budget is
  cut on a character boundary and marked with `…`; no input can write past a
  buffer, and the release build is the one that ships.
- **Names are data, never code.** Control bytes are replaced with `?` so a
  newline in a file name cannot start a fake prompt line, and both integrations
  turn off the second expansion pass (`promptvars` for bash, `prompt_subst` and
  `prompt_bang` for zsh) that would otherwise run a directory called `$(...)`.
- **The terminal is left as it was found.** The background query saves the
  terminal state, turns echo and canonical input off, reads the whole reply so
  no byte is left in the input queue, restores the state on every path, and
  holds off `SIGINT`/`SIGTERM`/`SIGHUP`/`SIGQUIT` while doing it.
- **The shell hook fits in.** bash 5.1 made `PROMPT_COMMAND` an array; prompty
  adds itself to whichever form it finds and never twice, so other hooks keep
  running.
- **The cache is written atomically.** Two terminals starting at once cannot
  leave a reader looking at half a file.
- **The one subprocess has a deadline.** A command that does not answer in two
  seconds is killed and the prompt falls back to reading `.git/HEAD`.

### Path truncation

Three kept components, `~` counting as one, and the repository as the anchor:

| working directory                                        | label                                            |
| -------------------------------------------------------- | ------------------------------------------------ |
| `~/plain/a`                                              | `~/plain/a`                                      |
| `~/plain/a/b`                                            | `…/plain/a/b`                                    |
| `/usr/share/doc`                                         | `/usr/share/doc` (the root slash does not count) |
| `/usr/share/doc/x`                                       | `…/share/doc/x`                                  |
| repository at `~/Projects/code/prompty`, cwd = repo root | `…/prompty`                                      |
| … cwd = `src/domain`                                     | `…/prompty/src/domain`                           |
| … cwd = `src/domain/deep/er`                             | `…/domain/deep/er`                               |

Inside a repository the ancestors above it are replaced by `…/`, which is what
makes the label stable no matter how deep the clone lives.

### Git

The branch, the working tree state and the upstream divergence are exactly what
`git status --porcelain=v2 --branch` reports, rendered with one glyph per
category: `=` conflict, `$` stash, `✘` deleted, `»` renamed, `!` modified, `+`
staged, `?` untracked, then `⇕` diverged or `⇡`/`⇣`.

Parsing the index directly would be faster but wrong — ignore rules, submodules,
sparse checkouts, `assume-unchanged` and ahead/behind all live in git's head,
not in the index — and being subtly wrong about a dirty tree is worse than being
slow. So it is one subprocess, and it can be switched off.

### What it deliberately does not do

- **No toolchain versions.** prompty shows what the project pins, never what
  happens to be installed.
- **No second subprocess.** There is no `node --version`, no `go version`, no
  `git rev-parse` on top of the status call.

## Environment

| variable                  | meaning                                                     |
| ------------------------- | ----------------------------------------------------------- |
| `PROMTY_BACKGROUND`       | `#rrggbb`, overrides the detected terminal background       |
| `PROMTY_GIT_STATUS`       | `0`/`false` to skip the `git status` call entirely          |
| `NO_COLOR`                | set to anything to disable colour entirely                  |
| `PROMTY_LAST_EXIT`        | exit status of the previous command, set by the integration |
| `PROMTY_LAST_DURATION_MS` | duration of the previous command, set by the integration    |

## Development

```sh
zig build             # 79 KiB static binary, ReleaseFast
zig build -Dmode=safe # same code with the safety checks on, for auditing
zig build test        # 193 unit and integration tests
zig build coverage    # the same tests under kcov, gate at 100% of lines
zig build bench       # measure a real render, fork included
zig build run -- render --no-color
nix build .#          # the package, built and tested in a sandbox
```

`zig build coverage` needs `kcov` (override its path with `-Dkcov=...`).

## Requirements

Linux, Zig 0.17, and a terminal that answers the OSC 11 background query (or
`PROMTY_BACKGROUND`).

## Layout

```
src/domain/       pure: colours, path shortening, durations, TZif, git porcelain, rendering
src/ports/        the six interfaces the outside world is reduced to
src/adapters/     Linux syscalls and one fork/exec behind those interfaces
src/application/  the use case, the command line and the shell scripts
src/main.zig      composition root: the only file that knows both sides
nix/              package, manifest reader and the home-manager module
tools/            coverage gate and benchmark
```

See [DESIGN.md](DESIGN.md) for the reasoning, the budget and the invariants.
