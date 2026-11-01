{
  lib,
  stdenv,
  zig,
}:

let
  manifest = import ./manifest.nix;
in
stdenv.mkDerivation (finalAttrs: {
  pname = manifest.name;
  version = manifest.version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../src
      ../tools
      ../README.md
      ../DESIGN.md
    ];
  };

  nativeBuildInputs = [ zig ];

  dontConfigure = true;

  # Zig wants caches it can write to, and the install step is the build step.
  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
    export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local-cache
    zig build --prefix "$out" -Dstrip=true
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
    export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local-cache
    zig build test --summary all
    runHook postCheck
  '';

  dontInstall = true;

  # The binary is static; there is nothing to patch or strip further.
  dontPatchELF = true;

  meta = {
    description = "A terminal prompt that measures itself in microseconds";
    license = lib.licenses.mit;
    mainProgram = manifest.name;
    platforms = lib.platforms.linux;
  };
})
