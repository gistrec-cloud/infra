#!/bin/sh
# certbot manual-cleanup-hook: drop ALL TXT records at the challenge name.
# The apex and wildcard validations share one name, so certbot calls this
# twice — the second call finds nothing and must not fail the renewal
# (hence: best-effort, always exit 0).
set -u
. /etc/letsencrypt/porkbun.ini

zone=$(printf '%s' "$CERTBOT_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
rest=${CERTBOT_DOMAIN%."$zone"}
if [ "$rest" = "$CERTBOT_DOMAIN" ] || [ -z "$rest" ]; then
    name="_acme-challenge"
else
    name="_acme-challenge.$rest"
fi

curl -sS -X POST "https://api.porkbun.com/api/json/v3/dns/deleteByNameType/$zone/TXT/$name" \
    -H 'Content-Type: application/json' \
    -d "{\"apikey\":\"$PORKBUN_API_KEY\",\"secretapikey\":\"$PORKBUN_SECRET_API_KEY\"}" \
    >/dev/null 2>&1 || true
exit 0
