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

| where                            | prompty     | starship 1.25.1 |
| -------------------------------- | ----------- | --------------- |
| empty directory                  | **0.92 ms** | 3.08 ms         |
| this repository, `git status` on | **4.3 ms**  | 13.73 ms        |
| this repository, `--git=false`   | **0.95 ms** | —               |
| a directory with 20,000 entries  | **0.92 ms** | 87.6 ms         |
| binary size                      | **68 KiB**  | 13.4 MiB        |

The difference is what each prompt _looks at_. prompty reads `.git/HEAD`, runs
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
  duration = false;         # true: the last command's time, right edge
  git = true;               # false: skip the git call, keep the branch
  background = "#1e1e2e";   # else prompty asks the terminal once and caches it
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
               [-g|--git] [-d|--duration]              git status, and the time
                                                       at the right edge
prompty init zsh|bash [-d|--duration]                  print the shell integration
prompty theme [detect [--force]]                       print (or redetect) the palette
prompty version                                        print name and version
```

A boolean flag on its own means true, so `-d`, `--duration` and `--duration=true`
are the same thing, and `--git=false` (or `-g=false`) is how the flag that
defaults to true is turned off. The value has to come after an `=`: anything
else there is a usage error rather than a guess.

## What it shows

Left to right: the user, the directory, the branch with its working-tree status,
then the dim detail — direnv, how long the last command took, the clock — and
finally a mark if that command failed.

| part         | where it comes from                                                                                                                     |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| user         | `$USER`, bold, on a red surface for root                                                                                                |
| directory    | `$PWD`, `~` for home, three components, anchored on the repository name                                                                 |
| branch       | `git status --branch`, or `.git/HEAD` with `--git=false`                                                                                |
| working tree | `= $ ✘ » ! + ?` and `⇡ ⇣ ⇕`, one glyph per category and no counts; a rebase, merge, cherry-pick or bisect in progress; a stashed change |
| detail       | `$DIRENV_DIFF`; how long the last command took (`$PROMTY_LAST_DURATION_MS`, dimmed, yellow past 2 s, red past 10 s); the clock          |
| last command | a red `×` when it failed (`$PROMTY_LAST_EXIT`)                                                                                          |

### The last command's duration, against the right edge

`-d`/`--duration` (or `programs.prompty.duration`) moves the duration out of the
line and puts it where a prompt has room to spare: bold yellow, in plain
milliseconds, ending at the last column of the terminal.

```
 badwatt  …/prompty  main !  14:32 ❯                                   1234ms
```

It replaces the dimmed `1.2s`, so the number is never shown twice. The line stops
one column short of the edge on purpose: a prompt that fills the last cell leaves
the terminal waiting to wrap, and the first character typed then jumps to the
next line instead of following the prompt. The width comes from `$COLUMNS`, which
the generated integration passes on the command line — a prompt's stdout is a
pipe and cannot be asked. A terminal that does not
report its width and a shell that does not export the variable mean no padding
rather than a guessed one, and a prompt already wider than the terminal is left
alone rather than wrapped.

Timing the command is the shell's job, and the two do it differently: zsh has a
`preexec` hook, bash has only a `DEBUG` trap, so the bash trap is generated only
when this option is on — the default bash integration still costs nothing per
command. Both end up passing `PROMTY_LAST_DURATION_MS` in whole milliseconds,
which is also what makes the dimmed placement work.

### Path truncation

Three kept components, `~` counting as one, repository as the anchor:

| working directory                          | label                  |
| ------------------------------------------ | ---------------------- |
| `~/plain/a`                                | `~/plain/a`            |
| `~/plain/a/b`                              | `…/plain/a/b`          |
| `/usr/share/doc/x`                         | `…/share/doc/x`        |
| repository at `~/code/prompty`, cwd = root | `…/prompty`            |
| … cwd = `src/domain`                       | `…/prompty/src/domain` |

A name longer than the whole budget is cut on a character boundary and marked
with `…`, never written past its buffer.

## Fast by construction, careful by default

- **One subprocess, only in a repository:** a single `git status
  --porcelain=v2 --branch`. Turn it off and the branch comes from `.git/HEAD`;
  `PROMTY_GIT=fast` keeps the branch and the tree but skips the untracked
  walk and the divergence walk, which measured 6.4 ms against 9.0 ms in a
  repository with five thousand files and five hundred untracked ones. A command
  that does not answer in two seconds is killed.
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

| variable                  | meaning                                                       |
| ------------------------- | ------------------------------------------------------------- |
| `PROMTY_BACKGROUND`       | `#rrggbb`, overrides the detected terminal background         |
| `PROMTY_GIT`              | `fast` for branch and tree only, `0`/`false` to skip the call |
| `NO_COLOR`                | set to anything to disable colour entirely                    |
| `PROMTY_LAST_EXIT`        | exit status of the previous command, set by the integration   |
| `PROMTY_LAST_DURATION_MS` | duration of the previous command, set by the integration      |
| `COLUMNS`                 | terminal width, passed by the integration when timing is on   |

## Development

```sh
zig build             # 68 KiB static binary, ReleaseFast
zig build -Dmode=safe # the same code with the safety checks on, for auditing
zig build test        # 228 unit, integration and property tests
zig build coverage    # the same tests under kcov, gate at 100% of lines
zig build smoke       # every command, in the shipping ReleaseFast build
zig build stack       # a render on a 64 KiB stack
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
