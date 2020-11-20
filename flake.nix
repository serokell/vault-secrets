{
  description = "Serokell Vault Tooling";

  inputs.nixpkgs.url = "github:serokell/nixpkgs";
  inputs.nix-unstable.url = "github:nixos/nix";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.flake-compat.url = "github:edolstra/flake-compat";
  inputs.flake-compat.flake = false;

  outputs = { self, nixpkgs, flake-utils, ... }@inputs: {

    overlay = final: prev: {
      vault-push-approles =
        final.callPackage ./scripts/vault-push-approles.nix { };
    };

    nixosModules.vault-secrets = import ./modules/vault-secrets.nix;
  } // (flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;
      inherit (lib) mapAttrs;

      nixMaster = inputs.nix-unstable.defaultPackage.${system};
    in {
      checks =
        let
          tests = import ./tests/modules/all-tests.nix {
            inherit pkgs system;
            callTest = t: t.test;
            nixosPath = "${nixpkgs}/nixos";
          };
        in {
          inherit (tests) vault-secrets;
        };

      devShell = pkgs.mkShell {
        buildInputs = [
          nixMaster
        ];
      };
    }));
}
