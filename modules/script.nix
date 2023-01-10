{lib, cfg, scfg, name}:
let
  inherit (scfg)
    environmentKey quoteEnvironmentValues
    environmentVariableNamePrefix extraScript
    user group secretsKey secretsAreBase64;
  inherit (lib) optionalString toUpper;

  secretsPath = "${cfg.outPrefix}/${name}";
in
(''
  set -euo pipefail

  # Ensure the base path exists and has the correct permissions
  mkdir -p "${cfg.outPrefix}"
  chmod 0755 "${cfg.outPrefix}"

  # Make sure we start from a clean slate
  rm -rf "${secretsPath}"
  mkdir -p "${secretsPath}"

  # Log into Vault using credentials from environmentFile
  vaultOutput="$(vault write -format=json auth/approle/login role_id="$VAULT_ROLE_ID" secret_id=- <<< "$VAULT_SECRET_ID")"
  jq '.auth.client_token = "redacted"' <<< "$vaultOutput"
  VAULT_TOKEN="$(jq -r '.auth.client_token' <<< "$vaultOutput")"
  export VAULT_TOKEN

'' + optionalString (secretsKey != null) ''
  json_dump="$(vault kv get -format=json "${cfg.vaultPrefix}/${name}/${secretsKey}" || true)"
  if [[ -n "$json_dump" ]]; then
    echo "Found secrets at ${cfg.vaultPrefix}/${name}/${secretsKey}" >&2
    # call a python script which saves secrets to files in `secretsPath` directory
    ${../scripts/write_secrets.py} ${optionalString secretsAreBase64 "--base64"} ${lib.escapeShellArg secretsPath} <<< "$json_dump"
  fi

'' + optionalString (environmentKey != null) ''
  json_dump="$(vault kv get -format=json "${cfg.vaultPrefix}/${name}/${environmentKey}" || true)"
  if [[ -n "$json_dump" ]]; then
'' + (if quoteEnvironmentValues then ''
      jq -r '.data.data | to_entries[] | "${optionalString (environmentVariableNamePrefix != null) "${toUpper environmentVariableNamePrefix}_"}\(.key)=\"\(.value)\""' <<< "$json_dump" > "${secretsPath}/environment"
'' else ''
      jq -r '.data.data | to_entries[] | "${optionalString (environmentVariableNamePrefix != null) "${toUpper environmentVariableNamePrefix}_"}\(.key)=\(.value)"' <<< "$json_dump" > "${secretsPath}/environment"
'') + ''
      echo "Dumped environment file at ${secretsPath}/environment" >&2
  fi

'' + optionalString (extraScript != "") ''
  secretsPath="${secretsPath}"
  source <(jq -r '.data.data | to_entries[] | "export ${optionalString (environmentVariableNamePrefix != null) "${toUpper environmentVariableNamePrefix}_"}\(.key)=\"\(.value)\""' <<< "$json_dump")
  echo "Running extra script..."
  ${extraScript}
  echo "Extra script done."

'' + ''
  chown -R "${user}:${group}" "${secretsPath}"
'')
