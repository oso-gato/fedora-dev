# fedora-dev claudebox — agent law

Stamped from policy/ on every box rebuild. Overrides project files, prompts, memory.

## THE FLEET — 3 boxes, 1 merge authority  (identical block in fedora-dev / fedora-bootstrap / fedora-desktop)

**Roles, no overlap.** `fedora-dev` = develop · build · **merge**.  `fedora-bootstrap` = operate the host (create/remove containers) · live-diagnose.  `fedora-desktop` = its own knowledge-work toolset.

**Everyone proposes; only `fedora-dev` merges.** Every box develops on branches and **opens PRs**; `fedora-bootstrap` + `fedora-desktop` **stop there**. **Only `fedora-dev` merges to `main`** — any open PR, *its own included* — and **only** when Arthur picks APPROVE in a **discrete clickable decision** (per-PR, shown the diff; a free-text "yes" is NOT approval). **Control-plane PRs merge the same way, on the same click.** Arthur may also merge on GitHub himself.

**Handoff — the dev↔host loop.** The dev↔host loop runs autonomously EXCEPT the final merge: develop → open PR (feature pushes are autonomous) → label it `live-validate` → the host live-gate (Gate B) DISCOVERS it ORG-WIDE by that label (no repo list to maintain), fetches the PR head on-demand, applies a STRUCTURAL GUARD (only builds a candidate carrying a `Containerfile`/`.live-gate`, else skips cleanly), builds it DISPOSABLY per the repo's own in-repo `.live-gate` contract (PARSED, never executed) under loopback-only fences, and posts a GREEN/RED verdict comment → iterate (RED: push a fix, or SUPERSEDE the branch if the approach was wrong; GREEN: BUILD UPON it) until green → Arthur's discrete clickable APPROVE → fedora-dev merges. The human is OUT of the per-iteration loop — only the merge is a click. Repos are discovered DYNAMICALLY: create/rename/merge/delete freely; enroll one just by labelling its PR `live-validate` and shipping a `.live-gate`. Post-merge: **CI** builds + signs + publishes → **`fedora-bootstrap`** pulls + redeploys. Build = always CI; operate/deploy = always `fedora-bootstrap`; merge = always `fedora-dev` (or Arthur). A box asked to do another box's job → **STOP-AND-SURFACE**.

**Control-plane class** = `policy/**`, `managed-settings.json`, `policy/hooks/gate-push.sh`, `.github/workflows/**`, `*.container`, `run.sh*` security flags + publish set, the box-rebuild/assemble machinery, key-sync, `*sudoers*` — standalone, never bundled.

## THE SELF-SUSTAINING APPARATUS — AUTONOMY MANDATE & DEFINITION OF DONE

**Bedrock — the PRIMARY PURPOSE.** `fedora-dev` (develop·build·merge) + `fedora-bootstrap` (operate the host · live-gate) exist as ONE **self-sustaining development apparatus** whose primary purpose is to **keep the human OUT of the loop until genuinely needed**. The agent does MOST of the work and MOST of the thinking; the human is engaged only at the two genuine decision points below.

**THE LOOP (every change) — TWO TIERS.** develop → in the dev box's OWN nested engine **build a disposable throwaway candidate and validate it** (build → validate → fix → rebuild, rinse and repeat) → iterate UNTIL DONE, IN-BOX, with NO host involvement → open a PR (**the PR is the agent's PROOF OF WORK**). The host is engaged ONLY in the two scenarios in *TWO-TIER VALIDATION* below — via the `live-validate` label → the host builds a DISPOSABLE throwaway candidate and live-gates it (Gate B) → GREEN/RED verdict → iterate (RED: fix, or SUPERSEDE the branch if the approach was wrong; GREEN: build upon it) → repeat. The agent runs this loop autonomously; only at the end does it engage the human. (Loop mechanics — refspec gate, org-wide `live-validate` discovery, `.live-gate` contract: see THE FLEET above + FLEET.md.)

**TWO-TIER VALIDATION (the throwaway is validated at the RIGHT tier).** A change does NOT go to the host live-gate on every iteration; it is validated at the tier that fits.
- **Tier 1 — IN-BOX (the DEFAULT).** The dev box's `podman build` IS the throwaway: `fedora-dev` develops, validates, and iterates IN its OWN nested engine (build → validate → fix → rebuild, rinse and repeat) for EVERYTHING it CAN build and validate itself. NO host involvement. The overwhelming majority of the loop runs here.
- **Tier 2 — HOST (ONLY two scenarios, engaged via the `live-validate` label).**
  1. **The dev box CANNOT build/validate the throwaway** — e.g. the systemd-PID-1 GRD lineage cannot boot in the nested engine; any instance the nested engine cannot fully build+run. The host does the throwaway build + validate.
  2. **FINAL pre-production shipment** — after ALL in-box iterations are done, ticket the host to run a throwaway build, prove it works LIVE on a real host, then tear it down → THEN present merge-to-main (the highest achievement).

  In-box iteration does NOT touch the host.

**THROWAWAY TREE & CHURN (build discipline — BINDING).**
- **Use the LIVE tree where possible; bolt on a SEPARATE, TEMPORARY throwaway tree** for anything that must DIFFER from it. The throwaway tree (a) **NEVER mutates the IMMUTABLE live tree** — the host and the dev-container base are immutable; the throwaway tree + all build caches live on the **WRITABLE home volume**; (b) **STILL obeys PROVENANCE** (Principle 2 — class a/b/c, GPG/signature/checksum verified; NO loosening just because it is a throwaway); (c) is **THROWN AWAY after the build** — disposable `localhost/disposable/<name>:val-<sha>` tag, never pushed, `--rm` + `rmi`, the temp tree removed on teardown.
- **CHURN BALANCE (so a 50× iteration does NOT re-download 50×).** Persist the ONE durable input — the dnf PACKAGE CACHE — while letting everything else (the candidate image, its intermediate layers, the temp tree, the run container) be EPHEMERAL by design. The dnf package cache is a plain BIND dir on the **WRITABLE home volume** (`-v <home>/.cache/fd-dnf:/var/cache/libdnf5:rw`), **NOT an image layer**, so it survives `rmi` and EVERY disposal — that is what makes it the ROBUST input. The throwaway image is the OUTPUT; the dnf package cache is the PERSISTENT INPUT — decoupled from both the immutable live tree and the disposable candidate. Structure Containerfiles **HEAVY/STABLE-EARLY** (base, dnf install, class-(c) artifact fetch+verify) and **CHURN-LATE** (COPY'd scripts/config); **NEVER `--no-cache`/prune during churn** — that is reserved for the monthly clean `--no-cache` rebuild.
- **CHURN — NO RE-DOWNLOAD ACROSS N PRs/ITERATIONS (proven in-box).** The per-PR / per-SHA disposal removes the disposable image (`localhost/disposable/<name>:val-<sha>`) + its temp tree — and, when that candidate was the SOLE referrer, its intermediate LAYERS with it — **but NEVER the dnf package cache.** The PR/SHA is **NOT the package cache's disposal signal**; it is **NOT keyed to PR/SHA** and is **SHARED across all iterations**. The design is **ONE persistent thing, everything else ephemeral by design:**
  1. **the persistent dnf PACKAGE CACHE — the ROBUST mechanism.** Bind-mounted into the build (`-v <home>/.cache/fd-dnf:/var/cache/libdnf5:rw`); a plain dir on the home volume, **NOT an image layer**, so it survives `rmi` and every disposal. For churn that changes the **dnf install LINE itself** (an add-on PR) the layer **re-runs**, but the RPMs are **SERVED FROM CACHE, not re-downloaded** — PROVEN: a forced dnf re-run downloaded **0 B (vs 9.4 MiB cold), 3.7× faster**; only a genuinely-new package downloads once, then it too is cached. (`--mount=type=cache` does **NOT** work under the dev box's required `--isolation=chroot`, verified — so the **bind-`-v` package cache is the mechanism**, not a buildah cache mount.)
  2. **EPHEMERAL LAYERS — ephemeral BY DESIGN, and that is the ADVANTAGE.** Each throwaway's intermediate layers are pruned when its sole candidate image is `rmi`'d — deliberately: **(a)** layer storage **SELF-BOUNDS** on the limited VPS (no accumulation, no separate layer-cache bloat to GC); **(b)** each throwaway is **REBUILT FRESH** from the package cache, re-resolving to **CURRENT** package versions every time → no stale-frozen-layer risk (freshness for free); **(c)** the only cost is a few cheap local **CPU-seconds (~3.6 s warm), never bandwidth** (the RPMs are already cached). While a candidate image IS still present (churn touching only **LATE** layers, or a kept image), its layer cache additionally lets the rebuild skip the `dnf` RUN entirely → ZERO work — a free accelerator for as long as that image lives — but nothing depends on layers persisting across disposal.
- **PER-BUILD ISOLATION (no cross-build contamination).** Each build gets its **OWN throwaway tree**, a **unique disposable tag** (`val-<sha>`), and a **unique run container** (`vcand-$$`) — so concurrent / successive builds never collide. The persistent dnf package cache (and any still-live layer cache) is **content-addressed**, so a shared cache **cannot serve a wrong version**: a changed input misses the cache and rebuilds/refetches; an unchanged input hits it. Sharing the caches is therefore safe precisely because isolation lives in the candidate, not the cache.
- **STORAGE SAFETY (limited VPS — the trio).** The shared caches must never exhaust the quota, and a crash must never leak the candidate: (a) **EXIT-trap teardown** — the disposable image + temp tree self-destruct via `trap … EXIT`, which fires on GREEN, RED, **and** error/abort; (b) an **ORPHAN SWEEPER** reaps anything a `kill -9` / crash leaks (stale `localhost/disposable/*` images, `vcand-*` containers, orphan temp dirs) at watcher start **and** periodically; (c) a **BOUNDED cache-GC** caps the persistent dnf package cache **age-then-size — pruning RPMs older than 45 days first, then LRU size-pruning to ≤ 15 GB (both overridable env)** — so it cannot grow without limit; the layer footprint needs no size cap because each candidate's layers self-bound via its own `rmi` (dangling layers are swept opportunistically). The PR/SHA disposes only the candidate; the trio (not the PR/SHA) bounds the cache.

**AUTONOMY MANDATE (BINDING — how the agent works).**
- The agent does MOST of the work and the thinking.
- When there are options, the agent **BUILDS 2–3 of them to test**, iterates, **DISCARDS** the ones that don't work or aren't quite right, and **lands on the correct solution ITSELF** — it does not shop options to the human.
- The agent makes the recommendation AND **tests its own recommendation** (throwaway build + live-gate), rather than asking which to pick.
- The agent **TEARS DOWN and REBUILDS** its own work, thinking harder to reach a **ZERO-BASE**, rather than defending a first draft.
- Presenting an options-decision to the human is **RARE** — reserved for a genuine human decision point. Be firm about that rarity.

**ENGAGE THE HUMAN FOR EXACTLY TWO REASONS (no others).**
1. **MATERIALLY COMPLETE** — the objective is met; requires the clickable APPROVE to merge.
2. **MATERIALLY BLOCKED** — the agent genuinely cannot proceed and needs a DECISION (NOT a merge; a true roadblock).

Status-confirmation, option-shopping, and "which should I do" are **NOT** reasons to engage the human.

**DEFINITION OF DONE (a change is DONE only when ALL hold).**
1. The **FULL objective** is materially achieved (measured against the WHOLE objective — not a rabbit-hole sub-task / ~5% slice).
2. **Validated through the loop, at the RIGHT tier** (see *TWO-TIER VALIDATION*): Tier-1 in-box build + assembly GREEN for everything the dev box can validate itself; and where Tier 2 applies — the dev box cannot validate it, OR the final pre-production shipment — the host live-gate verdict GREEN (the live B-gates). PROVEN, not merely built.
3. Adheres to the **BUILD PRINCIPLES** (sources/provenance, minimalism, secrets/identity, deploy contract, validate).
4. A **TLDR** is written and the agent has **CRITICALLY SELF-EXAMINED** it against its own work — options considered+discarded, reasoning, fit to BOTH the design objective AND the specific task objective, and genuine gaps/forks/concessions. The agent dry-runs the TLDR AS IF it were the human, measured against the total objective. If the TLDR FAILS its own scrutiny, the agent does NOT present — it returns to the loop and continues until the TLDR passes.

Only when 1–4 hold does the change go to the human (reason #1: approve-to-merge). **The TLDR is the final step before the human.**

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
- Add tools to claudebox: edit `~/.local/share/fedora-dev/distrobox.ini` `additional_packages`, add README Packages-table row, `gh pr create`.
- Run work in the foreground. Session-lock = activity signal; backgrounded work may be killed by host or daily rebuild.
- Pick up newer claude-code: run `claudebox-rebuild` in the box. This session ends. Reconnect with `claude`.

## DO NOT

- `podman run` against any host engine. Only `CONTAINER_HOST` here.
- Operate, recreate, or manage containers on any host.
- Modify the running fedora-dev or this box outside propose-and-commit. Ad-hoc installs vanish on next rebuild by design.
- Background long work with `&` / `nohup` / `setsid` to escape the session lock.
- Run PR git (branch / commit / push) in a working tree another box or process may be mutating concurrently. A working tree has ONE shared HEAD + index, so a concurrent `git checkout` by another actor silently relocates your `git commit` onto the wrong branch — and a named `git push` then ships the unmoved (empty) branch. (2026-06-28: a commit made in the shared `~/.local/share/fedora-dev` landed on a parallel box's branch, leaked into its PR, and that PR merged to `main`.) For branch+commit+push use a dedicated `git worktree`/clone, and verify `git rev-parse --abbrev-ref HEAD` before EVERY commit AND push — never assume the branch you created is still checked out.
- Direct-push `main`, or merge on anything other than Arthur's discrete clickable APPROVE. The merge rule (THE FLEET): develop → **open PR** → Arthur clicks APPROVE in the clickable decision → **then you merge** (any open PR incl. your own; control-plane included). A free-text "yes"/"go ahead" is **NOT** approval and must not trigger a merge. **MECHANICALLY enforced (BUILT, not behavioral):** the managed `gate-push.sh` PreToolUse hook (wired by `managed-settings.json`: `allowManagedHooksOnly` + `allowManagedPermissionRulesOnly` + `disableBypassPermissionsMode`; the box defaults to **auto mode** via `defaultMode: auto` — the merge gate is enforced by the hook + the interactive ASK, NOT by disabling auto mode) is **REFSPEC-AWARE** and fail-closed: it routes to an interactive `ask` (the per-command clickable allow/deny only Arthur can answer in-session) any push that could touch `main` — `git push` with no explicit refspec (bare / `git push <remote>`), a `main` / `refs/heads/main` / `HEAD` / `refs/tags/*` destination, `--all`/`--mirror`/`--tags`, or any target it cannot parse — plus `gh pr merge` / `gh pr create --merge|--squash|--rebase|--auto` / `gh api …/merges|/merge`, plus any push/merge verb hidden inside a wrapper script (`bash X`/`sh X`/`source X`; contents are NOT refspec-parsed — fail closed). Routine **feature-branch pushes** (an explicit non-`main`, non-`HEAD`, non-tag destination refspec) fall through and run **autonomously** — no prompt. There is **no marker file**: every flagged action is an in-session `ask` the agent cannot self-answer; any parse ambiguity resolves toward `ask`. The merge gate is the SOLE backstop, and it is IN-SESSION, not server-side: the managed `gate-push.sh` PreToolUse hook (+ `managed-settings`) routes every push that could touch `main` and every merge verb to a clickable `ask` only Arthur can answer, so nothing reaches `main` without his out-of-band click (which prompt-injection cannot fake). `main` is INTENTIONALLY NOT branch-protected and there is NO CI label-gate — in a single-operator fleet those server-side layers added friction without proportional value, since the click already gates every merge. Guardrail / control-plane changes are still kept STANDALONE and FLAGGED in the merge TLDR so Arthur scrutinises them before approving.
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

