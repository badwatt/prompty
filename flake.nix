{
  description = "prompty: a terminal prompt that measures itself in microseconds";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      # `nix profile install .#prompty` or `programs.prompty.enable = true;`
      packages = eachSystem (system: {
        default = (pkgsFor system).callPackage ./nix/package.nix { };
        prompty = self.packages.${system}.default;
      });

      # home-manager: add this to `imports` and set `programs.prompty.enable`.
      homeModules = {
        default = import ./nix/home-manager.nix { inherit self; };
        prompty = self.homeModules.default;
      };

      checks = eachSystem (system: {
        package = self.packages.${system}.default;
      });
    };
}
