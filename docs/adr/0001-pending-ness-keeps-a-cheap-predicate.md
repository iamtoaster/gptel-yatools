# 0001 — Pending-ness keeps a cheap predicate

## Status

Accepted.

## Context

The VFS table can answer two different questions about a path, and until
recently it spelled them the same way: `gptel-yatools-vfs-get` returned the
stored content, and only a later read revealed that the entry no longer
differed from disk. A function named `gptel-yatools-vfs-pending-p` claimed
to answer the pending question while its docstring admitted it answered
"is there an entry?". Three separate copies of "entry exists, but disk
caught up, so drop it" grew up around that ambiguity.

The obvious cleanup is to expose one function, `pending`, that returns the
entry only when it still differs from disk, and let everyone ask it.

That cleanup breaks three things.

**Structural checks.** `gptel-yatools-vfs--validate-insertable`,
`gptel-yatools-vfs--file-ancestor` and `gptel-yatools-vfs--has-children-p`
answer questions about the *shape* of the VFS — is this ancestor a file in
the VFS? does this path hold pending children? — not about whether anything
would be synced. Each of them runs while resolving a path or validating a
write, and each would gain a disk read per ancestor if it had to compare
content. `--validate-insertable` walks the whole directory chain.

**Skill-file checks.** `gptel-yatools-skills--skill-directory-p` asks
whether a `SKILL.md` exists in the VFS so that a skill being authored is
found before it is written. It runs once per directory in a walk of every
skill root, up to `gptel-yatools-skill-search-depth` levels deep.
`gptel-yatools-skills--resolve-file` asks the same of one file. Discovery is
already the expensive operation this package caches frontmatter to protect;
adding a disk read per candidate directory would undo that.

**The reaping rule itself.** Reaping has to happen somewhere. If only
`pending` reaps, then a caller that needs the structural answer can never
cause a stale entry to be dropped — which is correct — but it also means
`entry` must be a documented part of the interface rather than an
implementation detail, or the next person will "fix" the duplication.

## Decision

The pending-change module exposes both questions, named for what they answer:

- `gptel-yatools-vfs-entry` — "is there an entry here?" No disk I/O, no
  reaping. For callers that need the structural fact, or the entry's fields,
  without a comparison.
- `gptel-yatools-vfs-pending` — "…and does it still differ?" One disk read;
  the entry is reaped if disk caught up with it.
- `gptel-yatools-vfs-pending-paths` — the exact list, for tools that report
  what `file_sync` would write.
- `gptel-yatools-vfs-refusal` — the single answer to "can this be written
  now", of which a conflict is one kind.

`gptel-yatools-vfs-get` and `gptel-yatools-vfs-pending-p` are gone: both
names were ambiguous about which of the two questions they answered.

## Consequences

- A caller that wants the content of a pending entry asks `pending` and
  reads `:content`. There is no content accessor, so no third name for the
  same idea.
- The cheap question is public, and the ADR is why. A future reviewer who
  sees `entry` and `pending` side by side will otherwise merge them and make
  path resolution read the disk.
- Reaping happens where the comparison happens: inside `pending`, and in the
  enumeration walk, which must defer it because `maphash` must not see its
  table change underneath it. Those are the only two reaping sites, and both
  are inside the module.
- The header line's cache stays private to the module. Its invalidation entry
  point is `gptel-yatools-vfs-disk-moved-externally`, which says what the
  caller means — something wrote to disk behind the VFS — rather than
  naming a display mechanism. It flags the mode line and never redisplays;
  the announcement path in `gptel-yatools.el` owns the one explicit
  `redisplay` a tool call makes.
