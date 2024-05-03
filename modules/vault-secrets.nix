# SPDX-FileCopyrightText: 2020-2023 Serokell <https://serokell.io/>
#
# SPDX-License-Identifier: MPL-2.0

{ config, lib, pkgs, ... }:
let
  cfg = config.vault-secrets;
  inherit (lib) mkMerge mkDefault flip mapAttrs' nameValuePair optional;
in
{
  options = import ./options.nix { inherit lib cfg pkgs; };

  config = {
    systemd.services = mkMerge ([(flip mapAttrs' cfg.secrets (
      name: scfg: nameValuePair "${name}-secrets" {
        path = with pkgs; [ coreutils getent jq vault ];

        partOf = map (n: "${n}.service") scfg.services;
        wantedBy = optional (scfg.services == []) "multi-user.target" ;

        # network is needed to access the vault server
        requires = [ "network-online.target" ];
        after = [ "network-online.target" ];

        environment.VAULT_ADDR = cfg.vaultAddress;

        script = import ./script.nix { inherit cfg scfg lib name; };

        startLimitBurst = mkDefault 5;
        startLimitIntervalSec = mkDefault 300;

        serviceConfig = {
          EnvironmentFile = scfg.environmentFile;
          RemainAfterExit = true;
          Type = "oneshot";
          UMask = "0077";
          Restart = mkDefault "on-failure";
          RestartSec = mkDefault 10;
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
