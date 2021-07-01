# SPDX-FileCopyrightText: 2020 Serokell <https://serokell.io/>
#
# SPDX-License-Identifier: MPL-2.0

{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.vault-secrets;

  secretOptions = (with types; submodule (
    {name, ... }:
    {
      options = {
        environmentVariableNamePrefix = mkOption {
          type = with types; nullOr str;
          default = null;
          example = "SERVICE_NAME";
          description = ''
            A prefix to prepend to environment variable names in the
            <literal>environment</literal> file. Will be uppercase, and
            separated from the rest of the variable name by an underscore.

            For example, with a prefix <literal>foo</literal> and a key
            <literal>bar</literal>, the variable name will be
            <literal>FOO_bar</literal>. Note that the key is never upcased.
          '';
        };

        environmentFile = mkOption {
          type = with types; str;
          default = "/root/vault-secrets.env.d/${if cfg.approlePrefix != null then "${cfg.approlePrefix}-${name}" else "${name}"}";
          example = "/root/service.sh";
          description = ''
            Path to a file that contains the necessary environment variables for
            Vault to log into an AppRole and pull data. Should define
            <literal>VAULT_ROLE_ID</literal> and
            <literal>VAULT_SECRET_ID</literal>.
          '';
        };

        environmentKey = mkOption {
          type = with types; nullOr str;
          default = "environment";
          example = "environment_data";
          description = ''
            Vault KV key under <literal>vaultPrefix/namespace</literal> that
            contains the environment for this service. Keys will be dumped into
            <literal>outPrefix/name/environment</literal> in a format
            suitable for use with EnvironmentFile.
          '';
        };

        secretsKey = mkOption {
          type = with types; nullOr str;
          default = "secrets";
          example = "super/secret";
          description = ''
            Vault KV path under <literal>vaultPrefix</literal>
            that contains the secrets for this service.

            Keys in this secrets will be dumped into files under
            <literal>outPrefix/name/key</literal>.
          '';
        };

        secretsAreBase64 = mkOption {
          type = with types; bool;
          default = false;
          example = true;
          description = ''
            Whether or not values in <literal>secretsKey</literal> are base64
            encoded. Note that it's all or nothing, not per-key.

            This only affects secrets defined in <literal>secretsKey</literal>,
            and not those defined in <literal>environmentKey</literal>
          '';
        };

        quoteEnvironmentValues = mkOption {
          type = with types; bool;
          default = true;
          example = false;
          description = ''
            Whether or not values dumped into the environment file are to be
            quoted. Because Docker is garbage.
          '';
        };

        extraScript = mkOption {
          type = with types; nullOr lines;
          default = "";
          example = literalExample ''
            envsubst < infile > $secretspath/outfile
          '';
          description = ''
            Extra script to run in the secret unit context.

            Secrets defined in <literal>environmentKey</literal> are available
            as exported shell variables.

            The variable <literal>$secretsPath</literal> will be set to the
            folder containing all secrets files.

            If you need to write any files that contain secrets, such as a
            generated config file, write it under this folder.
          '';
        };

        services = mkOption {
          default = [ name ];
          type = with types; listOf str;
          description = ''
            Systemd services that depend on this secret. Defaults to the
            attribute name.

            Setting this option does not merge with the default value. If you
            want to preserve it, you'll need to define it explicitly.

            If set to empty, the unit will run on its own, rather than as a
            dependency of another unit. Useful for secrets that dont have a
            specific dependent unit.
          '';
        };

        user = mkOption {
          type = with types; str;
          default = "root";
          example = "gitlab-runner";
          description = ''
            User that should own the secrets files.
          '';
        };

        group = mkOption {
          type = with types; str;
          default = "nogroup";
          example = "nginx";
          description = ''
            Group that should own the secrets files.
          '';
        };

        __toString = mkOption {
          default = _: "${cfg.outPrefix}/${name}";
          readOnly = true;
        };
      };
    }
  ));
in
{
  options = {
    vault-secrets = {
      vaultPrefix = mkOption {
        type = with types; str;
        default = "kv";
        description = ''
          Base Vault KV path to prepend to all KV paths, including the mount point.
        '';
      };

      outPrefix = mkOption {
        type = with types; str;
        default = "/run/secrets";
        description = ''
          Base path to output secrets. The path will be created, owned by root, and chmod 700.

          Should probably be on tmpfs to avoid leaking secrets.
        '';
      };

      approlePrefix = mkOption {
        type = with types; nullOr str;
        default = null;
        description = ''
          Prepended to the secret name for resolving the default environmentFile path.
        '';
      };

      vaultAddress = mkOption {
        type = with types; str;
        default = "https://127.0.0.1:8200";
        description = ''
          The address of the Vault server, passed via <literal>VAULT_ADDR</literal> environment variable.
      '';
      };

      secrets = mkOption {
        type = with types; attrsOf secretOptions;
        default = {};
      };
    };
  };

  config = {
    systemd.services = lib.mkMerge ([(flip mapAttrs' cfg.secrets (
      name: scfg: with scfg;
      let
        secretsPath = "${cfg.outPrefix}/${name}";
      in nameValuePair "${name}-secrets" {
        path = with pkgs; [ getent jq vault-bin python3 ];

        partOf = map (n: "${name}.service") services;
        wantedBy = optional (services == []) "multi-user.target" ;

        # network is needed to access the vault server
        requires = [ "network-online.target" ];
        after = [ "network-online.target" ];

        environment.VAULT_ADDR = cfg.vaultAddress;

        script = ''
          set -euo pipefail

          # Ensure the base path exists and has the correct permissions
          mkdir -p "${cfg.outPrefix}"
          chmod 0755 "${cfg.outPrefix}"

          # Make sure we start from a clean slate
          rm -rf "${secretsPath}"
          mkdir -p "${secretsPath}"

          # Log into Vault using credentials from environmentFile
          vaultOutput="$(vault write -format=json auth/approle/login role_id="$VAULT_ROLE_ID" secret_id=- <<< "$VAULT_SECRET_ID")"
          jq '.auth.client_token = "redacted"' <<< "$vaultOutput"
          VAULT_TOKEN="$(jq -r '.auth.client_token' <<< "$vaultOutput")"
          export VAULT_TOKEN

        '' + optionalString (secretsKey != null) ''
          json_dump="$(vault kv get -format=json "${cfg.vaultPrefix}/${name}/${secretsKey}" || true)"
          if [[ -n "$json_dump" ]]; then
            echo "Found secrets at ${cfg.vaultPrefix}/${name}/${secretsKey}" >&2
            # call a python script which saves secrets to files in `secretsPath` directory
            ${../scripts/write_secrets.py} ${optionalString secretsAreBase64 "--base64"} ${lib.escapeShellArg secretsPath} <<< "$json_dump"
          fi

        '' + optionalString (environmentKey != null) ''
          json_dump="$(vault kv get -format=json "${cfg.vaultPrefix}/${name}/${environmentKey}" || true)"
          if [[ -n "$json_dump" ]]; then
        '' + (if quoteEnvironmentValues then ''
              jq -r '.data.data | to_entries[] | "${optionalString (environmentVariableNamePrefix != null) "${toUpper environmentVariableNamePrefix}_"}\(.key)=\"\(.value)\""' <<< "$json_dump" > "${secretsPath}/environment"
        '' else ''
              jq -r '.data.data | to_entries[] | "${optionalString (environmentVariableNamePrefix != null) "${toUpper environmentVariableNamePrefix}_"}\(.key)=\(.value)"' <<< "$json_dump" > "${secretsPath}/environment"
        '') + ''
              echo "Dumped environment file at ${secretsPath}/environment" >&2
          fi

        '' + optionalString (extraScript != "") ''
          secretsPath="${secretsPath}"
          source <(jq -r '.data.data | to_entries[] | "export ${optionalString (environmentVariableNamePrefix != null) "${toUpper environmentVariableNamePrefix}_"}\(.key)=\"\(.value)\""' <<< "$json_dump")
          echo "Running extra script..."
          ${extraScript}
          echo "Extra script done."

        '' + ''
          chown -R "${user}:${group}" "${secretsPath}"
        '';

        serviceConfig = {
          EnvironmentFile = environmentFile;
          RemainAfterExit = true;
          Type = "oneshot";
          UMask = "0077";
        };
      }
    ))] ++ (flip lib.mapAttrsToList cfg.secrets (
      name: scfg: with scfg;
      lib.genAttrs services (services: rec {
        requires = [ "${name}-secrets.service" ];
        after = requires;
        bindsTo = requires;
      }))
    ));
  };
}
