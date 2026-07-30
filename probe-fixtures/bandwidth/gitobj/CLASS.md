# bandwidth-probe fixture — GIT OBJECTS class (fedora-dev#322 / objective #311)

This class has no `Containerfile`: the asset is fetched by `git`, not by a build step, so the probe
drives it directly. The presence of this directory is what DECLARES the class; delete the directory and
the probe reports `SKIPPED`, which blocks exit 0 rather than passing quietly.

**What the probe does.** Two consecutive `git clone --depth 1` into fresh throwaway trees, each
measured. Both trees are reaped on every exit path.

**Why two fresh clones, rather than clone-then-fetch.** #311 measured the defect precisely: *"Git
clones: no cache. Every clone is fresh."* A `git fetch` over an unchanged repo pulls almost nothing
whatever caching exists, so a clone-then-fetch pair would read ~zero and report this class healthy
while the actual waste — every fresh clone paying for the whole history again — went unmeasured. Two
fresh clones measure the thing that is actually broken.

**Expected reading today: NONZERO, and that is correct.** There is no git object cache in this repo,
so build 2 re-downloads and the arm reports NONZERO → the probe reads RED. #311's non-goals say so
outright: this feature only measures, and is expected to read RED until the sibling features land. When
a cache does land, this arm turns ZERO on its own with no change here.

**The remote.** Resolved from this repo's own `origin` — self-contained, no third-party dependency, and
the same asset the apparatus really does clone (`fresh-tree.sh`, the poller's worktrees). To point the
arm elsewhere, put a URL on the first non-comment line of a file named `remote` beside this one.
