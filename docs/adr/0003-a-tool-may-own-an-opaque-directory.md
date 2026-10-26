# 0003 — A tool may own a directory the model cannot address

## Status

Accepted.

## Context

Every write in this package goes through the VFS: content is buffered,
`file_sync` shows a diff, and only then does disk change.  That rule is
what makes the review the control, and it is stated as a rule because a
tool that wrote around it would be writing files the user never saw.

`render_diagram` writes files.  A rendered image is bytes on disk, and the
chat needs somewhere to point at.  It is not covered by the rule above,
and the reason is not that the rule is inconvenient.

**The model cannot name the destination.** A render's path is the digest
of the source that produced it, under a directory chosen by a defcustom.
The model sends source and nothing else. There is no argument for a
directory, a file name or an extension, and no way to express one. So the
question the review answers — "should this content go to this path?" — has
no first half and no second half. There is nothing for the user to decide.

**The content is not text.** `gptel-yatools-vfs-write` refuses an SVG that
carries raw bytes and could never carry a PNG; the VFS is a text layer
with an encoding policy, and a bitmap is neither. Shipping images through
it would mean exempting them from the encoding checks that exist to keep
the VFS honest.

**Nothing is lost by not reviewing it.** The durable copy of every diagram
is the conversation: the tool call in the transcript holds the full source,
and the image is a pure function of it. A rejected or discarded cache entry
costs milliseconds to rebuild. A rejected `write_file` would cost the
user's work.

**The alternative is worse.** Confirming each render was considered and
rejected: a prompt that decides nothing teaches the user to approve without
reading, which is the failure mode the review exists to prevent. That
matters more here than anywhere else, because the same prompt would sit
next to `execute_command`'s, where the answer does decide something.

### The exception that proves the rule

`execute_command` is not covered by this ADR and must not be. It can write
anywhere the user can — including over the very files the VFS is holding a
baseline for — and it is the reason the confirmation line prints the whole
command rather than its first few hundred characters. It is not "a tool
that may write freely"; it is a tool whose one argument *is* the action,
and whose approval is the review.

The distinction is not "does it write". It is: **can the model express a
destination, and can the result be inspected as text?** `execute_command`
answers yes to both, and so is gated on approval. A render answers no to
both, and so is not.

## Decision

A tool may write outside the VFS when all three of these hold:

1. **The destination is not expressible by the model.** No argument names a
   path, a directory, or a file name; the tool derives them all from the
   content and from configuration the user set.
2. **The output is opaque.** It is not text the model could have produced
   or the user could read in a diff — an image, a binary, a compiled
   artifact. There is no meaningful review of it as content.
3. **The output is derived and disposable.** It can be regenerated from
   something that *is* durable and *is* reviewed or logged — here, the
   source in the tool call. Deleting the whole directory loses time, not
   data.

The tool owns exactly one directory, taken from a defcustom, and writes
nothing else. It does not touch an existing file outside that directory,
does not read the workspace, and does not put anything in the VFS.

`render_diagram` is the first such tool. The diagram cache is the first
such directory.

## Consequences

- "Writes go through the VFS" gains a stated exception instead of an
  unstated one. A future reviewer who sees `render_diagram` writing to disk
  should read this ADR before "fixing" it; the fix would remove the feature,
  not the exception.
- The three conditions are the test to apply to the next candidate. A tool
  that fails any one of them goes through `write_file`, with review, or it
  does not write.
- The cache directory is a preference, not a correctness requirement: a
  wiped cache is rebuilt from the transcript. That is what condition 3
  buys, and it is why no sweep, TTL or reference count is needed — the
  directory can simply be emptied.
- Nothing here weakens the confirmation machinery. `execute_command` stays
  confirmed, `file_sync` stays reviewed, and the render tool is
  unconfirmed *because* it has nothing to approve.
- A tool that later wants to write somewhere the model *can* influence —
  a path argument, a project subdirectory — fails condition 1 and must use
  the VFS. The conditions are about expressibility, not about trust in the
  caller.
