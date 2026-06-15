# fedora-dev

## Purpose

`fedora-dev` is a headless **build environment** for Fedora-based container
images. It is one half of a strict two-agent pipeline:

- **`fedora-dev` (this image)** — where Claude Code DEVELOPS and
  VALIDATION-BUILDS container images. Its output is *pushed git commits* in
  downstream image repositories. It NEVER deploys to hosts and NEVER manages
  running containers.
- **the host's claudebox** (in [`oso-gato/fedora-bootstrap`](https://github.com/oso-gato/fedora-bootstrap))
  — where Claude Code DEPLOYS and OPERATES those images on the Fedora VPS.
  It pulls from GHCR and recreates running containers via each image's
  `run.sh`. It NEVER builds.

The handoff is one-way and explicit:

```
develop HERE → push to GitHub → CI builds → publishes to
ghcr.io/oso-gato/<name>:latest → host's claudebox pulls + recreates
```

An image that lives only inside this container is unfinished work. A finished
change is pushed, CI-built, GHCR-published. If a task appears to require
deploying or operating a container on any host, that work belongs to the
host's claudebox — not here.

## Objective

**A headless Fedora workshop where Claude Code builds Fedora-based container
images.** You attach over ssh or mosh across the tailnet and land in tmux
automatically (every interactive login attaches to session `main`). From there
`claude` launches Claude Code inside an in-container **claudebox** (a Distrobox
container managed declaratively by `distrobox.ini`); the agent uses `podman`
to build and validate images via a bridge to fedora-dev's engine, then pushes
to GitHub for CI to take over. mosh makes the connection resilient; even when
the link dies, the tmux session, the box, and Claude's work survive.

Two cadences keep this current without babysitting:

- **fedora-dev base image** — rebuilt monthly via CI on the 15th (`--no-cache`).
  Refreshes Fedora packages, tailscale, distrobox itself, the supervision stack.
- **claudebox (Claude Code + its toolset)** — rebuilt **daily** at ~04:00 by an
  in-container supervisor. Pulls Anthropic's `latest` channel each time. Live spec
  lives on the home volume so mid-cycle edits survive monthly base recreations.

## Build Principles (binding — follow verbatim for any change to this repo)

| # | Principle | Rule |
|---|---|---|
| 1 | BASE | Build only from the official `registry.fedoraproject.org/fedora:${FEDORA_VERSION}` image. Version is a Containerfile `ARG` — never inlined. |
| 2 | SOURCES | Every package from an official source, exactly one of: (a) Fedora's own repos via dnf; (b) the vendor's/developer's own RPM or dnf repo (`.repo` with `gpgcheck=1`); (c) at worst, a developer/vendor-released AppImage (sha256 logged). Never: COPR or other third-party repos, pip/npm/cargo/brew installs, curl-pipe-sh, tarball drops. **This applies to BOTH the base image AND claudebox's `additional_packages`.** Exceptions only by explicit user waiver, recorded in the relevant Packages table. **Current waivers: none.** |
| 3 | MINIMAL | dnf only with `--setopt=install_weak_deps=False`. Every package gets a justifying row in the relevant Packages table (Base or Box); a package without a row is a violation. |
| 4 | VERIFY FIRST | Before adopting or bumping any source/version, fact-check it against the live source (web). Gate risky installs (version-mismatched vendor RPMs, new repos) in a scratch container before editing build files. |
| 5 | NO SECRETS / NO IDENTITY | No passwords, keys, or personal usernames in any layer, file, or commit. Container user is the generic `core` (uid 1000). Credentials enter only as runtime env vars; entrypoint fails fast when missing. |
| 6 | PINS | Vendor artifact versions are Containerfile `ARG`s or pinned in `distrobox.ini` — bump there only, after rule 4. |
| 7 | DEPLOY CONTRACT | Every image ships a `run.sh` that is the only sanctioned way to run it: runtime `--health-cmd` (OCI drops Containerfile HEALTHCHECK), devices, volumes, restart policy. Sensitive ports (ssh/RDP/VNC) stay tailnet-only — never `-p`. |
| 8 | CI + LAYERED CADENCE | `.github/workflows/build.yml` publishes the base image to GHCR: on push, on the 15th monthly (`--no-cache`), and on manual dispatch. Built-in token only. The IN-CONTAINER claudebox refreshes daily on its own timer + ad-hoc triggers; it never touches CI. |
| 9 | VALIDATE | After any change: build, deploy via `run.sh`, confirm `(healthy)` plus a functional probe of each access path. Final proof is CI green + a host deploy from claudebox-on-the-host. |
| 10 | PROPOSE-AND-COMMIT | The in-box agent grows `distrobox.ini`/`policy/`/`box-rebuild.sh` only by editing the LIVE clone at `/home/core/.local/share/fedora-dev/` and opening a PR (`gh pr create`). The human merges; the next box rebuild applies it. Ad-hoc installs in a running box vanish on rebuild by design. |

## Base Packages

The fedora-dev image itself. Refreshed monthly via CI.

| Package | Pin | Source (rule 2 class) | Why required |
|---|---|---|---|
| podman | Fedora current | distro (a) | the container ENGINE — claudebox runs on it; the agent's `podman build` lands here via CONTAINER_HOST |
| shadow-utils | Fedora current | distro (a) | newuidmap/newgidmap setuid helpers — mandatory for nested rootless podman |
| fuse-overlayfs | Fedora current | distro (a) | nested rootless storage driver (kernel forbids native overlay-on-overlay) |
| passt | Fedora current | distro (a) | pasta — podman 5 default rootless network backend |
| iptables-nft, nftables | Fedora current | distro (a) | tailscaled programs the firewall; crashes without the binaries |
| openssh-server | Fedora current | distro (a) | the login door: mosh bootstraps over ssh; tmux auto-attach fires on every interactive login. Pulls in `openssh` (which ships `ssh-keygen` for runtime host-key generation) |
| mosh | Fedora current | distro (a) | roaming-resilient remote shell (UDP, AEAD-authenticated; bootstraps over ssh) |
| tailscale | Tailscale dnf/rpm repo | vendor (b) | tailnet access — the only exposure path for :22 and mosh's UDP range |
| tmux | Fedora current | distro (a) | session multiplexer; every interactive login auto-attaches `main`. Trigger-and-detach is the operator pattern. |
| distrobox | Fedora current | distro (a) | declaratively bootstraps the in-container claudebox via `distrobox assemble create --file distrobox.ini` |
| inotify-tools | Fedora current | distro (a) | `inotifywait` in the entrypoint watches `rebuild.request` flag from the in-box agent (replaces systemd `.path` unit; we have no systemd here by design) |
| sudo | Fedora current | distro (a) | break-glass escalation for the operator (`core` in `wheel`). Architectural use case: zero — keeping it for emergency manual repair of `/etc`, `/var/lib/tailscale` |
| procps-ng | Fedora current | distro (a) | `pgrep` for the entrypoint watchdog AND for `run.sh`'s `--health-cmd` |
| glibc-langpack-en | Fedora current | distro (a) | UTF-8 rendering for tmux and the terminal observing Claude's output |
| nano | Fedora current | distro (a) | one break-glass editor (Fedora 44's minimal base doesn't reliably ship `vi`). ~600KB |

## Box Packages

Inside claudebox (`distrobox.ini`'s `additional_packages`). Refreshed daily by the in-container box rebuild from Anthropic's `latest` channel + Fedora repos.

| Package | Pin | Source (rule 2 class) | Why required |
|---|---|---|---|
| claude-code | Anthropic dnf/rpm repo (**`latest`** channel) | vendor (b) | the agent — claudebox's purpose; refreshed daily so new model releases are accessible day one |
| git | Fedora current | distro (a) | the VCS engine the agent drives for every project (Containerfiles, downstream image repos). Inside the box because the agent's shell is in the box |
| gh | GitHub dnf/rpm repo | vendor (b) | GitHub/GHCR auth, PRs (the propose-and-commit lifecycle), releases. Inside the box because the agent uses it; auth state at `~/.config/gh/` lives on the home volume so it's shared with anything else that ever needs it |
| openssh-clients | Fedora current | distro (a) | outbound ssh for git-over-ssh from inside the box |
| podman (client) | Fedora current | distro (a) | the agent's `podman build/run/exec/healthcheck` for downstream images. Engine is at fedora-dev's level; CLI in the box drives it via `CONTAINER_HOST` |
| bubblewrap | Fedora current | distro (a) | Linux user-namespace sandbox; Claude Code's Bash tool uses it for isolated tool execution |
| socat | Fedora current | distro (a) | paired with bubblewrap for IPC socket relay into/out of the sandbox |
| host-spawn | Fedora current | distro (a) | distrobox container-side host-exec component. Headless = no flatpak-session-helper, so the actual shims are deliberately NOT wired up; this package's presence prevents distrobox-create from `curl`'ing it from GitHub releases (source-control discipline per rule 2) |
| rclone | Fedora current | distro (a) | the agent's cloud/SMB/SSH/object-store reach for build files on other network drives |

## Deploy

Two paths, same image:

### Quadlet (preferred for managed hosts — systemd lifecycle, health-check restart, fedora-bootstrap integration)

The repo ships `fedora-dev.container` — a podman Quadlet (declarative systemd unit). Drop it in, populate the secrets env file, enable:

```sh
mkdir -p ~/.config/containers/systemd ~/.config/container-refresh
cp fedora-dev.container ~/.config/containers/systemd/

cat > ~/.config/container-refresh/fedora-dev.env <<EOF
CORE_PASSWORD=<your password>
# TS_AUTHKEY=tskey-...   # uncomment for unattended tailnet join
EOF
chmod 0600 ~/.config/container-refresh/fedora-dev.env

systemctl --user daemon-reload
systemctl --user enable --now fedora-dev.service
```

`fedora-bootstrap` performs all of this automatically when `fedora-dev` is in its `WORKLOAD_CONTAINERS` array — including pulling the Quadlet from this repo, writing the env file scaffold, and wiring the monthly refresh harness with busy-probe deferral and image-digest rollback.

### run.sh (manual / interactive / non-systemd hosts)

```sh
CORE_PASSWORD='…' [TS_AUTHKEY=tskey-…] [IMAGE=…] ./run.sh
```

Same runtime spec as the Quadlet (volumes, devices, health-cmd, etc.) but bound to a one-shot `podman run -d` invocation with no systemd around it.

### Connection

- The entrypoint refuses to start without `CORE_PASSWORD` — a published image can never carry a default credential.
- Connect: `ssh core@<tailnet-ip>` or `mosh core@<tailnet-ip>` — both land in tmux session `main`. Ports (22/tcp, 60000-61000/udp) tailnet-only — never publish.
- Volumes: `fedora-dev-home` (/home/core; preserves agent state, claude credentials, the LIVE distrobox.ini clone, podman storage), `fedora-dev-state` (tailscale state + ssh host keys, root-owned so the unprivileged user cannot swap host keys).
- Tailscale SSH is enabled (`--ssh`): once joined, any tailnet device can `ssh core@<hostname>` keylessly (lands in tmux).
- **First boot takes ~2-5 minutes** as the entrypoint clones the live spec and eagerly assembles claudebox in the background. Subsequent boots are instant. `claude` from the tmux shell starts the agent.

## Claudebox lifecycle

claudebox is rebuilt — never updated. Three paths, all converge on `box-rebuild.sh` (which runs detached via `setsid nohup` so it outlives the box it tears down):

1. **Daily** — `entrypoint.sh`'s daily-tick loop (`sleep 86400`) fires `claudebox-daily.sh` at ~04:00 each day. If `claude` is in a session (a SHARED `flock` is held on `~/.local/state/claudebox/session.lock`), the rebuild **defers**: drops a `rebuild.pending` marker. The `claude` wrapper checks the marker on session exit and fires the rebuild then. Live work is never interrupted.
2. **Ask Claude** — in-box `claudebox-rebuild` writes `~/.local/state/claudebox/rebuild.request`. The fedora-dev entrypoint's `inotifywait` watcher sees it (across the bind-mounted $HOME), consumes the flag, fires `box-rebuild.sh` detached. This session ends shortly; reconnect with `claude`.
3. **Manual** — `claudebox-rebuild` from the outer tmux shell starts the rebuild directly and tails the log.

Every rebuild: `distrobox rm -f claudebox` → `claudebox-assemble.sh` → fresh `distrobox assemble create` from `~/.local/share/fedora-dev/distrobox.ini` → reinstall latest-channel claude-code + tools → re-apply host bridges (`claudebox-init.sh`) → re-stamp policy (`policy/CLAUDE.md` + `managed-settings.json`). Your Claude login survives (it's in `~/.claude`, on the home volume).

### Live spec vs baked seed

`distrobox.ini` lives in **two** places:

- **Baked into the image** at `/usr/local/share/fedora-dev/` — used ONLY on first boot if the live clone doesn't exist yet (or as a seed when GitHub is unreachable).
- **Live git clone** at `/home/core/.local/share/fedora-dev/` — the runtime source of truth. Persists on the home volume across fedora-dev container recreations (so mid-cycle edits SURVIVE the monthly base-image refresh).

The agent edits the live clone, opens a PR with `gh pr create`, and the human merges. CI rebuilds the base with the new baked seed; the running container's live clone is unchanged. The agent can `git pull origin main` on the live clone to converge it with main after merge.

## Nested builds — `podman build` from inside the box

As `core` inside claudebox: `podman build/run/exec/healthcheck` "just works" because `CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock` is exported in the box's `/etc/profile.d/10-host-podman.sh` (written by `claudebox-init.sh` post-assemble). That socket is **fedora-dev's** rootless podman API socket, served by `podman system service` supervised in the entrypoint. distrobox bind-mounts `/run/user/1000/` from fedora-dev into the box at the same path.

So `podman build .` inside the box runs in **fedora-dev's engine** (one level of nesting, fuse-overlayfs storage on the home volume at `~/.local/share/containers/`), NOT in another nested engine inside the box. Storage, layer cache, built images, and stopped containers persist across box rebuilds AND across fedora-dev container recreations.

Subuid/subgid: `core:10000:55000` (sized to fit the outer rootless 65536-ID map; inner chowns to uid ≥ 55001 will fail — enlarge the host range first if ever needed).

No systemd inside: cgroupfs manager + file events logger preconfigured; XDG_RUNTIME_DIR provided by the entrypoint; the rebuild-trigger machinery is supervised by the entrypoint's pgrep watchdog instead of systemd units (faithful to fedora-dev's PID-1 design).

Host prerequisite (Debian hosts only): if `kernel.unprivileged_userns_apparmor_policy = 1`, nested rootless podman fails — relax the sysctl or run on Fedora-family hosts (SELinux, unaffected; `run.sh` already carries `--security-opt label=disable`).

## Cadence summary

| Layer | Cadence | Trigger | Source |
|---|---|---|---|
| Base image (RPM updates) | Monthly (15th @ 04:00 UTC) | CI cron `--no-cache` | Fedora + tailscale repos |
| Base image (spec changes) | On push to `main` | CI `on: push` | merged PRs from in-box agent |
| Claudebox (CLI + tools) | Daily (~04:00) | in-container `claudebox-daily.sh`; defers if session active | Anthropic `latest` channel + Fedora repos |
| Claudebox (ad-hoc) | On demand | in-box `claudebox-rebuild` OR host-shell `claudebox-rebuild` | same as daily |
| fedora-dev container itself | Operator-driven (or host cron) | safe-refresh on monthly cadence; SESSION-LOCK PROBE defers if claude is busy | new fedora-dev image from GHCR |

The fedora-dev container recreate is the only path that's external to fedora-dev itself — see `fedora-bootstrap` for the host-side `container-refresh.sh` + systemd timer that owns it.

Base bump: `ARG FEDORA_VERSION` in Containerfile (Fedora releases EOL ~13 months — bump about twice a year, re-verifying vendor repos per principle 4). The box's `image=` line in `distrobox.ini` (fedora-toolbox tag) must be bumped in lockstep.
