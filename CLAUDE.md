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
3. `fedora-dev` merges on Arthur's clickable APPROVE (or Arthur merges) — see THE FLEET in policy/CLAUDE.md.
4. Next claudebox rebuild applies the merged change. CI rebuilds the base
   image with the new baked seed on its own monthly cadence.

**Host live-gate — label a PR `live-validate`.** To have the host build + live-test a candidate
BEFORE it reaches Arthur, label the PR `live-validate`. The host (fedora-bootstrap) builds the
candidate DISPOSABLY, runs Gate B (health + access-probe), and posts a **GREEN/RED verdict comment**
on the PR automatically — while you keep working (it runs a throwaway container and never touches
your session, so an active dev session never blocks it). Iterate on RED (push a fix → the new commit
re-gates); present only a GREEN PR for Arthur's APPROVE. The host **comments, NEVER merges**.
(Optional: ship a `.live-gate` file at the repo top to override the host's default fence/probe for
this workload.)

Ad-hoc `dnf install` or `dnf remove` inside the running box works for the
current session but VANISHES on the next rebuild — by design. That's the
discipline that keeps the box reproducible.

## TICKETS & THE DEV LOOP (my role)

I am **DEVELOP · BUILD · MERGE** and the fleet's **SOLE merge authority**. The **PR is the ticket** — there is no separate tracker; an open PR against `main` is both the work item and the handoff token. My place in the loop (the full fleet map is `FLEET.md`):

1. **Develop → open PR.** Edit the LIVE clone, `gh pr create` (see PROPOSE-AND-COMMIT). The PR is the ticket.
2. **Request a host verdict — label `live-validate`.** This enrolls the PR in the host pre-merge live-gate. `fedora-bootstrap` runs `live-gate-watch.sh` (its `live-gate-watch.timer`, 15 s poll), which for each new head SHA (deduped once via `~/.local/state/live-gate/<WL>-<sha>.done`) builds a **disposable** candidate (`build-candidate.sh` → `localhost/disposable/<name>:val-<sha>`, never pushed) and runs **Gate B** (`validate-candidate.sh`: health + access-probe), then posts a `Host live-gate (Gate B): VERDICT GREEN|RED` comment on the PR. (Optional: ship a `.live-gate` file at the repo top to override the host's default fence/probe.) My own `build.yml` runs build-only on the PR (`push=false`) — that proves it *builds*; the host verdict proves it *runs*.
3. **Iterate on RED.** Push a fix commit; the new head SHA has no `.done` marker, so the host re-gates exactly once and re-comments. Loop until GREEN.
4. **Present only GREEN.** I list a repo's open PRs and present them to Arthur **one at a time as a discrete clickable decision**, diff shown. A free-text "yes" is **not** approval.
5. **Merge on APPROVE.** On Arthur's click I merge to `main` — **any PR, any author including my own, control-plane PRs included**. Control-plane PRs additionally need the human-applied `control-plane-approved` label for `build.yml`'s `control-plane-guard` to pass; they merge on the **same single click**, standalone, never bundled. My `gate-push.sh` routes every detected push/merge to an interactive `ask` prompt only Arthur can answer; I cannot self-approve. Arthur may also merge on GitHub himself.
6. **Hands off after merge.** Push to `main` triggers CI build + cosign-sign + GHCR publish; `fedora-bootstrap` pulls + redeploys via `workload-refresh@<name>`. I never operate, deploy, or `podman build` a shipping image — those are STOP-AND-SURFACE to `fedora-bootstrap` / CI.

**Paused-work / cross-box requests** ride a **GitHub Issue** in the target repo (a convention, not automation): when work parks mid-flight or another box surfaces a fix for a repo I own, the Issue carries the request + proposed diff; I turn it into a branch + PR, re-entering at step 1.

## HEADLESS (binding prerequisite)

fedora-dev runs **fully headless** — no physical monitor, GPU, or local login seat is ever
attached or required. The harness (the claudebox + the supervised services) needs no display, and
every desktop image built ON this base (the fedora-desktop **xrdp** and **grd** lineages) is
likewise headless — a *virtual* display rendered by software GL (llvmpipe), reached only over the
network (ssh / RDP / VNC / web). A change that makes any part depend on a real display, GPU, or
physical seat is a **defect**, not an option.

## BUILD PRINCIPLES (binding for every code change)

| # | Principle | Rule |
|---|---|---|
| 1 | BASE | Build only from the official `registry.fedoraproject.org/fedora:${FEDORA_VERSION}` image. Version is a Containerfile `ARG` — never inlined. |
| 2 | SOURCES | Every package/artifact from an official source, exactly one of: (a) Fedora's own repos via dnf; (b) the vendor's/developer's own RPM or dnf repo (`.repo` with `gpgcheck=1`); (c) an **official-upstream binary release artifact with NO class-(a)/(b) source** — bounded by the **Class-(c) rules** below (last-resort/zero-base; publisher GPG-signature-or-checksum-verified, fail-closed; one of three self-contained consumption shapes; never loose on `$PATH`; disclosed per-artifact). Never: COPR or other third-party repos, pip/npm/cargo/gem/brew installs, curl-pipe-sh, tarball-on-PATH, flatpak, snap. **Applies to BOTH the base image AND claudebox's `additional_packages`.** Anything outside (a)/(b)/(c)-as-scoped needs an explicit user waiver row. **Class-(c) artifacts in use: none.** |
| 3 | MINIMAL | dnf only with `--setopt=install_weak_deps=False`. Every package gets a justifying row in the relevant Packages table (BASE or BOX); a package without a row is a violation. **Install the most specific (leaf) package, never a convenience metapackage, unless a recorded architectural reason. `install_weak_deps=False` blocks weak Recommends but NOT a metapackage's hard Requires — so a metapackage can silently pull unused components (e.g. the `fail2ban` metapackage hard-pulls `fail2ban-firewalld`→`firewalld` + `fail2ban-sendmail`→`esmtp`; install `fail2ban-server`). If unsure whether a name is a metapackage, verify (`dnf repoquery --requires <pkg>`) and flag before adding.** **"MINIMUM" IS RELATIVE TO THE CHOSEN CAPABILITY, not the absolute package count.** Once a capability is decided (e.g. a working desktop; an RDP-grade web gate), install the minimal LEAF footprint that makes THAT capability work, and accept + DISCLOSE the irreducible hard-dependency closure it entails (e.g. a `gnome-shell` desktop→webkit + `gnome-control-center`; a KDE desktop→samba/codec). Between options that deliver the SAME capability, prefer the smaller-footprint / built-in / class-(a) one. A lighter option that REDUCES the capability is NOT "more minimal" — it is a lesser function, and choosing it is a recorded capability trade-off, NOT a minimalism win. (Worked decision in fedora-desktop: Guacamole [RDP-grade web gate — H.264/audio/clipboard/file-transfer in the browser, strong password + brute-force lockout] is the SOLE web gate; noVNC [VNC-grade] was removed fleet-wide — a public, non-tailnet door needs strong auth and noVNC's 8-char VncAuth is unacceptable there — so Guacamole's Tomcat + JVM + `.war` footprint IS the minimum for full strongly-authed RDP-in-the-browser.) |
| 4 | VERIFY FIRST | Before adopting or bumping any source/version, fact-check it against the live source (web). Gate risky installs (version-mismatched vendor RPMs, new repos) in a scratch container before editing build files. |
| 5 | NO SECRETS / NO IDENTITY | No passwords, keys, or personal usernames in any layer, file, or commit. Container user is the generic `core` (uid 1000). Credentials enter only as runtime env vars; entrypoint fails fast when missing. |
| 6 | PINS | Vendor artifact versions are Containerfile `ARG`s or pinned in `distrobox.ini` — bump there only, after rule 4. |
| 7 | DEPLOY CONTRACT | Every image ships a `run.sh` — the only sanctioned **non-interactive** way to run it: runtime `--health-cmd` (OCI drops Containerfile HEALTHCHECK), devices, volumes, restart policy, port set. An optional **`spin-up.sh`** wizard wraps it to ASK for `TS_AUTHKEY`/`IMAGE` interactively (blank key = `login.tailscale.com` web-login), but only ever delegates to `run.sh` — run.sh stays the single source of runtime truth. Sensitive ports (ssh/RDP/VNC) stay tailnet-only — never `-p`. The Quadlet is the systemd-managed equivalent. Never hand-roll `podman run`. |
| 8 | CI + LAYERED CADENCE | `.github/workflows/build.yml` publishes the base image to GHCR + cosign-signs it: on push, on the 15th monthly (`--no-cache`), and on manual dispatch. Built-in token only. The IN-CONTAINER claudebox refreshes daily on its own timer + ad-hoc triggers; it never touches CI. |
| 9 | VALIDATE | After any change: build, deploy via `run.sh`, confirm `(healthy)` plus a functional probe of each access path. Final proof is CI green + a host deploy from claudebox-on-the-host. |
| 10 | PROPOSE-AND-COMMIT | The in-box agent grows `distrobox.ini`/`policy/`/`box-rebuild.sh`/etc. only by editing the LIVE clone at `/home/core/.local/share/fedora-dev/` and opening a PR. `fedora-dev` merges on Arthur's clickable APPROVE; the next box rebuild applies. Ad-hoc installs vanish on rebuild. |

### Class-(c) sources — the bounded last-resort exception (fleet-wide; identical in fedora-desktop + fedora-dev + fedora-bootstrap)

**(c)** ONLY when **no class-(a) Fedora package and no class-(b) vendor `.repo`** exists for the
needed artifact — a **last-resort, zero-base check, re-confirmed at every version bump**; the
moment it appears in Fedora or a vendor `.repo` it MUST move to (a)/(b): an **official-upstream
binary release artifact**, fetched over TLS from the project's **own canonical release channel**
— whose exact host + org/repo (or release-API URL) is **pinned in the disclosure row and
changeable only as a control-plane change** — never a mirror, aggregator, COPR, PPA, OBS home
project, language-package-manager registry (Maven Central/npm/PyPI/crates.io/RubyGems), or
third-party rebuild. Each artifact MUST be **(1) version-pinned** via a Containerfile `ARG` (or
`distrobox.ini` pin), the SOLE exception being an artifact Principle 6 designates
latest-at-build; and **(2) integrity-verified before any use** — against the publisher's **GPG
signature** (`gpg --verify`, key fingerprint pinned in-repo) **whenever one is published**; a
bare `sha*sum -c` is acceptable **only** when the project publishes no signature; the build
**fails closed** on any mismatch / missing / unfetchable check. *(For a latest-at-build artifact
where no hash can be pre-pinned: TLS-authenticated fetch from the publisher's own release API +
**resolve-and-log** — an auditable record, NOT a fail-closed gate; reserved to explicitly-named
latest-at-build artifacts only.)* The artifact may be consumed in **exactly one of three
self-contained shapes**: (i) a developer/vendor **AppImage** run from `/opt` (never a bare
ELF/script/tarball); (ii) a webapp/archive **deployed into a class-(a) runtime** (an Apache
`.war` into Fedora's Tomcat); or (iii) a **build-time-only tool** that is itself (c)-verified,
transforms a named (c) artifact, fetches no further network, installs nothing onto `$PATH`, runs
deterministically, and is deleted. **A loose executable / script / tarball on `$PATH` is NEVER
permitted under (c).** Each (c) artifact gets a **disclosure row** in the Packages table (pinned
canonical URL + version + signature/checksum kind); the table's **enumeration line lists every
(c) artifact in use**. **Mechanical backstop (CI):** the control-plane diff-guard asserts every
binary on `$PATH` resolves to an rpm (`rpm -qf`).

**Class-(c) artifacts in use: none.** This repo ships no upstream binary artifact today; the rule
is carried for fleet parity so any future need inherits the identical bounded definition. (The
only repo with class-(c) artifacts is fedora-desktop: `guacamole.war` + Obsidian.)

## BASE PACKAGES

The fedora-dev image itself. Refreshed monthly via CI.

| Package | Pin | Source (rule 2 class) | Why required |
|---|---|---|---|
| podman | Fedora current | distro (a) | the container ENGINE — claudebox runs on it; the agent's `podman build` lands here via CONTAINER_HOST |
| shadow-utils | Fedora current | distro (a) | newuidmap/newgidmap setuid helpers — mandatory for nested rootless podman |
| fuse-overlayfs | Fedora current | distro (a) | nested rootless storage driver (kernel forbids native overlay-on-overlay) |
| passt | Fedora current | distro (a) | pasta — podman 5 default rootless network backend |
| nftables | Fedora current | distro (a) | the firewall backend. tailscaled programs its rules via the nftables **Netlink API** (no binary needed; it falls back to nftables and never crashes if iptables is absent — verified on the bootstrap host, which runs tailscaled with zero iptables); netavark's default firewall driver (nftables since Fedora 41); fail2ban bans via `nftables[type=multiport]`. (`iptables-nft` dropped — the prior "tailscaled crashes without the binaries" rationale was false.) |
| openssh-server | Fedora current | distro (a) | the login door (key-only since v1.1.9; keys synced from `github.com/<user>.keys` by entrypoint at every start). Two paths into :22 — Tailscale SSH on tailnet (keyless) AND public ssh on host :4444 → container :22. mosh bootstraps over either ssh path. |
| mosh | Fedora current | distro (a) | roaming-resilient remote shell (UDP, AEAD-authenticated; bootstraps over ssh). v1.1.9: public UDP range 61001-62000 (non-default, to avoid colliding with the bootstrap host's own public mosh which uses 60000-61000 on the same kernel UDP namespace); clients invoke with `mosh -p 61001:62000 --ssh="ssh -p 4444"` for the public path. |
| tailscale | Tailscale dnf/rpm repo | vendor (b) | tailnet node + keyless Tailscale SSH on the tailnet IP (primary access path). Co-exists with public ssh :4444 + public mosh 61001-62000 added in v1.1.9. |
| tmux | Fedora current | distro (a) | session multiplexer; every interactive login gets its OWN session in the shared `main` group (shared windows/work, independent per-client geometry — kills the multi-client resize-race garble), with a `/etc/tmux.conf` (default-terminal `tmux-256color`, `window-size smallest`, `aggressive-resize on`, `client-attached`/`-resized`→`refresh-client`). Trigger-and-detach is the operator pattern. |
| distrobox | Fedora current | distro (a) | declaratively bootstraps the in-container claudebox via `distrobox assemble create --file distrobox.ini` |
| inotify-tools | Fedora current | distro (a) | `inotifywait` in the entrypoint watches `rebuild.request` flag from the in-box agent (replaces systemd `.path` unit; no systemd here by design) |
| fail2ban-server | Fedora current | distro (a) | brute-force mitigation on the public ssh path (host :4444 → container :22, key-only). Watches `/var/log/secure`, bans IPs via `nftables[type=multiport]` (nft-only — no iptables in the image). Tailnet CGNAT 100.64.0.0/10 is `ignoreip`'d. The **leaf** package, NOT the `fail2ban` metapackage (which hard-pulls `fail2ban-firewalld`→`firewalld` + `fail2ban-sendmail`→`esmtp` — unused; `install_weak_deps=False` does not block hard Requires; see Build Principle 3). |
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
| spin-up.sh | interactive spin-up wizard (the by-hand entry point): ASKS for `TS_AUTHKEY` (blank = web-login fallback) + `IMAGE`, exports them, then `exec`s run.sh. Mirrors `fedora-desktop/spin-up.sh`; run.sh stays the non-interactive contract it delegates to |
| run.sh | manual deploy contract (`podman run -d`-style with --health-cmd, devices, volumes); the env-driven path `spin-up.sh` wraps; fallback for non-systemd hosts |
| fedora-dev.container | systemd Quadlet for managed deployment (declarative spec: AutoUpdate=registry, Notify=healthy, HealthCmd, Volume=, SecurityLabelDisable=true; **NO EnvironmentFile** — key-only sshd since v1.1.9, optional TS_AUTHKEY via podman `Secret=`) |
| distrobox.ini | claudebox manifest: image pin, pre_init_hook drops Anthropic `latest`-channel `.repo`, additional_packages |
| claudebox-init.sh | post-assemble host bridges (CONTAINER_HOST export + in-box `claudebox-rebuild` flag-writer). Runs over quote-safe `podman exec` (container-root) channel |
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

### In-box candidate validation — capability boundary + `bin/validate.sh`

The nested engine's RUN support is **narrower** than the "build/run/exec works" line above; `bin/validate.sh` gates exactly the tiers that are faithful at this nesting depth (autonomously established):

- **BUILD — requires `--isolation=chroot`.** A default-isolation build RUN step fails with `mount 'proc' to 'proc': Operation not permitted` (the build container can't mount a fresh `/proc` at this depth). `--isolation=chroot` runs RUN steps in a chroot (no new mount/pid ns) and succeeds.
- **ASSEMBLY — works.** `podman create` + `podman export | tar -t` + content inspection (no run): the reliable structural check.
- **ISOLATED LIVE RUN — blocked.** A container with its OWN netns hits `/proc/sys/net/ipv4/ping_group_range: Read-only file system`; its OWN pidns hits the same `mount proc` denial. Only a **degraded** `--network=host --pid=host` run works (shared namespaces → ambiguous probes + flaky teardown), so live-run is **best-effort / non-gating** in-box.
- **Faithful live validation belongs on the host** (own namespaces, one less nesting level) — the existing post-merge `container-refresh` health-gate + digest-rollback. The in-box harness gates build+assembly+lint; the host gates live.

`bin/validate.sh <repo-dir> [Containerfile] [build|nobuild]` → per-tier PASS/FAIL + a GREEN/RED verdict the agent iterates on, with no host and no human in the loop. **Repo-agnostic** (validates fedora-dev AND workload repos): auto-detects a **systemd-PID-1** lineage (`ENTRYPOINT /sbin/init` / `STOPSIGNAL SIGRTMIN+3`) and skips the degraded smoke for it (→ assembly-only in-box; its live gate is the host); lints **every shipped `*.sh`**; passes per-repo build-args via `$BUILD_ARGS`. **Host-immutable:** builds into an ephemeral image tree in the dev box's OWN nested engine (never the host live tree), tears down smoke containers on exit, and `DISCARD=1` removes the candidate image after testing. Tested GREEN on fedora-dev + both fedora-desktop lineages (xrdp + grd).

## CADENCE REFERENCE

| Layer | Cadence | Trigger | Source |
|---|---|---|---|
| Base image (RPM updates) | Monthly (15th @ 04:00 UTC) | CI cron `--no-cache` | Fedora + tailscale repos |
| Base image (spec changes) | On push to `main` | CI `on: push` | merged PRs from in-box agent |
| Claudebox (CLI + tools) | Daily (~04:00) | in-container `claudebox-daily.sh`; defers if session active | Anthropic `latest` channel + Fedora repos |
| Claudebox (ad-hoc) | On demand | in-box `claudebox-rebuild` OR host-shell `claudebox-rebuild` | same as daily |
| fedora-dev container itself | Operator-driven (or host cron) | safe-refresh on monthly cadence; SESSION-LOCK PROBE defers if claude is busy | new fedora-dev image from GHCR |

Base bump (Fedora 44 → 45): `ARG FEDORA_VERSION` in Containerfile is the single source of truth. The box's `image=quay.io/fedora/fedora-toolbox:N` line in distrobox.ini must bump in lockstep. Fedora releases EOL ~13 months — plan for twice a year, re-verifying vendor repos per Build Principle 4.
