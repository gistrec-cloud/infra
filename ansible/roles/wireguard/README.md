# wireguard

Private WireGuard mesh between fleet hosts. Every node gets a stable private IP
on `wg0` (10.10.0.0/24 by convention) so services talk over an encrypted tunnel
instead of the public internet. Built primarily so **MySQL replication**
(primary → replica) rides the tunnel — live since 2026-08-19, when russia-03
became the replica.

Everything else RF↔EU followed: the apps on russia-03 dial `primary.mysql`,
`primary.clickhouse` (9440) and the shared `tg-bot-api` (8081) by name over wg0
(all three A records point at 10.10.0.4), and netdata cross-probes peers'
`/health` + pings the wg IPs. Netdata's own metric streaming rides the tunnel
too since 2026-09-19 — `stream.conf` carries no TLS and authenticates with a
single API key, so every child now streams to the parent's wg IP and no public
source is allowed on 19999. Gating is mixed: 8081 is open only to
russia-03's wg IP, while MySQL and ClickHouse publish 3306 / 9440 / 8443 on
0.0.0.0, guarded by auth + their LE certs (`*.mysql.gistrec.cloud`,
`*.clickhouse.gistrec.cloud`) — exactly as the managed Yandex cluster was until
it was destroyed 2026-07-21.

## Topology

Full mesh: each host peers with every OTHER inventory host that defines
`wireguard_ip` in its host_vars. There is no `wireguard` inventory group —
membership is derived from that variable alone. A peer's public endpoint is its
inventory `ansible_host`; its tunnel IP and public key live in its (gitignored)
host_vars.

| host       | wireguard_ip | interface  |
|------------|--------------|------------|
| germany-02 | 10.10.0.2    | `wg-fleet` |
| russia-03  | 10.10.0.3    | `wg0`      |
| finland-01 | 10.10.0.4    | `wg0`      |

(10.10.0.1 is free — it was russia-01, destroyed 2026-08-19. 10.10.0.3 was
germany-01's until it was retired 2026-07-20; russia-03 took the address at its
onboarding, 2026-08-18. germany-02 joined 2026-09-19 and reused 10.10.0.2 from
the retired russia-02.)

**The interface name is per host, and peers never reference it** — only
`wireguard_ip`, `wireguard_pubkey` and `ansible_host` cross the boundary. That
is what lets germany-02 run `wg-fleet`: it is a shared machine whose other
tenant already holds `wg0`…`wg19` as userspace TUN devices (the kernel does not
see them as WireGuard, but the names are taken all the same). Deploying the
`wg0` default there would have landed on top of them.

That host also gets **no inbound 51820 rule** — its firewall is not ours to
manage. `PersistentKeepalive` keeps conntrack warm, so the tunnel is dialled
from its side and replies arrive as ESTABLISHED.

## One-time key generation (per host)

```bash
wg genkey | tee /tmp/wg.priv | wg pubkey        # prints the PUBLIC key
cat /tmp/wg.priv                                # the PRIVATE key
```

- Put the **public** key in that host's `host_vars/<host>.yml` as `wireguard_pubkey`.
- Put the **private** key in the vault as `vault_wg_privkey_<host>` (dashes →
  underscores, e.g. `vault_wg_privkey_russia_03`).
- Set `wireguard_ip` in the host's host_vars.

## Firewall

WireGuard listens on UDP `51820`. On hosts with `firewall_managed: true`, open it
to the mesh peers via `firewall_allow_udp` (see the `firewall` role) — live
host_vars name the peer through `hostvars`, never a literal IP:

```yaml
firewall_allow_udp:
  - { port: 51820, from: "{{ hostvars['finland-01'].ansible_host }}" }
```

On a host with no managed firewall there is no rule for us to add — its own
firewall decides. That is germany-02's case: it joined the mesh 2026-09-19 but
keeps `firewall_managed: false`, and no inbound 51820 rule was added to its ufw.
`PersistentKeepalive` makes it dial out, so replies arrive as ESTABLISHED.

## Verify

```bash
wg show                       # handshakes + transfer per peer
ping -c1 10.10.0.4            # from russia-03 — reach finland-01 over the tunnel
ping -c1 10.10.0.3            # from finland-01 — reach russia-03
```
