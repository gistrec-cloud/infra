# wireguard

Private WireGuard mesh between fleet hosts. Every node gets a stable private IP
on `wg0` (10.10.0.0/24 by convention) so services talk over an encrypted tunnel
instead of the public internet. Built primarily so **MySQL replication**
(primary → replica) rides the tunnel — live since 2026-08-19, when russia-03
became the replica.

Everything else RF↔EU followed: the apps on russia-03 dial `primary.mysql`,
`primary.clickhouse` (9440) and the shared `tg-bot-api` (8081) by name over wg0
(all three A records point at 10.10.0.4), and netdata cross-probes peers'
`/health` + pings the wg IPs. Netdata's own metric streaming does not — it goes
to the parent's public IP, as does everything germany-02 does (no
`wireguard_ip`, not a mesh member). Gating is mixed: 8081 is open only to
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

| host       | wireguard_ip |
|------------|--------------|
| russia-03  | 10.10.0.3    |
| finland-01 | 10.10.0.4    |

(Two nodes today, so each has exactly one peer. 10.10.0.1 was russia-01,
destroyed 2026-08-19; 10.10.0.2 was russia-02, retired 2026-07-21 — both free
for reuse. 10.10.0.3 was germany-01's until it was retired 2026-07-20;
russia-03 took the address at its onboarding, 2026-08-18.)

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
firewall decides. Moot today: both mesh members are managed, and the only
unmanaged host (germany-02) is not in the mesh.

## Verify

```bash
wg show                       # handshakes + transfer per peer
ping -c1 10.10.0.4            # from russia-03 — reach finland-01 over the tunnel
ping -c1 10.10.0.3            # from finland-01 — reach russia-03
```
