# Runbook: move apps to another host

Move any set of registry-managed apps between fleet hosts with **zero
user-visible downtime** — one command end to end:

```sh
scripts/move-apps.py <SRC> <DST>          # every app hosted on SRC
scripts/move-apps.py --app <name> <DST>   # one app   (--dry-run to preview)
```

It flips the configs (apps.yml + terraform/dns), rsyncs plain-file
dirs, deploys $DST twice, smokes it directly, applies DNS (refusing
any plan that isn't update-only), waits for public convergence and
reconciles $SRC. The appcron/apppm2/nginx ownership manifests remove
only registry objects that no longer belong there; unrelated manual
services remain untouched. CI is not part of a move: workflows target the
stable `deploy.*` alias and keep working untouched.

**Failure handling**: every step is idempotent, and completed steps
are checkpointed in `.move-apps.state.json` — re-running the same
command resumes at the failed step (`--reset` starts over; the file
is removed on success). `--dead-src` skips rsync/reconciliation when $SRC is
gone: artifact apps come back with their next CI deploy, clone apps
from git + 1P envs; only plain-file apps (no repo/CI — e.g. recovery)
die with their host, which is their own DR gap to close.

One-off prep for a first-time $DST: `nodeapp_install: true` /
`tls_managed: true` in its host_vars + a baseline `site.yml -l $DST`
run (the script checks and tells you). Everything else derives:
`web` membership from the registry, certs from the tls role, CI
target from the `deploy.*` alias (trusted via accept-new — no CI
variables to touch, DndCrime#15).

After first deploying the ownership-manifest version of the roles, run one
normal `site.yml` converge before the next move. That initial run records the
currently managed PM2 processes and vhosts without deleting anything; later
runs can then distinguish stale registry objects from hand-managed ones. The
move script checks these source manifests before changing either config.

## Rollback

Any point before the DNS step: nothing user-visible happened, just
stop (and `--reset` + re-flip if configs moved). After it: run the
move in reverse. Source cleanup happens only after the destination has
passed the public smoke checks.

## First use: germany-01 → finland-01 (2026-07)

The specifics on top of the generic procedure (`SRC=germany-01
DST=finland-01`):

- **Prerequisite PRs** (merge before Phase 0): this repo — nodeapp
  `nodeapp_install` gate, pm2 boot resurrection, apppm2 python3-venv;
  gistrec/askads — `askads-cloud` ecosystem app on **8078** +
  deploy.sh host parametrization; katrinaver/DndCrime —
  `workflow_dispatch` on the deploy workflows.
- **Moving apps**: `askads-cloud` (also set `pm2: [askads-cloud]` —
  the new ecosystem app binds 8078; the vhost already proxies to it),
  `dnd-crime-api`, `dnd-crime-api-staging`, `dnd-crime-landing`,
  `dnd-crime-landing-staging`, `recovery`.
- **Cert lineages**: askads-cloud, mcp-askads-cloud,
  dnd-crime-gistrec-cloud, dnd-crime-staging-gistrec-cloud
  (+ harmless extras).
- **Non-git dirs**: `~/DndCrime ~/DndCrimeStaging ~/DndCrimeLanding
  ~/DndCrimeLandingStaging ~/recovery`; finland-01's wg IP is
  10.10.0.4.
- **Smoke domains**: askads.cloud, mcp.askads.cloud,
  dnd-crime.gistrec.cloud, dnd-crime-staging.gistrec.cloud — all
  Cloudflare-proxied, so the DNS flip is instant.
- **External pointers** (DndCrime):

  DEPLOY_HOST is permanently `deploy.dnd-crime.gistrec.cloud` (grey
  CNAME in `terraform/dns`) — a move flips only that CNAME. The
  hostkey needs a per-move refresh; pipe WITHOUT `--body` (`--body -`
  stores a literal dash):

  ```sh
  ssh-keyscan -t ed25519 deploy.dnd-crime.gistrec.cloud 2>/dev/null \
    | gh variable set DEPLOY_HOSTKEY --repo katrinaver/DndCrime
  ```

  then `gh workflow run` prod + staging. askads: flip the cloud host
  default in `deploy.sh` — one line.
- **Freeze list** on germany-01: `pm2 stop askads dnd-crime-api
  dnd-crime-api-staging`.
- **Open questions** (decide separately): `recovery` — two Go
  binaries + env files, not under pm2 anywhere, moved as plain
  files — still needed at all?; `DndCrimeLanding{,Staging}` — CI
  pushes artifacts but no vhost serves them (pre-existing).
- **RESOLVED 2026-07-20**: germany-01 retired — powered off + deleted by
  the provider. Repo cleanup: DNS A record destroyed, wg peer 10.10.0.3 +
  firewall allow-rules dropped (russia-01/russia-02/finland-01), host_vars
  deleted, inventory host + static `web` group removed. germany-02's netdata
  stream was repointed off the germany-01 proxy straight to the russia-01
  parent first (verified arriving from its 109.122.198.50 source IP).
