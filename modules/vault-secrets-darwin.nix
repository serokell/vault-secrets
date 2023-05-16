# SPDX-FileCopyrightText: 2020 Serokell <https://serokell.io/>
#
# SPDX-License-Identifier: MPL-2.0

{ config, lib, pkgs, ... }:
let
  cfg = config.vault-secrets;
  inherit (lib) flip mapAttrs' mkMerge nameValuePair;
in
{
  options = import ./options.nix { inherit lib cfg pkgs; };

  config = {
    launchd.daemons = mkMerge ([(flip mapAttrs' cfg.secrets (
      name: scfg: nameValuePair "${name}-secrets" {
        path = with pkgs; [ getent jq vault-bin python3 coreutils bash ];
        environment.VAULT_ADDR = cfg.vaultAddress;
        # Needed to store vault token
        environment.HOME = "/var/root";

        script = ''
          if [[ ! -f ${scfg.environmentFile} ]]; then
            echo "Environment file with approle credentials doesn't exist"
            exit 1
          fi
          source ${scfg.environmentFile}
        '' + import ./script.nix { inherit lib cfg scfg name; } + ''
          # File to signal the restart for the daemon that uses fetched secrets
          touch "${cfg.outPrefix}/${name}-fetched"
        '';

        serviceConfig = {
          ProcessType = "Interactive";
          ThrottleInterval = 30;

          KeepAlive.SuccessfulExit = false;
          KeepAlive.PathState."${scfg.environmentFile}" = true;
          # This is actually 0077, but
          # property lists do not support encoding integers in octal
          Umask = 63;
          WatchPaths = [
            "${scfg.environmentFile}"
            "/etc/resolv.conf"
            "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist"
          ];
          # Keep a way to read logs, launchd doesn't accumulate stdout/stderr itself
          StandardErrorPath = "/var/log/vault-secrets/${name}-secrets-err.log";
          StandardOutPath = "/var/log/vault-secrets/${name}-secrets-out.log";
        };
      }
    ))] ++ (flip lib.mapAttrsToList cfg.secrets (
      name: scfg: with scfg;
      # Trigger restart for daemon that uses secrets provided by the secrets daemon
      lib.genAttrs services (services: rec {
        serviceConfig.WatchPaths = [ "${cfg.outPrefix}/${name}-fetched" ];
      })))
    );
  };
}
