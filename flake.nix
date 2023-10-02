{
  description = "Serokell Vault Tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nix, flake-utils, ... }@inputs:
    {

    overlay = final: prev: {
      vault-push-approles =
        final.callPackage ./scripts/vault-push-approles.nix { };
      vault-push-approle-envs =
        final.callPackage ./scripts/vault-push-approle-envs.nix { };
    };

    nixosModules.vault-secrets = import ./modules/vault-secrets.nix;
    darwinModules.vault-secrets = import ./modules/vault-secrets-darwin.nix;

    } // (flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;
        inherit (lib) mapAttrs;
      in {
        checks = let
          tests = import ./tests/modules/all-tests.nix {
            inherit pkgs system self;
            callTest = t: t.test;
            nixosPath = "${nixpkgs}/nixos";
          };
        in { inherit (tests) vault-secrets; };

        legacyPackages = nixpkgs.legacyPackages.${system}.extend self.overlay;
      }));
}
