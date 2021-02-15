{ nixosPath, self, ... }@args:

(import "${nixosPath}/tests/make-test-python.nix" ({ pkgs, ... }: rec {
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

    client = { pkgs, ... }: {
      imports = [ self.nixosModules.vault-secrets ];

      environment.systemPackages = [ pkgs.vault pkgs.jq ];
      environment.variables.VAULT_ADDR = "http://server:8200";

      # FIXME: How to provision testing approle credentials?
      vault-secrets = {
        vaultAddress = "http://server:8200";
        secrets.test = { services = [ ]; };
      };
    };
  };

  # API: https://github.com/NixOS/nixpkgs/blob/master/nixos/lib/test-driver/test-driver.py
  testScript = let
    sshToServer =
      "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i privkey.snakeoil server";

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

    server.succeed(
        "VAULT_ADDR=http://server:8200 VAULT_TOKEN=root vault auth enable approle"
    )

    server.succeed(
        "VAULT_ADDR=http://server:8200 VAULT_TOKEN=root vault secrets enable -version=2 kv"
    )

    client.succeed(
        "yes y | VAULT_TOKEN=root ${
          self.legacyPackages.${pkgs.system}.vault-push-approles fakeFlake
        }/bin/vault-push-approles"
    )

    client.succeed(
        "mkdir -p /root/vault-secrets.env.d; VAULT_TOKEN=root VAULD_ADDR=http://server:8200 ${../../scripts/vault-get-approle-env.sh} test > /root/vault-secrets.env.d/test"
    )

    client.succeed("systemctl restart test-secrets")

    client.wait_for_unit("test-secrets")

    client.succeed("VAULT_TOKEN=root vault secrets list")
  '';
})) args
