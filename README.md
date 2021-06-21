# NixOS tooling for Hashicorp Vault

A NixOS module and a set of helper scripts to fetch secrets from Vault
and provide them to systemd services.

## Module

[The module](./modules/vault-secrets.nix) declares a `vault-secrets` option
which can be used to fetch secrets from vault.

<!-- FIXME: add more documentation -->

## Scripts

[vault-push-approle-envs](./scripts/vault-push-approle-envs.nix) and [vault-push-approles](./scripts/vault-push-approles.nix)
are both script generators that take a flake and some overrides, then extract
some information about NixOS configurations that use the vault-secrets
module, and output a script that automates processes required to make the
module work. Both resulting scripts must be ran with an administrative-level
vault token after adding or changing the secrets definition.

Example of both script generators in action can be found here: <https://github.com/serokell/pegasus-infra/blob/ec204726674c5aa9c65ab170d1118e2d6bbcdb85/flake.nix#L89>

In short, you want to overlay the `overlay` from [this flake](./flake.nix)
on top of your nixpkgs, and then add `pkgs.vault-push-approles self { /*
overrides */ }` and `pkgs.vault-push-approle-envs self { /* overrides */
}` either to your `devShell`, or as separate `apps` in your flake.

### `vault-push-approles`

This script generates approle definitions and policies, and uploads them
to the Vault instance specified in the module configuration. If you need
to upload extra approles, or change some of the generated approle definitions
or policies, you can use overrides (see examples in the comments on top
of the script generator).

### `vault-push-approle-envs`

This script fetches approle credentials from Vault and then pushes those
credentials to the servers, so that the module can authenticate to Vault.
It guesses server hostnames from their `networking` config option. If you
want to override some hostnames, use `hostnameOverrides` like this:

```nix
vault-push-approle-envs self {
  hostnameOverrides."<attribute name in nixosConfigurations>" = "new.host.name";
}
```
