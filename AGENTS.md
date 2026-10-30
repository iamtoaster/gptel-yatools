# AGENTS.md

`gptel-yatools` is an Emacs Lisp package that adds tools to
[gptel](https://github.com/karthink/gptel): a buffer-local virtual
filesystem with a reviewed sync step, a shell runner, workspace paths, and
an Agent Skills catalog.  The package requires Emacs 29.1+, `gptel` and
`yaml`.  There is no Makefile, CI, formatter config, or separate package
manifest; the `Package-Requires` header in `gptel-yatools.el` is the
dependency declaration, and ERT is the test harness.

## First reads

- **`README.md`** — what the package does, the tool table, installation,
  configuration, and the user-visible safety model.
- **The `;;; Commentary:` at the top of each source file** — the most
  current statement of that module's responsibility, its seams, and its
  load order.  Read the target file's Commentary before its code.
- **`GLOSSARY.md`** — the domain vocabulary: *Result*, *provenance*,
  *tool boundary*, *workspace root*, *pending change*, *refusal*,
  *review*, *skill handle*.  Use these terms in code, comments, tests and
  commit messages; the glossary also lists names to avoid.
- **`docs/adr/`** — accepted architectural decisions.  Read them before
  proposing a refactor they already considered, especially:
  - `0001-pending-ness-keeps-a-cheap-predicate.md` — why
    `gptel-yatools-vfs-entry` and `-pending` are deliberately two
    questions.
  - `0002-the-tool-kit-stays-one-file.md` — why
    `gptel-yatools-common.el` is one file with declared seams (respond,
    call, define, and — by amendment — run).
  - `0003-a-tool-may-own-an-opaque-directory.md` — when a tool may write
    outside the VFS (conditions on the model's inability to name a path and
    the artifact being disposable), and why `execute_command` is not an
    instance of it.
  - `0004-a-remote-workspace-runs-on-its-host.md` — what a TRAMP workspace
    means for the file tools, the shell tool and the deadline; read it
    before adding a structural path walk (they must stop at `/ssh:host:/`)
    or a subprocess (it must be handler-built when the directory is
    remote).
  - `0005-a-tool-may-deliver-its-answer-later.md` — why `:async` is about
    delivery rather than about what a body does, what a job is, why a
    conclusion must run exactly once, and why cancellation had to be built
    here (gptel's own abort cannot see a tool call).  Read it before adding
    a tool that runs a process.
  - `0006-a-subprocess-runs-where-its-artifacts-live.md` — a process runs
    in its artifacts' directory, stated at the call, never inherited from
    `default-directory`.  Only `execute_command` has the workspace as its
    artifact; the diagram renderer has its cache, which is why it works in a
    remote workspace.
- **`docs/performance.md`** — how performance claims were measured
  (offline gptel loop, fixed `gptel--escape-raw-bytes` hot spot).  Measure
  before optimising.
- **`docs/subagent-investigation.md`** — a historical design report about
  a proposed subagent feature, not a description of implemented code.  Its
  test count and module descriptions are stale; use the source and glossary
  instead.

## Module map

| File | Owns | Start at |
| --- | --- | --- |
| `gptel-yatools-common.el` | The tool kit: `Result`, size limits, envelope, provenance rendering, deadline/call context, `gptel-yatools-define-tool`, previews, enabling tools, and the process runner both subprocess tools share. | `gptel-yatools-define-tool`, `gptel-yatools-ok`, `gptel-yatools--respond`, `gptel-yatools-page`, `gptel-yatools--run-process`, `gptel-yatools--remote-shell` |
| `gptel-yatools-vfs.el` | The buffer-local VFS: entries and baselines, conflict/refusal logic, pending changes, encoding, diffing, sync review UI, and the filesystem tools. | `gptel-yatools-vfs-entry`, `-pending`, `-read`, `-write`, `-edit`, `-refusal`, `-sync`; `gptel-yatools-write-diff-mode` |
| `gptel-yatools-shell.el` | `read_workspace_root` and `execute_command`: the command's own wording and its VFS-pending warning, over the shared process runner. | `gptel-yatools-execute-command`, `gptel-yatools-shell--run-command` |
| `gptel-yatools-skills.el` | Skill discovery, frontmatter validation, content-keyed parse cache, skill handles/resolution, the `skill` tool, attaching skills by hand, the skill browser. | `gptel-yatools-skills-resolve`, `-handle`, `-add`, `gptel-yatools-skills` |
| `gptel-yatools-diagram.el` | The `render_diagram` tool, the content-addressed diagram cache, the render token, the inline overlay, and the transcript rebuild. | `gptel-yatools-render-diagram`, `gptel-yatools-diagram--token`, `--ensure`, `--refresh`, `--rebuild-missing` |
| `gptel-yatools-agents.el` | The `subagent` tool: child records, the read-only capability list, the fixed boilerplate, the answer and its failures, the `[Subagents]` label and the picker. | `gptel-yatools-subagent`, `gptel-yatools-subagent--start`, `--callback`, `--settle`, `gptel-yatools-subagents` |
| `gptel-yatools.el` | gptel glue only: run a tool call in the buffer that owns the request, draw the header-line extras, load the tool modules. | `gptel-yatools--accept-tool-calls-in-owner`, `gptel-yatools--extend-header-line` |

Load order: `gptel-yatools-common.el` first; the tool modules require it
(`vfs` first, then `shell` and `skills`); `gptel-yatools.el` is the public
entry point and requires the tool modules at its end.

Useful entry points while exploring:

```sh
grep -n '^(gptel-yatools-define-tool' *.el     # all tool definitions
grep -n '^;;----' -A1 *.el                     # section banners per module
```

In Emacs, `C-h f gptel-yatools-define-tool` explains the tool contract;
`C-h f <tool-name>` on a generated boundary shows the same description the
model receives; `M-x gptel-yatools-skills` opens the skill browser.

## Test harness

The suite is ERT.  It uses no network and no user prompts, and
every test runs in a throwaway temp directory.  Run it from the repository
root:

```sh
emacs -Q --batch -L . -L <dir-with-gptel> -L <dir-with-yaml> \
  -l gptel-yatools.el \
  -l tests/gptel-yatools-tests.el \
  -l tests/gptel-yatools-vfs-tests.el \
  -l tests/gptel-yatools-skills-tests.el \
  -l tests/gptel-yatools-diagram-tests.el \
  -l tests/gptel-yatools-agents-tests.el \
  -f ert-run-tests-batch-and-exit
```

The diagram suite skips the tests that need PlantUML when it is not
installed — that is deliberate, and the rest of it (content addressing, the
transcript reader, the overlay, every refusal) runs without it.

`-Q` ignores the user's init files, so `gptel` and `yaml` must be on
`load-path`; `-L .` alone is not enough unless they are installed in the
default load path.

Run only the tests matching a regexp by replacing the final `-f` form:

```sh
emacs -Q --batch -L . -L <dir-with-gptel> -L <dir-with-yaml> \
  -l gptel-yatools.el -l tests/gptel-yatools-vfs-tests.el \
  --eval '(ert-run-tests-batch-and-exit "gptel-yatools-test-vfs-sync")'
```

Each suite loads on its own; load only the file that holds the tests you
need.  `tests/gptel-yatools-test-lib.el` is loaded by path from each suite
and is not a test file itself.

Interactively: load `tests/gptel-yatools-test-lib.el`, then the suite you
want, then `M-x ert RET RET`.

A clean byte-compile is part of the check (it writes `.elc` files, which
are gitignored):

```sh
emacs -Q --batch -L . -L <dir-with-gptel> -L <dir-with-yaml> \
  -f batch-byte-compile gptel-yatools.el gptel-yatools-common.el \
  gptel-yatools-vfs.el gptel-yatools-shell.el gptel-yatools-skills.el \
  gptel-yatools-diagram.el gptel-yatools-agents.el
rm -f *.elc
```

### Test conventions

- Test names use the `gptel-yatools-test-` prefix.  The suites are
  split by subject: package glue and shell tools in
  `gptel-yatools-tests.el`, filesystem in `-vfs-tests.el`, skills in
  `-skills-tests.el`, diagrams in `-diagram-tests.el`, child agents in
  `-agents-tests.el`.
- A suite that fakes `gptel-request' calls the tool *body*
  (`gptel-yatools-subagent--start`), not the boundary: an asynchronous
  tool's boundary waits for its answer when gptel is not the caller, and a
  fake never answers — which is a hang, not a test.
- Call tools through `gptel-yatools-test--tool`, which returns the
  generated boundary, so assertions see exactly the envelope the model
  would receive.  Use `gptel-yatools-test--should-be-enveloped` to check
  both envelope tags and JSON serialisability.
- `gptel-yatools-test--in-dir` deliberately makes the workspace root differ
  from `default-directory`; path bugs should fail rather than pass by
  coincidence.  `--vfs` gives a private VFS, `--with-file` writes a fixture,
  `--with-open-buffer` tests a visiting buffer, and `--noninteractive`
  turns every prompt into an error.
- Tests must never prompt the user.  Anything that would ask (sync review,
  overwrite confirmation, coding system) has to be stubbed or run with the
  helper that expects the refusal.
- `gptel-yatools-sync-without-review` is the batch escape hatch for the
  review step; the conflict and encoding checks still apply.
- Adding a new tool module means adding its filename to the hard-coded lists
  in `gptel-yatools-test-response-machinery-is-crossed-at-one-seam` and
  `gptel-yatools-test-subprocesses-are-run-at-one-seam`
  (`tests/gptel-yatools-tests.el`).

## Rules that the code depends on

- **One definition per tool.**  `gptel-yatools-define-tool` generates the
  implementation `NAME-tool` (returns a `gptel-yatools-result` or a job) and
  the boundary `NAME` (takes the trailing `timeout`, checks arguments, enforces
  the deadline, renders the envelope, catches errors), then registers the
  tool.  Its body returns a Result, not formatted text; every tool goes
  through that one definition path.
- **`:async` is about delivery only.**  A body returns a Result or a job
  (from `gptel-yatools--spawn-process`); `:async t` makes the boundary hand
  the job's envelope to gptel's callback instead of returning it, and
  nothing else about the body changes.  A conclusion runs exactly once —
  gptel counts a result every time the callback fires — and a synchronous
  tool that returns a job is reported as the definition bug it is.  See ADR
  0005.
- **Cancellation belongs here, not to gptel.**  `gptel-abort` looks a
  request up by its network process, which has finished by the time a tool
  runs, so it cannot stop one.  The buffer-local job registry,
  `gptel-yatools-cancel-tool-calls`, the `gptel-abort` advice and the
  kill-buffer hook are what make a running command stoppable; a new
  long-running tool inherits all of it by returning a job.
- **The response seam is narrow.**  A tool module may call
  `gptel-yatools--respond` and `gptel-yatools-page`; sizing, truncation,
  escaping and the XML envelope stay in `gptel-yatools-common.el`.
- **Provenance is data.**  A tool says `:disk`, `:vfs` or `:mixed` on its
  Result; the boundary renders it once, and is the only place it becomes
  prose.
- **Resolve paths once, at the tool edge.**  Everything past
  `gptel-yatools--resolve-path` takes an absolute resolved path.  A tool may
  rebind `default-directory` (the shell runner does); the call's workspace
  root stays fixed.
- **Writes go through the VFS.**  `write_file` buffers content; only
  `file_sync` writes disk, after review.  The VFS write interface owns
  validation, encoding, baseline/conflict detection and the write policy.
  The one exception is `gptel-yatools-diagram.el`, which owns a disposable
  cache directory the model cannot name a path in — ADR 0003 states the
  three conditions a tool must meet to qualify.  `execute_command` is not
  covered by that exception; it is gated on approval instead.
- **`entry` and `pending` answer different questions.**  `entry` is the
  cheap structural lookup; `pending` compares with disk and reaps entries
  that no longer differ.  Keep both, so each caller asks the question it
  actually has (ADR 0001).
- **One refusal answer.**  `gptel-yatools-vfs-refusal` decides conflicts and
  blocks for the review partition, the diff header and the actual write, so
  the files the user approved are the files that get written.
- **One seam runs every subprocess.**  `gptel-yatools--run-process`
  (`common.el`) takes an argv and a deadline and returns a
  `:status`/`:exit`/`:output` plist; it merges stderr, closes stdin, keeps
  the output of a process it kills, and kills the whole process group.  A
  tool module that calls `make-process` has reached past it — a test
  enforces that, the same way the respond seam is enforced.
- **A subprocess runs where its artifacts live.**  Pass `:directory`
  explicitly; do not let the process inherit `default-directory`.  Only
  `execute_command` has the workspace as its artifact, and only because
  the workspace is what it acts on — the diagram renderer has its cache.
  ADR 0006.
- **Skills are read from disk only.**  A pending `SKILL.md` write is
  invisible to discovery; the model must not author instructions that are
  then treated as authoritative before review.  `allowed-tools` is advisory
  and must stay labelled as such.
- **A remote workspace stays remote.**  Paths past the tool edge are
  ordinary file names, so file-name handlers carry the filesystem work to
  the host; anything this package does itself must not quietly happen
  locally instead.  Three consequences are easy to get wrong: a walk up a
  path's parents must stop when the name stops shrinking (`/ssh:host:/` is
  its own parent), a subprocess must be asked for with `:file-handler t`
  and the host's shell, or it runs on this machine, and an *absolute*
  path the model writes must be rebased onto the workspace's connection --
  `expand-file-name` ignores the root for an absolute name, so
  `read_path "/etc/hostname"` used to answer with the local computer's
  file and look completely ordinary doing it.  `gptel-yatools--resolve-path`
  is the one place that decides, and `gptel-yatools--remote-prefix` is
  what it rebases with (`file-remote-p` alone loses a multi-hop chain).  A
  path that decides *where* to act must name the same connection as the
  workspace (`gptel-yatools--connection`), not merely look remote.  See
  ADR 0004.
- **A tool call never re-enters a busy TRAMP connection.**  gptel runs
  tools from its response loop, which in a remote workspace can be inside
  another file operation; TRAMP then refuses the call and gptel reports it
  as a missing file.  `gptel-yatools--tool-calls-outside-the-sentinel`
  defers such calls until the connection is free — a condition, not a
  sleep, so concurrent subagents take turns.  Any new entry point that
  calls tools directly must go through it.
- **Remote cost is per command, so ask once.**  Every TRAMP filesystem
  question is a command plus a synchronous wait on the one connection the
  workspace shares.  Anything that looks at a *set* of paths must ask
  about the set in one call: `file-name-all-completions` for a listing
  (names and types together), `file-attributes` for one path's kind,
  rather than a predicate per entry or per property.  Measured, cold: a
  120-entry listing cost 125 round trips the obvious way and 4 the other
  way.
- **Tool calls never overlap, and the connection's own lock is not
  enough.**  TRAMP runs timers while it waits for output — so a second
  deferred call can start *inside* the first one's file operation, and
  two readers end up on one connection buffer: "End of file during
  parsing", results delivered to the wrong caller.  Measured: three
  calls, three concurrent.  `gptel-yatools--tool-call-running` is a plain
  variable, not a buffer-local one, because every subagent in a
  workspace shares the connection being protected.
- **Never create a timer from inside a request.**  TRAMP wraps every
  operation in `with-tramp-suspended-timers`, which binds `timer-list` to
  nil and discards anything pushed onto it: a `run-at-time` made there is
  silently lost — never cancelled, never fired, nothing reported.
  Measured directly: a timer created inside such a section never fires;
  one created outside survives one.  Since the tool-use handler runs from
  a process sentinel, which can be inside exactly such a section,
  deferred calls go on a queue worked by a single timer created at load
  time (`gptel-yatools--deferred-tool-calls`).
- **Nothing that runs on a timer may signal.**  A timer callback's error is
  logged by Emacs and nothing else: the work it was going to do simply
  does not happen, and whatever was waiting keeps waiting.  Every
  timer-driven path here — a job's deadline, a subagent's expiration, a
  deferred tool call — settles what it owns even when stopping the work
  itself fails, and reports the failure as the outcome it was, not as
  silence.
- **`quit` is not an `error`.**  `condition-case` does not catch `quit`
  under an `error` handler, so a `C-g` during a deferred tool call or a
  child's callback escaped every handler and left the state machine in
  TOOL for ever — no result, no error, a chat that could never continue.
  Anywhere this package runs from a timer or a sentinel, `quit` is caught
  and reported as an outcome.
- **A tool call does not react to `C-g`, and does not swallow it.**  Tool
  calls run synchronously on whatever is on the stack, so a `C-g` meant to
  close the minibuffer lands inside them.  Both wrong answers were tried:
  letting it abort the call (an error nobody asked for) and swallowing it
  (the minibuffer never closes, and a vanished keypress is worse because
  you cannot tell whether Emacs heard you).  The contract is a third
  thing: the call's work completes, and the quit is re-signalled by the
  outermost boundary once the result has been delivered, so it reaches
  what it was aimed at.  That is `gptel-yatools--without-quit` plus
  `gptel-yatools--replay-pending-quit`, and the split matters — replaying
  from inside `--call-tool` aborts the rest of a multi-call tool block,
  which is the stranding bug all over again.  Measured, so the next reader
  does not have to rediscover it: `inhibit-quit` defers the quit to a safe
  point *after* the binding ends, and catching it does not clear the flag.
- **A child agent is a reader.**  `gptel-yatools-subagent-tools` lists only
  read-only tools, and that is what every other decision in the agent module
  rests on: nothing it does can be lost, so there is no VFS policy, no merge
  and no recursion.  Adding a writing or a shell tool there invalidates the
  reasoning in that file — revisit it rather than extending the list.
- **A child's capabilities come from the package, not from the parent.**
  The list is resolved against `gptel-yatools--tools`, never filtered
  through the parent's `gptel-tools`: a parent that never enabled
  `read_path` must not hand the model a child that cannot read.
- **A subagent is a job, not a special case.**  It is a
  `gptel-yatools-job` whose work is a request instead of a process, so the
  deadline, the status line, `C-c C-k` and the exactly-once delivery rule
  come from the kit.  A new long-running tool of any kind should conclude
  through the same object.
- **Tests are not part of the package.**  They are loaded on demand and
  must not run in a user's normal Emacs startup.

## Before finishing

- The full ERT suite passes and any new behaviour has a test that goes
  through the tool boundary.
- The source files byte-compile without warnings.
- User-visible changes are reflected in `README.md`; new or changed domain
  terms in `GLOSSARY.md`; architectural decisions in a new ADR.
- No VFS changes are left pending: `vfs_diff`, then `file_sync` (or
  `vfs_discard`) before ending the session.
