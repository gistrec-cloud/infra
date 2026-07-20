# wireguard

Private WireGuard mesh between fleet hosts. Every node gets a stable private IP
on `wg0` (10.10.0.0/24 by convention) so services talk over an encrypted tunnel
instead of the public internet. Built primarily so **MySQL replication**
(primary → replica) rides the tunnel — no MySQL TLS certificates, no public
3306 exposure — its live use today is netdata streaming (russia-02/finland-01 →
russia-01) + ClickHouse.

## Topology

Full mesh: each host peers with every OTHER host in the `wireguard` inventory
group. A peer's public endpoint is its inventory `ansible_host`; its tunnel IP
and public key live in its (gitignored) host_vars.

| host       | wireguard_ip |
|------------|--------------|
| russia-01  | 10.10.0.1    |
| russia-02  | 10.10.0.2    |
| finland-01 | 10.10.0.4    |

(10.10.0.3 was germany-01, retired 2026-07-20 — free for reuse.)

## One-time key generation (per host)

```bash
wg genkey | tee /tmp/wg.priv | wg pubkey        # prints the PUBLIC key
cat /tmp/wg.priv                                # the PRIVATE key
```

- Put the **public** key in that host's `host_vars/<host>.yml` as `wireguard_pubkey`.
- Put the **private** key in the vault as `vault_wg_privkey_<host>` (dashes →
  underscores, e.g. `vault_wg_privkey_russia_01`).
- Set `wireguard_ip` in the host's host_vars.

## Firewall

WireGuard listens on UDP `51820`. On hosts with `firewall_managed: true`, open it
to the mesh peers via `firewall_allow_udp` (see the `firewall` role):

```yaml
firewall_allow_udp:
  - { port: 51820, from: 51.250.101.180 }   # russia-01
  - { port: 51820, from: 84.252.139.137 }   # russia-02
```

Hosts with no managed firewall accept the port by default (all current mesh
members run a managed firewall).

## Verify

```bash
wg show                       # handshakes + transfer per peer
ping -c1 10.10.0.1            # from any peer, reach russia-01 over the tunnel
```
