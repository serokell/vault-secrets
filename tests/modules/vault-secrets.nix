{ nixosPath, ... }@args:

(import "${nixosPath}/tests/make-test-python.nix" ({ pkgs, ... }: {
  name = "vault-secrets";
  nodes = {
    vault = { pkgs, lib, ... }: {
      environment.systemPackages = [ pkgs.vault ];
      environment.variables.VAULT_ADDR = "http://127.0.0.1:8200";

      networking.firewall.allowedTCPPorts = [ 8200 ];

      # An unsealed dummy vault
      systemd.services.vault = {
        wantedBy = ["multi-user.target"];
        after = [ "network.target" ];
        path = with pkgs; [ getent ];
        environment.HOME = "/var/lib/vault";
        serviceConfig = {
          ExecStart = lib.mkForce "${pkgs.vault}/bin/vault server -dev";
          StateDirectory = "vault";
          WorkingDirectory = "/var/lib/vault";
        };
      };
    };

    client = { pkgs, ... }: {
      environment.systemPackages = [ pkgs.vault ];
      environment.variables.VAULT_ADDR = "http://vault:8200";
    };
  };

  # API: https://github.com/NixOS/nixpkgs/blob/master/nixos/lib/test-driver/test-driver.py
  testScript = ''
    start_all()

    vault.wait_for_unit("multi-user.target")
    vault.wait_for_unit("vault.service")
    vault.wait_for_open_port(8200)
    vault.succeed("vault status | grep Sealed | grep false")

    client.succeed("export VAULT_TOKEN=$(ssh vault 'cat /var/lib/vault/.vault-token)'")
    client.succeed("vault secrets list")
  '';
})) args
