# The upstream re-baseline

This repository was re-baselined onto upstream firstmate on 2026-09-02.
Read this before attempting any future upstream sync, and before assuming anything about this repository's history prior to that date.

## What the repository is now

The foundation is upstream [`kunchenguid/firstmate`](https://github.com/kunchenguid/firstmate) at commit `8988af2` ("fix(bearings): keep active children underway during captain holds (#3505)", 2026-09-02), with upstream's real commit history intact behind it.
Two commits sit on top of that foundation on `rebaseline/00-base`:

- `8cdd88e` retires the no-mistakes CI gate by deleting `.github/workflows/no-mistakes-required.yml`.
- `462bdb9` is a merge commit joining this repository's own prior history (`127733f`) into the foundation, so both histories are reachable from a single tip.

Everything local to this fork was then re-applied on top of that base as a stack of pull requests, one slice per file group, rather than merged in from the side.

## Why this matters: `git merge upstream/main` now works

Before the re-baseline the two repositories shared **no commit history at all**.
This fork was created by a fresh file import rather than a `git clone`, so `git merge-base HEAD upstream/main` produced no output and exited non-zero, and the two trees had distinct root commits (`fae87e6` here, `ccdea30` upstream).
Every sync therefore had to go through a hand-built synthetic merge base and `git merge-file`.

After the re-baseline, `git merge-base rebaseline/00-base upstream/main` resolves to `8988af2`.
Upstream syncs are now an ordinary `git fetch upstream && git merge upstream/main`, with real three-way merges against a real common ancestor.

## The trap that made this necessary

Two findings from `data/upstream-classify-r5/report.md` (task `upstream-classify-r5`, run 2026-09-02) drove the decision to invert the direction and re-baseline instead of merging upstream in.

**The synthetic merge base named a commit that does not exist.**
The import commit message cited upstream `fbf9ad8` as the fork point.
That SHA is not in upstream's history: `git cat-file -t fbf9ad8` fails, `git fetch upstream fbf9ad8` finds no such ref, the GitHub API returns `422 No commit found for SHA`, and it is absent from all 32 fetched upstream refs.
The real closest upstream commit is `e063ca5` (2026-07-15), which matches this fork's root snapshot on 205 of its 209 files.
The other four files carried code that has never existed anywhere on `upstream/main`.

**That contamination silently deleted a safety guard, with no conflict marker.**
A real three-way merge of `bin/fm-spawn.sh` against the synthetic base removed `is_linked_worktree_of` entirely: five occurrences before the merge, zero after, and **not inside any conflict block**.
Its two test files merged with zero conflicts while losing 140 and 37 lines.
Because the synthetic base contained content upstream never had, the merge read that content as "upstream deleted this" and removed it cleanly.
`is_linked_worktree_of` is the treehouse-ownership half of the spawn worktree-isolation guard that the worktree-tangle protection depends on, so a low conflict count on `fm-spawn.sh` was a false safety signal rather than a green light.

The general lesson, which outlives these two specific commits: a synthetic merge base is only as trustworthy as its provenance, and an unverifiable provenance claim is a silent-data-loss risk, not a paperwork problem.
Verify a claimed fork point against the upstream remote before merging through it, and treat a conflict-free merge of a heavily diverged file as a reason to diff the result, not as evidence that the merge was safe.

## Reference

`data/upstream-classify-r5/report.md` holds the full classification: the 34-file overlap set, the per-file conflict analysis, the reproduction commands for both findings above, and the empirical evidence for each claim.
It is fleet-local and gitignored, so it lives only in the home that ran the investigation.
