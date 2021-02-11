#!/usr/bin/env bash

set -euo pipefail

# set -x

# Make sure we are logged into Vault
token_data="$(vault token lookup -format=json)"
vault_token_never_expire="$(jq '.data.expire_time == null' <<< "$token_data")"
vault_token_ttl="$(jq '.data.ttl' <<< "$token_data")"
if [[ $vault_token_never_expire == false && $vault_token_ttl -le 0 ]]; then
    echo 'Vault token expired or invalid. Please log into vault first.'
    exit 1
fi

# Make sure we have $1 and that the role exists
vault read "auth/approle/role/$1" >/dev/null

# Read the RoleID and generate a new SecretID
role_id="$(vault read -format=json auth/approle/role/"$1"/role-id | jq -r '.data.role_id')"
secret_id="$(vault write -f -format=json auth/approle/role/"$1"/secret-id | jq -r '.data.secret_id')"

cat <<-EOF
VAULT_ROLE_ID=$role_id
VAULT_SECRET_ID=$secret_id
EOF
