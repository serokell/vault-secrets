{
  description = "Serokell Vault Tooling";

  outputs = { self }: {

    nixosModules.vault-secrets = import ./modules/vault-secrets.nix;

    overlay = final: prev: {
      vault-push-approles =
        final.callPackage ./scripts/vault-push-approles.nix { };
      vault-push-approle-envs =
        final.callPackage ./scripts/vault-push-approle-envs.nix { };
    };
  };
}
