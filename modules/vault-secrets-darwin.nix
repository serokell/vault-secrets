# SPDX-FileCopyrightText: 2020 Serokell <https://serokell.io/>
#
# SPDX-License-Identifier: MPL-2.0

{ config, lib, pkgs, ... }:
let
  cfg = config.vault-secrets;
  inherit (cfg) flip mapAttrs' mkMerge nameValuePair;
in
{
  options = import ./options.nix { inherit lib cfg; };

  config = {
    launchd.daemons = mkMerge [(flip mapAttrs' cfg.secrets (
      name: scfg: nameValuePair "${name}-secrets" {
        path = with pkgs; [ getent jq vault-bin python3 ];
        environment.VAULT_ADDR = cfg.vaultAddress;

        script = ''
          source ${scfg.environmentFile}
        '' + import ./script.nix { inherit lib cfg scfg name; };

        serviceConfig = {
          KeepAlive = true;
          Umask = "0077";
        };
      }
    ))];
  };
}
