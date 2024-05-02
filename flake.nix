{
  description = "Serokell Vault Tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nix, ... }@inputs:
    let
      forSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" ];
    in
    {
      overlays.default = final: prev: {
        vault-push-approles =
          final.callPackage ./scripts/vault-push-approles.nix { };
        vault-push-approle-envs =
          final.callPackage ./scripts/vault-push-approle-envs.nix { };
      };

      nixosModules.vault-secrets = import ./modules/vault-secrets.nix;
      darwinModules.vault-secrets = import ./modules/vault-secrets-darwin.nix;

      checks = forSystems (system:
        let
          tests = import ./tests/modules/all-tests.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit system self;
            callTest = t: t.test;
            nixosPath = "${nixpkgs}/nixos";
          };
        in
        { inherit (tests) vault-secrets; });

      legacyPackages = forSystems (system:
        nixpkgs.legacyPackages.${system}.extend
          self.overlays.default);
    };
}
