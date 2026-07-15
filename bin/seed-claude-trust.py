#!/usr/bin/env python3
# seed-claude-trust.py — pre-accept Claude Code's first-run folder-trust dialog for the given cwd(s)
# (00-DESIGN.md D5). A restored (or fresh) interactive session otherwise stalls on the
# "Is this a project you trust?" prompt — "restored but idle", which R17 RESUME forbids. Seeding
# `projects["<cwd>"].hasTrustDialogAccepted = true` (+ hasCompletedProjectOnboarding) makes claude
# start ACTIVE. Trust is per-path (no fleet-wide managed-settings key exists), so bin/claude seeds each
# session's launch cwd.
#
# SAFETY: this edits ~/.claude.json, which running claude sessions also read-modify-write. So:
#   * ONLY writes when a flag actually needs changing (idempotent no-op after the first launch per cwd)
#     — the common case touches the file 0 times, so the race window is essentially never open;
#   * writes ATOMICALLY (temp + os.replace) so the file is never observed half-written;
#   * NEVER raises — any parse/IO failure degrades to "the trust prompt appears once", never a crash
#     and never a corrupted config. Run as: seed-claude-trust.py <abs-cwd> [<abs-cwd>...]
import json, os, sys

f = os.path.expanduser("~/.claude.json")
try:
    with open(f) as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}

projects = d.setdefault("projects", {})
if not isinstance(projects, dict):
    projects = d["projects"] = {}

changed = False
for cwd in sys.argv[1:]:
    if not cwd or not cwd.startswith("/"):
        continue
    p = projects.setdefault(cwd, {})
    if not isinstance(p, dict):
        p = projects[cwd] = {}
    if p.get("hasTrustDialogAccepted") is not True:
        p["hasTrustDialogAccepted"] = True
        changed = True
    if "hasCompletedProjectOnboarding" not in p:
        p["hasCompletedProjectOnboarding"] = True
        changed = True

if changed:
    try:
        tmp = f + ".seedtmp.%d" % os.getpid()
        with open(tmp, "w") as fh:
            json.dump(d, fh, indent=2)
        os.replace(tmp, f)
    except Exception:
        try:
            os.unlink(tmp)  # never leave a temp behind
        except Exception:
            pass
