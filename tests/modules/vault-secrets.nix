{ nixosPath, self, ... }@args:

(import "${nixosPath}/tests/make-test-python.nix" ({ pkgs, ... }:
  let ssh-keys = import "${self.inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs;
  in rec {
    name = "vault-secrets";
    nodes = {
      server = { pkgs, ... }:
        let
          serverArgs =
            "-dev -dev-root-token-id='root' -dev-listen-address='0.0.0.0:8200'";
        in {
          environment.systemPackages = [ pkgs.vault ];
          # An unsealed dummy vault
          networking.firewall.allowedTCPPorts = [ 8200 ];
          systemd.services.dummy-vault = {
            wantedBy = [ "multi-user.target" ];
            path = with pkgs; [ getent ];
            serviceConfig.ExecStart =
              "${pkgs.vault}/bin/vault server ${serverArgs}";
          };
        };

      client = { pkgs, config, ... }: {
        imports = [ self.nixosModules.vault-secrets ];

        systemd.services.test = {
          script = ''
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
          permitRootLogin = "yes";
        };

        users.users.root = {
          password = "";
          openssh.authorizedKeys.keys = [ ssh-keys.snakeOilPublicKey ];
        };

        vault-secrets = {
          vaultAddress = "http://server:8200";
          secrets.test = { };
        };

        networking.hostName = "client";
      };

      supervisor = { pkgs, ... }: {
        environment.variables.VAULT_ADDR = "http://server:8200";
        environment.variables.VAULT_TOKEN = "root";
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
    in ''
      start_all()

      server.wait_for_unit("multi-user.target")
      server.wait_for_unit("dummy-vault")
      server.wait_for_open_port(8200)

      supervisor.succeed("vault auth enable approle")

      supervisor.succeed("vault secrets enable -version=2 kv")

      supervisor.succeed("vault kv put kv/test/environment HELLO='Hello, World'")

      # Unset VAULT_ADDR and PATH to make sure those are set correctly in the script
      # We keep VAULT_TOKEN set because it's actually used to authenticate to vault
      supervisor.succeed(
          "VAULT_ADDR= PATH= ${
            self.legacyPackages.${pkgs.system}.vault-push-approles fakeFlake
          }/bin/vault-push-approles test"
      )

      supervisor.succeed(
          "cat ${ssh-keys.snakeOilPrivateKey} > privkey.snakeoil"
      )
      supervisor.succeed("chmod 600 privkey.snakeoil")

      supervisor.succeed(
          "VAULD_ADDR= PATH= SSH_OPTS='-o StrictHostKeyChecking=no -i privkey.snakeoil' ${
            self.legacyPackages.${pkgs.system}.vault-push-approle-envs fakeFlake
          }/bin/vault-push-approle-envs"
      )

      client.succeed("systemctl restart test")

      client.wait_for_unit("test-secrets")

      client.succeed("systemctl status test")
    '';
  })) args
