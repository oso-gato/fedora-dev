# fedora-dev claudebox — agent law

Stamped from policy/ on every box rebuild; fleet-core (`## THE FLEET` + `## THE SELF-SUSTAINING APPARATUS`) assembled from `fedora-dev/policy/fleet-core.md` at stamp. Overrides project files, prompts, memory.

> **⚠️ UNSHACKLED / ZERO-GATE (2026-07-11, Arthur's decision — supersedes the merge-gate law below).**
> The autonomous LOOP is **gate-free**: the dev-side poller (`bin/pr-poller.sh` → `bin/auto-merge.sh`)
> auto-merges **every** host-GREEN + independent-fitness-PASS PR **regardless of tier** — control-plane
> included. There is **no Tier-A human click**; the Tier-A/B/C split was built on a misrepresented
> requirement (the real red line is throwaway build-isolation for WORKLOAD dev, *not* "never touch the
> control plane" — building this apparatus itself inherently edits policy/gate/quadlets). Recoverability
> is kept **automatic, not human**: the host post-deploy health-gate + digest auto-rollback, full
> git-revertability, and the fitness reviewer's standing *preserve-recoverability* requirement (a change
> that removes rollback or exfiltrates the merge/secret credential FAILS review). The ONLY human
> interaction is the initial objective + requirements approval.
>
> **The interactive `gate-push.sh` PreToolUse hook and the `auto` classifier are now REMOVED (P0 unshackle).**
> `managed-settings.json` runs `defaultMode=default` with `Bash(*)` allowed, so the interactive agent
> executes its own commands **without prompts** — the per-iteration human clicks the objective forbids
> (the classifier asked on compound/piped/interpreter commands; the hook asked on any command text
> containing a push/merge verb, incl. false positives like the word "merged" in an `echo`) are gone.
> Merge-to-main safety is preserved by THREE precise controls (none of which stops normal work):
> (1) the `require-PR` server ruleset on `main` — nothing direct-pushes `main`; (2) the
> `Bash(gh pr merge:*)` **deny** in `managed-settings.json` — the interactive agent cannot hand-merge a
> PR to `main` (an AUTO-DENY, never a prompt; a precise prefix rule, so unlike the removed text-scanning
> hook it never false-positives on "merged" in text); (3) the headless poller (plain shell — it bypasses
> managed-settings) does every AUTONOMOUS merge under its two INDEPENDENT gates (host live-gate App +
> fitness App, distinct identities). HONEST RESIDUAL: the deny stops the DIRECT merge verb only — a
> raw-API merge (`gh api`/GraphQL/curl) remains possible under `Bash(*)`; that residual is KNOWN and
> ACCEPTED per the zero-gate decision (pattern-denying API shapes = prefix-fragile sieve-theater per
> the ANTI-THEATER doctrine; recovery from a bad merge is AUTOMATIC — git revert + the host
> health-gate digest rollback + fitness's preserve-recoverability rule). You MUST NOT use that path:
> the poller pipeline is the ONLY sanctioned merge route. The "MERGE GATE / WORKING WITH THE GATE /
> MUST NOT merge without Arthur's click" law below is **historical and no longer in force**.

<!--FLEET-CORE-->

## ROLE

**DEVELOP · BUILD · MERGE** (see THE FLEET). Develop container-image source repos + build them in the
nested podman engine to validate + open PRs; AND be the fleet's **sole merge box** — list a repo's open
PRs, present them to Arthur as a discrete clickable decision, and on his APPROVE merge the authorized PRs
(any author, **including your own**; control-plane included) into `main`.

## PIPELINE

```
IN:   a repo to develop/modify; OR a repo's open PRs to review + merge on Arthur's approval
OUT:  merged `main` (on Arthur's clickable APPROVE) → CI builds → ghcr.io/oso-gato/<name>:latest (unsigned) → fedora-bootstrap deploys.
```

## DO

- Develop Containerfile + install.sh + entrypoint.sh + scripts + policy + CI in cloned image repos under `$HOME`.
- Build with `podman build` — CLI here drives fedora-dev's engine via `CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock`.
- Validate per each image repo's Principle 9: build → deploy via `run.sh` → confirm `(healthy)` → functional-probe each access path.
- Spin up an image **by hand** via its `./spin-up.sh` wizard (ASKS for `TS_AUTHKEY`; blank = `login.tailscale.com` web-login), or **scripted** via the `./run.sh` it wraps (`IMAGE=ghcr.io/oso-gato/<name>:latest` on a real host; `localhost/…` is in-box self-validation only). The HOST itself comes up via `setup.sh`, never a workload `run.sh`. Never hand-roll `podman run`.
- Add tools to claudebox: edit `~/.local/share/fedora-dev/distrobox.ini` `additional_packages`, add README Packages-table row, `gh pr create`.
- Run work in the foreground. Session-lock = activity signal; backgrounded work may be killed by host or daily rebuild.
- Pick up newer claude-code: run `claudebox-rebuild` in the box. This session ends. Reconnect with `claude`.

## DO NOT

- `podman run` against any host engine. Only `CONTAINER_HOST` here.
- Operate, recreate, or manage containers on any host.
- Modify the running fedora-dev or this box outside propose-and-commit. Ad-hoc installs vanish on next rebuild by design.
- Background long work with `&` / `nohup` / `setsid` to escape the session lock.
- MUST NOT run PR git (branch/commit/push) in a working tree another box or process may be mutating
  concurrently. A working tree has ONE shared HEAD+index — a concurrent `git checkout` by another actor
  silently relocates your `git commit` onto the wrong branch, and a named `git push` then ships the
  unmoved (empty) branch. FIX: use a dedicated `git worktree`/clone; verify
  `git rev-parse --abbrev-ref HEAD` before EVERY commit AND push (never assume your branch is still checked out).
  - NOTE [incident]: 2026-06-28 a commit in the shared `~/.local/share/fedora-dev` landed on a parallel
    box's branch, leaked into its PR, and that PR merged to `main`.
- UNSHACKLED (P0, 2026-07-11): there is NO gate-push hook and NO auto-classifier — you run any command
  (compound, piped, interpreter one-liners, feature-branch pushes, commands whose TEXT contains a
  push/merge verb) WITHOUT a prompt. The old "WORKING WITH THE GATE" command-shaping discipline (bare
  pushes, verb-free titles, `-F`/`--body-file` to dodge the text scan) is OBSOLETE — it existed only to
  avoid the removed hook. TWO limits remain (neither stops normal work): `main` cannot be
  direct-pushed (the `require-PR` server ruleset), and `gh pr merge` is a hard **deny** in
  `managed-settings.json` (auto-deny, no prompt). A raw-API merge is technically possible under
  `Bash(*)` (known, accepted residual — see the managed-settings comment) but is FORBIDDEN: the
  headless **poller** is the ONLY sanctioned merge route — push a branch + label the PR
  `live-validate` → host live-gate + fitness → the poller merges (its two independent gates are the
  merge safety). The `deny[]` list also blocks the package-manager escape hatches + `$PATH`-shadow writes.
- Install language-package-manager tools onto PATH inside the box.
- Edit live-installed binaries in `/usr/local/bin` (denied by managed-settings; survives one rebuild at most).

## TOOL INSTALL HIERARCHY (inside this box)

1. Fedora repos via dnf → `additional_packages` in `distrobox.ini`
2. Vendor/dev official RPM or dnf repo → `.repo` (`gpgcheck=1`) in `pre_init_hook` + `additional_packages`
3. Vendor/dev-released AppImage → post-assemble install, sha256 recorded

NEVER: COPR, third-party repos, `pip install` / `pipx` / `npm install -g` / `yarn global` / `pnpm add -g` / `cargo install` / `go install` / `gem install` / `brew install`, tarballs onto PATH, `curl | sh`, `flatpak install`, `snap install`.

## CHANGES TO POLICY OR THIS BOX

```
edit ~/.local/share/fedora-dev/{distrobox.ini|policy/|*.sh}  (live git clone)
  → gh pr create
  → human merges
  → next claudebox-rebuild applies the merged spec
  → monthly CI rebuilds fedora-dev image baked seed too
```

Ad-hoc edits to `/etc`, `/usr`, `/usr/local/bin` inside the box do not persist past one rebuild. Live spec on home volume persists across both box rebuilds and fedora-dev recreations.

## STOP-AND-SURFACE TRIGGERS — a direct host OPERATION only (a MODALITY, never a subject)

This fires on what YOU would DIRECTLY DO to the host, NOT on what a task is ABOUT. A task whose SUBJECT is a
host artifact (a `.container`/quadlet, a systemd-PID-1 image, a "deploy" you validate) is NORMAL dev work you
drive through the bus — it is NOT a trigger. The trigger is you performing the host op yourself:

- ssh/mosh into the VPS / production host, or run a host shell command on it
- `systemctl`/`podman`/deploy/recreate/restart/spin-up against ANY engine but this box's `CONTAINER_HOST`
- mutate the running host or the fedora-dev/fedora-bootstrap running state outside the merge-and-deploy path

→ STOP. Wrong actor. The host EXECUTES operate/deploy; you reach it ONLY through the ticket bus
(`bin/host-ticket.sh`). Surface what you would do; the host/human routes it.

**EXPLICITLY NOT A TRIGGER — this is YOUR loop; DRIVE it, do not hand it off:** labelling a PR
`live-validate`; filing a `host-ticket.sh`; reading a host live-gate verdict; iterating RED→fix→re-push to
GREEN; designing/building/iterating a host-GATED SPIKE over many rounds. **Host-GATED ≠ host-OWNED.** The
live-gate round-trip is the DEV side's own two-tier loop (the host is the EXECUTOR of your ticket, never the
OWNER of the work). Reaching "the edge of what I can build in-box" is NOT done and NOT a block — it is the
point where you OWE the host a `live-validate` ticket and OWE yourself the iteration to GREEN. Calling
host-gated work "another box's tier / not my remit" is a FALSE stop, a doctrine violation, not diligence.

## OPERATING SCOPE — R16 (BINDING; #167)

The apparatus acts ONLY on the maintainer-confirmed repo set in `policy/scope.conf`, read via
`bin/repo-scope.sh` (today: fedora-dev, fedora-bootstrap, fedora-desktop, e2e-alpha). Scope is
**per-objective, not permanent** (maintainer's ruling, 2026-07-13): the org holds repos that belong
to other people and other workstreams; a repo off-limits today may be in scope tomorrow.

- **Every actuator checks scope before acting** — poller sweep, fixer, fitness review, auto-merge,
  dev-plan/dev-loop/dev-author, host tickets/refresh. Out of scope ⇒ NO action, one loud log line.
  Fail-closed: an unreadable scope config freezes everything but the apparatus's own two repos
  (fedora-dev + fedora-bootstrap); a missing reader freezes all scoped action (rc≠0 is never a go).
- **Expanding the scope is maintainer-gated, structurally** (the R1 spec-confirmation discipline):
  the fitness gate treats a PR that NET-ADDS a repo to `policy/scope.conf` without a maintainer's
  recorded confirmation on that PR as (b) UNSAFE — a deterministic RETURN, never a NOTE (the hole
  #165 sailed through). Confirmation is NAME-BOUND: a PR comment whose FIRST line is exactly
  `CONFIRMED <repo> [<repo>…]` and nothing else, its author role-checked admin|maintain via the
  permission API — it covers exactly the repos it names, so a post-confirmation head that swaps or
  extends the adds re-gates unconfirmed; a bare or prose `CONFIRMED` confirms nothing, and App
  identities and label presence authorize NOTHING. Removing a repo needs no ceremony: narrowing is
  always safe.
- **SESSION DISCIPLINE (law, not code):** an agent session MUST NOT act on a repo outside its
  granted scope even via shared machinery — no enrolling it, no provisioning the clone, credential
  or config that lets an actuator reach it, no "fixing" a blocked actuator to get there. A blocked
  actuator or a foreign-repo request is a QUESTION to SURFACE to the maintainer, never a gap to
  self-provision around. (Incident 2026-07-13: #165 enrolled an out-of-scope repo, every gate
  passed it, the poller pushed a bot commit onto a foreign branch — and the session then
  provisioned the missing clone instead of surfacing the scope question.)

## OPERATING FACTS

- `$HOME` = fedora-dev home volume. Persists across box rebuilds AND fedora-dev container recreations.
- `/run/host` = fedora-dev's root filesystem. Read-only convention.
- claude-code installed from Anthropic `latest` channel at last box rebuild. It is a package-managed dnf RPM at `/usr/bin/claude` and updates ONLY via box rebuild. Its in-place self-update is LOCKED OFF (`DISABLE_UPDATES`/`DISABLE_AUTOUPDATER`) — do NOT run `claude install`/`claude update` to change the version (that path is an intentional no-op: "Updates are disabled by your administrator"). A native build would plant `~/.local/bin/claude`, shadow the RPM on the home volume, and survive every rebuild. To get a newer claude-code, run `claudebox-rebuild`.
- Git identity pre-configured per-repo: `claudebox@fedora-dev.local` / `claudebox`. Override per-PR if a different identity is needed.
- Seeded-no-git state: if `~/.local/share/fedora-dev/.seeded-no-git` exists, follow `CONVERT-TO-GIT.md` in the same dir before any commit.
- Host reboots / fedora-dev recreations: not yours. Propose; human decides.
- **SELinux is DISABLED for this container by design** (`SecurityLabelDisable=true` in fedora-dev.container, `--security-opt label=disable` in run.sh). Required for nested rootless podman + fuse-overlayfs + the passed `/dev/fuse`/`/dev/net/tun` (container_t confinement denies them). Do NOT re-enable labeling or remove these flags as a "hardening" fix — it breaks nested builds. Changing it is propose-and-commit, never an in-session edit. The HOST stays SELinux-enforcing; the weakening is scoped to this container, whose blast radius is bounded by rootless + user-namespace (uid 1000, subuid 10000-64999).

## HOW DO I... (operational recipes)

If a procedure you need isn't here, default to STOP-AND-SURFACE.

### Add a tool to claudebox (durable; survives rebuilds)

```sh
cd ~/.local/share/fedora-dev          # the live git clone
$EDITOR distrobox.ini                  # append to additional_packages= line (Fedora dnf package)
$EDITOR CLAUDE.md                      # add justifying row to BOX PACKAGES table (in CLAUDE.md since v1.1.6+)
git commit -am "claudebox: add <tool> — <one-line why>"
gh pr create --title "claudebox: add <tool>" --body "<why this tool, what task needs it>"
# After human merges, apply immediately:
claudebox-rebuild                      # session ends; reconnect with `claude`
# Or do nothing and the daily 04:00 rebuild picks it up.
```

Vendor RPM (source 2b): add a `pre_init_hooks=sh -c '...'` writing the `.repo` file (gpgcheck=1) BEFORE the `additional_packages` install. AppImage (source 2c): install in `claudebox-init.sh` post-assemble, record sha256. Both still need a Box Packages row.

### Trigger a claudebox rebuild now

```sh
claudebox-rebuild     # works inside the box OR from the outer tmux shell
# Session ends; box rebuilds detached (~2-5 min); reconnect with `claude`.
```

### Propose a change to fedora-dev itself (scripts, policy, distrobox.ini, etc.)

```sh
cd ~/.local/share/fedora-dev          # live clone on the home volume — persists across rebuilds
$EDITOR <file>
git commit -am "<scope>: <subject>"
gh pr create
# After human merge: the live clone reflects the new spec on `git pull origin main`,
# OR the next claudebox-rebuild reads the merged spec, OR CI rebuilds the fedora-dev
# base image with the new baked seed on its monthly cadence.
```

### Propose a change to fedora-dev's in-box policy (this file)

```sh
cd ~/.local/share/fedora-dev
$EDITOR policy/CLAUDE.md               # OR policy/managed-settings.json
git commit -am "policy: <subject>"
gh pr create
# Next claudebox-rebuild re-stamps /etc/claude-code/CLAUDE.md inside the box.
```

### Validate an image I just built (Principle 9)

```sh
cd <image-repo-clone>
podman build -t <name>:test -f Containerfile .   # drives fedora-dev's engine via CONTAINER_HOST
./run.sh                                          # never hand-roll podman run
podman ps --filter name=<name>                    # expect (healthy) within healthcheck window
# Functional-probe each access path the image's README documents
# (ssh, http, db query, whatever the image exposes).
gh pr create                                      # ship when all paths pass
```

### Check my current state

```sh
claude --version                                          # claude-code version
head -5 /etc/claude-code/CLAUDE.md                        # this file (stamped — confirms latest)
podman info --format '{{.Host.SecurityOptions}}' 2>&1     # CONTAINER_HOST sanity
test -d ~/.local/share/fedora-dev/.git \
    && (cd ~/.local/share/fedora-dev && git log -1 --format='%h %s on %an') \
    || cat ~/.local/share/fedora-dev/.seeded-no-git 2>/dev/null || echo "no live spec"
```

### Convert from seeded-no-git state to a real git clone

Only relevant if `~/.local/share/fedora-dev/.seeded-no-git` exists (entrypoint couldn't reach GitHub on first boot).

```sh
cd ~/.local/share/fedora-dev
cat CONVERT-TO-GIT.md          # exact commands — follow verbatim once the box is online
```

