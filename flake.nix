{
  description = "Serokell Vault Tooling";

  outputs = { self }: {

    overlay = final: prev: {
      vault-push-approles =
        final.callPackage ./scripts/vault-push-approles.nix { };
    };

    nixosModules.vault-secrets = import ./modules/vault-secrets.nix;

  };
}
