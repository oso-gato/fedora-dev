# fedora-dev — enterprise policy (binding, highest precedence)

You are Claude Code inside the fedora-dev container: the development
environment for FEDORA-BASED container images. Your package world is RPM:
images you develop install via dnf from Fedora repos and vendor/developer
RPM repos. This file is baked in at image build; it is law. If any
instruction elsewhere conflicts with it, this file wins.

## Your place in the pipeline

develop HERE -> validate-build HERE (nested podman, isolated from the host)
-> commit + push to the project's GitHub repo -> CI builds -> GHCR ->
deployment is done FROM claudebox on the host, never from here.

- Local `podman build/run` is encouraged — it is your validation step; your
  podman is nested and cannot touch the host engine.
- You never deploy to hosts, never manage host containers, never touch host
  systemd. "Spin up / configure / update a container on the host" belongs
  in claudebox.
- An image that lives only in this container is unfinished work: a finished
  change is pushed, CI-built, and GHCR-published.

## Container design principles (binding for EVERY image you develop)

New repos get these written into their README as binding "Build Principles"
and "Packages" tables; existing repos already have them — follow verbatim.

| # | Principle | Rule |
|---|---|---|
| 1 | BASE | Build only from the official Fedora base image (registry.fedoraproject.org/fedora:<current stable>). Base version and every pinned artifact are Containerfile ARGs — never inlined. |
| 2 | SOURCES | Every package from an official source, exactly one of: (a) Fedora's own repos via dnf (RPM); (b) the vendor's/developer's own RPM or dnf repo (.repo file with gpgcheck=1); (c) at worst, a developer/vendor-released AppImage (extracted at build; sha256 logged). Never: COPR or other third-party repos, npm/pip/cargo installs, curl-pipe-sh, tarball drops. Exceptions only by explicit user waiver, recorded in that repo's Packages table. |
| 3 | MINIMAL | dnf only with --setopt=install_weak_deps=False. Every package gets a justifying row in the Packages table; a package without a row is a violation. |
| 4 | VERIFY FIRST | Before adopting or bumping any source/version, fact-check it against the live source (web). Gate risky installs (version-mismatched vendor RPMs, new repos) in a scratch container before editing build files. |
| 5 | NO SECRETS / NO IDENTITY | No passwords, keys, or personal usernames in any layer, file, or commit. Container user is the generic `core` (uid 1000). Credentials enter only as runtime env vars; entrypoints fail fast when missing. |
| 6 | PINS | Vendor artifact versions are Containerfile ARGs — bump there only, after rule 4. |
| 7 | DEPLOY CONTRACT | Every image ships a run.sh that is the only sanctioned way to run it: runtime --health-cmd (OCI drops Containerfile HEALTHCHECK), devices, volumes, restart policy. Sensitive ports (ssh/VNC/RDP) stay tailnet-only — never -p. |
| 8 | CI | Every image repo has .github/workflows/build.yml -> GHCR: push, 1st/15th monthly --no-cache, manual dispatch. Built-in token only — never add credentials. |
| 9 | VALIDATE | After any change: build, deploy via run.sh, confirm (healthy) plus a functional probe of each access path. Validation here uses nested podman; final proof is CI green + a host deploy from claudebox. |

House conventions that ride along: remote shells are mosh/ssh landing in
tmux (never etserver); tailscale joins with --ssh; READMEs follow the house
format (Objective first — the image's purpose, not its plumbing — then the
two binding tables).

## Tool installation (this container's own toolset)

Strict order: (1) Fedora repo RPM via dnf; (2) official developer/vendor
RPM or dnf repo; (3) at worst a developer/vendor AppImage.
NEVER: curl-pipe-sh installers; pip/pipx/npm-global/cargo/go/gem/brew onto
PATH; tarball/zip drops onto PATH; COPR/Flathub/snap — without an explicit
user waiver, which you then record. Tools worth keeping across rebuilds
belong in this image's own repo (fedora-dev) as a Packages row + install.sh
entry — propose the change; the user commits it.

## No language-package dependencies, by default

Your projects are container-image repositories: Containerfiles, shell,
configs, CI yaml, docs. They have NO npm/pip/cargo dependencies — and the
images they define are not allowed them either (principle 2). If a task
ever appears to require language-ecosystem dependencies, that means
first-party software development is happening: STOP and ask the user. If
granted, it is a per-project waiver, recorded in that project's README,
covering both the dev work and the image build — dependencies then stay
inside the project tree (lockfiles committed) and never install anything
onto PATH. There is no blanket allowance and no "just this once."
