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
| `gptel-yatools-common.el` | The tool kit: `Result`, size limits, envelope, provenance rendering, deadline/call context, `gptel-yatools-define-tool`, previews, enabling tools, and the process runner both subprocess tools share. | `gptel-yatools-define-tool`, `gptel-yatools-ok`, `gptel-yatools--respond`, `gptel-yatools-page`, `gptel-yatools--run-process` |
| `gptel-yatools-vfs.el` | The buffer-local VFS: entries and baselines, conflict/refusal logic, pending changes, encoding, diffing, sync review UI, and the filesystem tools. | `gptel-yatools-vfs-entry`, `-pending`, `-read`, `-write`, `-edit`, `-refusal`, `-sync`; `gptel-yatools-write-diff-mode` |
| `gptel-yatools-shell.el` | `read_workspace_root` and `execute_command`: the command's own wording and its VFS-pending warning, over the shared process runner. | `gptel-yatools-execute-command`, `gptel-yatools-shell--run-command` |
| `gptel-yatools-skills.el` | Skill discovery, frontmatter validation, content-keyed parse cache, skill handles/resolution, the `skill` tool, attaching skills by hand, the skill browser. | `gptel-yatools-skills-resolve`, `-handle`, `-add`, `gptel-yatools-skills` |
| `gptel-yatools-diagram.el` | The `render_diagram` tool, the content-addressed diagram cache, the render token, the inline overlay, and the transcript rebuild. | `gptel-yatools-render-diagram`, `gptel-yatools-diagram--token`, `--ensure`, `--refresh`, `--rebuild-missing` |
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
  gptel-yatools-diagram.el
rm -f *.elc
```

### Test conventions

- Test names use the `gptel-yatools-test-` prefix.  The three suites are
  split by subject: package glue and shell tools in
  `gptel-yatools-tests.el`, filesystem in `-vfs-tests.el`, skills in
  `-skills-tests.el`.
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
- Adding a new tool module means adding its filename to the hard-coded list
  in `gptel-yatools-test-response-machinery-is-crossed-at-one-seam`
  (`tests/gptel-yatools-tests.el`).

## Rules that the code depends on

- **One definition per tool.**  `gptel-yatools-define-tool` generates the
  implementation `NAME-tool` (returns a `gptel-yatools-result`) and the
  boundary `NAME` (takes the trailing `timeout`, checks arguments, enforces
  the deadline, renders the envelope, catches errors), then registers the
  tool.  Its body returns a Result, not formatted text; every tool goes
  through that one definition path.
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
- **Skills are read from disk only.**  A pending `SKILL.md` write is
  invisible to discovery; the model must not author instructions that are
  then treated as authoritative before review.  `allowed-tools` is advisory
  and must stay labelled as such.
- **Tests are not part of the package.**  They are loaded on demand and
  must not run in a user's normal Emacs startup.

## Before finishing

- The full ERT suite passes and any new behaviour has a test that goes
  through the tool boundary.
- The six source files byte-compile without warnings.
- User-visible changes are reflected in `README.md`; new or changed domain
  terms in `GLOSSARY.md`; architectural decisions in a new ADR.
- No VFS changes are left pending: `vfs_diff`, then `file_sync` (or
  `vfs_discard`) before ending the session.
