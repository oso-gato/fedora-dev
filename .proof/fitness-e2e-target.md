# Fitness-review end-to-end proof target (THROWAWAY — do not merge)

This pull request exists only to give the independent fitness-review harness
(`bin/fitness-review.sh --post`) a real, host-GREEN `live-validate` PR to post a
verdict against.

It proves, end to end, that the fitness App identity `oso-gato-fitness-claudebox`
— an identity **distinct from the PR author** (`oso-gato-nox-claudebox[bot]`) —
can post the `Fitness review: VERDICT …` comment that `bin/auto-merge.sh` reads as
the third, unforgeable gate (separation of duties).

Lifecycle: opened by the dev box → host live-gate (Gate B) posts VERDICT GREEN →
fitness-review harness posts its verdict → this PR is **closed, never merged**.
