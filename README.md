# NixOS tooling for Hashicorp Vault

A NixOS module and a set of helper scripts to fetch secrets from Vault
and provide them to systemd services.

## Module

[The module](./modules/vault-secrets.nix) declares a `vault-secrets` option
which can be used to fetch secrets from vault.

Each service is expected to have a separate "secret" with its own AppRole used
to log in. Secrets are never written to disk, but kept in tmpfs. By default,
they are only accessible by `root` and are `chmod 600`.

In this example, substitute `myservice` for a valid service name, and `hostname`
for your machine's hostname.

```nix
{ config, ... }:
let
  vs = config.vault-secrets.secrets;
in {
  vault-secrets = {
    # This applies to all secrets
    vaultPrefix = "kv/servers/${config.networking.hostName}";
    vaultAddress = "https://vault.example.com:8200";

    # Define a secret called `myservice`, with default options.
    secrets.myservice = {};
  };

  services.myservice = {
    enable = true;
    environmentFile = "${vs.myservice}/environment";
  };
}
```

Note that since version `1.15.0` Vault is distributed under an unfree "Business Source License"
and if you want to use `vault-secrets` within your Nix configuration, you'll have to explicitly allow
`vault` unfree package in your configuration. The most convenient way to do this is to add
```
nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (pkg.pname) [ "vault" ];
```
to the configuration of the system that uses `vault-secrets` module.
Also please note that `allowUnfreePredicate` definitions don't combine and it may override
this settings in your existing configuration in which case make sure to combine them manually.

In this example, we define a secret `myservice` for a service called
`myservice`. The AppRole used to log in will be `myservice`. In order to
log in using such an AppRole, it first needs to be created in Vault, and
credentials for it need to be generated, and placed in
`/etc/vault-secrets.env.d/myservice`. This file should be formatted according to
systemd `EnvironmentFile`, and contain the variables `VAULT_ROLE_ID` and
`VAULT_SECRET_ID`, both of which are UUID provided by Vault. Using the
script generators documented below significantly simplifies the process.

The secrets themselves will be fetched from Vault from two specific paths under
`vaultPrefix`. In this example, it will query `kv/servers/hostname/environment`
and `kv/servers/hostname/secrets`. Any keys defined in `environment` will be
dumped into `/run/secrets/myservice/environment` in a format suitable for usage
with systemd `EnvironmentFile`. Any keys defined in `secrets` will be dumped
into individual files under `/run/secrets/myservice`, named after the keys, and
containing the corresponding value. The values of `secrets` may optionally be
flagged as `base64` encoded, which is recommended if you need to store binary
data or multiline text, as Vault has a bad habit of mangling these.

There are options to configure every aspect of this setup to suit your
particular needs. These are just the defaults we have chosen, and which we have
found work for us in the vast majority of cases.

### Notable config options

There are more options. Please see the module for more information. These are
just the ones we use more often:

* `environmentVariableNamePrefix` allows to prefix all variable names in
  `environment` with a common string. Useful if you're configuring a service
  like Grafana, which prefixes all options with `GRAFANA_`. The trailing
  underscore is implied!
* `secretsAreBase64` will pipe all keys in `secrets` through `base64 --decode`
  before dumping to file. Useful for binary or multiline data.
* `quoteEnvironmentValues` defaults to true. Set to false if you need to be
  Docker compatible.
* `extraScript` runs int he same context as the unit itself, and allows for
  advanced manipulation of the secrets themselves, or even rendering config
  files with interpolated secret values. All `environment` secrets are
  automatically available in the environment, and the variable `$secretsPath`
  points to the folder where secrets will be placed. If you generate any files
  based on secrets, you should probably put them here.
* `services` is a list of strings that defaults to a unit with the same name
  as the secret itself. The units listed will be bound to the secret-fetching
  unit, in order to start/stop/restart as one. If your service unit has
  a different name, or if you need to bind multiple units, this is where you do
  that.
* `user` and `group` allow setting the owning user and group of the entire
  output folder.
* `approlePrefix` makes it easy to simplistically namespace AppRoles. Since
  these are not actually namespaced in Vault, and the name defaults to the name
  of the secret, if you want to have two servers with the same secret/service
  name, you will have a clash in the AppRole name. Use this setting to prefix
  the AppRole with the server name.

## Scripts

[vault-push-approle-envs](./scripts/vault-push-approle-envs.nix) and [vault-push-approles](./scripts/vault-push-approles.nix)
are both script generators that take a flake and some overrides, then extract
some information about NixOS configurations that use the vault-secrets
module, and output a script that automates processes required to make the
module work. Both resulting scripts must be ran with an administrative-level
vault token after adding or changing the secrets definition.

Example of both script generators in action can be found here: <https://github.com/serokell/gemini-infra/blob/6bb3e0d/flake.nix#L118>

In short, you want to overlay the `overlay` from [this flake](./flake.nix)
on top of your nixpkgs, and then add `pkgs.vault-push-approles self { /*
overrides */ }` and `pkgs.vault-push-approle-envs self { /* overrides */
}` either to your `devShell`, or as separate `apps` in your flake.

Due to the fact that Vault is distributed under unfree license you'll also need
to explicitly allow this unfree packages in your overlay, for example:
```
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    vault-secrets = "github:serokell/vault-secrets";
    ...
  };
  outputs = { self, nixpkgs, vault-secrets, .. }@inputs:
    let
      pkgs = import nixpkgs {
        config.allowUnfreePredicate = pkg: builtins.elem (pkg.pname) [ "vault" ];
        overlays = [ vault-secrets.overlays.default ];
      };
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        VAULT_ADDR = "https://my-vault-instance.org";
        buildInputs = [
          pkgs.vault
          (pkgs.vault-push-approle-envs self)
          (pkgs.vault-push-approles self)
        ];
      };
    }
}
```

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
  hostNameOverrides."<attribute name in nixosConfigurations>" = "new.host.name";
}
```
