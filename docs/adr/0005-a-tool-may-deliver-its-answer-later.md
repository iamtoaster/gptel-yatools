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
   registry of live jobs that every job enters through
   `gptel-yatools--make-job-live`, `gptel-yatools-cancel-tool-calls` on
   `C-c C-k` in `gptel-mode-map`, advice so that `gptel-abort` kills the
   jobs too, and a `kill-buffer-hook` so a killed chat does not leave work
   running.  Cancelling kills the jobs first and then moves the request to
   `ABRT`; delivering a "cancelled" result instead would invite the model
   to retry, turning one cancel into a loop of them.
8. **Two budgets.** `gptel-yatools-timeout` (120 s) bounds a synchronous
   call, where the number is about how long the editor is unavailable.
   `gptel-yatools-async-timeout` (600 s) bounds an asynchronous one, where
   the number is about not leaving a runaway command on the host.  Each
   tool's `timeout` argument description quotes the one that applies to it.
9. **Output is capped while it runs.** A job stops accepting output at 1 MB
   and says so, because the envelope is capped at 64 kB anyway and a
   ten-minute budget spent on a command that loops would otherwise hold
   everything it printed.

## Amendment — one registrar makes a job live

The subagent is the second long-running tool, and it is not a process: its
work is another gptel request. Item 1 says a body returns a job and the kit
owns the rest, and items 4 and 7 promise that the deadline and the
cancellation come with it. They did not. Becoming live — registration into
the buffer's job registry, the kill-buffer hook, the deadline timer and the
status-line count — was written inside `gptel-yatools--spawn-process`, so
the subagent rebuilt each of the four beside it, kept a second
`gptel-abort` advice of its own, and never reached the status line. The
declared interface was false for the one tool that most needed it.

The four steps were never about processes. They are what "live" means, and
they now have a name:

- live: `gptel-yatools--make-job-live` (a job in, the same job made
  cancellable, countable, timed and attached to its buffer's kill hook).

`gptel-yatools--spawn-process` calls it once the process exists, and
`gptel-yatools-subagent--start` calls it once the child's record exists.
The two call at different moments for one reason, and it is the invariant
worth keeping: **a job is registered at the moment it can be stopped, and
not before.** A process job registered before `make-process` returned
could be cancelled while TRAMP was still opening the connection and leave
a live process nothing tracks; a child can be stopped as soon as its
record exists, so it registers first.

Two consequences follow, and both are deletes:

- The subagent's own timer, its `gptel-abort` advice and
  `gptel-yatools--cancel-subagents-in` are gone. `C-c C-k`, `M-x
  gptel-abort`, the deadline and killing the chat all reach a child the
  same way they reach a command — through the registry, one cancel path.
  What the child supplies is what stopping *it* means.
- The reason a job is stopped is part of the interface. A signal has no
  words, but a child request has to say in its answer what stopped it, so
  CANCEL takes `(JOB REASON)` and the kit supplies `cancelled` or
  `timed-out`. That replaces a second slot for the deadline: work whose
  timeout needs its own wording writes it when it is told the reason.

A job that could not be started is not registered. There is nothing to
stop and nothing to count, and the boundary delivers its `START-ERROR`
either way.

## Amendment — a failure is still an answer

Every failure the model reads is built in one of two shapes: the call ran
out of time, or the call failed. Three entry points -- the synchronous
boundary, the asynchronous start, and the asynchronous boundary's own
error path -- each built both shapes, in the same words, five places in
all. Two constructors now exist, `gptel-yatools--timeout-envelope` and
`gptel-yatools--failure-envelope`, and the entry points call them. A
change to either sentence is a change in one place, and a fourth entry
point has nothing left to copy.

Rendering a conclusion needed the same treatment for a different reason.
A job's RESULT function runs *inside* delivery, and by then the job has
been marked delivered and has left its buffer's registry. If that function
signals -- a nil slot read, a formatter tripping over unexpected output --
there is nothing left to retry and, in a sentinel, nobody to see the
error: the callback is never called, gptel waits for a tool result that
never comes, and the chat cannot continue. So
`gptel-yatools--job-conclusion` renders a job's outcome and turns a
failure to render into the failure envelope. Item 4 says a conclusion
happens exactly once; this says it always happens at all.

`quit` is caught there with the errors, for the usual reason:
`condition-case` does not treat it as one, so a handler written for errors
alone lets it through, and from a timer or a sentinel nothing above
catches it either.

The constructors do not merge a body's own wording with the boundary's.
Bodies still write their own sentences, and many of them -- nine in the
agent module alone -- reach the model as a Result body rather than as a
signal, along a path the boundary's prefix never touches. Giving those a
constructor of their own changes the Result contract, not this one, and is
not done here.

## Amendment — a child's failure can be claimed

A child fails for reasons that have nothing to do with its task: a dropped
connection, a 429, a body that would not parse. Whether such a failure is
worth another attempt is a policy, and the policy belongs in a config, not
here. What was missing was a place to *put* it. A config could only advise
the module's own functions, and the one moment that mattered — before the
parent is told the child failed — was not reachable from outside at all:
the failure settled the child on the spot, delivered a failure to the
parent, and the retried request that followed belonged to nobody.

So a child now has three named hook variables rather than a set of
functions to advise:

- `gptel-yatools-subagent-started-functions`, `-settled-functions`:
  observation. They report and return; the module goes on doing what it was
  going to do.
- `gptel-yatools-subagent-failed-functions`: a veto, run with
  `run-hook-with-args-until-success`. A non-nil return **claims** the
  failure, and the child is not settled: it stays `running`, its job stays
  live, its deadline stays armed, and the parent's tool call keeps waiting
  inside the budget it was given. A retry then answers that call, and a
  retry that never succeeds ends as the timeout it always was.

Claiming is a promise. Nothing in the kit finishes a claimed failure, and a
child claimed and forgotten runs until its deadline collects it — which is
the correct default, because the alternative is a child that stops costing
tokens when a config's timer fires or does not.

The operations a policy needs are public for the same reason: a child is
not something a config should have to reach into.

- `gptel-yatools-subagent-buffer-p` (is this buffer a child this package
  still owns? — a detached child answers nil, since it is an ordinary
  session by then),
- `gptel-yatools-subagent-insert` (write into a child without the write
  counting as the user taking it over),
- `gptel-yatools-subagent-retry` (run a settled child again, in place,
  leaving its job and deadline alone).

The retry leaves the job alone on purpose. Re-arming the deadline would
give the child a second budget the parent is not waiting for, and the
exactly-once rule in item 4 would have nothing to protect: the parent would
have been told the child failed while the child carried on.

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
- A subagent now shows in the header line (`Running 1 subagent...`) and
  dies with the chat that started it, which is what the README promised
  before the code did.  `C-c C-k` and `gptel-abort` in the parent stop the
  children it started.  A child the user has detached is no longer the
  parent's job, so the parent does not stop it — that is the detached
  child's definition, not an oversight.
- A seam test now pins the registrar the way one already pins the process
  runner: no module outside `gptel-yatools-common.el` may mention the job
  registry or a job's timer, so "return a job" cannot quietly become
  "return a job and register it yourself".
- A child's failure can now be claimed by a config hook before the parent
  is told, which is what makes a retry invisible to the parent.  The
  module's own tests cover the seam end to end; what a config does with it
  — backoff, which statuses are worth retrying, whether to continue a
  partial reply — stays out of this package.
