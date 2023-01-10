# SPDX-FileCopyrightText: 2020 Serokell <https://serokell.io/>
#
# SPDX-License-Identifier: MPL-2.0

{ config, lib, pkgs, ... }:
let
  cfg = config.vault-secrets;
  inherit (lib) mkMerge flip mapAttrs' nameValuePair optional;
in
{
  options = import ./options.nix { inherit lib cfg; };

  config = {
    systemd.services = mkMerge ([(flip mapAttrs' cfg.secrets (
      name: scfg: nameValuePair "${name}-secrets" {
        path = with pkgs; [ getent jq vault-bin python3 ];

        partOf = map (n: "${name}.service") scfg.services;
        wantedBy = optional (scfg.services == []) "multi-user.target" ;

        # network is needed to access the vault server
        requires = [ "network-online.target" ];
        after = [ "network-online.target" ];

        environment.VAULT_ADDR = cfg.vaultAddress;

        script = import ./script.nix { inherit cfg scfg lib name; };

        serviceConfig = {
          EnvironmentFile = scfg.environmentFile;
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
