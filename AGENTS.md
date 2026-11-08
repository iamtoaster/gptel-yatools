# gptel-yatools

Extra [gptel](https://github.com/karthink/gptel) tools: a small,
buffer-local **virtual filesystem** with a reviewed sync step, a shell
runner, workspace paths, Agent Skills, inline PlantUML diagrams and a
read-only child agent.

A tool body returns a `Result` (a body, its provenance and an optional
context comment); one generated boundary per tool renders that into the
envelope the model sees.  Writes go into the VFS and reach disk only
through `file_sync`, after a diff the user accepts.  Emacs 29.1+, `gptel`
and `yaml` are the dependencies — `Package-Requires` in
`gptel-yatools.el` is the only manifest.  ERT is the test harness, Eldev
runs it, and GitHub Actions runs Eldev on every supported Emacs.

## Relevant commands

### How to run the tests

The suite is ERT: no network, no prompts, every fixture in a throwaway
temp directory made with `make-temp-file` (so nothing leaves
`temporary-file-directory`).

```sh
bin/eldev test [SELECTOR...]
```

`SELECTOR` is an ERT selector, e.g. `'^gptel-yatools-test-vfs-'`; several
combine as `or`, and `-f '*vfs-tests.el'` narrows by file instead.  Eldev
resolves `gptel` and `yaml` itself, from MELPA as `Package-Requires`
declares them, and runs Emacs with `--no-init-file` and friends, so no
user init file is loaded and the machine's own `load-path` is not part of
the repository.  `EMACS` selects the executable.

`bin/eldev' is Eldev itself, committed so that a clean checkout needs no
install step; the first run bootstraps it and caches under `.eldev/`,
which is gitignored.  `bin/eldev help` lists every command, and
`Eldev` is the project descriptor that says where the dependencies come
from.

The diagram suite skips the tests that need PlantUML when it is not
installed; the rest of it (content addressing, the transcript reader, the
overlay, every refusal) runs without it.  `gptel-yatools-test-lib.el` is
loaded by path from each suite and is not a test file itself.

Interactively: `M-x load-file RET tests/gptel-yatools-test-lib.el RET`,
then the suite, then `M-x ert RET gptel-yatools-test- RET`.

### How to check the compile, and lint

A clean byte-compile is part of the check, and `Eldev` turns a warning
into a failure so that "clean" is enforced rather than hoped for:

```sh
bin/eldev compile
bin/eldev lint          # checkdoc, package-lint and relint
bin/eldev check         # compile, then tests, then lint
```

`.elc` files are left behind and are gitignored; `bin/eldev clean`
removes them along with the `.eldev/` cache.

### What CI runs

`.github/workflows/ci.yml` runs `bin/eldev compile` and `bin/eldev test`
on Emacs 29.1, 30.2 and 31.1 — 29.1 is the floor `Package-Requires`
states — with PlantUML installed in every cell so the render tests run
rather than skip.  `bin/eldev lint` runs once, on the newest of those.

### How to use the package interactively

Load `gptel-yatools.el`, then `(gptel-yatools-enable "filesystem")` in a
buffer.  `M-x gptel-yatools-skills` opens the skill browser,
`M-x gptel-yatools-subagents` lists running children, and
`M-x gptel-yatools-enable` picks categories or tools.

Useful while exploring:

```sh
grep -n '^(gptel-yatools-define-tool' *.el     # every tool definition
grep -n '^;;----' -A1 *.el                     # section banners per module
```

`C-h f gptel-yatools-define-tool` explains the tool contract; `C-h f
<tool-name>` shows the description the model receives.

## Conventions

### Commits

One sentence in the imperative, saying what changed and why it matters
(`Sweep the diagram cache by age, on an idle timer`).  Never a bare
"fixes".  Every change is committed, so it can be reversed.

### Documentation that ships

| File | Audience | Rule |
| --- | --- | --- |
| `README.md` | users | Only what a user needs: description, installation, configuration, tool usage.  No rationale, no test harness, no `path:line`. |
| `GLOSSARY.md` | everyone writing here | The domain vocabulary.  Use its terms in code, comments, tests and commit messages; avoid its *Avoid* lists. |
| `docs/adr/` | whoever changes the design | One decision per file, immutable once accepted; amend with a new ADR instead of rewriting. |
| `AGENTS.md` | agents working on the code | This file: commands, conventions, index. |
| `.live-docs/` | nobody (gitignored) | `PROJECT.md` and `TASKS.org` — local state for the current session. |

Record a request in `.live-docs/TASKS.org` as soon as it is made, mark
items done immediately, and drop a finished topic once git is clean.

### Every tool goes through one definition

`gptel-yatools-define-tool` generates the implementation `NAME-tool`
(returns a Result or a job) and the boundary `NAME` (takes the trailing
`timeout`, checks arguments, enforces the deadline, renders the envelope,
catches errors).  A body returns a Result, never formatted text.

### The seams are narrow

Four of them, each with a test that fails when a module reaches past it:

- **Response** — a tool module may call `gptel-yatools--respond` and
  `gptel-yatools-page`; sizing, truncation, escaping and the XML envelope
  stay in `common.el`.
- **Process** — everything runs through `gptel-yatools--run-process`
  (`common.el`, `:911`) with an explicit `:directory`.  A module calling
  `make-process` has left the seam.  A subprocess runs where its
  artifacts live (ADR 0006).
- **Job** — `gptel-yatools--make-job-live` (`common.el:656`) is the only
  place a job becomes live: registry, deadline timer, kill hook, status
  line.  A module that pushes into the registry, arms its own timer or
  adds its own abort advice has left the machinery behind (ADR 0005).
- **Path** — `gptel-yatools--resolve-path` (`common.el:1038`) resolves a
  path once, at the tool's edge; past it everything takes an absolute
  path and never interprets it again.

### Nothing here describes one machine

The repository is read by people whose Emacs is laid out differently, so
no default, comment, message or document may name a directory that is one
installation's convention:

- Under `user-emacs-directory` the package claims one directory, named
  after itself: `gptel-yatools/`.  Not `var/gptel-yatools/`, and nothing
  else with a directory level of someone's own invention.
- A temp file is built from `temporary-file-directory`, never a literal
  `/tmp`.
- A path in a document is a placeholder (`/path/to/gptel-yatools`,
  `~/.emacs.d`, `/usr/local/bin/plantuml`), never a path that exists on
  the author's machine.
- A default that is a `defcustom` a user may legitimately change is not
  asserted by a test; the convention is enforced in review.

### Rules the code depends on

Each one is enforced by a test or stated in an ADR; read the ADR before
changing the rule.

- **`:async` is about delivery only.**  The body and the Result are the
  same; only the envelope's delivery differs.  A conclusion runs exactly
  once (ADR 0005).
- **Cancellation lives here, not in gptel.**  `gptel-abort` looks a
  request up by its network process, which has finished by the time a
  tool runs.  `C-c C-k` is `gptel-yatools-cancel-tool-calls`, and a job
  inherits cancellation by being registered, not by reimplementing it.
- **Provenance is data.**  A tool says `:disk`, `:vfs`, `:mixed` or
  `:derived` on its Result; the boundary is the only place it becomes
  prose.
- **Writes go through the VFS.**  `file_sync` is the only writer of disk.
  The one exception is the diagram cache, which is disposable and
  unreachable by a path the model can name (ADR 0003);
  `execute_command` is not an instance and is gated on approval instead.
- **`entry` and `pending` answer different questions.**  `entry` is the
  cheap structural lookup, `pending` compares with disk (ADR 0001).  Keep
  both, so each caller asks the question it has.
- **One refusal answer.**  `gptel-yatools-vfs-refusal` decides for the
  review partition, the diff header and the write, so the files the user
  approved are the files written.  What a *write* refuses is settled when
  the entry is made; what a *sync* refuses is what an open review can
  change (ADR 0007).
- **A remote workspace stays remote.**  File-name handlers carry the work
  to the host; anything this package does itself must not quietly happen
  locally instead.  A structural walk stops when the name stops shrinking
  (`/ssh:host:/` is its own parent); a subprocess is asked for with
  `:file-handler t`; an absolute path is rebased onto the workspace's
  connection (ADR 0004).
- **Same connection, not merely remote.**  A path deciding *where* to act
  compares `gptel-yatools--connection`, because `file-remote-p` reports
  only the last hop of `/ssh:a|sudo:root@b:/x`.
- **Ask the remote once per question.**  A TRAMP filesystem question is a
  command plus a wait on one shared connection, so a set of paths is asked
  about in one call (`file-name-all-completions`, `file-attributes`).
  Measured: 125 round trips the obvious way, 4 the other way, for a
  120-entry listing.
- **Tool calls never overlap on one connection.**  TRAMP runs timers while
  it waits, so a second call can start inside the first one's file
  operation.  `gptel-yatools--tool-call-running` is deliberately not
  buffer-local.
- **Never create a timer from inside a request.**  TRAMP binds
  `timer-list` to nil inside `with-tramp-suspended-timers`, so a
  `run-at-time` made there is lost silently.  Deferred calls go on a queue
  worked by a timer created at load time.
- **Nothing that runs on a timer or a sentinel may signal,** and `quit` is
  not an `error`: both are caught and reported as the outcome they were.
  A tool call does not react to `C-g` and does not swallow it
  (`gptel-yatools--without-quit` + `gptel-yatools--replay-pending-quit`).
- **A disposable cache still needs a lifetime.**  The diagram cache is
  swept by age, on an idle timer, once a session; a sweep never runs on a
  tool call's path and never signals.
- **Skills are read from disk only.**  A pending `SKILL.md` is invisible
  to discovery, so the model cannot author instructions that are
  authoritative before review.  `allowed-tools` is advisory and stays
  labelled as such.
- **An image is delivered twice, on purpose.**  A `gptel-context` entry
  carries it to later requests; the pending queue reaches the request that
  asked, because gptel builds a payload once and the tool loop re-sends it
  (ADR 0008).  Neither alone works: the queue alone forgets, the context
  alone is one request late.  The queue is cleared as each request starts,
  so an image cannot arrive twice in one payload.
- **A child agent is a reader.**  `gptel-yatools-subagent-tools` lists
  read-only tools, and nothing else in the agent module needs reviewing
  because of it.  Adding a writing or shell tool there invalidates its
  reasoning — revisit the module, do not extend the list.
- **A capability list comes from the package, not the parent.**  Children
  resolve against `gptel-yatools--tools`, never the parent's `gptel-tools`.
- **A hook observes; only the failure hook may veto.**
  `-started-functions` and `-settled-functions` report;
  `-failed-functions` claims a failure by returning non-nil, and claiming
  is a promise to finish the job.
- **Tests are not part of the package.**  Loaded on demand, never from a
  user's startup.

### Test conventions

- Names use the `gptel-yatools-test-` prefix.  Suites are split by
  subject: package glue and shell in `gptel-yatools-tests.el`, filesystem
  in `-vfs-tests.el`, skills in `-skills-tests.el`, diagrams in
  `-diagram-tests.el`, children in `-agents-tests.el`, images in
  `-media-tests.el`.
- Call tools through `gptel-yatools-test--tool`, which returns the
  generated boundary, so assertions see the envelope the model would.
  `gptel-yatools-test--should-be-enveloped` checks both tags and JSON
  serialisability.
- `gptel-yatools-test--in-dir` deliberately makes the workspace root
  differ from `default-directory`; path bugs should fail rather than pass
  by coincidence.  `--vfs` gives a private VFS, `--with-file` writes a
  fixture, `--with-open-buffer` tests a visiting buffer, `--noninteractive`
  turns every prompt into an error.
- A suite that fakes `gptel-request` calls the tool *body*
  (`gptel-yatools-subagent--start`), not the boundary: an asynchronous
  boundary waits for an answer a fake never gives.
- Paths in tests come from `make-temp-file` and
  `temporary-file-directory`; never a literal `/tmp`.  External programs
  are guarded with `skip-unless (executable-find …)`.
- Adding a tool module means adding its filename to the hard-coded lists
  in `gptel-yatools-test-response-machinery-is-crossed-at-one-seam` and
  `gptel-yatools-test-subprocesses-are-run-at-one-seam`.

## Short index

### The tool kit — `gptel-yatools-common.el`

Owns the `Result`, size limits, the envelope, provenance rendering, the
call context and deadline, `gptel-yatools-define-tool`, previews, tool
enabling, and the job registrar and process runner that both subprocess
tools share.

`gptel-yatools-define-tool` `:2683`, `gptel-yatools-ok` `:1581`,
`gptel-yatools--respond` `:1606`, `gptel-yatools-page` `:2243`,
`gptel-yatools-call` (the call context) `:110`, `gptel-yatools--new-call`
`:1836`, `gptel-yatools--make-job-live` `:656`,
`gptel-yatools--cancel-jobs` `:554`, `gptel-yatools--run-process` `:911`,
`gptel-yatools--resolve-path` `:1038`, `gptel-yatools--connection` `:240`,
`gptel-yatools--remote-shell` `:282`, `gptel-yatools--printable-block`
`:1134`, `gptel-yatools--job-conclusion` `:2170`,
`gptel-yatools--without-quit` `:1928`, `gptel-yatools-enable` `:2898`.

### The VFS — `gptel-yatools-vfs.el`

The buffer-local VFS: entries and baselines, conflict and refusal logic,
pending changes, encoding, diffing, the sync review UI, and the
filesystem tools.

`gptel-yatools-vfs-entry` `:156`, `-pending` `:171`, `-put` `:208`,
`-with-text` `:899`, `-write` `:1054`, `-refusal` `:1683`, `-sync`
`:2024`, `gptel-yatools-write-diff-mode` `:1310`, and the write policy
defcustoms at `:950`.

### The shell — `gptel-yatools-shell.el`

`read_workspace_root` and `execute_command`: the command's wording and its
VFS-pending warning, over the shared process runner.
`gptel-yatools-shell--run-command` `:112`, the tool definitions at `:202`
and `:210`.

### Skills — `gptel-yatools-skills.el`

Discovery, frontmatter validation, the content-keyed parse cache, skill
handles and resolution, the `skill` tool, attaching skills by hand, the
skill browser.  `gptel-yatools-skills--discover` `:509`,
`-assign-handles` `:563`, `gptel-yatools-skills-handle` `:597`,
`gptel-yatools-skills-resolve` `:786`, `gptel-yatools-skills-add` `:1146`,
`gptel-yatools-skills` `:1283`.

### Images — `gptel-yatools-media.el`

Turns a file the read tools would refuse as binary into an image the model
is shown: the format is decided by the file's first bytes — taken from the
read that already happened, so an ordinary read costs nothing more — the
model's acceptance is asked of gptel's model metadata, and an accepted image
is attached to the conversation twice over: queued for the request being
answered and kept in `gptel-context` for the turns after it (ADR 0008).
`gptel-yatools-media-type` `:119`, `gptel-yatools-media-attach` `:308`,
`gptel-yatools-media-deliver` `:395`, `gptel-yatools-media-forget` `:213`,
`gptel-yatools-media--head-from-text` `:104`,
`gptel-yatools-media--pending` `:145`, and the defcustom at `:51`.

### Diagrams — `gptel-yatools-diagram.el`

The `render_diagram` tool, the content-addressed cache and its age sweep,
the render token, the inline overlay, the transcript rebuild.
`gptel-yatools-diagram--sweep-cache` `:154`, `--token` `:416`,
`--refresh` `:892`, `--rebuild-missing` `:935`; the tool at `:774`.

### Child agents — `gptel-yatools-agents.el`

The `subagent` tool: child records, the read-only capability list, the
answer and its failures, the `[Subagents]` label and the picker.
`gptel-yatools-subagent--settle` `:722`, `--callback` `:852`,
`gptel-yatools-subagent--start` `:1141`, `gptel-yatools-subagent-retry`
`:1239`.

### gptel glue — `gptel-yatools.el`

Runs a tool call in the buffer that owns the request, defers calls in a
busy remote workspace, delivers attached images, draws the header-line
extras, binds `C-c C-k`, loads the tool modules.
`gptel-yatools--accept-tool-calls-in-owner`
`:83`, `gptel-yatools--tool-call-running` `:193`,
`gptel-yatools--deferred-tool-calls` `:214`,
`gptel-yatools--tool-calls-outside-the-sentinel` `:356`,
`gptel-yatools--deliver-attached-media` `:501`,
`gptel-yatools--media-queue-cleared` `:497`,
`gptel-yatools--extend-header-line` `:594`.

### Seams, and who crosses them

- **Response** — `gptel-yatools--respond`, `gptel-yatools-page`
  (`common.el:1606`, `:2243`); crossed by every tool module.
- **Process** — `gptel-yatools--run-process` (`common.el:911`); crossed by
  `shell.el` and `diagram.el`.
- **Job** — `gptel-yatools--make-job-live` (`common.el:656`); crossed by
  `shell.el` and `agents.el`.
- **Path** — `gptel-yatools--resolve-path` (`common.el:1038`); crossed by
  every tool that takes a path.
- **Refusal** — `gptel-yatools-vfs-refusal` (`vfs.el:1683`); crossed by
  the review partition, the diff header and the write.

### Decisions — `docs/adr/`

Read the one you are about to contradict.

- `0001` — why `vfs-entry` and `vfs-pending` are two questions.
- `0002` — why `common.el` is one file with declared seams.
- `0003` — when a tool may own an opaque directory.
- `0004` — what a remote workspace means for the file tools, the shell
  and the deadline.
- `0005` — why `:async` is about delivery, what a job is, and why
  cancellation had to be built here.
- `0006` — a subprocess runs where its artifacts live.
- `0007` — why there are two lists of write/sync checks.
- `0008` — why an image is delivered twice: once to the request that asked
  for it, and once to the conversation.

## Before finishing

- `bin/eldev check` passes — compile, tests, lint — and any new behaviour
  has a test that goes through the tool boundary.
- User-visible changes are in `README.md`; new or changed domain terms in
  `GLOSSARY.md`; a design decision in a new ADR.
- No VFS changes are left pending: `vfs_diff`, then `file_sync` (or
  `vfs_discard`) before ending the session.
