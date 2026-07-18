#!/usr/bin/env python3
"""Move registry apps between fleet hosts — END TO END, one command:
config flip (apps.yml + terraform/dns), rsync of plain-file dirs,
deploy, smoke, DNS apply, CI re-runs, source freeze.

Usage:
  scripts/move-apps.py <SRC> <DST>           # every app hosted on SRC
  scripts/move-apps.py --app <name> <DST>    # one app
  ... --dry-run    # preview the flip + plan, write nothing
  ... --dead-src   # SRC is gone: skip rsync/freeze (CI re-runs cover
                   # artifact apps; plain-file apps are lost with SRC)
  ... --reset      # drop a stale checkpoint and start over

Failure handling: every step is idempotent, and completed steps are
checkpointed in .move-apps.state.json — re-running the SAME command
resumes at the failed step. The checkpoint is removed on success.
"""
import json, os, re, shlex, subprocess, sys, tempfile, time

import yaml

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

APPS, TFVARS = "ansible/apps.yml", "terraform/dns/terraform.tfvars"
INV, STATE = "ansible/inventory/hosts.yml", ".move-apps.state.json"
DOMAIN_SUFFIX = ".vps.gistrec.cloud"

# ── args ──
app, dry, dead_src, reset, pos = "", False, False, False, []
it = iter(sys.argv[1:])
for a in it:
    if a == "--app": app = next(it, "")
    elif a == "--dry-run": dry = True
    elif a == "--dead-src": dead_src = True
    elif a == "--reset": reset = True
    else: pos.append(a)
if app and len(pos) == 1: src, dst = "", pos[0]
elif not app and len(pos) == 2: src, dst = pos
else: sys.exit("usage: move-apps.py [--app NAME] [SRC] DST [--dry-run|--dead-src|--reset]")

def die(msg): sys.exit(f"FAIL: {msg}")
def note(msg): print(f"     {msg}")

inv_hosts = set((yaml.safe_load(open(INV)) or {})["all"]["hosts"])
registry = yaml.safe_load(open(APPS))["apps"]
if app:
    if app not in registry: die(f"app {app!r} is not in the registry")
    src = registry[app]["host"]

for h in (src, dst):
    if h not in inv_hosts: die(f"{h} is not an inventory host ({', '.join(sorted(inv_hosts))})")
if src == dst: die("SRC == DST")

# ── checkpoint ──
if reset and os.path.exists(STATE): os.remove(STATE)
state = json.load(open(STATE)) if os.path.exists(STATE) else None
sig = {"src": src, "dst": dst, "app": app}
if state and {k: state[k] for k in sig} != sig:
    die(f"a checkpoint for a DIFFERENT move exists ({STATE}: "
        f"{state['src']} -> {state['dst']}, app={state['app'] or 'all'}) — finish it or --reset")

if state is None:
    moving = {app: registry[app]} if app else {n: a for n, a in registry.items() if a.get("host") == src}
    if not moving: die(f"no registry apps on {src}")
    tf_names = [m.group(1) for l in open(TFVARS) if (m := re.search(r'name\s*=\s*"([^"]+)"', l))]
    vh = {v for a in moving.values() for v in (a.get("vhosts") or [])}
    domains = sorted({n for n in tf_names if n.replace(".", "-") in vh})
    aliases = sorted({n for n in tf_names if n.startswith("deploy.") and n[len("deploy."):] in domains})
    state = {**sig, "done": [],
             "apps": sorted(moving),
             "domains": domains, "aliases": aliases,
             "pm2": sorted(p for a in moving.values() for p in (a.get("process") or {}).get("pm2", [])),
             # plain-file + CI-artifact dirs travel by rsync (clone apps are
             # rebuilt by the role — their venvs don't survive an OS change)
             "rsync_dirs": sorted({"~/" + a["dir"].split("/")[0] for a in moving.values()
                                   if a.get("dir") not in (None, ".")
                                   and (a.get("process") or {}).get("type") != "clone"}),
             "ci": sorted([a.get("repo"), w] for n, a in moving.items()
                          for w in a.get("ci", []) if a.get("repo")),
             "ci_missing": sorted(n for n, a in moving.items()
                                  if (a.get("process") or {}).get("type") == "artifact" and not a.get("ci"))}

def save(): json.dump(state, open(STATE, "w"), indent=1)

# ── helpers ──
def run(cmd, cwd=None, env=None):
    print("  + " + " ".join(map(shlex.quote, cmd)))
    subprocess.run(cmd, cwd=cwd, env={**os.environ, **(env or {})}, check=True)

_conn = {}
def conn(host):
    """(public_ip, ssh_user, keyfile, wg_ip) — templated by ansible itself:
    raw inventory JSON keeps Jinja unrendered (key files are a convention)."""
    if host not in _conn:
        with tempfile.NamedTemporaryFile("w", suffix=".vpf") as f:
            f.write("dummy"); f.flush()
            out = subprocess.run(
                ["ansible", host, "-m", "ansible.builtin.debug", "-a",
                 "msg={{ ansible_host }}|{{ ansible_user }}|{{ ansible_ssh_private_key_file }}|{{ wireguard_ip | default('') }}"],
                cwd="ansible",
                env={**os.environ, "ANSIBLE_VAULT_PASSWORD_FILE": f.name,
                     # ansible.cfg renders results as yaml; force json so the
                     # "host | SUCCESS => {...}" tail parses as data
                     "ANSIBLE_CALLBACK_RESULT_FORMAT": "json"},
                capture_output=True, text=True, check=True).stdout
        try:
            msg = json.loads(out[out.index("{"):])["msg"]
        except (ValueError, LookupError):
            die(f"cannot render connection vars for {host}: {out[:200]!r}")
        _conn[host] = msg.split("|")
    return _conn[host]

def ssh_argv(host, remote_cmd, forward_agent=False):
    ip, user, key, _ = conn(host)
    key = os.path.expanduser(key)
    return ["ssh", *(["-A"] if forward_agent else []), "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=15", "-i", key, f"{user}@{ip}", remote_cmd]

def reachable(host):
    return subprocess.run(ssh_argv(host, "true"), capture_output=True).returncode == 0

def http_code(url, resolve=None):
    cmd = ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10"]
    if resolve: cmd += ["--resolve", resolve]
    return subprocess.run(cmd + [url], capture_output=True, text=True).stdout.strip()

# ── steps ──
def flip():
    lines, cur, seen = open(APPS).read().splitlines(keepends=True), None, set()
    for i, l in enumerate(lines):
        if (m := re.match(r"^  (\S+?):\s*$", l)): cur = m.group(1)
        if cur in state["apps"]:
            if re.match(rf"^    host: {re.escape(src)}\s*$", l):
                lines[i] = f"    host: {dst}\n"; seen.add(cur)
            elif re.match(rf"^    host: {re.escape(dst)}\s*$", l):
                seen.add(cur)  # already flipped (resume)
    if (missing := set(state["apps"]) - seen): die(f"could not flip host: for {sorted(missing)}")
    tf, targets = open(TFVARS).read().splitlines(keepends=True), set(state["domains"] + state["aliases"])
    changed = []
    for i, l in enumerate(tf):
        m = re.search(r'name\s*=\s*"([^"]+)"', l)
        if not m or m.group(1) not in targets: continue
        new = (l.replace(f'host = "{src}"', f'host = "{dst}"')
                .replace(f'"{src}{DOMAIN_SUFFIX}"', f'"{dst}{DOMAIN_SUFFIX}"'))
        if new != l: tf[i] = new; changed.append(m.group(1))
    print(f"  apps: {', '.join(state['apps'])} -> {dst}")
    print(f"  dns:  {', '.join(changed) or 'already flipped'}")
    if dry:
        print("dry-run: nothing written"); sys.exit(0)
    open(APPS, "w").writelines(lines); open(TFVARS, "w").writelines(tf)

def prep_dst():
    """A returning DST may hold FROZEN pm2 processes under the moving names —
    apppm2 would see them as 'already exists' and never start them."""
    if not state["pm2"]:
        note("no pm2 apps in this move"); return
    out = subprocess.run(ssh_argv(dst, "pm2 jlist 2>/dev/null || true"),
                         capture_output=True, text=True).stdout
    try:
        procs = json.loads(out or "[]")
    except ValueError:
        note("pm2 absent/unreadable on DST — nothing to clean"); return
    names = set(state["pm2"])
    stale = [p["name"] for p in procs if p["name"] in names and p["pm2_env"]["status"] != "online"]
    online = [p["name"] for p in procs if p["name"] in names and p["pm2_env"]["status"] == "online"]
    if online:
        note(f"WARN: already ONLINE on {dst} (left untouched): {', '.join(online)}")
    if not stale:
        note("no stale pm2 leftovers on DST"); return
    note(f"deleting stale pm2 leftovers on {dst}: {', '.join(stale)}")
    run(ssh_argv(dst, "pm2 delete " + " ".join(map(shlex.quote, stale)) + " && pm2 save --force"))

def rsync():
    if dead_src or not state["rsync_dirs"]:
        note("skipped (dead SRC / nothing to copy)"); return
    if not reachable(src):
        note(f"WARN: {src} unreachable — artifact apps will come from CI re-runs;"
             f" plain-file dirs ({', '.join(state['rsync_dirs'])}) are NOT copied"); return
    _, duser, _, dwg = conn(dst)
    target_ip = dwg or conn(dst)[0]
    run(ssh_argv(src, "rsync -a -e 'ssh -o StrictHostKeyChecking=accept-new' "
                 + " ".join(state["rsync_dirs"]) + f" {duser}@{target_ip}:~/", forward_agent=True))

def deploy():
    for _ in range(2):
        run(["ansible-playbook", "site.yml", "-l", dst], cwd="ansible")

def smoke_local():
    ip = conn(dst)[0]
    bad = []
    for d in state["domains"]:
        code = http_code(f"https://{d}/", resolve=f"{d}:443:{ip}")
        print(f"  {d}: {code}")
        if code == "000" or code.startswith("5"): bad.append(d)
    if bad: die(f"local smoke failed on {dst}: {', '.join(bad)} — fix and re-run (resumes here)")

def dns():
    env = {}
    if "TF_VAR_cloudflare_api_token" not in os.environ:
        env["TF_VAR_cloudflare_api_token"] = subprocess.run(
            ["op", "read", "op://Gistrec Cloud/cf-dns-token/password"],
            capture_output=True, text=True, check=True).stdout.strip()
    plan = tempfile.mktemp(suffix=".tfplan")
    out = subprocess.run(["terraform", f"-chdir=terraform/dns", "plan", "-no-color", "-out", plan],
                         env={**os.environ, **env}, capture_output=True, text=True, check=True).stdout
    if "No changes." in out:
        note("DNS already applied"); return
    m = re.search(r"Plan: (\d+) to add, (\d+) to change, (\d+) to destroy", out)
    if not m or m.group(1) != "0" or m.group(3) != "0":
        die(f"terraform plan is not update-only ({m.group(0) if m else 'unparsable'}) — investigate manually")
    note(m.group(0) + " (in-place only)")
    run(["terraform", "-chdir=terraform/dns", "apply", plan], env=env)

def smoke_public():
    ip = conn(dst)[0]
    for attempt in range(12):
        bad = []
        for a in state["aliases"]:
            got = subprocess.run(["dig", "+short", a], capture_output=True, text=True).stdout.split()
            if ip not in got: bad.append(f"{a} !-> {ip}")
        for d in state["domains"]:
            code = http_code(f"https://{d}/")
            if code == "000" or code.startswith("5"): bad.append(f"{d}: {code}")
        if not bad:
            print(f"  all green ({', '.join(state['domains'])})"); return
        note(f"waiting for DNS/edge ({'; '.join(bad)}) — retry {attempt + 1}/12 in 30s")
        time.sleep(30)
    die("public smoke did not converge in 6 min — investigate, then re-run")

def ci():
    for repo, wf in state["ci"]:
        run(["gh", "workflow", "run", wf, "--repo", repo])
    for n in state["ci_missing"]:
        note(f"WARN: artifact app {n} has no ci: field — re-run its deploy workflow manually")
    if not state["ci"] and not state["ci_missing"]: note("no CI-artifact apps in this move")

def freeze():
    if not state["pm2"]:
        note("no pm2 processes to freeze"); return
    if dead_src or not reachable(src):
        note(f"skipped ({src} dead/unreachable)"); return
    stops = "; ".join(f"pm2 stop {shlex.quote(p)} || true" for p in state["pm2"])
    run(ssh_argv(src, f"{stops}; pm2 save --force"))

# ── preflight: a first-time DST needs its one-off host_vars flags ──
hv_path = f"ansible/host_vars/{dst}.yml"
hv = (yaml.safe_load(open(hv_path)) if os.path.exists(hv_path) else None) or {}
needs = [f for f, needed in [("nodeapp_install", state["pm2"]), ("tls_managed", state["domains"])]
         if needed and not hv.get(f)]
if needs:
    die(f"first time on {dst}? set {' + '.join(f + ': true' for f in needs)} in {hv_path}, then re-run")

steps = [("flip", flip), ("prep-dst", prep_dst), ("rsync", rsync), ("deploy", deploy),
         ("smoke-local", smoke_local), ("dns", dns), ("smoke-public", smoke_public),
         ("ci", ci), ("freeze", freeze)]

print(f"move: {', '.join(state['apps'])}  {src} -> {dst}"
      + (f"  (resuming after: {', '.join(state['done'])})" if state["done"] else ""))
if not dry: save()
for name, fn in steps:
    if name in state["done"]:
        print(f"[done] {name}"); continue
    print(f"\n=== {name} ===")
    fn()
    state["done"].append(name); save()

os.remove(STATE)
print(f"\nMove complete: {', '.join(state['apps'])} now on {dst}; {src} frozen "
      f"(rollback: re-run the move in reverse). Reminder: repo-private backup "
      f"covers apps.yml/tfvars changes on its usual policy.")