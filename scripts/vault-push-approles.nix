# Generate and push approles to vault
{ writeShellScriptBin, writeText, jq, vault, coreutils, bash, lib }:
# Inputs: a flake with `nixosConfigurations`

# Usage:
# apps.x86_64-linux.vault-push-approles = { type = "app"; program = "${pkgs.vault-push-approles self}/bin/vault-push-approles"; }

{ nixosConfigurations ? { }, ... }: rec {
  # Overrideable functions
  # Usage examples:
  # pkgs.vault-push-approles self { approleCapabilities.aquarius-albali-borgbackup = [ "read" "write" ]; }
  /* pkgs.vault-push-approles self (final: prev: {
       approleCapabilitiesFor = { approleName, namespace, ... }@params:
         if namespace == "albali" then [ "read" "write" ] else prev.approleCapabilitiesFor params;
     })
  */
  # pkgs.vault-push-approles { } { extraApproles = [ { ... } ] }

  # `final` contains fixed-point functions after applying user-supplied overrides
  overrideable = final: {

    # Approles to upload in addition to the ones generated from
    # vault-secrets' NixOS module definitions. Must contain all the
    # options from top-level vault-secrets option and all the options
    # from vault-secrets.secrets.<name> submodule, as well as
    # "approleName" attribute
    extraApproles = [ ];

    # Render an attrset into a JSON file
    renderJSON = name: content:
      writeText "${name}.json" (builtins.toJSON content);

    # Default approle parameters
    approleParams = {
      secret_id_ttl = "";
      token_num_uses = 0;
      token_ttl = "20m";
      token_max_ttl = "30m";
      secret_id_num_uses = 0;
    };

    # Generate an approle parameters attrset based on its name and other
    # options from its secret definition
    mkApprole = { approleName, ... }:
      (final.approleParams // { token_policies = [ approleName ]; });

    # Create a JSON (HCL) file with approle parameters in it from its secret definition
    renderApprole = { approleName, ... }@params:
      final.renderJSON "approle-${approleName}" (final.mkApprole params);

    # An attrset mapping `approleName`s to capabilities required by those approles
    approleCapabilities = { };

    # Get capabilities for the given secret definition
    approleCapabilitiesFor = { approleName, ... }:
      final.approleCapabilities.${approleName} or [ "read" ];

    # Generate an approle policy from its secret definition
    mkPolicy = { approleName, name, vaultPrefix, ... }@params:
      let
        splitPrefix =
          builtins.filter builtins.isString (builtins.split "/" vaultPrefix);

        insertAt = lst: index: value:
          (lib.lists.take index lst) ++ [ value ] ++ (lib.lists.drop index lst);

        makePrefix = value:
          builtins.concatStringsSep "/" (insertAt splitPrefix 1 value);

        metadataPrefix = makePrefix "metadata";
        dataPrefix = makePrefix "+";
      in {
        path = {
          "${metadataPrefix}/${name}/*".capabilities = [ "list" ];
          "${dataPrefix}/${name}/*".capabilities =
            final.approleCapabilitiesFor params;
        };
      };

    # Create a JSON (HCL) file with the approle's policy from its secret definition
    renderPolicy = { approleName, ... }@params:
      final.renderJSON "policy-${approleName}" (final.mkPolicy params);

  };

  __toString = self:
    let
      # Hooray fix point
      final = lib.fix self.overrideable;

      inherit (final) renderApprole renderPolicy renderJSON extraApproles;

      # The script that writes the approle to the vault server
      writeApprole = { approleName, vaultAddress, ... }@params:
        let
          approle = renderApprole params;
          policy = renderPolicy params;
          vaultWrite = ''
            vault write "auth/approle/role/${approleName}" "@${approle}"
            vault policy write "${approleName}" "${policy}"
          '';

        in ''
          export VAULT_ADDR="${vaultAddress}"

          ${./vault-ensure-token.sh}

          write() {
            set -x
            ${vaultWrite}
            set +x
          }

          # Ask the user what to do with the current approle
          ask_write() {
            if ! [[ "''${VAULT_PUSH_ALL_APPROLES:-}" == "true" ]]; then
              read -rsn 1 -p "Write approle ${approleName} to ${vaultAddress}? [(a)ll/(y)es/(d)etails/(s)kip/(q)uit] "
              echo
              case "$REPLY" in
                # Write all the approles including this one
                A|a)
                  VAULT_PUSH_ALL_APPROLES=true
                  ;;
                # Write the current approle, ask for the next one
                y)
                  ;;
                # Show details about this approle, ask about it again
                d)
                  {
                    echo "* Merged attributes of this approle:"
                    cat "${renderJSON "merged" params}" | ${jq}/bin/jq .
                    echo "* Approle JSON (${approle}):"
                    cat ${approle} | ${jq}/bin/jq .
                    echo "* Policy JSON (${policy}):"
                    cat ${policy} | ${jq}/bin/jq
                    echo "* Will execute the following commands:"
                    echo '${vaultWrite}'
                    ask_write
                    return
                  } | ''${PAGER:-less}
                  ;;
                # Don't write the current approle, ask for the next one
                s)
                  {
                    echo "* Skipping ${approleName}"
                    return
                  }
                  ;;
                # Quit
                q)
                  exit 1
                  ;;
                *)
                  echo "* Unrecognized reply: $REPLY. Please try again"
                  ask_write
                  return
                  ;;
              esac
            fi

            write
            echo
          }

          if [[ $# -eq 0 ]]; then
            # If we don't get any arguments, ask about this approle
            ask_write
          elif [[ " $@ " =~ " ${approleName} " ]]; then
          # If this approle is in the argument list, just upload it
            write
          fi
        '';

      # Get all approles for vault-secrets in configuration
      approleParamsForMachine = cfg:
        let
          vs = cfg.config.vault-secrets;
          prefix = lib.optionalString (!isNull vs.approlePrefix)
            "${vs.approlePrefix}-";
        in builtins.attrValues (builtins.mapAttrs (name: secret:
          builtins.removeAttrs (vs // secret // {
            approleName = "${prefix}${name}";
            inherit name;
          }) [ "__toString" "secrets" ]) vs.secrets);

      # Find all configurations that have vault-secrets defined
      configsWithSecrets = lib.filterAttrs (_: cfg:
        cfg.config ? vault-secrets && cfg.config.vault-secrets.secrets != { })
        nixosConfigurations;

      # Get all approles for all NixOS configurations in the given flake
      approleParamsForAllMachines =
        builtins.mapAttrs (lib.const approleParamsForMachine)
        configsWithSecrets;

      # All approles for all NixOS configurations plus the extra approles
      allApproleParams =
        (builtins.concatLists (builtins.attrValues approleParamsForAllMachines)
          ++ extraApproles);

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
      writeAllApproles =
        assert allUnique (map (x: x.approleName) allApproleParams);
        lib.concatMapStringsSep "\n" writeApprole allApproleParams;
    in writeShellScriptBin "vault-push-approles" ''
      set -euo pipefail
      export PATH=$PATH''${PATH:+':'}'${lib.makeBinPath [ jq vault coreutils bash ]}'
      ${writeAllApproles}
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
