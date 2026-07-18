# Runbook: break-glass SSH

Emergency access for when the normal path is gone — laptop lost,
1Password unavailable, a home directory wiped, or a login user broken.
The path shares fate with nothing:

- **Private key**: resident on the YubiKey (ed25519-sk). Not on any
  disk, not in 1Password. Usable from any machine with an OpenSSH
  that has security-key support.
- **User**: `rescue` — its own account on every managed host, locked
  password, passwordless sudo via a root-owned drop-in (by design:
  break-glass must not depend on 1Password for a sudo password).
- **Keys on the host**: root-owned `/etc/ssh/rescue_keys`, pointed at
  by a `Match User rescue` block at the end of `/etc/ssh/sshd_config`
  — outside every home dir, so `rm -rf ~` or a compromised login user
  cannot sever it, and `rescue` itself cannot edit its keys.

## Use it

On any trusted machine. macOS note: the system ssh lacks security-key
support — use Homebrew OpenSSH. On the laptop the key stub already
exists as `~/.ssh/breakglass_sk`; on a fresh machine re-derive it from
the YubiKey first:

```sh
ssh-keygen -K                        # asks the YubiKey PIN, writes id_*_rk* stubs
ssh -i ~/.ssh/breakglass_sk \
    -o IdentityAgent=none -o IdentitiesOnly=yes \
    rescue@<host>.vps.gistrec.cloud  # touch the key when it blinks
sudo -i                              # no password
```

Last resort if sshd itself is dead: the provider console (Hetzner /
Yandex Cloud / the germany panels) — independent of everything above.

## Provisioning

The `breakglass` role, opt-in via `breakglass_managed: true` in
host_vars — currently every fleet host, **including germany-02**
(2026-07-18 scope exception: emergency access only; the box otherwise
stays netdata + chrony only). Public keys live in the gitignored
inventory (`all: vars: breakglass_ssh_keys`). The `Match` block is
appended to the end of the main `sshd_config` rather than
`sshd_config.d` on purpose: pre-8.4 sshd leaks `Match` blocks past the
end of included files, and not every host's sshd vintage is ours to
control.

## Care

- **Quarterly test**: log in as `rescue` on one host with the YubiKey
  and run `sudo -i`. Last verified: russia-02, 2026-07-16 (pre-role).
- **Rotate / revoke**: edit `breakglass_ssh_keys` in the inventory,
  re-run `ansible-playbook site.yml --tags breakglass`.
- **Losing the YubiKey** loses break-glass only — normal 1P-managed
  access is unaffected; provision a new key, rotate as above.
