# Runbook: move apps to another host

Move any set of registry-managed apps from one fleet host to another
with **zero user-visible downtime**: the source keeps serving until a
DNS flip. Hosts are parameters, not part of the procedure — name them
once and use the variables everywhere below:

```sh
SRC=germany-01 DST=finland-01   # the only place hosts are named
```

Why a move is small: data lives in managed MySQL (nothing on host
disks), secrets live in 1Password (`dotenv <app>` documents = deploy
source), "what runs where" is `ansible/apps.yml`, and DNS points at
hosts by name (`host_ips` in `terraform/dns`). For registry-managed
apps the move IS `host: $DST` + one playbook run — everything below is
the checklist around that flip.

**What moves**: the apps in `apps.yml` with `host: $SRC` — all of
them, or any subset (the registry is per-app). Per moving app, the
registry answers what else travels: `dir:` (non-git files to rsync),
`vhosts:` (domains to smoke and flip), `process.pm2:` (what to freeze
on $SRC), `repo:`/`notes:` (where external deploy pointers live).

## Phase 0 — prepare $DST (safe any time, no user impact)

1. **Inventory** (`ansible/inventory/hosts.yml`, gitignored): add
   $DST to the groups matching what it takes on (`web` for
   nginx + vhosts).
2. **host_vars/$DST.yml**: `nodeapp_install: true` if it runs pm2
   apps. (80/443 need no firewall change — the firewall role always
   opens SSH/80/443.)
3. **Baseline run** — nginx + certbot, snippets, node + pm2 + boot
   resurrection. No vhosts yet (apps still declare $SRC):

   ```sh
   cd ansible && ansible-playbook site.yml -l $DST
   ```

4. **TLS certs** — nothing to do: the `tls` role (runs in the baseline
   above for `tls_managed` hosts) issues per-zone wildcard certs via
   DNS-01 on every web host, and renewal is local — it doesn't care
   where DNS points. Exception: a domain outside the Cloudflare zones
   (edalle.ru) keeps its own lineage — move it the old way (tar the
   lineage over ssh) if its app ever moves.
5. **Fresh env backups** — the registry deploys env files from 1P, so
   they must be current: `scripts/backup-envs.sh $SRC`.

## Phase 1 — the move (zero downtime)

1. **Non-git dirs** — CI artifacts (`process.type: artifact`) and
   anything else a clone can't recreate; check each moving app's
   `dir:`. Copy over the WireGuard mesh (wg IPs: `wireguard_ip` in
   host_vars):

   ```sh
   ssh gistrec@$SRC.vps.gistrec.cloud \
     'rsync -a <dirs from the registry> gistrec@<wg-ip of $DST>:~/'
   ```

2. **Registry flip** (`ansible/apps.yml`): `host: $DST` on every
   moving app.
3. **Deploy everything the registry knows**:

   ```sh
   cd ansible && ansible-playbook site.yml -l $DST
   ```

   Clones + bootstraps runtimes, writes env files from 1P, installs
   deploy keys + control scripts, starts pm2 processes, enables
   vhosts. Run it twice; the second run must be `changed=0`.
4. **Local smoke on $DST** (before any DNS change), for every domain
   from the moving apps' `vhosts:`:

   ```sh
   for h in <domains>; do
     curl -sk --resolve "$h:443:$(dig +short $DST.vps.gistrec.cloud)" \
       -o /dev/null -w "$h: %{http_code}\n" "https://$h/"
   done
   ```

5. **DNS flip** (`terraform/dns/terraform.tfvars`): grep `$SRC`, flip
   the moving apps' records — A records: `host = "$SRC"` → `"$DST"`;
   CNAMEs at the host: content `$SRC.vps...` → `$DST.vps...` — then
   `terraform apply`. Cloudflare-proxied records flip instantly;
   grey-cloud ones wait out their TTL (auto = 300 s).
6. **External deploy pointers** — anything outside this repo that
   names the host (CI variables, deploy scripts — see each app's
   `repo:`/`notes:`). Flip them, then re-run each CI deploy to prove
   the path lands on $DST.
7. **Public smoke**: the domains over real DNS + a click-through of
   the stateful flows; `pm2 logs` on $DST clean.
8. **Freeze $SRC** (rollback stays possible; nothing deleted) — stop
   the moved `process.pm2:` names:

   ```sh
   ssh gistrec@$SRC.vps.gistrec.cloud 'pm2 stop <pm2 names> && pm2 save --force'
   ```

9. **Backups**: `scripts/backup-envs.sh` ($DST now carries the env
   files) and `scripts/backup-repo-files.sh` (apps.yml, hosts.yml,
   dns tfvars all changed).

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

  ```sh
  gh variable set DEPLOY_HOST --repo katrinaver/DndCrime --body finland-01.vps.gistrec.cloud
  ssh-keyscan -t ed25519 finland-01.vps.gistrec.cloud 2>/dev/null \
    | gh variable set DEPLOY_HOSTKEY --repo katrinaver/DndCrime --body -
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
