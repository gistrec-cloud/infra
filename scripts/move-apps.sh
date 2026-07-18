#!/usr/bin/env bash
# Move registry apps between fleet hosts: flips ansible/apps.yml and the
# matching terraform/dns records in one shot, then prints the remaining
# runbook commands (docs/runbooks/move-apps.md is the full story).
#
# Usage:
#   scripts/move-apps.sh <SRC> <DST>           # every app hosted on SRC
#   scripts/move-apps.sh --app <name> <DST>    # one app
#   ... --dry-run                              # show the plan, write nothing
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '2,10p' "$0" >&2; exit 1; }

APP="" DRY=0 ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
if [ -n "$APP" ]; then
  [ ${#ARGS[@]} -eq 1 ] || usage
  SRC="" DST=${ARGS[0]}
else
  [ ${#ARGS[@]} -eq 2 ] || usage
  SRC=${ARGS[0]} DST=${ARGS[1]}
fi

DRY=$DRY SRC=$SRC DST=$DST APP=$APP python3 - <<'PY'
import os, re, sys

dry, src, dst, app = (os.environ[k] for k in ("DRY", "SRC", "DST", "APP"))
dry = dry == "1"
apps_path, tfvars_path = "ansible/apps.yml", "terraform/dns/terraform.tfvars"
inv_path = "ansible/inventory/hosts.yml"

# Hosts come from the inventory — refuse typos before touching anything.
import yaml
inv_hosts = set((yaml.safe_load(open(inv_path)) or {}).get("all", {}).get("hosts", {}))
for h in filter(None, [src, dst]):
    if h not in inv_hosts:
        sys.exit(f"FAIL: {h} is not an inventory host ({', '.join(sorted(inv_hosts))})")

registry = yaml.safe_load(open(apps_path))["apps"]
if app:
    if app not in registry:
        sys.exit(f"FAIL: app {app!r} is not in the registry")
    src = registry[app]["host"]
    if src == dst:
        sys.exit(f"FAIL: {app} already lives on {dst}")
    moving = {app: registry[app]}
else:
    moving = {n: a for n, a in registry.items() if a.get("host") == src}
    if not moving:
        sys.exit(f"FAIL: no registry apps on {src}")

# ── apps.yml: flip `host:` inside each moving app block (text-level edit —
# comments and formatting survive) ──
lines = open(apps_path).read().splitlines(keepends=True)
cur, flipped = None, []
for i, l in enumerate(lines):
    m = re.match(r"^  (\S+?):\s*$", l)
    if m:
        cur = m.group(1)
    if cur in moving and re.match(rf"^    host: {re.escape(src)}\s*$", l):
        lines[i] = f"    host: {dst}\n"
        flipped.append(cur)
missing = set(moving) - set(flipped)
if missing:
    sys.exit(f"FAIL: could not flip host: for {sorted(missing)} in {apps_path}")

# ── terraform.tfvars: re-point the moving records ──
# Whole-host: every `host = "SRC"` (except SRC's own <SRC>.vps A record) and
# every CNAME content "<SRC>.vps...". Per-app: only records whose dashed name
# matches the app's vhosts, plus their "deploy.<domain>" aliases.
tf = open(tfvars_path).read().splitlines(keepends=True)
sel_domains = None
if app:
    vhosts = set(moving[app].get("vhosts") or [])
    names = [m.group(1) for l in tf if (m := re.search(r'name\s*=\s*"([^"]+)"', l))]
    sel_domains = {n for n in names if n.replace(".", "-") in vhosts}
    sel_domains |= {n for n in names if n.startswith("deploy.") and n[len("deploy."):] in sel_domains}

dns_changes = []
for i, l in enumerate(tf):
    m = re.search(r'name\s*=\s*"([^"]+)"', l)
    if not m:
        continue
    name = m.group(1)
    if name == f"{src}.vps.gistrec.cloud":
        continue  # the host's own address record never moves
    if sel_domains is not None and name not in sel_domains:
        continue
    new = l.replace(f'host = "{src}"', f'host = "{dst}"') \
           .replace(f'"{src}.vps.gistrec.cloud"', f'"{dst}.vps.gistrec.cloud"')
    if new != l:
        tf[i] = new
        dns_changes.append(name)

print(f"apps  ({len(flipped)}): " + ", ".join(f"{n} -> {dst}" for n in sorted(flipped)))
print(f"dns   ({len(dns_changes)}): " + (", ".join(sorted(dns_changes)) or "nothing to flip"))
if dry:
    print("dry-run: nothing written")
    sys.exit(0)
open(apps_path, "w").writelines(lines)
open(tfvars_path, "w").writelines(tf)

# ── the rest of the runbook, precomputed for these apps ──
pm2 = sorted(p for a in moving.values() for p in (a.get("process") or {}).get("pm2", []))
artifact = sorted(n for n, a in moving.items() if (a.get("process") or {}).get("type") == "artifact")
dirs = sorted("~/" + a["dir"] for a in moving.values() if a.get("dir") not in (None, "."))
doms = sorted({n for n in dns_changes if not n.startswith("deploy.")})
print(f"""
Next (see docs/runbooks/move-apps.md):
  1. first time on {dst}? host_vars: nodeapp_install/tls_managed
  2. non-git files — CI artifacts re-deploy themselves (step 5); anything
     else, if {src} is alive:
       ssh -A gistrec@{src}.vps.gistrec.cloud 'rsync -a -e "ssh -o StrictHostKeyChecking=accept-new" {" ".join(dirs)} gistrec@<wg-ip of {dst}>:~/'
  3. cd ansible && ansible-playbook site.yml -l {dst}   # run twice
  4. smoke, then flip DNS:
       for h in {" ".join(doms)}; do curl -sk --resolve "$h:443:<ip of {dst}>" -o /dev/null -w "$h: %{{http_code}}\\n" "https://$h/"; done
       cd terraform/dns && terraform apply              # in-place updates only
  5. re-run CI deploys of: {", ".join(artifact) or "-"}
  6. freeze {src}: ssh gistrec@{src}.vps.gistrec.cloud 'pm2 stop {" ".join(pm2)} && pm2 save --force'""")
PY
