# The application name and version live in exactly one place: build.zig.zon.
# This reads them from there so that the Nix derivation cannot drift from it.
let
  text = builtins.readFile ../build.zig.zon;
  lines = builtins.filter builtins.isString (builtins.split "\n" text);

  firstMatch = pattern:
    let
      matching = builtins.filter (line: builtins.match pattern line != null) lines;
    in
    if matching == [ ] then
      throw "build.zig.zon does not match ${pattern}"
    else
      builtins.head (builtins.match pattern (builtins.head matching));
in
{
  # `.name = .prompty,` — an enum literal, not a string.
  name = firstMatch ".*\\.name = \\.([A-Za-z0-9_]+).*";

  # `.version = "0.1.0",`
  version = firstMatch ".*\\.version = \"([^\"]+)\".*";
}
