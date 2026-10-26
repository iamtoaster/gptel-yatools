# 0002 — The tool kit stays one file, with three declared seams

## Status

Accepted.

## Context

`gptel-yatools-common.el` is the file every tool module requires. It holds
four things that look like separate concerns:

- **respond** — the `gptel-yatools-result` struct, the size limits, raw-byte
  escaping, truncation, the XML envelope, and the page budget
  `gptel-yatools-page` offers to a tool that pages its own output;
- **call** — the `gptel-yatools-call` context, the deadline timer, and the
  pause for a user reading a diff;
- **define** — `gptel-yatools-define-tool`, which writes the implementation
  and the boundary from one definition and registers the tool;
- **enable** — `gptel-yatools-enable` and `-enable-all`, which decide what
  is sent.

The obvious refactor is to split it into three or four files, one per
concern, following the Emacs convention that a file is a module.

That refactor buys less than it costs.

**The dependency runs the wrong way.** The definition macro calls the
response machinery at load time, and the response machinery is used by
every tool the macro writes. Splitting them creates a `require` edge
between two files that must always load together, and a load-order
constraint that neither file states.

**There is no state to hide.** Every other module in this package earned its
own file by owning state: the VFS owns the table, the skill catalog owns the
parse cache, the shell module owns the process handling. The response
machinery has no state at all — it is a set of pure functions over strings.
A file boundary would only be a boundary between two halves of one idea.

**The problem was never the file.** It was that a tool could reach past the
respond seam without anyone noticing: `vfs_diff` called
`gptel-yatools--page-text` directly, and the truncation helpers were as
reachable as the envelope. Nothing in the file said which names were
interface and which were guts.

## Decision

Keep one file. Declare the three caller-facing interfaces in the Commentary
— respond, call, define — and make each one's members explicit:

- respond: `gptel-yatools--respond`, `gptel-yatools-page`.
- call: `gptel-yatools--call-with-timeout`, `--call-root`,
  `--call-deadline`, `--call-suspended-p`, `--with-deadline-suspended`.
- define: `gptel-yatools-define-tool`, `gptel-yatools-enable`,
  `gptel-yatools-enable-all`.

Mark the respond seam with a test instead of a file boundary:
`gptel-yatools-test-response-machinery-is-crossed-at-one-seam` fails if any
tool module mentions `--truncate`, `--truncate-slow`, `--envelope`,
`--escape-raw-bytes`, `--hard-cut`, `--respond` or `--page-text`.

`--page-text` becomes public as `gptel-yatools-page`, because `vfs_diff`
genuinely needs the budget to page its own output. Naming it is the point:
an omission became a stated interface.

## Amendment — a fourth interface, `run`

Two tool modules run subprocesses: `execute_command` and `render_diagram`.
By the time the diagram module arrived, the shell runner's process loop had
been copied into it, and the copy had already lost two of the four rules
the original encodes — closing stdin, and keeping the output of a process
that timed out — while both copies still carried the same poll margin, the
same process-group kill and the same reap.

The runner therefore moved into this file as `gptel-yatools--run-process`,
the fourth declared interface:

- run: `gptel-yatools--run-process` (an argv and a deadline in, a
  `:status`/`:exit`/`:output` plist out).

This does not reopen the decision above. The rule the original decision
rests on — *a module earns its own file by owning state* — still holds:
the runner keeps nothing between calls. What it owns is a mechanism, and a
mechanism two callers must not implement twice.

The prompt to revisit would be the one the ADR already names: if the runner
ever grows state (a process registry, a per-buffer queue, a cache of
executables), it can earn a file then. Until it does, a file boundary would
again be a boundary between two halves of one idea — `common.el` loads
before either tool module, and the `require` edge would run the wrong way.

One consequence for the seam test: `--run-process` is a stated interface, so
it is exempt from the "no tool module reaches past respond" list, exactly as
`gptel-yatools-page` is.

## Consequences

- The seam is enforced by a test, which is the only thing that keeps an
  interface from eroding once someone finds a private name convenient.
- If the response machinery ever grows state of its own — a cache, a
  buffer-local setting — it can earn a file then, by the same rule the
  other modules followed.
- A future reviewer who proposes splitting this file should read this ADR
  first: the split is not wrong in principle, it is wrong until one of the
  three parts owns something.
