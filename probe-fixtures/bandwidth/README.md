# bandwidth-probe fixtures

Fixtures for `bin/bandwidth-probe.sh` (fedora-dev#322, feat of objective #311). They live in the repo
so the probe is **self-contained and repeatable** — it never depends on a scratch context somebody has
to build by hand, and what it measures is reviewable in a diff.

One directory per asset class, named exactly as the probe's class ids:

| dir | class | how the probe drives it | why it is shaped this way |
|---|---|---|---|
| `ospkg/` | OS packages | two `build-throwaway.sh` builds, each with a **unique `CACHEBUST`** | the cachebust defeats the podman LAYER cache on purpose, so build 2's `dnf` step genuinely re-runs and the **persistent dnf package cache** is what must supply the bytes. Without it the layer cache answers for the class and the dnf cache is never consulted — the arm would pass without measuring the thing #311 is about. |
| `baseimg/` | base images | two `build-throwaway.sh` builds, no cachebust | the cache under test IS the local layer/blob store, and `FROM` consults it directly. Nothing is forced: build 2 costing zero bytes is precisely the property being measured. The `COPY` keeps the fixture's only network-touching step the base-image resolution. |
| `gitobj/` | git objects | two fresh `git clone --depth 1` into throwaway trees | a *cache* for git objects is what #311 found missing ("Git clones: no cache. Every clone is fresh"), so the honest fixture is two consecutive **fresh** clones. Build 2 re-downloading everything is the true reading today, and the arm is expected to report NONZERO until a sibling feature lands a cache. The remote defaults to this repo's own `origin`; `gitobj/remote` overrides it. |
| `langdep/` | language / vendor downloads | **deliberately absent** | there is no such asset in this repo to measure. Build Principle 2 forbids pip/npm/cargo/gem installs outright, and `CLAUDE.md` records "Class-(c) artifacts in use: none." The probe therefore reports `SKIPPED (no langdep asset in the fixture)`, and a SKIPPED class **blocks exit 0** — silence must never read as zero bytes. |

## Adding a class fixture

Drop in `<class>/Containerfile` and the probe measures it on the next run — the arm list is
data-driven, so a class stops being SKIPPED the moment an asset exists to measure. If the fixture's
step would otherwise be served by the layer cache and you want the *asset* cache measured instead,
declare `ARG CACHEBUST` and reference it in the step, as `ospkg/` does.

## What these fixtures cost

`ospkg` and `baseimg` cost nothing on a warm box (that is the point). `gitobj` genuinely re-downloads
a shallow clone on every run, and the negative control genuinely downloads once more — that is the
price of a control that can actually fail, and #311's acceptance is a measurement, not an assertion.
