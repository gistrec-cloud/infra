# Runbook: germany-01 → finland-01

Move every app off germany-01 onto finland-01 with **zero user-visible
downtime**: the old host keeps serving until a DNS flip, and every
app-facing domain is Cloudflare-proxied, so the flip is instant.

Why this is now a small job: data lives in managed MySQL (no local
state to move), secrets live in 1Password (`dotenv <app>` documents =
deploy source), and "what runs where" is `ansible/apps.yml` — for
registry-managed apps the move IS `host: finland-01` + one playbook
run. The germany-specific extras are CI artifacts (DndCrime), the
askads-cloud port flip, TLS certs, and the DNS/GH switches.

**What moves** (from `apps.yml`): `askads-cloud`, `dnd-crime-api`,
`dnd-crime-api-staging`, `dnd-crime-landing`, `dnd-crime-landing-staging`,
`recovery`.

Prerequisite PRs (merge before Phase 0):
- infra: nodeapp `nodeapp_install` gate + pm2 boot resurrection +
  apppm2 python3-venv (this PR)
- gistrec/askads: `askads-cloud` ecosystem app on **8078** + deploy.sh
  host parametrization
- katrinaver/DndCrime: `workflow_dispatch` on the deploy workflows

---

## Phase 0 — prepare finland-01 (safe any time, no user impact)

1. **Inventory** (`ansible/inventory/hosts.yml`, gitignored): add
   `finland-01` to the `web` group.
2. **host_vars/finland-01.yml**: add `nodeapp_install: true`.
   (80/443 need no firewall change — the firewall role always opens
   SSH/80/443.)
3. **Baseline run** — installs nginx + certbot, snippets, node + pm2 +
   boot resurrection. No vhosts yet (apps still declare germany-01):

   ```sh
   cd ansible && ansible-playbook site.yml -l finland-01
   ```

4. **TLS certs** — copy the four Let's Encrypt lineages from
   germany-01 so nginx can start serving them the moment vhosts land
   (renewal continues on finland after the DNS flip; germany's copies
   just expire). Via the laptop, preserving ownership:

   ```sh
   for d in live archive renewal; do
     ssh gistrec@germany-01.vps.gistrec.cloud "sudo tar czf - -C /etc/letsencrypt $d" \
       | ssh gistrec@finland-01.vps.gistrec.cloud "sudo tar xzf - -C /etc/letsencrypt"
   done
   # covers: askads-cloud, mcp-askads-cloud, dnd-crime-gistrec-cloud,
   #         dnd-crime-staging-gistrec-cloud (+ harmless extras)
   ```

5. **Fresh env backups** — the registry deploys env files from 1P, so
   they must be current: `scripts/backup-envs.sh germany-01`.

## Phase 1 — the move (~15 min of work, zero downtime)

1. **CI artifacts + jail dirs** — DndCrime binaries/dists and the
   recovery dir are not in any git clone; copy them over the WireGuard
   mesh (germany-01 = 10.10.0.3, finland-01 = 10.10.0.4):

   ```sh
   ssh gistrec@germany-01.vps.gistrec.cloud \
     'rsync -a ~/DndCrime ~/DndCrimeStaging ~/DndCrimeLanding ~/DndCrimeLandingStaging ~/recovery \
        gistrec@10.10.0.4:~/'
   ```

2. **Registry flip** (`ansible/apps.yml`): for the six apps above set
   `host: finland-01`; on `askads-cloud` also set `pm2: [askads-cloud]`
   (the new ecosystem app that binds **8078** — the vhost already
   proxies to 8078).
3. **Deploy everything the registry knows**:

   ```sh
   cd ansible && ansible-playbook site.yml -l finland-01
   ```

   This clones askads, builds its venv + web/out, writes env files
   from 1P, installs the DndCrime deploy keys + control scripts,
   starts the pm2 processes (askads-cloud from the repo ecosystem,
   dnd-crime-* from the rsynced `ecosystem.config.js`), and enables
   the four vhosts. Run it twice; the second run must be `changed=0`.
4. **Local smoke on finland-01** (before any DNS change):

   ```sh
   for h in askads.cloud mcp.askads.cloud dnd-crime.gistrec.cloud dnd-crime-staging.gistrec.cloud; do
     curl -sk --resolve "$h:443:$(dig +short finland-01.vps.gistrec.cloud)" \
       -o /dev/null -w "$h: %{http_code}\n" "https://$h/"
   done
   ```

5. **DNS flip** (`terraform/dns/terraform.tfvars`):
   - `askads.cloud` A record: `host = "germany-01"` → `host = "finland-01"`
     (mcp/www are CNAMEs to the apex — nothing else to touch);
   - `dnd-crime.gistrec.cloud` + `dnd-crime-staging.gistrec.cloud`
     CNAME content → `finland-01.vps.gistrec.cloud`;
   - `terraform apply`. All three are Cloudflare-proxied — the switch
     is instant, no TTL wait.
6. **GitHub switches** (DndCrime deploys):

   ```sh
   gh variable set DEPLOY_HOST --repo katrinaver/DndCrime --body finland-01.vps.gistrec.cloud
   ssh-keyscan -t ed25519 finland-01.vps.gistrec.cloud 2>/dev/null \
     | gh variable set DEPLOY_HOSTKEY --repo katrinaver/DndCrime --body -
   ```

   Then run the prod + staging deploy workflows via
   `gh workflow run` — proves the CI path lands on the new host.
7. **askads deploy path**: flip the cloud host default in
   `deploy.sh` (gistrec/askads) to finland-01 — one line.
8. **Public smoke**: the four domains over real DNS + a booking-style
   click-through on dnd-crime; `pm2 logs` on finland clean.
9. **Freeze germany** (rollback stays possible; nothing deleted):

   ```sh
   ssh gistrec@germany-01.vps.gistrec.cloud 'pm2 stop askads dnd-crime-api dnd-crime-api-staging && pm2 save --force'
   ```

10. **Backups**: `scripts/backup-envs.sh` (finland now carries the env
    files) and `scripts/backup-repo-files.sh` (apps.yml, hosts.yml,
    dns tfvars all changed).

## Rollback

Any point before step 5: nothing user-visible happened, just stop.
After step 5: revert the tfvars change + `terraform apply` (instant,
CF-proxied), unfreeze germany's pm2. Germany is untouched until you
deliberately retire it.

## Open questions (decide separately)

- **recovery**: two Go binaries + env files, NOT under pm2 anywhere —
  moved as plain files. Is it still needed at all?
- **DndCrimeLanding{,Staging}**: CI pushes artifacts, but no vhost
  serves them (pre-existing question).
- **germany-01 fate**: after a quiet week — retire (terraform), or
  keep as a spare. Its legacy DNS aliases die in August either way.
