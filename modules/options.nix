{lib, cfg, pkgs, ...}:
let
  inherit (lib) types mkOption;
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
          default = let
            rootDir = if builtins.match ".*-darwin" pkgs.stdenv.hostPlatform.system != null then "/var/root" else "/root";
            fileName = if cfg.approlePrefix != null then "${cfg.approlePrefix}-${name}" else "${name}";
          in "${rootDir}/vault-secrets.env.d/${fileName}";
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

        loginRetries = mkOption {
          type = with types; int;
          default = 5;
          description = ''
            Number of attempts script will try to login into Vault.
            This may be useful in case secrets service is restarted when internet
            connection is not yet available. Sadly After=network-online.target
            doesn't always guarantee that.
          '';
        };

        __toString = mkOption {
          default = _: "${cfg.outPrefix}/${name}";
          readOnly = true;
        };
      };
    }
  ));
in {
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
  }
