#!/bin/sh
# certbot manual-auth-hook: publish the DNS-01 TXT record via the Porkbun API,
# then wait until an authoritative NS actually serves it (LE validates against
# the authoritative set; Porkbun has no propagation flag like the CF plugin).
# Keys: /etc/letsencrypt/porkbun.ini (tls role). Zone = last two labels of
# CERTBOT_DOMAIN — fine for our TLDs, revisit before any co.uk-style zone.
set -eu
. /etc/letsencrypt/porkbun.ini

zone=$(printf '%s' "$CERTBOT_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
rest=${CERTBOT_DOMAIN%."$zone"}
if [ "$rest" = "$CERTBOT_DOMAIN" ] || [ -z "$rest" ]; then
    name="_acme-challenge"
else
    name="_acme-challenge.$rest"
fi

out=$(curl -fsS -X POST "https://api.porkbun.com/api/json/v3/dns/create/$zone" \
    -H 'Content-Type: application/json' \
    -d "{\"apikey\":\"$PORKBUN_API_KEY\",\"secretapikey\":\"$PORKBUN_SECRET_API_KEY\",\"name\":\"$name\",\"type\":\"TXT\",\"content\":\"$CERTBOT_VALIDATION\",\"ttl\":\"600\"}")
case $out in
    *'"status":"SUCCESS"'*) ;;
    *) echo "porkbun dns/create failed: $out" >&2; exit 1 ;;
esac

ns=$(dig +short NS "$zone" | head -n1)
i=0
while [ "$i" -lt 30 ]; do
    if dig +short TXT "_acme-challenge.$CERTBOT_DOMAIN" @"$ns" | grep -qF "$CERTBOT_VALIDATION"; then
        exit 0
    fi
    i=$((i + 1))
    sleep 10
done
echo "TXT _acme-challenge.$CERTBOT_DOMAIN not visible on $ns after 300s" >&2
exit 1
