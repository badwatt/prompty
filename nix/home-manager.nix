# A home-manager module: `programs.prompty.enable = true;` is the whole setup.
#
# It installs the package, wires the prompt into the shells that are enabled and
# leaves every other line of the user's shell configuration alone.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.prompty;
  command = lib.getExe cfg.package;
in
{
  options.programs.prompty = {
    enable = lib.mkEnableOption "prompty as the interactive shell prompt";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalMD "the prompty package from this flake";
      description = "The prompty package to install.";
    };

    gitStatus = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ask git for the working tree status on every prompt. It costs about four
        milliseconds inside a repository; turning it off leaves the branch, read
        straight from `.git/HEAD`.
      '';
    };

    background = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "#[0-9a-fA-F]{6}");
      default = null;
      example = "#1e1e2e";
      description = ''
        Terminal background colour, used to derive the palette. Left unset,
        prompty asks the terminal once and remembers the answer.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    # Ordered after the rest of the user's initialisation, and idempotent: the
    # generated script refuses to install itself twice.
    programs.zsh.initContent = lib.mkOrder 1200 ''
      eval "$(${command} init zsh)"
    '';

    programs.bash.initExtra = ''
      eval "$(${command} init bash)"
    '';

    home.sessionVariables = lib.mkMerge [
      (lib.mkIf (!cfg.gitStatus) { PROMTY_GIT_STATUS = "0"; })
      (lib.mkIf (cfg.background != null) { PROMTY_BACKGROUND = cfg.background; })
    ];
  };
}
