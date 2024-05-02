{ nixosPath, self, ... }@args:

(import "${nixosPath}/tests/make-test-python.nix" ({ pkgs, ... }:
  let
    ssh-keys = import "${self.inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
    vault-port = 8200;
    vault-address = "http://server:${toString vault-port}";
  in rec {
    name = "vault-secrets";
    nodes = {
      server = { pkgs, ... }:
        let
          serverArgs =
            "-dev -dev-root-token-id='root' -dev-listen-address='0.0.0.0:${toString vault-port}'";
        in {
          # An unsealed dummy vault
          networking.firewall.allowedTCPPorts = [ vault-port ];
          systemd.services.dummy-vault = {
            wantedBy = [ "multi-user.target" ];
            path = with pkgs; [ getent vault ];
            script = "vault server ${serverArgs}";
          };
        };

      client = { pkgs, config, ... }: {
        imports = [ self.nixosModules.vault-secrets ];

        systemd.services.test = {
          script = ''
            ls '${config.vault-secrets.secrets.test}'
            cat '${config.vault-secrets.secrets.test}/test_file' | grep 'Test file contents!'
            cat '${config.vault-secrets.secrets.test}/check_escaping' | grep "\"'\`"
            env
            echo $HELLO | grep 'Hello, World'
          '';
          wantedBy = [ "multi-user.target" ];
          serviceConfig.EnvironmentFile =
            "${config.vault-secrets.secrets.test}/environment";
          serviceConfig.Type = "oneshot";
          serviceConfig.RemainAfterExit = "yes";
        };

        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "yes";
        };

        users.users.root = {
          password = "";
          openssh.authorizedKeys.keys = [ ssh-keys.snakeOilPublicKey ];
        };

        vault-secrets = {
          vaultAddress = vault-address;
          secrets.test = { };
        };

        networking.hostName = "client";
      };

      supervisor = { pkgs, ... }: {
        environment.systemPackages = [ pkgs.vault ];
      };
    };

    # API: https://github.com/NixOS/nixpkgs/blob/master/nixos/lib/test-driver/test-driver.py
    testScript = let
      # A set of flake outputs mimicking what one would find in an actual flake defining a NixOS system
      fakeFlake = {
        nixosConfigurations.client = self.inputs.nixpkgs.lib.nixosSystem {
          modules = [ nodes.client ];
          inherit (pkgs) system;
        };
      };

      inherit (self.legacyPackages.${pkgs.system})
        vault-push-approles vault-push-approle-envs;

      supervisor-setup = pkgs.writeShellScript "supervisor-setup" ''
        set -euo pipefail

        set -x

        VAULT_ADDR="${vault-address}"
        VAULT_TOKEN=root

        export VAULT_ADDR VAULT_TOKEN

        # Set up Vault
        vault auth enable approle
        vault secrets enable -version=2 kv

        # Put secrets for the test unit into Vault
        vault kv put kv/test/environment HELLO='Hello, World'
        vault kv put kv/test/secrets \
          test_file='Test file contents!' \
          check_escaping="\"'\`"

        # Set up SSH hostkey to connect to the client
        cat ${ssh-keys.snakeOilPrivateKey} > privkey.snakeoil
        chmod 600 privkey.snakeoil
        SSH_OPTS='-o StrictHostKeyChecking=no -i privkey.snakeoil'
        export SSH_OPTS

        # Unset VAULT_ADDR and PATH to make sure those are set correctly in the scripts
        # We keep VAULT_TOKEN set because it's actually used to authenticate to vault
        VAULD_ADDR=
        PATH=
        export VAULT_ADDR PATH

        # Push approles to vault
        ${vault-push-approles fakeFlake}/bin/vault-push-approles test

        # Upload approle environments to the client
        ${vault-push-approle-envs fakeFlake}/bin/vault-push-approle-envs
      '';
    in ''
      start_all()

      server.wait_for_unit("multi-user.target")
      server.wait_for_unit("dummy-vault")
      server.wait_for_open_port(8200)

      supervisor.succeed("${supervisor-setup}")

      client.succeed("systemctl restart test")

      client.wait_for_unit("test-secrets")

      client.succeed("systemctl status test")
    '';
  })) args
