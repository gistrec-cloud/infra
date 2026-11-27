#!/usr/bin/env bash
# Creates the "Agent Access" vault and a read-only service account for it.
# The token never reaches stdout: it goes to a 1Password item in Personal
# (backup) and to the macOS Keychain item "op-agent-access" (used by omp/Claude).
set -euo pipefail

VAULT="Agent Access"
SA="agent-access-ro"
KEYCHAIN_SERVICE="op-agent-access"

if op vault get "$VAULT" >/dev/null 2>&1; then
	echo "vault exists: $VAULT"
else
	op vault create "$VAULT" >/dev/null
	echo "vault created: $VAULT"
fi

TOKEN="$(op service-account create "$SA" --vault "$VAULT:read_items" --raw)"
trap 'unset TOKEN' EXIT
echo "service account created: $SA (read_items on $VAULT)"

jq -n --arg t "$TOKEN" --arg title "1Password service account $SA" \
	'{title: $title, category: "API_CREDENTIAL", fields: [{id: "credential", type: "CONCEALED", label: "credential", value: $t}]}' |
	op item create --vault Personal >/dev/null
echo "token backup saved: Personal / 1Password service account $SA"

security add-generic-password -U -a "$USER" -s "$KEYCHAIN_SERVICE" -l "1Password service account $SA" -w "$TOKEN"
echo "token saved to Keychain: $KEYCHAIN_SERVICE"

OP_SERVICE_ACCOUNT_TOKEN="$TOKEN" op user get --me --format json | jq -r '"token check: type=\(.type) name=\(.name)"'
