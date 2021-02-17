#!/usr/bin/env bash

set -euo pipefail

token_data="$(vault token lookup -format=json)"
vault_token_never_expire="$(jq '.data.expire_time == null' <<< "$token_data")"
vault_token_ttl="$(jq '.data.ttl' <<< "$token_data")"
if [[ $vault_token_never_expire == false && $vault_token_ttl -le 0 ]]; then
    echo 'Vault token expired or invalid. Please log into vault first.'
    exit 1
fi
