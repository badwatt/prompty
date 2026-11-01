# prompty

A terminal prompt that measures itself in microseconds.

```
  badwatt   …/prompty    main ✘!   1.2s   14:32 ❯
```

One line: three powerline surfaces that fade into your terminal's own
background, then dim detail, then the chevron. Zero configuration.

## Performance

Every number is a full `fork` + `exec` + render, 100-1000 runs, same machine,
same directory, default configuration of each prompt:

| where | prompty | starship 1.25.1 |
| --- | --- | --- |
| empty directory | **1.04 ms** | 3.08 ms |
| this repository, `git status` on | **4.92 ms** | 13.73 ms |
| this repository, `--no-git-status` | **1.05 ms** | — |
| a directory with 20,000 entries | **1.06 ms** | 87.6 ms |
| binary size | **60 KiB** | 13.4 MiB |

The difference is what each prompt *looks at*. prompty reads `.git/HEAD`, runs
one `git status` when you are in a repository, and reads the clock. It never
lists a directory and never asks a program for its version. Outside a
repository a render is 22 syscalls, whether the directory holds nothing or
twenty thousand files; the other prompt pays for the file count on every
command.

Reproduce it:

```sh
zig build bench -- 300                                  # prompty
zig build bench -- 100 "$(command -v starship)" prompt  # whatever you have
```

`tools/bench.zig` spawns the command N times and prints min / median / mean /
p95 / max, fork included.

## Install with Nix

```nix
# flake.nix
inputs.prompty.url = "github:badwatt/prompty";
inputs.prompty.inputs.nixpkgs.follows = "nixpkgs";

# home-manager modules
imports = [ inputs.prompty.homeModules.default ];

programs.prompty.enable = true;
```

That is the whole setup: the package is installed and the prompt is wired into
every shell home-manager manages, ordered after the rest of your initialisation
and idempotent if sourced twice. No shell file to edit.

```nix
programs.prompty = {
  enable = true;
  gitStatus = true;        # false: skip the git call, keep the branch
  background = "#1e1e2e";  # else prompty asks the terminal once and caches it
};
```

## Install on Linux

```sh
zig build
install -m755 zig-out/bin/prompty ~/.local/bin/prompty
```

```sh
# ~/.zshrc            or            # ~/.bashrc
eval "$(prompty init zsh)"           eval "$(prompty init bash)"
```

The first interactive shell asks the terminal for its background colour and
caches the answer; every prompt after that is a fork and a few hundred
microseconds. A Nerd Font is needed for the glyphs.

## Commands

```
prompty render [--shell=zsh|bash|plain] [--no-color]   print the prompt
               [--no-git-status]                       skip the git call
prompty init zsh|bash                                  print the shell integration
prompty theme [detect [--force]]                       print (or redetect) the palette
prompty version                                        print name and version
```

## What it shows

Left to right: the user, the directory, the branch with its working-tree status,
then the dim detail — direnv, how long the last command took, the clock — and
finally a mark if that command failed.

| part | where it comes from |
| --- | --- |
| user | `$USER`, bold, on a red surface for root |
| directory | `$PWD`, `~` for home, three components, anchored on the repository name |
| branch | `git status --branch`, or `.git/HEAD` with `--no-git-status` |
| working tree | `= $ ✘ » ! + ?` and `⇡ ⇣ ⇕`, one glyph per category and no counts; a rebase, merge, cherry-pick or bisect in progress; a stashed change |
| detail | `$DIRENV_DIFF`; how long the last command took (`$PROMTY_LAST_DURATION_MS`, yellow past 2 s, red past 10 s); the clock |
| last command | a red `×` when it failed (`$PROMTY_LAST_EXIT`) |

### Path truncation

Three kept components, `~` counting as one, repository as the anchor:

| working directory | label |
| --- | --- |
| `~/plain/a` | `~/plain/a` |
| `~/plain/a/b` | `…/plain/a/b` |
| `/usr/share/doc/x` | `…/share/doc/x` |
| repository at `~/code/prompty`, cwd = root | `…/prompty` |
| … cwd = `src/domain` | `…/prompty/src/domain` |

A name longer than the whole budget is cut on a character boundary and marked
with `…`, never written past its buffer.

## Fast by construction, careful by default

- **One subprocess, only in a repository:** a single `git status
  --porcelain=v2 --branch`. Turn it off and the branch comes from `.git/HEAD`.
  A command that does not answer in two seconds is killed.
- **Nothing proportional to the directory.** No listing, no manifest scan, no
  version probing, no allocation: fixed stack buffers, one `write` per prompt.
- **No configuration file.** The palette is derived from the terminal background
  in Oklab, so the surfaces are subtle variations of the colour you already
  chose.
- **Names are data, not code.** Control bytes become `?`, and both integrations
  turn off the second expansion pass (`promptvars` for bash, `prompt_subst` and
  `prompt_bang` for zsh) that would otherwise run a directory named `$(...)`.
- **The terminal is left as found.** The background query saves the terminal
  state, reads the whole reply so no byte is left in the input queue, restores
  the state on every path, and holds off `SIGINT`/`SIGTERM`/`SIGHUP`/`SIGQUIT`
  while doing it.
- **Degrade, never fail.** A missing zone file means UTC, a silent terminal
  means the default palette, a huge repository means the branch without counts.

## Environment

| variable | meaning |
| --- | --- |
| `PROMTY_BACKGROUND` | `#rrggbb`, overrides the detected terminal background |
| `PROMTY_GIT_STATUS` | `0`/`false` to skip the `git status` call entirely |
| `NO_COLOR` | set to anything to disable colour entirely |
| `PROMTY_LAST_EXIT` | exit status of the previous command, set by the integration |
| `PROMTY_LAST_DURATION_MS` | duration of the previous command, set by the integration |

## Development

```sh
zig build             # 60 KiB static binary, ReleaseFast
zig build -Dmode=safe # the same code with the safety checks on, for auditing
zig build test        # 192 unit and integration tests
zig build coverage    # the same tests under kcov, gate at 100% of lines
zig build bench       # measure a real render, fork included
zig build run -- render --no-color
nix build .#          # the package, built and tested in a sandbox
```

`zig build coverage` needs `kcov` (override with `-Dkcov=...`).

CI runs `fmt:check` and the test suite on every push and pull request. Bumping
the version in `build.zig.zon` and pushing to `main` tags that version and
publishes a release with static `x86_64-linux` and `aarch64-linux` binaries, a
changelog built from the commits and a `SHA256SUMS` file.

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
