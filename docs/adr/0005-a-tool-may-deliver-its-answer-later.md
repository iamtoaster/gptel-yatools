# 0005 — A tool may deliver its answer later

## Status

Accepted.

## Context

Every tool in this package used to answer on the stack: gptel calls the
boundary, the boundary runs the body, renders a Result and returns the
envelope.  That is fine for a file read or a diff, and it was fine for a
shell command only as long as commands were short.  They are not: a build
or a test suite holds Emacs for as long as it runs.

The rule the package stated against asynchronous tools was this:

> An asynchronous tool cannot cross the boundary, so registering one must
> fail.  Its result arrives long after the call returns, so there is no
> Result for the boundary to render.

That reasoning was sound and it described the boundary's limitation, not
asynchrony's.  A boundary that renders a Result does not care *when* the
Result exists; it cares that something renders it, sizes it, escapes it
and answers gptel exactly once.  All of that can happen in a callback.

Facts established from gptel's source and from measurement:

- gptel calls an asynchronous tool as `(apply FUNCTION CALLBACK
  ARG-VALUES)` — the callback first, then the declared arguments — and
  does nothing with the return value.  The callback is an ordinary unary
  closure, and `gptel--to-string` passes a string through unchanged, so an
  envelope delivered through it arrives intact.
- `gptel--process-tool-call` counts the tool calls of the response that
  have not reported yet and only advances the state machine when the last
  one does.  So N asynchronous calls in one response run concurrently and
  the request resumes by itself.
- gptel has **no** timeout machinery for asynchronous tools.  Whatever
  bounds one has to be ours.
- `gptel-abort` finds the request through `gptel--request-alist`, whose
  entry is the *network* process.  That entry is removed once the response
  has arrived, so **during a tool call `gptel-abort` finds nothing and does
  nothing**.  Synchronous commands were stoppable only because our polling
  loop lets `C-g` through and the `unwind-protect` kills the process.
  Asynchronous commands have no such loop, so cancellation has to be built.

## Decision

**`:async` decides delivery, not what the body does.**

1. A tool body returns either a `Result` or a **job** — work it has handed
   to a process, made by `gptel-yatools--spawn-process`.  The job carries
   the process, the buffer that owns the call, the deadline, and a function
   of the outcome plist that returns the Result to report.  The body owns
   *what to run* and *how to read the outcome*; nothing else.
2. The boundary decides what happens next.  With `:async t` it hands the
   job's conclusion to gptel's callback; without it, it waits for the job
   and returns the envelope.  Same body, same Result, same envelope, one
   branch.
3. Delivery re-enters the owner buffer and rebinds the call context, so a
   result rendered minutes later resolves paths against the workspace root
   settled at call time and reads the VFS of the buffer that asked.
4. A conclusion runs **exactly once**.  A deadline timer and a process
   sentinel can both fire, and gptel counts a result every time the
   callback runs, so a second delivery would inject the result twice and
   could advance the request twice.  First delivery wins; later ones are
   dropped.
5. **One process implementation.** `gptel-yatools--run-process` — the
   poll-and-return plist that `render_diagram` uses for its batch render —
   is now "spawn a job, then wait for it".  A synchronous tool is an
   asynchronous tool whose answer is waited for, which is what keeps the
   four process rules (merged stderr, closed stdin, output kept on a kill,
   whole-group kill) in one place.
6. **A synchronous tool that returns a job is a definition bug** and is
   reported as one, in the usual envelope.  gptel would stringify the job
   struct and send the printed struct to the model, which is corrupt rather
   than merely useless.
7. **Cancellation is provided here**, because gptel cannot: a buffer-local
   registry of live jobs, `gptel-yatools-cancel-tool-calls` on `C-c C-k` in
   `gptel-mode-map`, advice so that `gptel-abort` kills the jobs too, and a
   `kill-buffer-hook` so a killed chat does not leave a command running.
   Cancelling kills the jobs first and then moves the request to `ABRT`;
   delivering a "cancelled" result instead would invite the model to retry,
   turning one cancel into a loop of them.
8. **Two budgets.** `gptel-yatools-timeout` (120 s) bounds a synchronous
   call, where the number is about how long the editor is unavailable.
   `gptel-yatools-async-timeout` (600 s) bounds an asynchronous one, where
   the number is about not leaving a runaway command on the host.  Each
   tool's `timeout` argument description quotes the one that applies to it.
9. **Output is capped while it runs.** A job stops accepting output at 1 MB
   and says so, because the envelope is capped at 64 kB anyway and a
   ten-minute budget spent on a command that loops would otherwise hold
   everything it printed.

## Consequences

- `execute_command` no longer blocks Emacs.  Direct calls — from `eval`, a
  hook, or a test — are detected by type (the first argument is a function
  only when gptel is calling) and are still answered synchronously, so the
  two ways of calling a tool both produce the same envelope.
- The status line is gptel's, with one thing added: gptel sets " Calling
  tool (execute_command)" before the tool runs and leaves it there, so a
  per-buffer timer repaints it once a second with a count and an elapsed
  time, and stops when the last live job concludes.  It does not run when
  `gptel-use-header-line` is nil, because there `gptel--update-status`
  falls through to `message` and a message every second is not a status.
- Two commands in one response now run concurrently, where before they ran
  in order.  The tool description says so; serialising them would need a
  queue and a story for what cancelling a queued item means.
- With a remote workspace, `make-process` must establish the TRAMP
  connection before it can return: the boundary blocks for that (about 3 s
  cold, under 1 s warm) even though the command does not.  That is TRAMP's
  implementation, and it is documented rather than papered over.
- Backends that are not `tramp-sh` do not support TRAMP's remote
  `signal-process`, so a remote kill there is a no-op.  The job's deadline
  is the backstop.
- `render_diagram` did not change.  It calls `--run-process` and gets a
  plist, exactly as before, on top of the same spawner; its definition is
  untouched and it can become asynchronous later by adding `:async t`.
- The suite tests the asynchronous path without a network: a stand-in
  `file-name-handler-alist` entry receives `make-process` through
  `:file-handler`, a helper drives real callbacks with a hard deadline so a
  broken implementation fails instead of hanging, and the synchronous tools
  exercise the shared machinery on every run.
