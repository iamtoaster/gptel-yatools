# 0007 — Two questions may be answered by two lists

## Status

Accepted.

## Context

An architecture review (2026-10-30) proposed consolidating the checks that
stand between a write and the disk. `gptel-yatools-vfs-write` has an ordered
`cond`, `gptel-yatools-vfs-refusal` has another, and the review read the two
as one question answered twice: *"can this file be written right now?" has
two implementations that share conditions but agree on neither order nor
wording, and four write-only checks never reach the refusal the review acts
on.* The proposal was to move those four checks into `vfs-refusal` as
`:blocked` kinds and let the write ask it once.

Reading both lists before acting weakened the case, and the weakening is the
content of this decision. Of the four checks said to be missing:

- **Content is not a string** is a statement about the call, not the file.
  An entry always holds a string; a non-string is a caller's type error, and
  it is refused before the question about the file is asked.
- **A target that is a directory** was already refused, but was described
  with the sentence written for devices and sockets, because
  `file-regular-p` is false for every one of them. That is a wording bug,
  fixed; it was not a missing check.
- **A control character in the path**, and **pending entries stored under
  the target**, are refused by the write and cannot be reached through any
  other path: the write is the only place an entry is created. Adding them
  to the sync would be dead code, and dead code in a refusal reads as
  evidence that the tool paths are leakier than they are.

## Decision

**The two lists are two questions, and each check belongs to the question
whose answer can still be wrong when it runs.**

- A **write** refuses what is fixed about the entry it is making: the shape
  of the content, the characters in the path, the subtree already pending at
  that path. None of these can change while a review sits open.
- A **sync** refuses what the world moving on can change: the baseline
  (a conflict), the write policy (customisable mid-review), an ancestor or
  the target changing kind, a visiting buffer going dirty, the content no
  longer fitting its encoding. This is why `gptel-yatools-vfs-refusal` is
  asked again immediately before writing rather than trusting the answer the
  review was built from.

Consolidating them is not a neutral simplification, because the two lists
disagree about one case on purpose: **a write must accept a conflicted
path.** The baseline is what a conflict is measured against, so a write that
refused conflicts would make a conflicted file impossible to edit — the
user's only recourse would be `overwrite`, which needs their confirmation,
or `vfs_discard`, which throws the work away. Every attempt to merge the
lists has to special-case that one file back out again.

The checks that *do* answer the same question are shared as predicates,
already: `gptel-yatools-vfs--write-policy-refusal` and
`gptel-yatools-vfs--file-ancestor` are called by both. What was genuinely
duplicated was `gptel-yatools-vfs--validate-insertable`, a second ancestor
walk with its own wording, and it is deleted; the write now asks
`--file-ancestor` and words the remedy from whether the blocking ancestor is
a pending entry or a file on disk.

## Consequences

- A check added to one list must be justified against the rule above. "It
  seemed like it belonged with the others" is not enough; the question is
  whether the condition can change between the write and the sync.
- The review's proposal returns a `:blocked` kind with a reason; the write
  returns an `Error:` sentence with a remedy. That difference stays, because
  the readers are different: the review prints a reason beside a path it
  shows, and the write answers a model that is expected to act on the
  remedy.
- `GLOSSARY.md`'s *Refusal* entry says "the one answer" — the one answer to
  the sync question, which it was and remains. It now says so explicitly, so
  the phrase cannot be quoted as authority for merging the lists.
- The `write_file` tool description is prose written once, not generated
  from the checks. A test asserts that each check's key phrase appears in it,
  so a check added without describing it fails, without anybody assembling
  model-facing English from plists.
- If a future change makes a write-only check reachable from another entry
  point — a second way to create a pending entry — the rule sends it to
  `vfs-refusal` instead, because from that moment it is no longer fixed at
  entry time.
