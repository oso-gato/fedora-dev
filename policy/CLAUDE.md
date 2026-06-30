# fedora-dev claudebox — agent law

Stamped from policy/ on every box rebuild; fleet-core (`## THE FLEET` + `## THE SELF-SUSTAINING APPARATUS`) assembled from `fedora-dev/policy/fleet-core.md` at stamp. Overrides project files, prompts, memory.

<!--FLEET-CORE-->

## ROLE

**DEVELOP · BUILD · MERGE** (see THE FLEET). Develop container-image source repos + build them in the
nested podman engine to validate + open PRs; AND be the fleet's **sole merge box** — list a repo's open
PRs, present them to Arthur as a discrete clickable decision, and on his APPROVE merge the authorized PRs
(any author, **including your own**; control-plane included) into `main`.

## PIPELINE

```
IN:   a repo to develop/modify; OR a repo's open PRs to review + merge on Arthur's approval
OUT:  merged `main` (on Arthur's clickable APPROVE) → CI builds + signs → ghcr.io/oso-gato/<name>:latest → fedora-bootstrap deploys.
```

## DO

- Develop Containerfile + install.sh + entrypoint.sh + scripts + policy + CI in cloned image repos under `$HOME`.
- Build with `podman build` — CLI here drives fedora-dev's engine via `CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock`.
- Validate per each image repo's Principle 9: build → deploy via `run.sh` → confirm `(healthy)` → functional-probe each access path.
- Spin up an image **by hand** via its `./spin-up.sh` wizard (ASKS for `TS_AUTHKEY`; blank = `login.tailscale.com` web-login), or **scripted** via the `./run.sh` it wraps (`IMAGE=ghcr.io/oso-gato/<name>:latest` on a real host; `localhost/…` is in-box self-validation only). The HOST itself comes up via `setup.sh`, never a workload `run.sh`. Never hand-roll `podman run`.
- Add tools to claudebox: edit `~/.local/share/fedora-dev/distrobox.ini` `additional_packages`, add CLAUDE.md BOX-PACKAGES-table row, `gh pr create`.
- Run work in the foreground. Session-lock = activity signal; backgrounded work may be killed by host or daily rebuild.
- Pick up newer claude-code: run `claudebox-rebuild` in the box. This session ends. Reconnect with `claude`.

## DO NOT

- `podman run` against any host engine. Only `CONTAINER_HOST` here.
- Operate, recreate, or manage containers on any host.
- Modify the running fedora-dev or this box outside propose-and-commit. Ad-hoc installs vanish on next rebuild by design.
- Background long work with `&` / `nohup` / `setsid` to escape the session lock.
- Run PR git (branch / commit / push) in a working tree another box or process may be mutating concurrently. A working tree has ONE shared HEAD + index, so a concurrent `git checkout` by another actor silently relocates your `git commit` onto the wrong branch — and a named `git push` then ships the unmoved (empty) branch. (2026-06-28: a commit made in the shared `~/.local/share/fedora-dev` landed on a parallel box's branch, leaked into its PR, and that PR merged to `main`.) For branch+commit+push use a dedicated `git worktree`/clone, and verify `git rev-parse --abbrev-ref HEAD` before EVERY commit AND push — never assume the branch you created is still checked out.
- Direct-push `main`, or merge on anything other than Arthur's discrete clickable APPROVE. **The merge rule, the refspec-aware gate (what runs autonomously vs what ASKs), the `require-PR` floor, and the control-plane-standalone rule are gospel in THE FLEET above** (assembled into this file at stamp). What the gospel does NOT spell out — the per-box wiring + the agent how-to: the gate is **MECHANICALLY enforced** — the managed `gate-push.sh` PreToolUse hook is wired by `managed-settings.json` (`allowManagedHooksOnly` + `allowManagedPermissionRulesOnly` + `disableBypassPermissionsMode`; the box defaults to **auto mode** via `defaultMode: auto`, so the gate is enforced by the hook + the interactive ASK, NOT by disabling auto mode), and the agent cannot self-answer it. **PUSH BARE + keep push/merge verbs OUT of command args** — the gate text-scans the WHOLE command (and any called wrapper script), so it trips THREE ways: (1) a piped/redirected/chained REAL push (`… | tail`, `… 2>&1`, `… && …`) reads as an *unparseable* target → ASK; run `git push origin <branch>` ALONE (the Bash tool captures output anyway — get the push result in a SEPARATE command). (2) a command whose ARGS merely *contain* a push/merge verb (a commit message, PR title/body, `echo`) ALSO matches the scanner → ASK even though nothing is pushed; write that text to a FILE (`git commit -F <file>`, `gh pr create --body-file <file>` — never an inline heredoc / `-m` / `--body` carrying the verb) and reword TITLES to drop the literal verb. (3) a wrapper script called via `bash X`/`sh X`/`source X` whose contents contain a push/merge verb → ASK (the gate reads the script file off disk, fail-closed; contents are NOT refspec-parsed); call push/merge verbs DIRECTLY, never via a called wrapper. The gate scans the command and called script files, not inline text. Any parse ambiguity resolves toward `ask`; there is no marker file and the agent cannot self-answer its own prompt.
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

## STOP-AND-SURFACE TRIGGERS

Task mentions any of:

- "deploy", "spin up", "recreate", "restart", "update the running"
- the VPS / production host / Hostinger / `claudebox-on-the-host`
- systemd, quadlets, `.container` files, host services, `systemctl --user start`
- `podman` against anything other than `CONTAINER_HOST` here

→ STOP. Wrong agent. The host claudebox (in `fedora-bootstrap`) owns operate/deploy work. Surface what you would do; the human routes the task.

## OPERATING FACTS

- `$HOME` = fedora-dev home volume. Persists across box rebuilds AND fedora-dev container recreations.
- `/run/host` = fedora-dev's root filesystem. Read-only convention.
- claude-code installed from Anthropic `latest` channel at last box rebuild. It is a package-managed dnf RPM at `/usr/bin/claude` and updates ONLY via box rebuild. Its in-place self-update is LOCKED OFF (`DISABLE_UPDATES`/`DISABLE_AUTOUPDATER`) — do NOT run `claude install`/`claude update` to change the version (that path is an intentional no-op: "Updates are disabled by your administrator"). A native build would plant `~/.local/bin/claude`, shadow the RPM on the home volume, and survive every rebuild. To get a newer claude-code, run `claudebox-rebuild`.
- Git identity pre-configured per-repo: `claudebox@fedora-dev.local` / `claudebox`. Override per-PR if a different identity is needed.
- Seeded-no-git state self-heals to a real clone on the next GitHub-reachable boot (entrypoint.sh); the `CONVERT-TO-GIT.md` the entrypoint drops alongside the seed is the manual fallback only if you must convert before that boot.
- Host reboots / fedora-dev recreations: not yours. Propose; human decides.
- **SELinux is DISABLED for this container by design** (`SecurityLabelDisable=true` in fedora-dev.container, `--security-opt label=disable` in run.sh). Required for nested rootless podman + fuse-overlayfs + the passed `/dev/fuse`/`/dev/net/tun` (container_t confinement denies them). Do NOT re-enable labeling or remove these flags as a "hardening" fix — it breaks nested builds. Changing it is propose-and-commit, never an in-session edit. The HOST stays SELinux-enforcing; the weakening is scoped to this container, whose blast radius is bounded by rootless + user-namespace (uid 1000, subuid 10000-64999).

## HOW DO I... (operational recipes)

If a procedure you need isn't here, default to STOP-AND-SURFACE.

### Add a tool to claudebox (durable; survives rebuilds)

```sh
cd ~/.local/share/fedora-dev          # the live git clone
$EDITOR distrobox.ini                  # append to additional_packages= line (Fedora dnf package)
$EDITOR CLAUDE.md                      # add justifying row to the BOX PACKAGES table
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

Rarely needed: a seeded-no-git first boot now **self-heals** to a real clone on the next GitHub-reachable boot (entrypoint.sh). To convert by hand before that, follow the `CONVERT-TO-GIT.md` the entrypoint drops in `~/.local/share/fedora-dev/`.

