#!/usr/bin/env bash

set -euo pipefail

# Make sure we have $1 and that the role exists
vault read "auth/approle/role/$1" >/dev/null

# Read the RoleID and generate a new SecretID
role_id="$(vault read -format=json auth/approle/role/"$1"/role-id | jq -r '.data.role_id')"
secret_id="$(vault write -f -format=json auth/approle/role/"$1"/secret-id | jq -r '.data.secret_id')"

cat <<-EOF
VAULT_ROLE_ID=$role_id
VAULT_SECRET_ID=$secret_id
EOF
