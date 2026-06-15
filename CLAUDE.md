# fedora-dev — agent rules for editing this repo

## BEFORE ANY CHANGE

Read README.md for human-facing context (what fedora-dev is, what it
provides, how operators use it, the design summary). THIS file carries the
binding agent-facing tables (BUILD PRINCIPLES, BASE PACKAGES, BOX PACKAGES,
REPO FILE PURPOSES) and the in-repo procedures.

`policy/CLAUDE.md` + `policy/managed-settings.json` are the law stamped into
the in-container claudebox at runtime — editing them in THIS repo is the ONLY
way they change.

## TWO LAYERS, TWO CADENCES, TWO SOURCES OF TRUTH

- **fedora-dev base image** — `Containerfile` + `install.sh` + `entrypoint.sh`
  + `bin/` wrappers + the baked seed at `/usr/local/share/fedora-dev/`.
  Rebuilt **monthly** on the 15th by CI (`--no-cache`). Changes flow: edit →
  PR → merge → CI build → cosign-sign → GHCR `:latest` → host-side refresh
  recreates the running container.

- **claudebox (in-container Distrobox)** — `distrobox.ini` +
  `claudebox-init.sh` + `box-rebuild.sh` + `claudebox-daily.sh` +
  `claudebox-assemble.sh` + `policy/`. The runtime source of truth is the
  LIVE git clone at `/home/core/.local/share/fedora-dev/` inside the running
  fedora-dev container, NOT the baked seed. Rebuilt **daily** in-container
  plus on-demand. Changes flow: edit (in the live clone, inside the agent's
  session) → PR → merge → next rebuild applies.

The live spec on the home volume persists across BOTH box rebuilds AND
fedora-dev container recreations. That's the design that lets mid-cycle
edits survive monthly base recreates without losing work.

## PROPOSE-AND-COMMIT (binding for the in-box agent)

Durable changes to fedora-dev itself flow through git:

1. Edit the LIVE clone at `~/.local/share/fedora-dev/` (inside the agent's
   session, on the home volume — persists across rebuilds).
2. `gh pr create` from the clone.
3. Human merges.
4. Next claudebox rebuild applies the merged change. CI rebuilds the base
   image with the new baked seed on its own monthly cadence.

Ad-hoc `dnf install` or `dnf remove` inside the running box works for the
current session but VANISHES on the next rebuild — by design. That's the
discipline that keeps the box reproducible.

## BUILD PRINCIPLES (binding for every code change)

| # | Principle | Rule |
|---|---|---|
| 1 | BASE | Build only from the official `registry.fedoraproject.org/fedora:${FEDORA_VERSION}` image. Version is a Containerfile `ARG` — never inlined. |
| 2 | SOURCES | Every package from an official source, exactly one of: (a) Fedora's own repos via dnf; (b) the vendor's/developer's own RPM or dnf repo (`.repo` with `gpgcheck=1`); (c) at worst, a developer/vendor-released AppImage (sha256 logged). Never: COPR or other third-party repos, pip/npm/cargo/brew installs, curl-pipe-sh, tarball drops. **Applies to BOTH the base image AND claudebox's `additional_packages`.** Exceptions only by explicit user waiver, recorded as a new row in the relevant Packages table. **Current waivers: none.** |
| 3 | MINIMAL | dnf only with `--setopt=install_weak_deps=False`. Every package gets a justifying row in the relevant Packages table (BASE or BOX); a package without a row is a violation. |
| 4 | VERIFY FIRST | Before adopting or bumping any source/version, fact-check it against the live source (web). Gate risky installs (version-mismatched vendor RPMs, new repos) in a scratch container before editing build files. |
| 5 | NO SECRETS / NO IDENTITY | No passwords, keys, or personal usernames in any layer, file, or commit. Container user is the generic `core` (uid 1000). Credentials enter only as runtime env vars; entrypoint fails fast when missing. |
| 6 | PINS | Vendor artifact versions are Containerfile `ARG`s or pinned in `distrobox.ini` — bump there only, after rule 4. |
| 7 | DEPLOY CONTRACT | Every image (this one and downstream) ships a `run.sh` that is the only sanctioned way to run it: runtime `--health-cmd` (OCI drops Containerfile HEALTHCHECK), devices, volumes, restart policy. Sensitive ports (ssh/RDP/VNC) stay tailnet-only — never `-p`. The Quadlet at the repo top is the systemd-managed equivalent. |
| 8 | CI + LAYERED CADENCE | `.github/workflows/build.yml` publishes the base image to GHCR + cosign-signs it: on push, on the 15th monthly (`--no-cache`), and on manual dispatch. Built-in token only. The IN-CONTAINER claudebox refreshes daily on its own timer + ad-hoc triggers; it never touches CI. |
| 9 | VALIDATE | After any change: build, deploy via `run.sh`, confirm `(healthy)` plus a functional probe of each access path. Final proof is CI green + a host deploy from claudebox-on-the-host. |
| 10 | PROPOSE-AND-COMMIT | The in-box agent grows `distrobox.ini`/`policy/`/`box-rebuild.sh`/etc. only by editing the LIVE clone at `/home/core/.local/share/fedora-dev/` and opening a PR. The human merges; the next box rebuild applies. Ad-hoc installs vanish on rebuild. |

## BASE PACKAGES

The fedora-dev image itself. Refreshed monthly via CI.

| Package | Pin | Source (rule 2 class) | Why required |
|---|---|---|---|
| podman | Fedora current | distro (a) | the container ENGINE — claudebox runs on it; the agent's `podman build` lands here via CONTAINER_HOST |
| shadow-utils | Fedora current | distro (a) | newuidmap/newgidmap setuid helpers — mandatory for nested rootless podman |
| fuse-overlayfs | Fedora current | distro (a) | nested rootless storage driver (kernel forbids native overlay-on-overlay) |
| passt | Fedora current | distro (a) | pasta — podman 5 default rootless network backend |
| iptables-nft, nftables | Fedora current | distro (a) | tailscaled programs the firewall; crashes without the binaries |
| openssh-server | Fedora current | distro (a) | the login door (key-only since v1.1.9; keys synced from `github.com/<user>.keys` by entrypoint at every start). Two paths into :22 — Tailscale SSH on tailnet (keyless) AND public ssh on host :4444 → container :22. mosh bootstraps over either ssh path. |
| mosh | Fedora current | distro (a) | roaming-resilient remote shell (UDP, AEAD-authenticated; bootstraps over ssh). v1.1.9: public UDP range 61001-62000 (non-default, to avoid colliding with the bootstrap host's own public mosh which uses 60000-61000 on the same kernel UDP namespace); clients invoke with `mosh -p 61001:62000 --ssh="ssh -p 4444"` for the public path. |
| tailscale | Tailscale dnf/rpm repo | vendor (b) | tailnet node + keyless Tailscale SSH on the tailnet IP (primary access path). Co-exists with public ssh :4444 + public mosh 61001-62000 added in v1.1.9. |
| tmux | Fedora current | distro (a) | session multiplexer; every interactive login auto-attaches `main`. Trigger-and-detach is the operator pattern. |
| distrobox | Fedora current | distro (a) | declaratively bootstraps the in-container claudebox via `distrobox assemble create --file distrobox.ini` |
| inotify-tools | Fedora current | distro (a) | `inotifywait` in the entrypoint watches `rebuild.request` flag from the in-box agent (replaces systemd `.path` unit; no systemd here by design) |
| fail2ban | Fedora current | distro (a) | brute-force mitigation on the public ssh path (host :4444 → container :22, key-only). Watches `/var/log/secure`, bans IPs via iptables-nft. Tailnet CGNAT 100.64.0.0/10 is `ignoreip`'d. |
| rsyslog | Fedora current | distro (a) | captures sshd's `AUTHPRIV` events to `/var/log/secure` so fail2ban can read them (no systemd-journald in this container) |
| sudo | Fedora current | distro (a) | break-glass escalation for the operator (`core` in `wheel`). v1.1.9: no password set on `core` (chpasswd dropped), so sudo is effectively unreachable for the human; break-glass is `podman exec -u 0 fedora-dev bash` from the VPS host. Kept for completeness; near-zero footprint. |
| procps-ng | Fedora current | distro (a) | `pgrep` for the entrypoint watchdog AND for `run.sh`'s `--health-cmd` |
| glibc-langpack-en | Fedora current | distro (a) | UTF-8 rendering for tmux and the terminal observing Claude's output |
| nano | Fedora current | distro (a) | one break-glass editor (Fedora 44's minimal base doesn't reliably ship `vi`). ~600KB |

## BOX PACKAGES

Inside claudebox (`distrobox.ini`'s `additional_packages`). Refreshed daily from Anthropic's `latest` channel + Fedora repos.

| Package | Pin | Source (rule 2 class) | Why required |
|---|---|---|---|
| claude-code | Anthropic dnf/rpm repo (`latest` channel) | vendor (b) | the agent — claudebox's purpose; refreshed daily so new model releases are accessible day one |
| git | Fedora current | distro (a) | VCS engine the agent drives. Inside the box because the agent's shell is in the box |
| gh | GitHub dnf/rpm repo | vendor (b) | GitHub/GHCR auth, PRs (propose-and-commit lifecycle), releases. Auth state at `~/.config/gh/` lives on the home volume — shared across box rebuilds |
| openssh-clients | Fedora current | distro (a) | outbound ssh for git-over-ssh from inside the box |
| podman (client) | Fedora current | distro (a) | the agent's `podman build/run/exec/healthcheck`. Engine is at fedora-dev's level; CLI in the box drives it via `CONTAINER_HOST` |
| bubblewrap | Fedora current | distro (a) | Linux user-namespace sandbox; Claude Code's Bash tool uses it for isolated execution |
| socat | Fedora current | distro (a) | paired with bubblewrap for IPC socket relay into/out of the sandbox |
| host-spawn | Fedora current | distro (a) | distrobox container-side host-exec component. Headless = no flatpak-session-helper, so the actual shims are deliberately NOT wired up; presence prevents distrobox-create from `curl`'ing it from GitHub releases (rule 2 source-control) |
| rclone | Fedora current | distro (a) | the agent's cloud/SMB/SSH/object-store reach for build files on other network drives |

## REPO FILE PURPOSES

| File | Purpose |
|---|---|
| README.md | human-facing project doc (purpose, deploy, operate, design appendix) |
| CLAUDE.md | this file — agent rules for editing this repo |
| Containerfile | base image build spec (FROM fedora:ARG; runs install.sh; COPY's entrypoint + scripts + bin/) |
| install.sh | base image install (Fedora repo + Tailscale repo dnf installs; nested-podman config; sshd config; defensive setcap on newuidmap/newgidmap) |
| entrypoint.sh | PID 1 (root): supervises sshd + tailscaled + rootless podman API socket + inotify rebuild-flag watcher + daily-tick + first-boot live-clone-or-seed + eager first-boot claudebox assemble; pgrep+kill-0 watchdog; SIGTERM trap for clean shutdown |
| run.sh | manual deploy contract (`podman run -d`-style with --health-cmd, devices, volumes); fallback for non-systemd hosts |
| fedora-dev.container | systemd Quadlet for managed deployment (declarative spec with AutoUpdate=registry, Notify=healthy, HealthCmd, Volume=, EnvironmentFile=) |
| distrobox.ini | claudebox manifest: image pin, pre_init_hook drops Anthropic `latest`-channel `.repo`, additional_packages |
| claudebox-init.sh | post-assemble host bridges (CONTAINER_HOST export + in-box `claudebox-rebuild` flag-writer). Runs over quote-safe `distrobox enter -- sudo` channel |
| claudebox-assemble.sh | called by entrypoint on first boot + by box-rebuild on every rebuild: `distrobox rm -f` (recovery) → `distrobox assemble create` → first-enter retry → bridges + policy stamp |
| box-rebuild.sh | full claudebox rebuild (self-serializing via flock); triggered by daily tick / in-box flag / host-shell command — all converge here |
| claudebox-daily.sh | daily-refresh decision: probe session lock → rebuild now if idle, else write `rebuild.pending` marker (the `claude` wrapper fires it on session exit) |
| bin/claude | host-shell wrapper; holds SHARED session lock for session lifetime so daily refresh + host's monthly fedora-dev refresh defer while live; on exit fires deferred rebuild atomically |
| bin/claudebox-rebuild | host-shell trigger; starts box-rebuild.sh detached + tails the log |
| policy/CLAUDE.md | runtime law for the in-claudebox agent (its role, do/don't, propose-and-commit, validation discipline) |
| policy/managed-settings.json | deny-rule guardrails (defense-in-depth) + bypass-permissions disabled (managed tier) |
| .github/workflows/build.yml | CI: on push + 15th monthly (--no-cache) + manual; build-push-action + cosign keyless signing via OIDC |

## NESTED BUILDS — CONTAINER_HOST BRIDGE (reference)

As `core` inside claudebox: `podman build/run/exec/healthcheck` works because `CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock` is exported in `/etc/profile.d/10-host-podman.sh` (written by `claudebox-init.sh` post-assemble). That socket is **fedora-dev's** rootless podman API socket, served by `podman system service` supervised in the entrypoint. distrobox bind-mounts `/run/user/1000/` from fedora-dev into the box at the same path.

Result: `podman build .` inside the box runs in **fedora-dev's engine** (one level of nesting, fuse-overlayfs storage on the home volume at `~/.local/share/containers/`), NOT in another nested engine inside the box. Storage, layer cache, built images, and stopped containers persist across box rebuilds AND across fedora-dev container recreations.

Subuid/subgid: `core:10000:55000` (sized to fit the outer rootless 65536-ID map; inner chowns to uid ≥ 55001 will fail — enlarge the host range first if ever needed).

No systemd inside fedora-dev: cgroupfs manager + file events logger preconfigured; XDG_RUNTIME_DIR provided by the entrypoint; the rebuild-trigger machinery is supervised by the entrypoint's pgrep watchdog instead of systemd units.

## CADENCE REFERENCE

| Layer | Cadence | Trigger | Source |
|---|---|---|---|
| Base image (RPM updates) | Monthly (15th @ 04:00 UTC) | CI cron `--no-cache` | Fedora + tailscale repos |
| Base image (spec changes) | On push to `main` | CI `on: push` | merged PRs from in-box agent |
| Claudebox (CLI + tools) | Daily (~04:00) | in-container `claudebox-daily.sh`; defers if session active | Anthropic `latest` channel + Fedora repos |
| Claudebox (ad-hoc) | On demand | in-box `claudebox-rebuild` OR host-shell `claudebox-rebuild` | same as daily |
| fedora-dev container itself | Operator-driven (or host cron) | safe-refresh on monthly cadence; SESSION-LOCK PROBE defers if claude is busy | new fedora-dev image from GHCR |

Base bump (Fedora 44 → 45): `ARG FEDORA_VERSION` in Containerfile is the single source of truth. The box's `image=quay.io/fedora/fedora-toolbox:N` line in distrobox.ini must bump in lockstep. Fedora releases EOL ~13 months — plan for twice a year, re-verifying vendor repos per Build Principle 4.
