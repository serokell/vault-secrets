{ nixosPath, ... }@args:

(import "${nixosPath}/tests/make-test-python.nix" ({ pkgs, ... }: {
  name = "vault-secrets";
  nodes = {
    server = { pkgs, ... }: {
      # An unsealed dummy vault
      networking.firewall.allowedTCPPorts = [ 8200 ];
      systemd.services.dummy-vault = {
        wantedBy = ["multi-user.target"];
        path = with pkgs; [ getent ];
        serviceConfig = {
          ExecStart = "${pkgs.vault}/bin/vault server -dev -dev-root-token-id='root' -dev-listen-address='0.0.0.0:8200'";
        };
      };
    };

    client = { pkgs, ... }: {
      environment.systemPackages = [ pkgs.vault ];
      environment.variables.VAULT_ADDR = "http://server:8200";
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

    client.succeed("VAULT_TOKEN=root vault secrets list")
  '';
})) args
