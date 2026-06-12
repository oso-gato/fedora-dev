# fedora-dev

## Objective

**Run Claude Code to build container images.** A headless workshop: you
attach over ssh or mosh across the tailnet and land in tmux automatically (every interactive login attaches to session "main"), and
drive Claude Code with podman, git, and gh to build and publish Fedora-based
images. tmux is always the innermost layer — mosh makes the connection resilient,
but even when a connection dies, the tmux session and whatever Claude Code
was doing in it survive untouched.

## Build Principles (binding — follow verbatim for any change to this image)

| # | Principle | Rule |
|---|---|---|
| 1 | BASE | Build only from the official base image `registry.fedoraproject.org/fedora:${FEDORA_VERSION}`. The version is a Containerfile `ARG` where applicable; never inline pinned versions. |
| 2 | SOURCES | Every package from an official source, exactly one of: (a) the distro's own repos; (b) the vendor's own package repo; (c) an artifact released by the developer themselves. Never: third-party repos, npm/pip installs, `curl \| sh`. Exceptions only by explicit user waiver, recorded in the Packages table. Current waivers: none. |
| 3 | MINIMAL | Install only what is required (`--setopt=install_weak_deps=False`). Every package must have a row in the Packages table justifying it; adding a package without a row is a violation. |
| 4 | VERIFY FIRST | Before changing any source or version, fact-check it against the live source (web). Gate risky installs (version-mismatched vendor packages, new repos) in a scratch container before editing build files. |
| 5 | NO SECRETS / NO IDENTITY | No passwords, keys, or personal usernames in any layer, file, or commit. Container user is the generic `core` (uid 1000). Credentials enter only as runtime env vars; the entrypoint must fail fast if they are missing. |
| 6 | PINS | Vendor artifact versions are Containerfile `ARG`s — bump there only, after rule 4. |
| 7 | DEPLOY | Only via `./run.sh` — it carries the runtime `--health-cmd` (OCI images silently drop Containerfile HEALTHCHECK), devices, volumes, and restart policy. Never hand-roll `podman run`. Sensitive ports (RDP/VNC/ssh) stay tailnet-only — never publish them with `-p`. |
| 8 | CI | Published via `.github/workflows/build.yml` to GHCR — on push, on the 1st/15th monthly (`--no-cache`), and on manual dispatch. CI uses the built-in token only; never add credentials. |
| 9 | VALIDATE | After any change: build, deploy via run.sh, confirm `(healthy)` plus a functional probe of each access path before declaring success. |

## Packages

| Package | Pin | Source (rule 2 class) | Why required |
|---|---|---|---|
| podman | Fedora current | distro (a) | builds/pushes other images — the image's purpose (covers buildah/skopeo use-cases) |
| shadow-utils | Fedora current | distro (a) | newuidmap/newgidmap setuid helpers — mandatory for nested rootless podman |
| fuse-overlayfs | Fedora current | distro (a) | nested rootless storage driver (kernel forbids native overlay-on-overlay) |
| passt | Fedora current | distro (a) | pasta — podman 5 default rootless network backend |
| iptables-nft, nftables | Fedora current | distro (a) | tailscaled programs the firewall; crashes without the binaries |
| openssh-server | Fedora current | distro (a) | the login door: mosh bootstraps over ssh; tmux auto-attach fires on every interactive login |
| openssh-clients | Fedora current | distro (a) | outbound ssh: git-over-ssh, reaching other hosts |
| claude-code | Anthropic dnf/rpm repo | vendor (b) | requested app |
| tailscale | Tailscale dnf/rpm repo | vendor (b) | tailnet access — the only exposure path for :22/:2022 |
| gh | GitHub dnf/rpm repo | vendor (b) | GitHub/GHCR auth, PRs, releases (delegates VCS to git) |
| mosh | Fedora current | distro (a) | roaming-resilient remote shell (UDP, AEAD-authenticated; bootstraps over ssh) |
| rclone | ARG `RCLONE_VERSION` | developer (c) | requested app |
| tmux, fastfetch | Fedora current | distro (a) | requested apps |
| git | Fedora current | distro (a) | the VCS engine gh and Claude Code drive; CI pushes |
| sudo, procps-ng, glibc-langpack-en, less, nano | Fedora current | distro (a) | non-root admin; pgrep for watchdog+health; UTF-8 TUI rendering; pager; one small editor |

## Deploy

```sh
CORE_PASSWORD='…' [TS_AUTHKEY=tskey-…] ./run.sh
```

- The entrypoint refuses to start without `CORE_PASSWORD` (login for `core`
  over ssh/mosh) — a published image can never carry a default credential.
- Connect: `ssh core@<tailnet-ip>` or `mosh core@<tailnet-ip>` — both land in
  tmux session "main". Ports (22/tcp, 60000-61000/udp) tailnet-only — never publish.
- Volumes: `fedora-dev-home` (/home/core), `fedora-dev-state` (tailscale state + ssh host keys,
  root-owned so the unprivileged user cannot swap host keys).
- Tailscale SSH is enabled (`--ssh`): once joined, any tailnet device can
  `ssh core@<hostname>` keylessly — auth is your tailnet identity (lands in
  tmux where the image has the auto-attach drop-in).
- Tailnet join link: `tailscale status` in any shell inside the container.

## Nested builds (inside the container)

As `core`: `podman build/push` just works — storage in
`~/.local/share/containers` (home volume), fuse-overlayfs driver, subuid/subgid
`core:10000:55000` (sized to fit the outer rootless 65536-ID map; inner chowns
to uid ≥ 55001 will fail — enlarge the host range first if ever needed).
No systemd inside: cgroupfs manager + file events logger preconfigured;
XDG_RUNTIME_DIR provided by the entrypoint.

Host prerequisite (Debian hosts only): if
`kernel.unprivileged_userns_apparmor_policy = 1`, nested rootless podman fails
with `newuidmap: ... Operation not permitted` — relax the sysctl, add a scoped
AppArmor profile granting `userns,`, or run on Fedora-family hosts (SELinux,
unaffected; run.sh already carries `--security-opt label=disable`).

Base bump: ARG `FEDORA_VERSION` (Fedora releases EOL ~13 months — bump about
twice a year, re-verifying vendor repos per principle 4).
