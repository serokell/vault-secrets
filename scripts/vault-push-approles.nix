# Generate and push approles to vault
{ writeShellScriptBin, jq, vault, coreutils, lib }:
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

  overrideable = final: {
    extraApproles = [ ];

    renderJSON = name: content:
      builtins.toFile "${name}.json" (builtins.toJSON content);

    approleParams = {
      secret_id_ttl = "";
      token_num_uses = 0;
      token_ttl = "20m";
      token_max_ttl = "30m";
      secret_id_num_uses = 0;
    };

    mkApprole = { name, ... }:
      (final.approleParams // { token_policies = [ name ]; });

    renderApprole = { approleName, ... }@params:
      final.renderJSON "approle-${approleName}" (final.mkApprole params);

    approleCapabilities = { };

    approleCapabilitiesFor = { approleName, ... }:
      final.approleCapabilities.${approleName} or [ "read" ];

    mkPolicy = { approleName, name, vaultPathPrefix, namespace, ... }@params:
      let
        splitPrefix = builtins.filter builtins.isString
          (builtins.split "/" vaultPathPrefix);

        insertAt = lst: index: value:
          (lib.lists.take index lst) ++ [ value ] ++ (lib.lists.drop index lst);

        makePrefix = value:
          builtins.concatStringsSep "/" (insertAt splitPrefix 1 value);

        metadataPrefix = makePrefix "metadata";
        dataPrefix = makePrefix "+";
      in {
        path = [
          {
            "${metadataPrefix}/${namespace}/${name}/*" =
              [{ capabilities = [ "list" ]; }];
          }
          {
            "${dataPrefix}/${namespace}/${name}/*" =
              [{ capabilities = final.approleCapabilitiesFor params; }];
          }
        ];
      };

    renderPolicy = { approleName, ... }@params:
      final.renderJSON "policy-${approleName}" (final.mkPolicy params);
  };

  __toString = self:
    let
      final = lib.fix self.overrideable;

      inherit (final) renderApprole renderPolicy renderJSON extraApproles;

      writeApprole = { approleName, vaultAddress, ... }@params:
        let
          approle = renderApprole params;
          policy = renderPolicy params;
          vaultWrite = ''
            echo '+' vault write "auth/approle/role/${approleName}" "@${approle}"
            echo '+' vault policy write "${approleName}" "${policy}"
          '';

        in ''
          export VAULT_ADDR="${vaultAddress}"

          # Ensure a valid Vault token is available
          token_data="$(${vault}/bin/vault token lookup -format=json)"
          vault_token_never_expire="$(${jq}/bin/jq '.data.expire_time == null' <<< "$token_data")"
          vault_token_ttl="$(${jq}/bin/jq '.data.ttl' <<< "$token_data")"
          if [[ $vault_token_never_expire == false && $vault_token_ttl -le 0 ]]; then
            echo 'Vault token expired or invalid. Please log into vault first.'
            exit 1
          fi

          write() {
            # set -x
            ${vaultWrite}
            # set +x
          }

          ask_write() {
            if ! [[ "''${VAULT_PUSH_ALL_APPROLES:-}" == "true" ]]; then
              read -rsn 1 -p "Write approle ${approleName} to ${vaultAddress}? [(A)ll/(y)es/(d)etails/(s)kip/(q)uit] "
              echo
              case "$REPLY" in
                A|a|"") # All
                  VAULT_PUSH_ALL_APPROLES=true
                  ;;

                y) # yes
                  # Continue
                  ;;

                d) # details
                  {
                    echo "* Merged attributes of this approle:"
                    cat "${renderJSON "merged" params}" | ${jq}/bin/jq .
                    echo

                    echo "* Approle JSON (${approle}):"
                    cat ${approle} | ${jq}/bin/jq .
                    echo

                    echo "* Policy JSON (${policy}):"
                    cat ${policy} | ${jq}/bin/jq
                    echo

                    echo "* Will execute the following commands:"
                    echo '${vaultWrite}'
                    echo
                  } | ''${PAGER:-less}

                  ask_write
                  return
                  ;;

                s) # skip
                  echo "* Skipping ${approleName}"
                  echo
                  return
                  ;;

                q) # quit
                  exit 1
                  ;;

                *) # unknown
                  echo "* Unrecognized reply: $REPLY. Please try again."
                  echo
                  ask_write
                  return
                  ;;
              esac
            fi

            write
            echo
          }

          if [[ $# -eq 0 ]]; then
            ask_write
          elif [[ " $@ " =~ " ${approleName} " ]]; then
            write
          fi
        '';

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

      configsWithSecrets = lib.filterAttrs (_: cfg:
        cfg.config ? vault-secrets && cfg.config.vault-secrets.secrets != { })
        nixosConfigurations;

      approleParamsForAllMachines =
        builtins.mapAttrs (lib.const approleParamsForMachine)
        configsWithSecrets;

      allApproleParams =
        (builtins.concatLists (builtins.attrValues approleParamsForAllMachines)
          ++ extraApproles);

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
      writeAllApproles =
        assert allUnique (map (x: x.approleName) allApproleParams);
        lib.concatMapStringsSep "\n" writeApprole allApproleParams;
    in writeShellScriptBin "vault-push-approles" ''
      set -euo pipefail
      ${writeAllApproles}
    '';

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
