# Runbook: move apps to another host

Move any set of registry-managed apps between fleet hosts with **zero
user-visible downtime**: the source keeps serving until a DNS flip.
The config side is one command:

```sh
scripts/move-apps.sh <SRC> <DST>          # every app hosted on SRC
scripts/move-apps.sh --app <name> <DST>   # one app   (--dry-run to preview)
```

It flips `host:` in `ansible/apps.yml` and the matching `terraform/dns`
records, then prints the remaining steps below with the app names,
domains and pm2 names already filled in.

Why a move is small: data lives in managed MySQL (nothing on host
disks), secrets live in 1Password (`dotenv <app>` documents = deploy
source, kept fresh by the after-every-secret-change policy — moves
don't touch them), "what runs where" is `ansible/apps.yml`, `web`
membership derives from it, and DNS points at hosts by name. CI
deploys target the stable `deploy.*` alias and trust it
(accept-new) — a move needs no CI-side changes at all.

## The move

1. **First time on $DST only** — `host_vars/$DST.yml`:
   `nodeapp_install: true` for pm2 apps, `tls_managed: true` for
   role-issued certs; then a baseline `ansible-playbook site.yml -l
   $DST`.
2. **`scripts/move-apps.sh $SRC $DST`** — registry + DNS tfvars
   flipped, nothing applied yet.
3. **Non-git files.** CI-artifact apps (`process.type: artifact`)
   need nothing here — step 6 repopulates them even if $SRC is dead.
   Plain-file apps (no `repo:`/CI — e.g. recovery) exist ONLY on
   $SRC; if it is alive:

   ```sh
   ssh -A gistrec@$SRC.vps.gistrec.cloud \
     'rsync -a -e "ssh -o StrictHostKeyChecking=accept-new" \
        <dirs> gistrec@<wg-ip of $DST>:~/'
   ```

   (`-A` — hosts hold no keys for each other; `accept-new` — first
   hop to a wg IP.) A dead $SRC loses these apps — their DR story is
   their own problem, the registry `notes:` must say which ones they
   are. edalle.ru's hand-managed cert lineage travels the same way.
4. **Deploy**: `cd ansible && ansible-playbook site.yml -l $DST`,
   twice; the second run must be `changed=0` (on a cold $DST the
   first run skips pm2 apps until the runtime lands).
5. **Smoke, then DNS**: curl every moving domain with `--resolve
   "$h:443:<ip of $DST>"`, then `cd terraform/dns && terraform
   apply` — the plan must be **in-place updates only** (pointer
   records are keyed by name). Proxied records flip instantly, grey
   ones within TTL (300 s).
6. **CI-artifact apps**: re-run their deploy workflows (`gh workflow
   run ...`) — they land on $DST via the deploy alias and rebuild
   the artifact dirs.
7. **Freeze $SRC** (if alive; rollback stays possible):

   ```sh
   ssh gistrec@$SRC.vps.gistrec.cloud 'pm2 stop <pm2 names> && pm2 save --force'
   ```

## Rollback

Any point before the DNS flip: nothing user-visible happened, just
stop. After it: revert the tfvars flip + `terraform apply`, unfreeze
$SRC's pm2. $SRC is untouched until you deliberately retire it.

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
  pushes artifacts but no vhost serves them (pre-existing);
  germany-01's fate after a quiet week — retire (terraform) or keep
  as a spare; its legacy DNS aliases die in August either way.
