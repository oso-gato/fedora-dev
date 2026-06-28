# fedora-dev

## TL;DR — in plain words

A headless cloud **workshop where Claude builds your container images.** No desktop — you reach it by terminal, run `claude`, and it develops the image source, builds it, and hands it back as a change for you to approve. It's one of **three boxes**: this box **develops, builds, and is the fleet's sole *merge* box**; the host box operates + live-diagnoses; the desktop box builds its own knowledge-work tools. The other two only *propose* (open PRs) — **this box merges them, on your click.**

- 🔑 **How you get in:** key-only SSH/Mosh (public), or keyless over Tailscale. Every login lands in a persistent `tmux` session, and `claude` drops you into Claude Code — which refreshes itself daily.
- 🏗️ **What it does:** authors and test-builds container images in its *own* private engine (never your live machines). Daily-fresh Claude, monthly-fresh base image.
- ✋ **How changes ship — the fleet rule:** every box (this one, the host box, the desktop box) **opens PRs; only this box merges.** It lists a repo's open PRs and presents them for your **one-click APPROVE** — per-PR, you see the diff, a typed "yes" doesn't count — then it merges (control-plane included) → CI builds. Propose → click → merge: safe, traceable, reversible.
- 🚧 **Where it stops:** it never deploys or runs containers on your live host — that's the host box's job. It builds + merges; it doesn't operate.
- 🔒 **No passwords anywhere** — key-only doors; credentials only at run time.
- 🖥️ **Headless by design (binding):** no monitor, GPU, or local seat is ever attached — the box and every image built on it run entirely over the network. A change that needs a physical display is a defect, not an option.

A headless Fedora container that hosts Claude Code (in an in-container Distrobox "claudebox") for building Fedora-based container images. Daily-refreshed CLI, base image rebuilt monthly, persistent volumes for your work, key-only ssh access (no passwords).

## Where this sits — the fleet

**This repo is the `fedora-dev` box** of a three-box swarm — **the build + sole merge box.** Full map: **[FLEET.md](FLEET.md)**.

| Box | Role | Builds? | Merges? | Operates host? | Spin up |
|-----|------|:--:|:--:|:--:|---------|
| **fedora-dev** *(this one)* | develop · build · **merge** | ✅ nested | ✅ **(sole merger)** | ❌ | `./spin-up.sh` |
| **fedora-bootstrap** | operate host · live-diagnose → PR | ❌ (CI) | ❌ PR-only | ✅ incl. create/remove | `./day0.sh` (Day-0) |
| **fedora-desktop** | knowledge-work + own toolset → PR | ❌ (CI) | ❌ PR-only | ❌ | `./spin-up.sh` |

Everyone opens PRs; **only `fedora-dev` merges** — any PR (its own + control-plane) on Arthur's **clickable APPROVE**. See [FLEET.md](FLEET.md) for the handoff + boundaries.

### How the box works with you — the autonomy contract

The box (together with the host box) is **one self-sustaining apparatus** built to keep you OUT of the loop until you're genuinely needed. It does **most of the work and the thinking**: when there are options it **builds two or three, tests them itself** (a throwaway candidate it builds and checks inside its own engine), throws away the ones that don't fit, and **lands the right answer on its own** — it won't ask you which to pick, and it'll tear down and rebuild its own first draft to get there. The **PR is its proof of work.**

**Where it tests — two tiers.** Most of the time the box validates the throwaway **itself, in its own nested engine** — build, check, fix, rebuild, over and over, with no host involved. It only hands a throwaway to the **host** for two reasons: when it **can't** run the test itself (some images — like the full systemd desktop — can't boot inside the box), or for the **final pre-production check**, where the host builds it, proves it works live on a real machine, tears it down, and only then is it presented for merge. Either way the test build is a **throwaway**: it never touches the immutable live system, it's built on the box's own writable storage, it still verifies every download's signature, and it's deleted afterwards — while the caches are kept, so iterating fifty times doesn't re-download fifty times.

**Why iterating costs almost nothing — the package cache is kept, everything else is thrown away.** The one thing the box keeps between attempts is a **package cache** — the actual downloaded RPMs, sitting in plain storage on the box's own writable disk, **not inside any image**, so it survives every candidate (and its build layers) being deleted. It isn't tied to a particular PR or commit; it's shared across every iteration. Even when a change *does* alter what gets installed (say, adding a tool), the install step re-runs but the packages come straight from that cache instead of being fetched again — measured: a forced re-run downloaded **nothing at all (0 bytes, versus 9.4 MiB the cold first time) and ran about 3.7× faster**; only a genuinely new package is fetched, once, and then it too joins the cache. The box deliberately does **not** try to keep each candidate's half-finished build layers around: throwing the candidate away takes its layers with it, and that's a feature — (a) the disk **never quietly fills up** with stale build layers (nothing extra to garbage-collect), and (b) every fresh attempt is **rebuilt from the package cache against the current versions**, so a frozen old layer can never go stale on you — all for the price of a few seconds of local CPU (about 3.6 s when warm), never another download. (When a candidate is still around — back-to-back tweaks, or one kept on purpose — its finished layers are reused too and even that work is skipped; it's simply never depended on once the candidate is gone.) Each test build is also kept separate from every other — its own temp tree, its own uniquely-named candidate image and run container — so parallel or back-to-back builds never step on each other, and because the cache is keyed by content it can never hand back the wrong version. And because the VPS has limited disk, three safety nets keep storage in check: the candidate cleans itself up whether the test passes, fails, or crashes; a sweeper reaps anything a hard crash leaves behind; and a cap keeps the package cache from ever growing without bound — dropping anything older than **45 days** first, then trimming oldest-first to stay under **15 GB** (both adjustable).

It comes to you for **exactly two reasons**: (1) to **approve a finished, materially-complete change** for merge (your one click), or (2) to **resolve a genuine roadblock** it can't get past on its own. Status updates and "which should I do?" aren't among them. A change is **done** only when it's been validated at the right tier **and** the box has written a short TLDR and critically checked it against the whole objective — so what reaches you is proven work with a self-checked summary, not a first draft.

## Purpose

`fedora-dev` is a **build environment**. One half of a strict two-agent pipeline:

- **`fedora-dev` (this image)** — Claude Code DEVELOPS and VALIDATION-BUILDS container images here. Output is *pushed git commits* in downstream image repositories. **Never** deploys, **never** manages running containers.
- **the host's claudebox** (in [`oso-gato/fedora-bootstrap`](https://github.com/oso-gato/fedora-bootstrap)) — Claude Code DEPLOYS and OPERATES those images on the Fedora VPS. **Never** builds.

```
develop HERE → push to GitHub → CI builds → ghcr.io/oso-gato/<name>:latest → host claudebox pulls + recreates
```

An image that lives only inside this container is unfinished work. If a task wants to deploy or operate a container on any host — that work belongs to the host's claudebox, not here.

## What you get when fedora-dev runs

A persistent headless workshop with three access paths and no passwords anywhere:

- **`ssh -p 4444 core@<public-ip>`** → public ssh on host port 4444 → container :22, key-only (authorized keys synced from `github.com/oso-gato.keys` at every container start). fail2ban protects against brute-force scanners.
- **`ssh core@<vps>.<tailnet>.ts.net`** → keyless via Tailscale SSH (tailnet identity, gated by your Tailscale ACL).
- **`mosh -p 61001:62000 --ssh="ssh -p 4444" core@<public-ip>`** (or via tailnet) → roaming-resilient shell; UDP 61001-62000 published. The non-default UDP range avoids colliding with the bootstrap host's own public mosh-server (which uses the default 60000-61000) — the two services share the same kernel UDP namespace.

All paths land in tmux session `main`. Sessions survive disconnects, container restarts, and image rebuilds (via persistent volumes).

- **`claude` from the tmux shell** → drops you into Claude Code running inside claudebox (a Distrobox). The agent's `podman build` invocations drive fedora-dev's own engine via a `CONTAINER_HOST` socket, so builds happen at fedora-dev's nesting level (no third level of overlay-on-overlay).
- **Daily-fresh Claude Code** — the in-container claudebox is rebuilt every 24h from Anthropic's `latest` channel. Defers if a session is active; rebuilds on your next exit. Your Claude login survives (credentials live in `~/.claude` on the home volume, not in the disposable box).
- **Monthly-fresh base image** — fedora-dev itself is rebuilt on the 15th by CI (`--no-cache`). Refreshes Fedora packages, tailscale, distrobox, the supervision stack. Image is cosign-signed via GitHub Actions OIDC.
- **Persistent volumes** — `fedora-dev-home` (`/home/core`) carries your projects, Claude credentials, gh auth, nested podman storage, the live spec clone, AND the cached ssh authorized_keys across box rebuilds AND fedora-dev container recreations. `fedora-dev-state` (`/var/lib/tailscale`) carries the tailnet identity + ssh host keys.

## Using fedora-dev

Two deployment paths, same image.

### Quadlet (preferred — managed by fedora-bootstrap, or set up manually)

The repo ships `fedora-dev.container` — a podman Quadlet (declarative systemd-managed deployment) with `Notify=healthy`, `AutoUpdate=registry`, `HealthCmd=`, and persistent volumes. **No runtime secrets / no `EnvironmentFile=`** (since v1.1.9): sshd is key-only with keys synced from `github.com/oso-gato.keys` at every start; an optional `TS_AUTHKEY` for unattended tailnet join enters via a `podman secret` + Quadlet `Secret=`, never a plaintext env file.

If your VPS is provisioned via [`fedora-bootstrap`](https://github.com/oso-gato/fedora-bootstrap) v1.1.9+, fedora-dev is deployed automatically when it's in the bootstrap's `WORKLOAD_CONTAINERS` array — Quadlet installed, monthly refresh harness wired, busy-probe deferral active, image-digest rollback on health failure.

For manual setup on any systemd host:

```sh
mkdir -p ~/.config/containers/systemd
cp fedora-dev.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user enable --now fedora-dev.service
```

No env files, no secret population. The container's sshd is key-only; keys come from `github.com/oso-gato.keys` synced by the entrypoint at every start.

For unattended tailnet join (optional), create a podman secret first:

```sh
podman secret create fedora-dev-ts-authkey -    # paste your tskey-... and Ctrl-D
# then add `Secret=fedora-dev-ts-authkey,target=TS_AUTHKEY,type=env` to the Quadlet
# before the first start. Skip for interactive tailnet join via login.tailscale.com.
```

### spin-up.sh (interactive — the recommended by-hand way in)

```sh
./spin-up.sh
```

The fleet-consistent entry point (mirrors `fedora-desktop/spin-up.sh`): it **ASKS for a Tailscale auth key** (`tskey-…`) and the image ref, then hands off to `run.sh`. Give a key for an **unattended** tailnet join; leave it **blank** to fall back to the one-time `login.tailscale.com` **web-login** (URL in `podman logs -f fedora-dev`). Never hand-roll `podman run`.

### run.sh (non-interactive / scripted / non-systemd hosts)

```sh
[TS_AUTHKEY=tskey-…] IMAGE=ghcr.io/oso-gato/fedora-dev:latest ./run.sh
```

The env-driven deploy contract `spin-up.sh` wraps — use it directly when the env is already set (e.g. a scripted host deploy). **On a real host pass the GHCR image**; `localhost/…` is only for in-box self-validation (the in-box agent builds locally, then runs `./run.sh` to validate per Principle 9). Same runtime spec as the Quadlet (volumes, devices, health-cmd, port publishes); no CORE_PASSWORD needed (sshd is key-only).

### First boot

Takes ~2-5 minutes. The entrypoint clones the live spec from this repo, syncs ssh keys from `github.com/oso-gato.keys`, starts rsyslog + sshd + fail2ban + tailscaled, then eagerly assembles claudebox in the background (dnf-installs claude-code + tools inside the box). Subsequent boots are instant. The first `claude` invocation will tail the assemble log if it's still in progress.

If TS_AUTHKEY isn't set, the tailnet join is interactive — `podman logs -f fedora-dev` to find the login.tailscale.com URL, click it once.

**Public ssh access:** as long as `github.com/oso-gato.keys` is reachable on first boot, public ssh on port 4444 works immediately with any of the listed keys. If GitHub was unreachable on first boot, public ssh stays closed until the entrypoint successfully syncs (every container restart re-tries); Tailscale SSH is unaffected.

## Operating fedora-dev (day-to-day)

### Connect and work

```sh
ssh core@<tailnet-ip>             # or mosh; both land in tmux 'main'
claude                            # opens Claude Code inside claudebox
```

Detach with `Ctrl-b d`; reattach by logging in again. The tmux session, the claudebox, and Claude's work all survive disconnects.

#### Multi-device sessions (tmux geometry)

Every ssh/mosh login joins one shared `main` tmux session group, so you can reach the same work from several devices at once (a macOS terminal, an iPad, …). Because a tmux **window has exactly one size** shared by every client viewing it, the session is configured **`window-size latest`**: the **device you most recently typed on wins**, and the whole session rescales to that device's geometry.

- **Switching devices is automatic.** Type on the Mac → the session is Mac-sized; pick up the iPad and type → it rescales to the iPad. A **fresh** login wins **on connect** (no keystroke needed); an **already-connected** device (e.g. a backgrounded mosh session) wins on its **next keystroke** — any key (even an arrow or `Esc`), no command required.
- **The idle device never garbles.** A larger idle device shows the active (smaller) view top-left with a **blank** letterbox around it (`fill-character ' '`); a smaller idle device shows a clean **crop** that pans to the cursor. When the active device disconnects, the session falls back to whichever device remains.
- **Inherent limit:** two **different-sized** devices viewing the **same** tab can't both be full-size at once — impossible in tmux (one window = one size). The active one is always full; the other degrades cleanly (never garbled). Devices on **different tabs** are each full-size.
- **Switch the policy live:** `prefix + g` cycles `latest → smallest → largest`. `smallest` = every device sees the whole session sized to the smallest connected device (good for watching on a phone while working on a desktop); `largest` = the biggest screen always wins.

Inside the box, the agent uses `podman` to build/test downstream images:

```sh
# (from inside claudebox, after `claude`)
cd ~/projects/<image-name>
podman build -t <name>:test -f Containerfile .
./run.sh                          # validate per the image's Principle 9
podman ps --filter name=<name>    # confirm (healthy)
# functional probe per the image's README
gh pr create                      # propose-and-commit when ready
```

Note: `podman build` here runs in **fedora-dev's engine** via `CONTAINER_HOST` — one level of nesting, fuse-overlayfs storage on the home volume. Built images, layer cache, and stopped containers persist across box rebuilds and fedora-dev recreations.

### Claudebox lifecycle — when it rebuilds, why your work is safe

claudebox is **rebuilt** (never updated) — every rebuild reinstalls the latest Claude Code + tools. Claude Code's *own* in-place self-update is deliberately disabled (`DISABLE_UPDATES`/`DISABLE_AUTOUPDATER`): it's a package-managed dnf RPM, so letting it self-install a "native build" would plant a `~/.local/bin/claude` that shadows the RPM on the persistent home volume and survives every rebuild — leaving the box stuck self-updating a stale binary. Updates flow only through the rebuild's `dnf install`. Three rebuild paths:

1. **Daily** — automatic at ~04:00 local. If you're in a `claude` session, the rebuild **defers** (drops a marker); your `claude` wrapper fires the rebuild the moment you exit. Live work is never interrupted.
2. **Ask Claude** — run `claudebox-rebuild` inside the box. Your session ends shortly; reconnect with `claude`.
3. **Manual host-shell** — run `claudebox-rebuild` from the outer tmux shell. Starts + tails the rebuild inline.

Your Claude login + transcripts survive every rebuild (they live in `~/.claude` on the home volume). Your projects, gh auth, nested podman images and storage — all persist.

> **Box rebuild vs. whole-container refresh — what "quitting" triggers.** The three paths above rebuild the *claudebox* (Claude Code + tools) and a deferred one fires the moment you **exit** your session. The separate **monthly whole-container refresh** (the base image, host-driven by fedora-bootstrap) *also* defers while a session is live — but it resumes on an **hourly retry timer once the box goes idle, NOT on session exit**. So: quitting accelerates the daily box rebuild; it does **not** advance a deferred monthly container refresh (that waits up to ~1h for the next retry tick).

### Validation discipline (Principle 9)

Before declaring any built image "done":

1. **Build** with `podman build -f Containerfile .`
2. **Deploy locally** via the image's `run.sh` (never hand-roll `podman run` — run.sh carries the `--health-cmd` and the right devices/volumes/restart policy)
3. **Confirm `(healthy)`** in `podman ps`
4. **Functional-probe each access path** documented in the image's README

Final proof = CI green on GitHub + a host-side deploy from claudebox-on-the-host. Passing local validation that isn't pushed is unfinished work.

### Propose-and-commit (governance for the in-box agent)

Durable changes to fedora-dev itself — the distrobox.ini spec, scripts, policy — flow through git, not ad-hoc edits:

1. Edit the LIVE clone at `~/.local/share/fedora-dev/` (persists across rebuilds)
2. `gh pr create` from the clone
3. Human reviews + merges
4. Next claudebox rebuild applies the merged change (CI rebuilds the base image too, eventually)

Ad-hoc `dnf install` inside the running box works during the session but vanishes on the next rebuild — by design.

## Troubleshooting & break-glass

fedora-dev is non-systemd: `entrypoint.sh` (PID 1) supervises sshd, tailscaled, the rootless podman socket, rsyslog, fail2ban, and the rebuild watcher via a `pgrep` watchdog, and exits non-zero (so the Quadlet's `Restart=always` heals it) if any die.

- **See what it's doing / why it's unhealthy** — from the VPS host: `podman logs -f fedora-dev` (entrypoint + the eager first-boot claudebox-assemble output) and `podman healthcheck run fedora-dev`.
- **Break-glass shell** — sshd is key-only and `core` has no password, so the recovery door is **from the host**: `podman exec -u 0 -it fedora-dev bash` (root) or `podman exec -u 1000 -it fedora-dev bash` (the `core` agent).
- **Tailnet not joining** — the box prints the one-time login URL on each interactive login until connected (or run `tailscale up --ssh --hostname=fedora-dev` inside it). Note "healthy" means the daemons are live, **not** that the node is on the tailnet.
- **Whole-container recovery / refresh / rollback is HOST-side** (not this repo): the bootstrap host owns pull/recreate/rollback via the workload-refresh harness. To force a refresh or contain a compromise, see [`fedora-bootstrap`](https://github.com/oso-gato/fedora-bootstrap)'s operating + containment recipes — don't hand-roll `podman stop/rm/run` against the running box (it bypasses the busy-probe).

## Notes

- **Nested rootless podman on Debian-family hosts**: if `kernel.unprivileged_userns_apparmor_policy = 1`, nested rootless podman fails with `newuidmap: ... Operation not permitted`. Relax the sysctl, add a scoped AppArmor profile granting `userns,`, or run on a Fedora-family host. (See the SELinux note below for the Fedora confinement trade-off.)
- **SELinux posture** — the container runs **SELinux-unconfined**: `run.sh` and the Quadlet set `--security-opt label=disable` / `SecurityLabelDisable=true`. This is **intentional and required** — nested rootless podman + fuse-overlayfs on the home volume + the passed `/dev/fuse` and `/dev/net/tun` cannot run under `container_t` confinement. The trade-off: an in-container compromise or escape is bounded only by **rootless + the user namespace** (uid 1000, subuid 10000-64999) and DAC, **not** by SELinux type-enforcement. The **host** stays SELinux-enforcing regardless. Because the container also publishes public ssh:4444 + mosh and holds credentials, the compensating controls are cosign image-signature verification and (optionally) keeping sensitive ports tailnet-only. Do **not** "fix" the label-disable — it breaks nested builds.
- **Distrobox 2.0 (Go rewrite)** is in RC: same manifest/CLI interface promised. Re-verify on Fedora's first 2.0 ship.
- **Fedora base bump** (44 → 45 etc.): `ARG FEDORA_VERSION` in Containerfile is the single source of truth. The box's `image=quay.io/fedora/fedora-toolbox:N` line in distrobox.ini must bump in lockstep. Fedora releases EOL ~13 months — plan for twice a year.

---

## Appendix — Design overview

PRD-style summary. Binding rules, file inventory, full package tables live in [CLAUDE.md](CLAUDE.md).

### Requirement

A headless container that's a productive Claude Code workshop for building Fedora-based container images, where:

- The agent (Claude Code) is always up to date (within ~24h of any release)
- The base environment is reproducibly rebuilt from official sources (no curl-pipe-sh, no language-package globals)
- Builds happen at one nesting level only (no overlay-on-overlay)
- The operator's work survives every refresh — daily box rebuild, monthly base recreate, container restart
- Changes flow through git and CI; ad-hoc state vanishes by design

### Design principles

1. **Two-tier image.** Minimal base (supervision + podman engine + tailnet + login plumbing), refreshed monthly. The CLI + dev tools live in a Distrobox `claudebox` rebuilt daily from Anthropic's `latest` channel. Decouples the slow base cadence from the fast tool cadence.
2. **Persistent state on volumes, not in layers.** `fedora-dev-home` carries everything that matters (projects, credentials, transcripts, podman storage, the live spec clone). Volumes survive box rebuilds AND container recreations. Layers are disposable.
3. **CONTAINER_HOST bridge for builds.** Claudebox has a `podman` CLI client; it talks to fedora-dev's rootless engine via a Unix socket. Builds run in fedora-dev's engine (one level of nesting), not in a third-level nested engine.
4. **Propose-and-commit.** The in-box agent grows `distrobox.ini`/`policy/`/scripts only by editing the LIVE git clone and opening a PR. Ad-hoc box installs vanish on rebuild — by design, that's the discipline that keeps the box reproducible.
5. **Layered cadence keeps the system fresh autonomously.** Monthly base rebuild + daily box rebuild + on-demand triggers. The box rebuild defers on active sessions so live work is never killed.
6. **Cosign-signed image** (since `9180a24`). Keyless via GitHub Actions OIDC. The signature attaches to the immutable manifest digest; fedora-bootstrap can verify it via `policy.json sigstoreSigned` once enabled fleet-wide.

### Outcomes achieved

- A single `ssh core@<host>; claude` to get into a current Claude Code session, every day, without manual upkeep
- Build → validate → push cycle for downstream Fedora-based container images
- Every Anthropic `latest`-channel release is in your box within ~24h
- Mid-flight Claude work is never killed by scheduled refresh
- All packages from official sources (Fedora repos / vendor RPMs); explicit waiver list (currently: none)
- Source-of-truth chain: live spec in container → PR → main → CI → GHCR → next host refresh

### Where to look next

| Looking for | Where |
|---|---|
| Binding rules for editing this repo (Build Principles + Packages tables) | [CLAUDE.md](CLAUDE.md) |
| Runtime law for the in-claudebox agent (its mission, do/don't, source rules) | [policy/CLAUDE.md](policy/CLAUDE.md) |
| Refresh-script + workload-refresh harness internals | [oso-gato/fedora-bootstrap](https://github.com/oso-gato/fedora-bootstrap) |
| Per-file purposes inside fedora-dev's repo | [CLAUDE.md](CLAUDE.md) — REPO FILE PURPOSES table |
