# Generate and push approles to vault
{ writeShellScriptBin, jq, vault, coreutils, lib }:
# Inputs: a flake with `nixosConfigurations`

# Usage:
# apps.x86_64-linux.vault-push-approle-envs = { type = "app"; program = "${pkgs.vault-push-approle-envs self}/bin/vault-push-approle-envs"; }

{ nixosConfigurations ? { }, ... }: rec {
  overrideable = final: {
    hostNameOverrides = { };
    getHostName = { attrName, config, ... }:
      final.hostNameOverrides.${attrName} or (if isNull
      config.networking.domain then
        config.networking.hostName
      else
        "${config.networking.hostName}.${config.networking.domain}");
  };

  __toString = self:
    let

      final = lib.fix self.overrideable;

      # The script that writes the approle to the vault server
      pushApproleEnv =
        { approleName, vaultAddress, environmentFile, ... }@params:
        let
          hostname = final.getHostName params;

          push = ''
            ${
              ./vault-get-approle-env.sh
            } ${approleName} | ssh "${hostname}" ''${SSH_OPTS:-} "sudo mkdir -p ${
              builtins.dirOf environmentFile
            }; sudo tee ${environmentFile} >/dev/null"
          '';
        in ''
          export VAULT_ADDR="${vaultAddress}"

          if [[ $# -eq 0 ]] || [[ " $@ " =~ " ${approleName} " ]]; then
            # If we don't get any arguments, or the current approle name is in the arguments list, push it
            echo "Uploading ${approleName} to ${hostname}"
            set -x
            ${push}
            set +x
          fi
        '';

      # Get all approles for vault-secrets in configuration
      approleParamsForMachine = attrName: cfg:
        let
          vs = cfg.config.vault-secrets;
          prefix = lib.optionalString (!isNull vs.approlePrefix)
            "${vs.approlePrefix}-";
        in builtins.attrValues (builtins.mapAttrs (name: secret:
          builtins.removeAttrs (vs // secret // {
            approleName = "${prefix}${name}";
            inherit name attrName;
            inherit (cfg) config;
          }) [ "__toString" "secrets" ]) vs.secrets);

      # Find all configurations that have vault-secrets defined
      configsWithSecrets = lib.filterAttrs (_: cfg:
        cfg.config ? vault-secrets && cfg.config.vault-secrets.secrets != { })
        nixosConfigurations;

      # Get all approles for all NixOS configurations in the given flake
      approleParamsForAllMachines =
        builtins.mapAttrs approleParamsForMachine configsWithSecrets;

      # All approles for all NixOS configurations plus the extra approles
      allApproleParams =
        builtins.concatLists (builtins.attrValues approleParamsForAllMachines);

      # Check whether all the elements in the list are unique
      allUnique = lst:
        let
          allUnique' = builtins.foldl' ({ traversed, result }:
            x:
            if !result || builtins.elem x traversed then {
              inherit traversed;
              result = false;
            } else {
              traversed = traversed ++ [ x ];
              result = true;
            }) {
              traversed = [ ];
              result = true; # In an empty list, all elements are unique
            };
        in (allUnique' lst).result;

      # A script to write all approles
      pushAllApproleEnvs =
        assert allUnique (map (x: x.approleName) allApproleParams);
        lib.concatMapStringsSep "\n" pushApproleEnv allApproleParams;
    in writeShellScriptBin "vault-push-approle-envs" ''
      set -euo pipefail
      export PATH='${jq}/bin:${vault}/bin':''${PATH:+':'}$PATH
      ${pushAllApproleEnvs}
    '';

  # Allows to ergonomically override `overrideable` values with a simple function application
  # Accepts either an attrset with override values, or a function of
  # `final` (which will contain the final version of all the overrideable functions)
  __functor = self: overrides:
    self // {
      overrideable = s:
        (self.overrideable s) // (if builtins.isFunction overrides then
          overrides s (self.overrideable s)
        else
          overrides);
    };

  __functionArgs = builtins.mapAttrs (_: _: false) (overrideable { });
}
