# wireguard

Private WireGuard mesh between fleet hosts. Every node gets a stable private IP
on `wg0` (10.10.0.0/24 by convention) so services talk over an encrypted tunnel
instead of the public internet. Built primarily so **MySQL replication**
(russia-01 → germany-01) rides the tunnel — no MySQL TLS certificates, no public
3306 exposure — but it is reusable for ClickHouse, netdata streaming, etc.

## Topology

Full mesh: each host peers with every OTHER host in the `wireguard` inventory
group. A peer's public endpoint is its inventory `ansible_host`; its tunnel IP
and public key live in its (gitignored) host_vars.

| host | wireguard_ip |
|---|---|
| russia-01 | 10.10.0.1 |
| germany-01 | 10.10.0.2 |
| russia-02 | 10.10.0.3 |

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
  - { port: 51820, from: 148.222.187.38 }   # germany-01
  - { port: 51820, from: 84.252.139.137 }   # russia-02
```

Hosts with no managed firewall (e.g. germany-01) accept the port by default.

## Verify

```bash
wg show                       # handshakes + transfer per peer
ping -c1 10.10.0.1            # from germany-01, reach russia-01 over the tunnel
```
