# 0004 — A remote workspace runs on its own host

## Status

Accepted.

## Context

Every path this package touches is an ordinary Emacs file name, so a
workspace rooted at a TRAMP name such as `/ssh:host:/repo` was already
mostly working before anyone said so out loud: reads, writes, encoding
detection, conflict baselines, skills and project-root detection are all
performed by file-name handlers, so they happen on the host without the
package knowing the difference.

Two things did not work, and both failed quietly.

**A structural walk could not end.** `--file-ancestor` climbed a path's
parents until it saw `nil`, `""`, `"/"` or the path itself. A remote
name's top-most directory is `/ssh:host:/`, which `file-name-directory`
returns unchanged and which none of those predicates match, so the walk
never terminated — and because each pass asked `file-regular-p` about that
root, it was an endless round trip to the host rather than a cheap spin.
`vfs_diff` and `file_sync` reached that walk for every pending file, so a
remote workspace could be read and written but never synced.

**A subprocess did not follow the name.** `--run-process` called
`make-process` without `:file-handler`, which tells Emacs to build the
process locally. The command therefore ran on the machine Emacs was
running on, in `~`, and the reply described a workspace it had never
touched. `execute_command` asks the user to approve a command *in a
workspace*; running it somewhere else is the one failure the approval
cannot catch.

Three smaller facts were measured against a real host and shaped the fix:

- `shell-file-name` is a path on this machine, so naming it remotely is
  `exec: …: not found` and exit 127. The remote shell has to be asked for
  by name on the host.
- `:connection-type 'pipe` makes TRAMP rewrite the command into a heredoc
  fed to `/dev/tty`, and the tty echoes the wrapper into the buffer this
  package reads as output — 145 characters of `cd … && exec <<'uuid' env
  INSIDE_EMACS…` in front of the command's own answer. Only the tty path
  (`:connection-type` nil) returns the command's bytes.
- `(process-id PROCESS)` for a remote process is the pid of the *local*
  ssh/docker client, so the local whole-group kill signalled a group here
  and left the command running on the host. `signal-process` on the
  process object is handler-mediated and does kill the remote pid.

## Decision

1. **A remote workspace is supported.** The file tools behave exactly as
   they do locally; the file-name handler is what makes that true, and no
   tool needs a remote special case.
2. **The shell tool runs commands on the host that owns the workspace.**
   `--run-process` asks `make-process` for a handler-built process
   (`:file-handler t`) when the directory is remote, uses the tty
   connection type there, and names the host's shell rather than this
   machine's.
3. **The remote shell is probed, not assumed.** The TRAMP method's
   declared shell is a default (`/bin/sh` for every backend that ships
   with Emacs), so it is checked with `file-executable-p` along with
   `/bin/ash` and `ash` — a stripped busybox host may have only the last
   two. The answer is cached per host, because each probe is a round trip
   and the host does not change mid-session.
4. **A remote kill is TRAMP's.** The local process-group kill is kept for
   local commands; a remote one goes through `signal-process` on the
   process object, which TRAMP translates into a remote `kill`.
5. **A DIRECTORY on another machine is refused, whatever that machine
   is.** `expand-file-name` lets an absolute path replace the workspace
   root, so the command would run somewhere the workspace is not — this
   machine, or a second server.  The check compares *connections*
   (`gptel-yatools--connection`) rather than `file-remote-p` answers,
   because the latter reports only the last hop of
   `/ssh:a|sudo:root@b:/x`: two names reaching `b` through different jump
   hosts would look identical.  The identity is TRAMP's dissection —
   hop, method, user, host, port — with the prefix as the fallback for
   handlers that are not TRAMP's.  It runs before anything asks whether
   the directory exists, so a refusal never opens a connection to a host
   nobody named.
6. **The report says where the command ran.** The exit-status line reads
   "in `.` on the remote host `host:`", because "in `.`" cannot be told
   apart from a local run. The tool description says the same, so the model
   does not have to infer it.

The deadline keeps covering everything, connection included. It is counted
from the top of `--run-process`, and the margin before the kill is larger
on a remote host, so the runner reports a timeout with its partial output
instead of the tool-level timer aborting the call ahead of it.

## Consequences

- The four rules `--run-process` exists for are unchanged in spirit and
  branch in two places: which shell, and how to kill. Both are one
  `if (file-remote-p …)` in one function, which is why the seam was worth
  having.
- Round trips are the new cost centre, not correctness. A directory
  listing asks `file-directory-p` once per entry; `vfs_diff` reads every
  pending file. That is a performance question for a later change, and it
  does not affect what the answers say.
- `vfs_diff` keeps running a local `diff` over local temp copies, which is
  correct because the content is already in memory: TRAMP answers
  `unhandled-file-name-directory` with a local directory for exactly this
  case.
- Remote behaviour is tested without a network: a `/mock:`-style entry in
  `file-name-handler-alist` is what makes a name remote to Emacs, and a
  stand-in handler that receives `make-process` through `:file-handler`
  pins both the flags this package passes and the output it produces. A
  stand-in cannot prove how TRAMP behaves; the measurements above were
  taken against a real host, and a manual recipe for repeating them lives
  in the README.
- Backends that are not `tramp-sh` do not support TRAMP's remote
  `signal-process`; there the kill is a no-op and the process is left
  running on the host. That is TRAMP's limit, documented here rather than
  worked around with a fallback nobody can test.
- A command can only run where its workspace is, and the check that
  enforces that is `gptel-yatools--connection`.  Any future tool that
  accepts a path deciding *where* to act -- not merely what to read --
  should ask it rather than compare host names.
