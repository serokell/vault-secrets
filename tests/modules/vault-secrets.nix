{ nixosPath, self, ... }@args:

(import "${nixosPath}/tests/make-test-python.nix" ({ pkgs, ... }: {
  name = "vault-secrets";
  nodes = {
    server = { pkgs, ... }:
    let
      serverArgs = "-dev -dev-root-token-id='root' -dev-listen-address='0.0.0.0:8200'";
    in {
      # An unsealed dummy vault
      networking.firewall.allowedTCPPorts = [ 8200 ];
      systemd.services.dummy-vault = {
        wantedBy = ["multi-user.target"];
        path = with pkgs; [ getent ];
        serviceConfig.ExecStart = "${pkgs.vault}/bin/vault server ${serverArgs}";
      };
    };

    client = { pkgs, ... }: {
      imports = [ self.nixosModules.vault-secrets ];

      environment.systemPackages = [ pkgs.vault ];
      environment.variables.VAULT_ADDR = "http://server:8200";

      vault-secrets = {
        vaultAddress = "http://server:8200";
        secrets.test = {
          services = [];
        };
      };
    };
  };

  # API: https://github.com/NixOS/nixpkgs/blob/master/nixos/lib/test-driver/test-driver.py
  testScript = let
    sshToServer = "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i privkey.snakeoil server";
  in ''
    start_all()

    server.wait_for_unit("multi-user.target")
    server.wait_for_unit("dummy-vault")
    server.wait_for_open_port(8200)

    client.wait_for_unit("test-secrets")
    client.succeed("VAULT_TOKEN=root vault secrets list")
  '';
})) args
