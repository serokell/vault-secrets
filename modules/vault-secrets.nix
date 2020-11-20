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
        namespace = mkOption {
          type = with types; str;
          default = cfg.namespace;
          example = "servers/jupiter/services";
          description = ''
            Vault KV path under which all service secrets live, under
            <literal>basePath</literal>. No leading or trailing slash!
          '';
        };

        environmentKey = mkOption {
          type = with types; nullOr str;
          default = "environment";
          example = "environment_data";
          description = ''
            Vault KV key under <literal>vaultPathPrefix/namespace</literal> that
            contains the environment for this service. Keys will be dumped into
            <literal>outPathPrefix/name/environment</literal> in a format
            suitable for use with EnvironmentFile.
          '';
        };

        environmentPrefix = mkOption {
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
            VAULT_ADDRESS, VAULT_ROLE_ID and VAULT_SECRET_ID.
          '';
        };

        secretsKey = mkOption {
          type = with types; nullOr str;
          default = "secrets";
          example = "super/secret";
          description = ''
            Vault KV path under <literal>vaultPathPrefix/namespace</literal>
            that contains the secrets for this service.

            Keys in this secrets will be dumped into files under
            <literal>outPathPrefix/name/key</literal>.
          '';
        };

        secretsBase64 = mkOption {
          type = with types; bool;
          default = false;
          example = true;
          description = ''
            Whether or not values in <literal>secrets</literal> are base64
            encoded. Note that it's all or nothing, not per-key.
          '';
        };

        extraScript = mkOption {
          type = with types; nullOr lines;
          default = "";
          example = literalExample ''
            envsubst < infile > $secretspath/outfile
          '';
          description = ''
            Extra script to run in the secret unit context
          '';
        };

        services = mkOption {
          default = [ name ];
          type = with types; listOf str;
          description = ''
            Systemd services that depend on this secret. Defaults to the
            attribute name.

            If set to empty, the unit will run on its own, rather than as a
            dependency of another unit. Useful for secrets that dont have a
            specific dependent unit.
          '';
        };

        user = mkOption {
          type = with types; nullOr str;
          default = null;
          example = "gitlab-runner";
          description = ''
            User that should own the secrets files. Defaults to root.
          '';
        };

        __toString = mkOption {
          default = _: "${cfg.outPathPrefix}/${name}";
          readOnly = true;
        };
      };
    }
  ));
in
{
  options = {
    vault-secrets = {
      vaultPathPrefix = mkOption {
        type = with types; str;
        default = "kv";
        description = ''
          Base Vault KV path to prepend to all KV paths, including the mount point.
        '';
      };

      vaultAddress = mkOption {
        type = with types; str;
        default = "https://127.0.0.1:8200";
        description = ''
          The address of the Vault server, passed via <literal>VAULT_ADDR</literal> environment variable.
      '';
      };

      namespace = mkOption {
        type = with types; str;
        default = "services";
        description = ''
          Base Vault KV path to prepend to all KV paths, under
          <literal>vaultPathPrefix</literal>. Default for all secrets defined in
          the module.
        '';
      };

      approlePrefix = mkOption {
        type = with types; nullOr str;
        default = null;
        description = ''
          Prepended to the secret name for resolving the default environmentFile path.
        '';
      };

      outPathPrefix = mkOption {
        type = with types; str;
        default = "/run/secrets";
        description = ''
          Base path to output secrets. The path will be created, owned by root, and chmod 700.

          Should probably be on tmpfs to avoid leaking secrets.
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
        secretsPath = "${cfg.outPathPrefix}/${name}";
      in nameValuePair "${name}-secrets" {
        path = with pkgs; [ getent jq vault-bin ];

        partOf = map (n: "${name}.service") services;
        wantedBy = optional (services == [])  "multi-user.target" ;

        # network is needed to access the vault server
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        environment.VAULT_ADDR = cfg.vaultAddress;

        script = ''
          set -euo pipefail

          mkdir -pm 0755 "${cfg.outPathPrefix}"

          # Because the path might already exist, fix mode
          chmod 0755 "${cfg.outPathPrefix}"

          # Make sure we start from a clean slate
          rm -rf "${secretsPath}"
          mkdir -p "${secretsPath}"

          vaultOutput="$(vault write -format=json auth/approle/login role_id="$VAULT_ROLE_ID" secret_id=- <<< "$VAULT_SECRET_ID")"
          jq '.auth.client_token = "redacted"' <<< "$vaultOutput"

          VAULT_TOKEN="$(jq -r '.auth.client_token' <<< "$vaultOutput")"
          export VAULT_TOKEN
        '' + optionalString (secretsKey != null) ''
          json_dump="$(vault kv get -format=json "${cfg.vaultPathPrefix}/${namespace}/${name}/${secretsKey}" || true)"
          if [[ -n "$json_dump" ]]; then
        '' + (if secretsBase64 then ''
              dumpsecrets="$(jq -r 'select(.data.data != null) | .data.data | to_entries[] | "base64 -d <<< \"\(.value)\" > ${secretsPath}/\(.key)"' <<< "$json_dump")"
        '' else ''
              dumpsecrets="$(jq -r 'select(.data.data != null) | .data.data | to_entries[] | "builtin printf \"%s\\n\" \"\(.value)\" > ${secretsPath}/\(.key)"' <<< "$json_dump")"
        '') + optionalString (secretsKey != null) ''
              echo "Found secrets at ${cfg.vaultPathPrefix}/${namespace}/${name}/secrets (''${#dumpsecrets} bytes)" >&2
              eval "$dumpsecrets"
          fi
        '' + optionalString (environmentKey != null) ''
          json_dump="$(vault kv get -format=json "${cfg.vaultPathPrefix}/${namespace}/${name}/${environmentKey}" || true)"
          if [[ -n "$json_dump" ]]; then
              jq -r '.data.data | to_entries[] | "${optionalString (environmentPrefix != null) "${toUpper environmentPrefix}_"}\(.key)=\"\(.value)\""' <<< "$json_dump" > "${secretsPath}/environment"
              echo "Dumped environment file at ${secretsPath}/environment" >&2
          fi
        '' + ''
          secretsPath="${secretsPath}"
          ${extraScript}
        '' + optionalString (user != null) ''
          chown -R "${user}:nobody" "${secretsPath}"
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
