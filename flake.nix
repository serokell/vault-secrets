{
  description = "Serokell Vault Tooling";

  nixConfig = {
    flake-registry = "https://github.com/serokell/flake-registry/raw/master/flake-registry.json";
  };

  inputs.flake-compat.flake = false;

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

        nixMaster = inputs.nix.defaultPackage.${system};
      in {
        checks = let
          tests = import ./tests/modules/all-tests.nix {
            inherit pkgs system self;
            callTest = t: t.test;
            nixosPath = "${nixpkgs}/nixos";
          };
        in { inherit (tests) vault-secrets; };

        legacyPackages = nixpkgs.legacyPackages.${system}.extend self.overlay;

        devShell = pkgs.mkShell { buildInputs = [ nixMaster ]; };
      }));
}
