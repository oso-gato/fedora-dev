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
BEFORE it reaches Arthur, label the PR `live-validate` — this works for **any repo in the org**, not
just fedora-dev. The host (fedora-bootstrap) DISCOVERS labelled PRs ORG-WIDE by that label (no repo
list to maintain), fetches the head on-demand, applies a **structural guard** (builds only a
candidate carrying a `Containerfile`/`.live-gate`, else skips cleanly), builds it DISPOSABLY per the
repo's own in-repo **`.live-gate` contract** (PARSED as a declarative contract, never executed as a
script; absent → host default fence/probe), runs Gate B (health + access-probe) under loopback-only
fences, and posts a **GREEN/RED verdict comment** on the PR automatically — while you keep working
(it runs a throwaway container and never touches your session, so an active dev session never blocks
it). Iterate on RED (push a fix → the new commit re-gates; or SUPERSEDE the branch if the approach
was wrong; on GREEN, build upon it); present only a GREEN PR for Arthur's APPROVE. The host
**comments, NEVER merges**. Enrolment is fully dynamic: create/rename/merge/delete repos freely —
enroll one just by labelling its PR `live-validate` and shipping a `.live-gate`.

Ad-hoc `dnf install` or `dnf remove` inside the running box works for the
current session but VANISHES on the next rebuild — by design. That's the
discipline that keeps the box reproducible.

## TICKETS & THE DEV LOOP (my role)

I am **DEVELOP · BUILD · MERGE** and the fleet's **SOLE merge authority**. The **PR is the ticket** — there is no separate tracker; an open PR against `main` is both the work item and the handoff token. My place in the loop (the full fleet map is `FLEET.md`):

1. **Develop → open PR.** Edit the LIVE clone, `gh pr create` (see PROPOSE-AND-COMMIT). The PR is the ticket. **Feature-branch pushes are autonomous** — the refspec-aware gate prompts only on a push that could touch `main` plus the merge verbs.
2. **Request a host verdict — label `live-validate`.** This enrolls the PR in the host pre-merge live-gate — for **any repo in the org**, not just fedora-dev (the host discovers labelled PRs ORG-WIDE by the label, no repo list to maintain). `fedora-bootstrap` runs `live-gate-watch.sh` (its `live-gate-watch.timer`, 10 s poll), which for each new head SHA (deduped once via `~/.local/state/live-gate/<WL>-<sha>.done`, and ONLY once the verdict comment is actually delivered) applies a **structural guard** (builds only a candidate carrying a `Containerfile`/`.live-gate`, else skips cleanly), builds a **disposable** candidate (`build-candidate.sh` → `localhost/disposable/<name>:val-<sha>-<target>`, never pushed) per the repo's own in-repo **`.live-gate` contract** (PARSED, never executed; absent → host default fence/probe) and runs **Gate B** (`validate-candidate.sh`: health + access-probe) under loopback-only fences, then posts a `Host live-gate (Gate B): VERDICT GREEN|RED` comment on the PR. My own `build.yml` runs build-only on the PR (`push=false`) — that proves it *builds*; the host verdict proves it *runs*.
3. **Iterate on RED.** Push a fix commit (or SUPERSEDE the branch if the approach was wrong); the new head SHA has no `.done` marker, so the host re-gates exactly once and re-comments. On GREEN, build upon it. Loop until GREEN — the human is OUT of this per-iteration loop.
4. **Present only GREEN.** I list a repo's open PRs and present them to Arthur **one at a time as a discrete clickable decision**, diff shown. A free-text "yes" is **not** approval.
5. **Merge on APPROVE.** On Arthur's click I merge to `main` — **any PR, any author including my own, control-plane PRs included**; control-plane PRs merge on the **same single click**. My `gate-push.sh` is **refspec-aware**: feature-branch pushes run autonomously, but every push that could touch `main` plus the merge verbs route to an interactive `ask` prompt only Arthur can answer — there is no approval-marker mechanism, and I cannot self-approve. The merge gate is the SOLE backstop, and it is IN-SESSION, not server-side: the managed `gate-push.sh` PreToolUse hook (+ `managed-settings`) routes every push that could touch `main` and every merge verb to a clickable `ask` only Arthur can answer, so nothing reaches `main` without his out-of-band click (which prompt-injection cannot fake). `main` is INTENTIONALLY NOT branch-protected and there is NO CI label-gate — in a single-operator fleet those server-side layers added friction without proportional value, since the click already gates every merge. Guardrail / control-plane changes are still kept STANDALONE and FLAGGED in the merge TLDR so Arthur scrutinises them before approving. Arthur may also merge on GitHub himself.
6. **Hands off after merge.** Push to `main` triggers CI build + cosign-sign + GHCR publish; `fedora-bootstrap` pulls + redeploys via `workload-refresh@<name>`. I never operate, deploy, or `podman build` a shipping image — those are STOP-AND-SURFACE to `fedora-bootstrap` / CI.

**Paused-work / cross-box requests** ride a **GitHub Issue** in the target repo (a convention, not automation): when work parks mid-flight or another box surfaces a fix for a repo I own, the Issue carries the request + proposed diff; I turn it into a branch + PR, re-entering at step 1.

## HEADLESS (binding prerequisite)

fedora-dev runs **fully headless** — no physical monitor, GPU, or local login seat is ever
attached or required. The harness (the claudebox + the supervised services) needs no display, and
every desktop image built ON this base (the fedora-desktop **xrdp** and **grd** lineages) is
likewise headless — a *virtual* display rendered by software GL (llvmpipe), reached only over the
network (ssh / RDP / VNC / web). A change that makes any part depend on a real display, GPU, or
physical seat is a **defect**, not an option.


## DOC ARCHITECTURE — DRY rule (binding)

One authoritative home per concept; every other mention is a one-line pointer or deleted. Evidence and benchmarks live only in the principle they prove. Fleet-wide identical blocks are enforced by CI (`bin/fleet-guard-parity.sh`).

**Layer roles.** `policy/CLAUDE.md` = binding law (stamped at every box rebuild; always in context) — owns autonomy mandate, two-tier validation, DoD, merge gate, and control-plane class. `CLAUDE.md` (this file) = per-repo build rules (BUILD PRINCIPLES table) + per-file purpose map. `FLEET.md` = cross-box map (human + agent-accessible); shared sections fleet-wide. `README.md` = human-only; not an authoritative source for any agent rule.

## BUILD PRINCIPLES (binding for every code change)

**Principle 0 — the self-sustaining apparatus.** Autonomy mandate, two-tier validation, and Definition of Done live in `policy/CLAUDE.md` (THE SELF-SUSTAINING APPARATUS section); that law is always in context. BUILD PRINCIPLES 1–11 below are this repo's per-build rules.


| # | Principle | Rule |
|---|---|---|
| 1 | BASE | Build only from the official `registry.fedoraproject.org/fedora:${FEDORA_VERSION}` image. Version is a Containerfile `ARG` — never inlined. |
| 2 | SOURCES | Every package/artifact from an official source, exactly one of: (a) Fedora's own repos via dnf; (b) the vendor's/developer's own RPM or dnf repo (`.repo` with `gpgcheck=1`); (c) an **official-upstream binary release artifact with NO class-(a)/(b) source** — bounded by the **Class-(c) rules** below (last-resort/zero-base; take the vendor's directly-published raw binary — never apt/`.deb`; provenance-GRADED c1 GPG-sig / c2 checksum / c3 resolve-log, strongest-available, fail-closed, pinned; shape is a within-grade tiebreaker — a persistent runtime binary IS permitted; disclosed per-artifact). Never: COPR or other third-party repos, pip/npm/cargo/gem/brew installs, curl-pipe-sh, mirror/aggregator binaries, flatpak, snap. **Applies to BOTH the base image AND claudebox's `additional_packages`.** Anything outside (a)/(b)/(c)-as-scoped needs an explicit user waiver row. **Class-(c) artifacts in use: none.** |
| 3 | MINIMAL | dnf only with `--setopt=install_weak_deps=False`. Every package gets a justifying row in the relevant Packages table (BASE or BOX); a package without a row is a violation. **Install the most specific (leaf) package, never a convenience metapackage, unless a recorded architectural reason. `install_weak_deps=False` blocks weak Recommends but NOT a metapackage's hard Requires — so a metapackage can silently pull unused components (e.g. the `fail2ban` metapackage hard-pulls `fail2ban-firewalld`→`firewalld` + `fail2ban-sendmail`→`esmtp`; install `fail2ban-server`). If unsure whether a name is a metapackage, verify (`dnf repoquery --requires <pkg>`) and flag before adding.** **"MINIMUM" IS RELATIVE TO THE CHOSEN CAPABILITY, not the absolute package count.** Once a capability is decided (e.g. a working desktop; an RDP-grade web gate), install the minimal LEAF footprint that makes THAT capability work, and accept + DISCLOSE the irreducible hard-dependency closure it entails (e.g. a `gnome-shell` desktop→webkit + `gnome-control-center`; a KDE desktop→samba/codec). Between options that deliver the SAME capability, prefer the smaller-footprint / built-in / class-(a) one. A lighter option that REDUCES the capability is NOT "more minimal" — it is a lesser function, and choosing it is a recorded capability trade-off, NOT a minimalism win. (Worked decision in fedora-desktop: Guacamole [RDP-grade web gate — H.264/audio/clipboard/file-transfer in the browser, strong password + brute-force lockout] is the SOLE web gate; noVNC [VNC-grade] was removed fleet-wide — a public, non-tailnet door needs strong auth and noVNC's 8-char VncAuth is unacceptable there — so Guacamole's Tomcat + JVM + `.war` footprint IS the minimum for full strongly-authed RDP-in-the-browser.) |
| 4 | VERIFY FIRST | Before adopting or bumping any source/version, fact-check it against the live source (web). Gate risky installs (version-mismatched vendor RPMs, new repos) in a scratch container before editing build files. |
| 5 | NO SECRETS / NO IDENTITY | No passwords, keys, or personal usernames in any layer, file, or commit. Container user is the generic `core` (uid 1000). Credentials enter only as runtime env vars; entrypoint fails fast when missing. |
| 6 | PINS | Vendor artifact versions are Containerfile `ARG`s or pinned in `distrobox.ini` — bump there only, after rule 4. |
| 7 | DEPLOY CONTRACT | Every image ships a `run.sh` — the only sanctioned **non-interactive** way to run it: runtime `--health-cmd` (OCI drops Containerfile HEALTHCHECK), devices, volumes, restart policy, port set. An optional **`spin-up.sh`** wizard wraps it to ASK for `TS_AUTHKEY`/`IMAGE` interactively (blank key = `login.tailscale.com` web-login), but only ever delegates to `run.sh` — run.sh stays the single source of runtime truth. Sensitive ports (ssh/RDP/VNC) stay tailnet-only — never `-p`. The Quadlet is the systemd-managed equivalent. Never hand-roll `podman run`. |
| 8 | CI + LAYERED CADENCE | `.github/workflows/build.yml` publishes the base image to GHCR + cosign-signs it: on push, on the 15th monthly (`--no-cache`), and on manual dispatch. Built-in token only. The IN-CONTAINER claudebox refreshes daily on its own timer + ad-hoc triggers; it never touches CI. |
| 9 | VALIDATE | After any change: build, deploy via `run.sh`, confirm `(healthy)` plus a functional probe of each access path. Final proof is CI green + a host deploy from claudebox-on-the-host. **Prove runtime/terminal behaviour empirically, not by reasoning:** for tmux multi-client geometry, TUI redraw, and the like, drive multiple sized PTY clients with a real harness and assert the actual bytes each client renders (a naive byte VT model mis-reads UTF-8 fills like `·` as garbage) — not just a reported window size. **Validate at the REAL execution boundary, not the component in isolation:** a change spanning the base image ↔ in-box claudebox (credentials, PATH tools, env, sockets the in-box agent consumes) MUST be exercised end-to-end FROM INSIDE the box (an actual in-box `git push` / `git credential fill`), never just the component's `bash -n` + unit logic — reasoning about cross-context correctness is not validation. (2026-06-28: a credential helper wired to base-only `/usr/local/bin` + `/run/secrets` passed isolated Tier-1 but never authenticated in-box `git push`; ultra-verify caught it, component tests did not.) |
| 10 | THROWAWAY TREE & CHURN | Use the LIVE tree where possible; for anything that must DIFFER from it, bolt on a SEPARATE, TEMPORARY throwaway tree that (a) **NEVER mutates the IMMUTABLE live tree** (host + dev-container base are immutable — the throwaway tree + all build caches live on the WRITABLE home volume), (b) **STILL obeys PROVENANCE** (Principle 2 — class a/b/c, GPG/signature/checksum verified; NO loosening because it's a throwaway), (c) is **THROWN AWAY after the build** (disposable `localhost/disposable/<name>:val-<sha>` tag, never pushed, `--rm` + `rmi`; temp tree removed on teardown). **CHURN BALANCE:** persist the ONE durable input — the dnf PACKAGE CACHE (a plain BIND dir on the home volume, **NOT an image layer**, so it survives `rmi` and EVERY disposal) — and let everything else (candidate image, its layers, temp tree, run container) be EPHEMERAL by design; the throwaway image is the OUTPUT, the dnf package cache is the PERSISTENT INPUT. Structure Containerfiles **HEAVY/STABLE-EARLY** (base, dnf install, class-(c) fetch+verify) and **CHURN-LATE** (COPY'd scripts/config); **NEVER `--no-cache`/prune during churn** (reserved for the monthly clean `--no-cache` rebuild). **CHURN — NO re-download across N PRs/iterations (proven in-box):** the per-PR/per-SHA disposal removes the disposable image + temp tree — and, when it was the sole referrer, its intermediate layers too — **but NEVER the dnf package cache** (NOT keyed to PR/SHA; **SHARED across all iterations**). **ONE persistent thing, everything else ephemeral by design:** (1) the persistent dnf **PACKAGE CACHE — the ROBUST mechanism** (bind-mounted `-v <home>/.cache/fd-dnf:/var/cache/libdnf5:rw`; a plain dir, NOT an image layer, surviving `rmi` and every disposal): churn that changes the dnf install LINE (an add-on PR) re-runs the layer but **serves RPMs FROM CACHE, not re-downloaded** — PROVEN a forced dnf re-run downloaded **0 B (vs 9.4 MiB cold), 3.7× faster**; only a genuinely-new package downloads once. (`--mount=type=cache` does NOT work under the required `--isolation=chroot`, verified — the **bind-`-v` package cache is the mechanism**.) (2) **EPHEMERAL LAYERS — ephemeral BY DESIGN, an ADVANTAGE:** a throwaway's layers are pruned with its sole candidate's `rmi`, so (a) layer storage **self-bounds** (no accumulation / no layer-cache to GC), (b) each throwaway **rebuilds FRESH** from the package cache → CURRENT package versions, no stale-frozen-layer risk (freshness for free), (c) the only cost is a few local **CPU-seconds (~3.6 s warm), never bandwidth**. While a candidate image lives (LATE-layer churn, or a kept image), its layer cache also lets the rebuild skip the dnf RUN entirely → ZERO work — a free accelerator — but nothing relies on layers surviving disposal. **ISOLATION:** each build has its OWN throwaway tree + unique disposable tag (`val-<sha>`) + unique run container (`vcand-$$`) → no cross-build contamination; the dnf package cache (and any live layer cache) is content-addressed so it cannot serve a wrong version. **STORAGE SAFETY (limited VPS):** (a) the disposable image+tree self-destruct via `trap … EXIT` (fires on GREEN/RED/error); (b) an ORPHAN SWEEPER reaps anything a `kill -9`/crash leaks (stale `localhost/disposable/*`, `vcand-*`, orphan temp dirs) at watcher start + periodically; (c) a BOUNDED cache-GC caps the persistent dnf package cache age-then-size (RPMs >45 days pruned first, then LRU size-prune to ≤15 GB; both overridable env) so it cannot exhaust the quota — layers self-bound via `rmi`, dangling ones swept opportunistically. |
| 11 | PROPOSE-AND-COMMIT | The in-box agent grows `distrobox.ini`/`policy/`/`box-rebuild.sh`/etc. only by editing the LIVE clone at `/home/core/.local/share/fedora-dev/` and opening a PR. `fedora-dev` merges on Arthur's clickable APPROVE; the next box rebuild applies. Ad-hoc installs vanish on rebuild. |

### Class-(c) sources — the bounded last-resort exception (fleet-wide; identical in fedora-desktop + fedora-dev + fedora-bootstrap)

**(c)** ONLY when **no class-(a) Fedora package and no class-(b) vendor `.repo`** exists for the
needed artifact — a **last-resort, zero-base check, re-confirmed at every version bump**; the
moment it appears in Fedora or a vendor `.repo` it MUST move to (a)/(b): an **official-upstream
binary release artifact**, fetched over TLS from the project's **own canonical release channel**
— whose exact host + org/repo (or release-API URL) is **pinned in the disclosure row and
changeable only as a control-plane change** — never a mirror, aggregator, COPR, PPA, OBS home
project, language-package-manager registry (Maven Central/npm/PyPI/crates.io/RubyGems), or
third-party rebuild. Each artifact MUST be **(1) version-pinned** via a Containerfile `ARG` (or
`distrobox.ini`/setup pin), the SOLE exception being an artifact Principle 6 designates
latest-at-build; and **(2) integrity-verified FAIL-CLOSED before any use, GRADED by what is
verifiable on the RAW BINARY via the direct-download path** (not by a signed repo we do not
consume):
- **c1** — a detached **GPG signature on the binary** (`<artifact>.asc`/`.sig`), verified against
  the vendor's key fingerprint pinned in-repo (`gpg --verify`). Strongest.
- **c2** — a vendor-published **checksum** (`sha256/sha512`) with **no binary signature
  available**; `sha*sum -c`, acceptable ONLY because no signature is offered.
- **c3** — a **latest-at-build** artifact with no pre-pinnable hash: TLS-authenticated fetch from
  the vendor's own release API + **resolve-and-log** (auditable record, NOT a fail-closed gate);
  reserved to artifacts that GENUINELY cannot be pinned, each **individually named AND
  control-plane-approved** — never a general unpinned escape hatch.

Take the **strongest grade the direct channel offers** — you may NOT use c2 when a c1 signature
exists, nor c3 when a hash can be pinned. The build **fails closed** on any mismatch / missing /
unfetchable check.

**Consume the BINARY, never a foreign-distro package manager.** Where a vendor ships a signed
**apt** (or other non-dnf) repo but no dnf repo, do NOT add or invoke that package manager on
Fedora, and do NOT unpack its `.deb`/`.pkg` to reach the binary — take the vendor's
**directly-published raw binary** from the same canonical channel and verify it per the grades
above. A signed foreign-distro repo raises confidence the vendor's key is genuine but does NOT set
the grade; the grade is what we can verify on the binary we install.

**Shape is a within-grade TIEBREAKER, not a gate.** A **persistent runtime-layer binary IS
permitted** (the former absolute "$PATH binary NEVER permitted" ban is removed — the rule gates
PROVENANCE, not shape). When two artifacts share a grade, prefer strongest→weakest: (i) a
**build-time-only tool** (runs once, installs nothing on `$PATH`, deleted) → (ii) a webapp/archive
**deployed into a class-(a) runtime** (an Apache `.war` into Fedora's Tomcat) → (iii) a
self-contained **AppImage from `/opt`** → (iv) a **persistent runtime-layer binary** (e.g. an OCI
runtime such as `runsc`) registered with the engine. Each (c) artifact gets a **disclosure row**
in the Packages table (pinned canonical URL + version + **grade c1/c2/c3** + shape); the table's
**enumeration line lists every (c) artifact in use**.

**ANTI-THEATER (doctrine — do not rebuild the sieve).** A static SCRIPT-SCAN for "bad" fetch/install
patterns is **NOT** a valid 2(c) backstop — it is the exact pattern the fleet already de-theatered
(v1.2.48 dropped the inert `--cap-add` denylist; `managed-settings.json`'s deny-list "is best-effort
only… not the boundary"). Detecting bad patterns in arbitrary shell is a sieve — a seventh evasion
always exists — and a guard that implies coverage it can't deliver is **worse than none**. For a
fetched binary the boundary is the **installer's OWN fail-closed verification** (sha/GPG; exit non-zero
+ install nothing on any mismatch/missing) **+ the disclosure row + the click** — never a scan.
(A host static fetch-guard was built and closed for exactly this reason.)

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
| nftables | Fedora current | distro (a) | the firewall backend. tailscaled programs its rules via the nftables **Netlink API** (no binary needed; it falls back to nftables and never crashes if iptables is absent — verified on the bootstrap host, which runs tailscaled with zero iptables); netavark's default firewall driver (nftables since Fedora 41). (`iptables-nft` dropped — the prior "tailscaled crashes without the binaries" rationale was false.) |
| openssh-server | Fedora current | distro (a) | the login door (key-only since v1.1.9; ALL keys from `github.com/<user>.keys` synced by entrypoint at every start — the GitHub account is the single trust root, no in-image allowlist; key trust is managed centrally on the account). Two paths into :22 — Tailscale SSH on tailnet (keyless) AND public ssh on host :4444 → container :22. mosh bootstraps over either ssh path. |
| mosh | Fedora current | distro (a) | roaming-resilient remote shell (UDP, AEAD-authenticated; bootstraps over ssh). v1.1.9: public UDP range 61001-62000 (non-default, to avoid colliding with the bootstrap host's own public mosh which uses 60000-61000 on the same kernel UDP namespace); clients invoke with `mosh -p 61001:62000 --ssh="ssh -p 4444"` for the public path. |
| tailscale | Tailscale dnf/rpm repo | vendor (b) | tailnet node + keyless Tailscale SSH on the tailnet IP (primary access path). Co-exists with public ssh :4444 + public mosh 61001-62000 added in v1.1.9. |
| tmux | Fedora current | distro (a) | session multiplexer; every interactive login gets its OWN session in the shared `main` group (shared windows/work, independent per-client current-window selection), with a `/etc/tmux.conf` tuned for multi-device co-view: `default-terminal tmux-256color`, `window-size latest` (the session follows whichever device most recently sent input — seamless macOS↔iPad handoff over mosh; **`prefix+g` cycles latest→smallest→largest**), `fill-character ' '` (idle larger device blank-letterboxes instead of `·`-garble), `aggressive-resize on`, `client-attached`/`-resized`→`refresh-client`. NB tmux gives a window ONE size, so differently-sized devices on the SAME tab can't each be full-size — `latest` makes the active device win; the rest degrade cleanly (crop/letterbox, never garbled). Trigger-and-detach is the operator pattern. |
| distrobox | Fedora current | distro (a) | declaratively bootstraps the in-container claudebox via `distrobox assemble create --file distrobox.ini` |
| inotify-tools | Fedora current | distro (a) | `inotifywait` in the entrypoint watches `rebuild.request` flag from the in-box agent (replaces systemd `.path` unit; no systemd here by design) |
| sudo | Fedora current | distro (a) | break-glass escalation for the operator (`core` in `wheel`). v1.1.9: no password set on `core` (chpasswd dropped), so sudo is effectively unreachable for the human; break-glass is `podman exec -u 0 fedora-dev bash` from the VPS host. Kept for completeness; near-zero footprint. |
| procps-ng | Fedora current | distro (a) | `pgrep` for the entrypoint watchdog AND for `run.sh`'s `--health-cmd` |
| glibc-langpack-en | Fedora current | distro (a) | UTF-8 rendering for tmux and the terminal observing Claude's output |
| openssl | Fedora current | distro (a) | RS256-signs the GitHub App JWT in `bin/gh-app-auth.sh` — the standing-credential minter runs in `entrypoint.sh` at the BASE layer, where `gh` is absent. The `openssl` CLI is not otherwise pulled into the base (only `openssl-libs` is). ~1MB |
| git-core | Fedora current | distro (a) | base-layer git for `entrypoint.sh`'s first-boot live-spec clone + the `seeded-no-git` self-heal (clone / ls-remote / config run at the BASE layer, before/without the claudebox) AND the standing-credential's `credential.helper store` wiring. The LEAF package (the `git` metapackage pulls perl-Git + git-{email,svn,…}); `git-core` provides the `git` binary + clone/config/ls-remote. The agent's own richer `git` is the claudebox copy. |
| nano | Fedora current | distro (a) | one break-glass editor (Fedora 44's minimal base doesn't reliably ship `vi`). ~600KB |

## BOX PACKAGES

Inside claudebox (`distrobox.ini`'s `additional_packages`). Refreshed daily from Anthropic's `latest` channel + Fedora repos.

| Package | Pin | Source (rule 2 class) | Why required |
|---|---|---|---|
| claude-code | Anthropic dnf/rpm repo (`latest` channel) | vendor (b) | the agent — claudebox's purpose; refreshed daily so new model releases are accessible day one. In-place self-update is LOCKED OFF (`DISABLE_UPDATES`/`DISABLE_AUTOUPDATER` — set in `/etc/profile.d` by `claudebox-init.sh` + policy-tier in `managed-settings.json`) so a self-managing "native build" can't plant `~/.local/bin/claude` and shadow the RPM on the home volume; updates flow ONLY via the box rebuild's `dnf install` (the documented "Pick up newer claude-code: run `claudebox-rebuild`" path). `claudebox-init.sh` also self-heals any pre-existing native shadow off the home volume |
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
| entrypoint.sh | PID 1 (root): syncs ALL ssh keys from `github.com/<user>.keys` (key-only sshd; the GitHub account is the trust root) + supervises sshd + tailscaled + rootless podman API socket + inotify rebuild-flag watcher + daily-tick + first-boot live-clone-or-seed + eager first-boot claudebox assemble; **provisions the STANDING GitHub credential** (App token via `gh-app-auth.sh install`, or a static `GH_TOKEN`) + **ferries the FITNESS App token** (mints a <=1h token from `/run/secrets/gh_app_key_fitness` → `~core/.config/fitness/env` 0600; the fitness KEY never enters the box — only the token; independent-reviewer identity for `bin/fitness-review.sh`) + **self-heals a `seeded-no-git` live spec into a real clone** once GitHub is reachable + 40-min refresh ticks for BOTH App tokens; pgrep+kill-0 watchdog; SIGTERM trap for clean shutdown |
| spin-up.sh | interactive spin-up wizard (the by-hand entry point): ASKS for `TS_AUTHKEY` (blank = web-login fallback) + `IMAGE` + (optional) a **standing GitHub App credential PASTED at the prompt** (App ID/Installation ID + the PEM → a podman secret via `bin/gh-app-provision.sh`), exports them, then `exec`s run.sh. **`COLLECT_ONLY=1`** gathers the answers + creates the secret and EMITS them as `export` lines WITHOUT launching — so the host `day0.sh` can drive this wizard to ask fedora-dev's OWN questions (single source of truth) instead of duplicating them. Mirrors `fedora-desktop/spin-up.sh` |
| run.sh | manual deploy contract (`podman run -d`-style with --health-cmd, devices, volumes); the env-driven path `spin-up.sh` wraps; fallback for non-systemd hosts. Optional STANDING GitHub credential: `GH_APP_ID`+`GH_APP_INSTALLATION_ID`+ one of `GH_APP_SECRET` (a podman secret — the paste path), `GH_APP_KEY_FILE` (bind a PEM), or `GH_TOKEN`; the key lands read-only in tmpfs `/run/secrets/gh_app_key`. Optional FITNESS-REVIEW credential (the fleet-wide independent reviewer): `GH_APP_FITNESS_ID`+`GH_APP_FITNESS_INSTALLATION_ID`+`GH_APP_FITNESS_SECRET` (or `GH_APP_FITNESS_KEY_FILE_HOST`); key → tmpfs `/run/secrets/gh_app_key_fitness`, consumed by the entrypoint's fitness ferry |
| fedora-dev.container | systemd Quadlet for managed deployment (declarative spec: AutoUpdate=registry, Notify=healthy, HealthCmd, Volume=, SecurityLabelDisable=true; **NO EnvironmentFile** — key-only sshd since v1.1.9, optional TS_AUTHKEY via podman `Secret=`; optional standing GitHub App credential via `Secret=gh_app_key` + `Environment=GH_APP_ID=…`; optional fitness-review credential via `Secret=gh_app_key_fitness` + `Environment=GH_APP_FITNESS_ID=…` — fleet-constant IDs inline, commented until the secret exists) |
| distrobox.ini | claudebox manifest: image pin, pre_init_hook drops Anthropic `latest`-channel `.repo`, additional_packages |
| claudebox-init.sh | post-assemble host bridges (CONTAINER_HOST export + in-box `claudebox-rebuild` flag-writer). Runs over quote-safe `podman exec` (container-root) channel. Also writes the claude-code self-update LOCKOUT (`/etc/profile.d/20-claude-no-selfupdate.sh`: `DISABLE_UPDATES`/`DISABLE_AUTOUPDATER`) and SELF-HEALS any native-build shadow (`~/.local/bin/claude` symlink into `~/.local/share/claude/` + the version store) off the home volume so the package-managed `/usr/bin/claude` always wins |
| claudebox-assemble.sh | called by entrypoint on first boot + by box-rebuild on every rebuild: `distrobox rm -f` (recovery) → `distrobox assemble create` → first-enter retry → bridges + policy stamp. An EXIT trap writes `~/.local/state/claudebox/.assemble-failed` on any non-zero exit (clears it on success) — the single authoritative signal for every assemble path (first boot, `bin/claude` self-heal, box-rebuild) that the health cmd reads so a half-assembled box surfaces UNHEALTHY (#11) |
| box-rebuild.sh | full claudebox rebuild (self-serializing via flock); triggered by daily tick / in-box flag / host-shell command — all converge here |
| claudebox-daily.sh | daily-refresh decision: probe session lock → rebuild now if idle, else write `rebuild.pending` marker (the `claude` wrapper fires it on session exit) |
| bin/claude | host-shell wrapper; holds SHARED session lock for session lifetime so daily refresh + host's monthly fedora-dev refresh defer while live; on exit fires deferred rebuild atomically |
| bin/claudebox-rebuild | host-shell trigger; starts box-rebuild.sh detached + tails the log |
| bin/build-throwaway.sh | standardized in-box THROWAWAY candidate build: wraps `podman build --isolation=chroot` with the persistent dnf cache (`$HOME/.cache/fd-dnf`→`/var/cache/libdnf5`) + the home-volume layer cache so churn re-downloads nothing; tags `localhost/disposable/<name>:val-<sha-or-rand>` (never pushed); trap teardown rmi's the candidate + rm's any temp tree on EXIT (success/fail/INT/TERM/HUP) while the caches persist; sweeps orphan disposable images + temp trees first so a kill-9 leaves nothing on the home volume; builds only the repo's OWN Containerfile (provenance) and never mutates the immutable live tree (`-c <srcdir>` bolts on a separate throwaway COPY tree on the writable home volume). Complements `bin/validate.sh` (the full T1–T4 verdict harness) |
| bin/fresh-tree.sh | start task work on a GUARANTEED-fresh tree: `git fetch` + a `git worktree` checked out on a NEW branch off current `origin/main`, with its OWN HEAD+index, isolated from the persistent clone — the TOOLING for the worktree mandate in `policy/CLAUDE.md` (kills the stale-clone hazard where a long-lived `~/repos/<repo>` silently trails origin/main → wrong-base edits). Usage: `WT="$(bin/fresh-tree.sh <repo> <branch>)" && cd "$WT"`; commit + bare-push from there; `git -C <clone> worktree remove "$WT"` when done. Idempotent (reaps a stale same-named worktree first) |
| bin/gh-app-auth.sh | STANDING, auto-rotating GitHub credential so the autonomous dev loop never stops for auth. Mints a short-lived (<=1h) GitHub **App installation token** from the App private key (RS256 JWT via `openssl`; key read from tmpfs `/run/secrets/gh_app_key`, NEVER layered — Principle 5). `install` wires the token to BOTH consumers via **home-volume paths that exist IN-BOX** (where the agent runs git): git's built-in **`store` helper** + `~/.git-credentials`, and the box `gh` CLI's `hosts.yml` (+ `config.yml` version marker, avoiding gh's multi-account migration). `token` prints a fresh token. The <=1h token is re-minted on the entrypoint 40-min tick. Fail-closed (any missing input/signing/API error → non-zero, nothing on stdout; bounded curl timeouts so init can't hang). **Control-plane (secrets/identity).** |
| bin/gh-app-provision.sh | paste-based GitHub App provisioning helper for the SETUP wizards (a sourceable function library): reads an App private-key PEM **PASTED at the terminal** and streams it STRAIGHT into a `podman secret` (`--replace`, never a loose file on disk) + collects the two PUBLIC ids — feeding the container contract above (`bin/gh-app-auth.sh`, secret at `/run/secrets/gh_app_key`). `prompt_github_app` (by-hand `spin-up.sh`); `read_pem_to_var`/`make_secret_from_var` (the root→core ferry the host `day0.sh` uses). CANONICAL here; mirrored VERBATIM into fedora-desktop + fedora-bootstrap (keep in lockstep). **Control-plane (secrets/identity).** |
| bin/check-build-parity.sh | asserts the Tier-1 (in-box) build invocations carry the SAME parity-critical flags as the Tier-2 host build — the dnf-cache bind (`/var/cache/libdnf5`) + `BUILD_ARGS` forwarding — so an in-box GREEN reliably predicts a host GREEN. Motivated by #53 (validate.sh lacked the cache bind, so a bind-mount-only failure passed in-box but REDd at the host). `--isolation=chroot` is the one JUSTIFIED divergence (required in-box for nesting; absent on the host top-level engine). Run after touching any `podman build` line; checks `build-throwaway.sh` + `validate.sh` against fedora-bootstrap's `build-candidate.sh` (when its clone is present) |
| bin/fitness-review.sh | the INDEPENDENT fitness harness (Step 4b): headless `claude -p` reviews a GREEN PR against the three questions (Q1 asked-for / Q2 non-contradict / Q3 fit + doctrine) and posts `Fitness review: VERDICT PASS\|RETURN\|ESCALATE` **as the fleet fitness App** (`FITNESS_LOGIN`, default `oso-gato-fitness-claudebox`) — the unforgeable signal `bin/auto-merge.sh` greps. Token via env `FITNESS_GH_TOKEN` or the entrypoint's ferried `~/.config/fitness/env` (explicit env wins). Fail-closed: refuses when the login is unset/== PR author, when the PR isn't host-GREEN, or when no token is available to --post. **Control-plane (merge-trust identity).** |
| bin/pr-poller.sh | the DEV-SIDE POLLER (Step 5): plain-shell watcher (NO model in the loop) that routes each open PR by (host verdict, tier, fitness verdict) via the pure `plan()` core — RED → bounded headless fixer on the FEATURE branch; GREEN+unreviewed → `fitness-review.sh`; GREEN+B/C+PASS → `auto-merge.sh` (**dry-run unless `POLLER_ARMED=1`** — arming is the #96 Tier-A click); Tier A / ambiguity → surface to Arthur. Progress-based fixer stop (no silent quit), flock singleton, `--selftest` for the pure core. Every host/fitness verdict is bound to the PR's head SHA and the merge is `--match-head-commit`-pinned (a fresh, ungated head never inherits a prior verdict). Each sweep FIRST retires SUPERSEDED PRs deterministically: a MERGED PR whose body carries a WHOLE LINE that is exactly `Supersedes #N[, #M…]` (same-repo; markdown-aware all-or-nothing parse — backticked/blockquoted/mid-sentence/malformed lines and fenced/code-indented blocks never act) closes a still-OPEN #N with a comment — the sanctioned close path (the interactive agent is classifier-denied `gh pr close` on PRs it didn't create, run-003 lesson b). Runs even DISARMED: the authorizing event is the superseder's human-gated merge; a close is reversible and never touches main (`RETIRE_LOOKBACK` most-recently-updated merged PRs, default 15, so a late-merging parked PR still enters the window; scan-once + retired state markers; a human REOPEN is durable — a prior retire comment on the PR blocks any re-close even after state loss; fail-closed to no-op on issue numbers / cross-repo refs / non-open targets / transient API failures, close failures logged as RETIRE FAILED). Sweep is fetch-BATCHED for the 10s cadence: ONE TSV list call carries number+ref+sha, ONE sha-bound comments call per open PR; tier(files) + fitness comments are fetched ONLY at the GREEN routing moment, rc-checked so a transient fetch failure SKIPS that PR for that sweep (retry next) instead of misrouting (no tier=A-by-failure PRESENT stickiness, no spurious fitness re-runs); steady state ≈ 360×(2+N) calls/h, ceiling ~10 sustained open PRs. |
| bin/poller-service.sh | supervises `bin/pr-poller.sh --watch` as a headless service. OPT-IN via `POLLER_ENABLED=1` (Quadlet/run.sh env), launched by `entrypoint.sh` INSIDE the claudebox (the poller's REVIEW/FIX steps spawn `claude`, absent from the base) as PLAIN shell — no Claude Code → no gate/classifier → the sanctioned deterministic auto-merge path can execute once armed (the interactive agent is deliberately gated FROM merging). Waits for `.assembled` + the standing GitHub credential, then runs the watch loop with restart-on-death. DISARMED by default (`POLLER_ARMED=0`); arming is the #96 Tier-A flip. |
| bin/auto-merge.sh | the DETERMINISTIC merge executor: re-checks ALL THREE gates fail-closed from GitHub (tier=B/C via `tier-classify.sh`, host GREEN by `$LG_HOST_LOGIN`, fitness PASS by `$FITNESS_LOGIN` ≠ PR author) and only then merges; any missing/unverifiable gate ⇒ REFUSE. `--dry-run` prints the decision. **Control-plane (the merge boundary's executor).** |
| bin/tier-classify.sh | pure tier classifier: changed-file paths (stdin) → `A\|B\|C` per the control-plane class list (policy/** , managed-settings, Quadlets, workflows, run.sh security flags, gate hooks ⇒ A). Fail-closed: unknown/unclassifiable ⇒ A (human). |
| policy/CLAUDE.md | runtime law for the in-claudebox agent (its role, do/don't, propose-and-commit, validation discipline) |
| policy/managed-settings.json | deny-rule guardrails (defense-in-depth) + bypass-permissions disabled (managed tier) + `env` lockout (`DISABLE_UPDATES`/`DISABLE_AUTOUPDATER`) so claude-code never self-updates in-place (paired with the profile.d lockout in `claudebox-init.sh`) |
| policy/hooks/gate-push.sh | the REFSPEC-AWARE promotion-gate PreToolUse hook (Bash matcher), stamped to `/etc/claude-code/hooks/`. Feature-branch pushes fall through autonomously; any push that could touch `main` plus the merge verbs route to an in-session `ask` only Arthur can answer (on `fedora-dev`, the merge box). Fail-closed, no jq dependency, wrapper-script scanning. **Control-plane class** — the in-session backstop behind the clickable merge. (PR-only boxes ship the same hook with main/merge → `deny` instead of `ask`.) |
| policy/hooks/gate-push.test.sh | full ALLOW/ASK/DENY matrix for `gate-push.sh` (incl. chained/quoted/escaped/variable adversarial evasions to `main`); `bash policy/hooks/gate-push.test.sh` → exit 0 = all rows pass. Run after any gate edit |
| health-marker.test.sh | regression test for the #11 assemble-health marker: asserts the two health-predicate copies (quadlet `HealthCmd` + `run.sh` `--health-cmd`) stay byte-identical and carry the `.assemble-failed` clause, exercises the verbatim assemble EXIT trap, and drives the exact shipped predicate through the SUCCEEDED / IN-PROGRESS / FAILED states (incl. the stale-`.assembled` failed-rebuild case); `bash health-marker.test.sh` → exit 0 = all rows pass. Run after touching the health cmd, the assemble marker, or the trap |
| bin/fleet-guard-parity.sh | fleet guard-parity check: fetches the SHARED claude-code guard payload (managed-settings deny-list + `env` lockout, the #45 self-update lockout/self-heal in `claudebox-init.sh`, claude-code provenance in `distrobox.ini`) from every fleet claudebox repo (public, raw, no auth) and FAILS if any drifts from fedora-dev (the canonical anchor). The "one source of truth" for a self-contained-repo fleet — it ENFORCES the duplicated copies stay identical instead of physically merging them (which would break dev's offline seeded-no-git path). Catches the #45-class silent drift automatically |
| .github/workflows/build.yml | CI: on push + 15th monthly (--no-cache) + manual; build-push-action + cosign keyless signing via OIDC |
| .github/workflows/fleet-guard-parity.yml | CI: runs `bin/fleet-guard-parity.sh` on push/PR/manual + daily (04:30 UTC) so guard drift surfaces even with no PR activity; built-in token only (fleet repos are public) |

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
