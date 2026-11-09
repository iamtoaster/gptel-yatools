# gptel-yatools

Extra [gptel](https://github.com/karthink/gptel) tools — "yet another tools".

`gptel-yatools` gives a gptel model a small, **buffer-local virtual
filesystem** layered over the real one, plus the tools a coding assistant
needs to work in it: workspace-relative paths, line-addressed reads, file and
line search, shell commands, Agent Skills and PlantUML diagrams.

Writes go through the virtual filesystem: the model's changes are buffered,
shown to you as a unified diff, and only then written to disk.  Reads see
your pending changes, so a write and the read that follows it cannot
disagree.

## What it does

- **Buffered writes with a review step.**  `write_file` and `write_file_diff`
  change the VFS only; `file_sync` shows the diff and waits for your
  acceptance.  Nothing reaches disk without that step.
- **Conflicts reported, not resolved.**  A file that changed on disk after
  the model read it, a target that has become a FIFO, a pending write whose
  parent is now a regular file, content the file's encoding cannot
  represent — each is refused with a reason, and the files the review offers
  are exactly the files the sync writes.
- **Per-chat isolation.**  The VFS is buffer-local, so two chats never see
  each other's pending writes, and a request's tools run in the buffer that
  owns it.
- **Workspace-relative paths.**  A relative path means the same file in every
  tool: it is resolved against the workspace root once, at the tool's edge.
- **Provenance on every reply.**  A read of a pending copy, a diff, a
  directory listing that merges disk with VFS-only entries — each carries
  that fact to the model, and a merged listing marks the rows that are not
  on disk yet.
- **Remote workspaces.**  A chat whose `default-directory` is a TRAMP name
  (`/ssh:host:/repo`, `/docker:name:/src`) works without configuration; the
  file tools and the shell run on that host.

### What it assumes about you

The review is the only control there is, so it is worth knowing what it
assumes.  `gptel-yatools` runs with **your** permissions: it can read any
file you can read and run any command you can run, and the text it reads is
sent to the model's provider.  `execute_command` asks before it runs
anything and `file_sync` shows a diff before it writes; those two prompts
are the whole of the protection.  A command you approve keeps running after
the call returns, so the confirmation line says `[runs in the background]`,
and <kbd>C-c C-k</kbd> (or `M-x gptel-abort`) is how you stop it.  Do not
enable the shell tool on a repository you do not trust.

A command you approve is **not sandboxed**: it runs as you, so it can write
anywhere you can write, whatever the VFS would have refused.  Use tool
confirmations; the VFS is a review step for the model's file writes, not a
security boundary around the shell.

What you are shown is what will happen.  File names and file contents are
displayed with anything invisible made visible, so a diff cannot describe
itself as something other than what it is, and the confirmation for
`execute_command` shows the whole command rather than its first few hundred
characters — with its line breaks and indentation intact, so an inline
script reads as the script it is.  A few files are off-limits to the agent
entirely — your Emacs startup files, `.dir-locals.el`, and the package's
own source — because a change to one of those would run the next time Emacs
starts.

## Installation

Requires Emacs 29.1 or later, [gptel](https://github.com/karthink/gptel)
and [yaml](https://github.com/zkry/yaml.el).  Nothing else is needed;
TRAMP ships with Emacs.

**Linux only, so far.**  This package has been developed and tested on Linux
machines and assumes a Linux machine.  The shell tool runs commands through a
POSIX shell, the shells it looks for on a remote host are POSIX ones
(`/bin/sh`, `/bin/ash`), and `vfs_diff` and the sync review expect a GNU `diff`
on `exec-path`.  Nothing has been tried on Windows, and it may break there; if
you run it on another platform, expect to read the code rather than the
manual.

### straight.el

```elisp
(use-package gptel-yatools
  :after gptel
  :straight (:type git :host github :repo "iamtoaster/gptel-yatools")
  :config (gptel-yatools-enable "filesystem"))  ; add "shell" when you want it
```

### package-vc or plain `load-path`

```elisp
(package-vc-install '(gptel-yatools :url "https://github.com/iamtoaster/gptel-yatools"))
```

or clone the repository and `(add-to-list 'load-path "/path/to/gptel-yatools")`.
To follow your own checkout of the repository, straight.el takes a local path
instead:

```elisp
(use-package gptel-yatools
  :after gptel
  :straight (:local-repo "/path/to/gptel-yatools")
  :config (gptel-yatools-enable "filesystem"))
```

## Usage

Loading the package registers every tool in gptel's tool registry, so they
appear in the `gptel-menu` tool picker straight away.  Registration does not
enable anything: which tools a request sends is `gptel-tools`, and that stays
untouched until you say otherwise.

```elisp
(gptel-yatools-enable "filesystem")             ; read and write files
(gptel-yatools-enable "shell")                  ; run shell commands
(gptel-yatools-enable "write_file" "file_sync") ; by name
(gptel-yatools-enable-all)                      ; every tool
```

Enabled tools are prepended to `gptel-tools` and replace earlier entries with
the same name, so calling an enable function twice (or re-evaluating your
config) does not send a tool twice.  Both functions are also commands, so
`M-x gptel-yatools-enable` lets you pick categories and tools interactively.
Picking tools in `gptel-menu` works too and is buffer-local; the enable
functions set the value through `customize-set-variable`, so a chat buffer
with its own `gptel-tools` keeps it.

The categories are `filesystem`, `workspace`, `shell`, `skills`, `diagram`
and `agents`; the tool table below says which tool belongs to which.

## Configuration

Every option is a defcustom, so `M-x customize-group RET gptel-yatools`
lists them all with their documentation.

### Which tools a chat sends

| | |
| --- | --- |
| `gptel-yatools-enable` | Enable the named categories and tools.  Also a command. |
| `gptel-yatools-enable-all` | Enable every tool.  Also a command. |

### Timeouts and cancellation

| Option | Default | Meaning |
| --- | --- | --- |
| `gptel-yatools-timeout` | 120 s | Deadline for a **synchronous** call.  It blocks Emacs while it runs, so this is also how long your editor is unavailable. |
| `gptel-yatools-async-timeout` | 600 s | Deadline for an **asynchronous** call (`execute_command`, `subagent`).  The call returns immediately, so this bounds a runaway command, not your patience. |
| `gptel-yatools-ignore-quit` | `t` | Let a <kbd>C-g</kbd> aimed at something else pass *through* a running tool call: the call finishes and delivers its result, then the quit is re-signalled to whatever it was aimed at. |
| `gptel-yatools-tool-trace` | `nil` | Record what happens to each pending tool call, step by step.  A diagnostic; leave it off. |
| `gptel-yatools-tool-trace-file` | `gptel-yatools-trace.log` in the temp directory | Where the trace goes. |

### Remote workspaces

A tool call in a remote workspace waits for a free TRAMP connection rather
than assuming one, because TRAMP refuses a second call into a connection it
is already using.  These bound that wait:

| Option | Default | Meaning |
| --- | --- | --- |
| `gptel-yatools-remote-tool-delay` | 0.2 s | Seconds between checks for a free connection. |
| `gptel-yatools-remote-tool-tries` | 100 | Most checks before giving up (twenty seconds at the default interval). |
| `gptel-yatools-remote-tool-wait-limit` | 120 s | Most seconds a call may wait behind another call. |

Every tool also takes an optional per-call `timeout` argument, which
overrides the default for that call.  Time spent waiting for you — reading a
`file_sync` diff, confirming `execute_command` — does not count against any
deadline.

<kbd>C-c C-k</kbd> in a `gptel-mode` buffer
(`M-x gptel-yatools-cancel-tool-calls`) kills every command and subagent that
buffer started and stops the request.  `M-x gptel-abort` does the same.
This package binds `C-c C-k` in `gptel-mode-map`, so a later binding in your
config wins.

### Filesystem

| Option | Default | Meaning |
| --- | --- | --- |
| `gptel-yatools-sync-without-review` | `nil` | Skip the sync review, for batch or scripted use.  See below. |
| `gptel-yatools-media-size-limit` | 5 MiB | Largest image `read_path` will attach to the conversation.  `0` removes the limit. |
| `gptel-yatools-write-denied-files` | your Emacs startup files | Files no writing tool may touch, whatever directory they are in. |
| `gptel-yatools-write-denied-file-names` | `(".dir-locals.el" ".dir-locals-2.el")` | File names no writing tool may touch, in any directory. |
| `gptel-yatools-write-denied-directories` | this package's own directory | Directories no writing tool may put files in.  Matched by `file-truename`, so a symlink into one is caught too. |

The three deny lists are the write policy: a target on any of them is refused
with the name of the setting that denied it, and the model is told to report
that rather than working around it through the shell.

#### Syncing unattended

`file_sync` shows you a diff and waits for you to accept it.  In a script, an
org-babel block or a batch Emacs there is nobody to ask, so it refuses — which
is why nothing can be written there by default.  To sync without the review:

```elisp
(setq gptel-yatools-sync-without-review t)
```

This waives the review, not the checks: a file that changed on disk since the
VFS captured it, a file whose visiting buffer has unsaved changes, and content
the file's encoding cannot represent are all still refused and reported.  The
model is never told about this option, and it does not make writes automatic —
the model still has to call `file_sync`.  Overwriting a file that changed on
disk since it was read is confirmed separately, per call, and is not covered
by this setting.

### Search

`glob` and `grep` walk the workspace themselves, in Elisp: no `rg`, no `fd`,
nothing to install.  On a remote workspace they run one script on the host
instead of asking about each file across the connection.

| Option | Default | Meaning |
| --- | --- | --- |
| `gptel-yatools-search-skip-directories` | `.git`, `node_modules`, `.venv` and similar | Directory names a search does not descend into, at any depth. |
| `gptel-yatools-search-max-file-size` | 1 MiB | Largest file whose contents are read.  Bigger files are skipped and named in the reply, and `glob` still finds them. |
| `gptel-yatools-search-file-limit` | 4000 | Files one search may visit before it stops and says so. |
| `gptel-yatools-search-seconds-limit` | 20 | Seconds one search may spend walking before it stops and says so. |
| `gptel-yatools-glob-result-limit` | 200 | Paths one `glob` returns, newest first. |
| `gptel-yatools-grep-match-limit` | 200 | Lines one `grep` returns, taken from the files with the most matches. |
| `gptel-yatools-grep-matches-per-file-limit` | 20 | Lines one file may contribute, so one busy file cannot crowd out the rest. |
| `gptel-yatools-search-remote-chunk-bytes` | 512 KiB | Bytes of contents one transfer from a remote host may carry. |
| `gptel-yatools-search-remote-chunk-records` | 2000 | Files one metadata-only transfer from a remote host may report. |

Every limit ends in a sentence the model is told, so a partial answer is never
mistaken for a complete one.  `.gitignore` is not consulted: the skip list is
explicit, and a directory you need skipped is a name to add to it.

### Skills

| Option | Default | Meaning |
| --- | --- | --- |
| `gptel-yatools-skill-directories` | `.agents/skills` in the workspace, `skills/` under `user-emacs-directory` | Where skills are looked for.  Entries may be functions, and so may the whole list. |
| `gptel-yatools-skill-search-depth` | 4 | How many levels below a root skills are found.  A directory cut off by the limit is reported rather than silently skipped. |

Relative entries are resolved against the workspace root.  A root that depends
on the current project is a function away:

```elisp
(setq gptel-yatools-skill-directories
      (list ".agents/skills"
            (lambda () (expand-file-name "skills" user-emacs-directory))))
```

`M-x gptel-yatools-skills` opens the skill browser.

### Diagrams

| Option | Default | Meaning |
| --- | --- | --- |
| `gptel-yatools-plantuml-command` | `"plantuml"` | The renderer, as a name on `exec-path` or an absolute path. |
| `gptel-yatools-plantuml-security-profile` | `"SANDBOX"` | The profile PlantUML renders under. |
| `gptel-yatools-diagram-cache-directory` | `gptel-yatools/cache/` under `user-emacs-directory` | Where rendered images and their sources are kept. |
| `gptel-yatools-diagram-cache-max-age-days` | 30 | Delete cache entries not rendered within this many days, on the first idle moment of a session.  `nil` keeps everything. |
| `gptel-yatools-diagram-inline` | `t` | Draw diagrams in the chat buffer.  Off, the token stays as text. |
| `gptel-yatools-plantuml-graphviz-timeout` | 30 s | Ceiling for GraphViz layout, capped by the call's own remaining deadline. |
| `gptel-yatools-diagram-cheatsheet` | built in | The reference the tool answers from: `## ` sections, one per diagram type. |

```elisp
(setq gptel-yatools-plantuml-command "/usr/local/bin/plantuml"
      gptel-yatools-plantuml-security-profile "SANDBOX")
```

The security profile is a **default, not a boundary**.  Under `SANDBOX` the
renderer cannot read a file or fetch a URL — `!include ./theme.puml` and
`!theme mytheme` are refused — while `!theme cerulean` and
`!include <C4/C4_Container>` keep working, because those come out of the
PlantUML jar.  Set it to `"LEGACY"` (or `nil`) to allow local includes.  It is
not containment: with the shell tool enabled the model can render through
`execute_command`, which is unrestricted unless tool confirmations are on.

`M-x gptel-yatools-diagram-clear-cache` empties the cache — the thing to do
after upgrading PlantUML or changing the security profile.

### Subagents

| Option | Default | Meaning |
| --- | --- | --- |
| `gptel-yatools-subagent-tools` | read-only tools | What a child agent may use.  Adding a writing or shell tool invalidates the design, so think first. |
| `gptel-yatools-subagent-max-turns` | 200 | Model responses a child may produce before it is stopped. |
| `gptel-yatools-subagent-max-tool-calls` | 500 | Tool calls a child may make before it is stopped. |
| `gptel-yatools-subagent-timeout` | 1800 s | Deadline for a child.  The real guard against a runaway; the two counts above are backstops. |
| `gptel-yatools-subagent-model` | `nil` | Model for children, so they can run cheaper than the parent. |
| `gptel-yatools-subagent-task-width` | 30 | Characters of a child's task shown in the subagent picker. |

Three hooks report what a child is doing, and three functions let a policy act
on it without advising anything private:

| | |
| --- | --- |
| `gptel-yatools-subagent-started-functions` | called with the record after each request is issued |
| `gptel-yatools-subagent-failed-functions` | called with the record and gptel's info before a failure settles; **returning non-nil claims it** |
| `gptel-yatools-subagent-settled-functions` | called with the record after it settles, for any reason |
| `gptel-yatools-subagent-buffer-p` | is this buffer a child? |
| `gptel-yatools-subagent-insert` | write into a child without taking it over |
| `gptel-yatools-subagent-retry` | run a settled (or claimed-failed) child again, in place |

The failure hook is the one that changes anything.  Claiming a failure means
the child is *not* settled and the parent is told nothing: its tool call goes
on waiting inside the budget it was given, and running out of that budget is
what finally makes the failure a timeout.  A retry in the middle of it is
therefore invisible to the parent, which is what you want for a dropped
connection or a 429:

```elisp
(defun my-subagent-retry-maybe (record info)
  "Retry RECORD after a failure worth retrying, and claim it."
  (when (member (plist-get info :http-status) '("429" "502" "503"))
    ;; This runs in gptel's sentinel: start the request from a timer, and
    ;; ignore the refusal if the child died or was taken over meanwhile.
    (run-at-time 2 nil
                 (lambda ()
                   (ignore-errors (gptel-yatools-subagent-retry record))))
    t))

(add-hook 'gptel-yatools-subagent-failed-functions
          #'my-subagent-retry-maybe)
```

Pass `gptel-yatools-subagent-retry` a second argument to append an instruction
before re-sending — `"Continue exactly where you stopped."` — which is what you
want when the failed attempt had already streamed part of its answer.

Claiming is a promise.  A failure you claim and never follow up leaves the
child running until its deadline, so either retry it or stop it.

## Tools

| Tool | Category | Purpose |
| --- | --- | --- |
| `read_path` | filesystem | Read a file, or list a directory; pending VFS copies win over disk.  An image the model can see is attached to the conversation instead of being read as text. |
| `read_file_from_offset` | filesystem | Read `lines` lines starting at a 1-based `offset`. |
| `fetch_lines_from_file_using_regex` | filesystem | Return matching lines of **one known file**, each prefixed with its line number.  Uncapped. |
| `glob` | filesystem | Find files by a shell wildcard (`*.el`, `src/**/*.c`), newest first.  Does not need the path in advance. |
| `grep` | filesystem | Find lines by an Emacs regexp anywhere in a tree, case-insensitively unless the pattern has a capital. |
| `write_file` | filesystem | Replace a file's contents **in the VFS**; the disk is not touched until `file_sync`. |
| `write_file_diff` | filesystem | Replace one exact occurrence of `old_string` with `new_string`, in the VFS. |
| `file_sync` | filesystem | Write pending changes to disk, after showing the diff for review. |
| `vfs_diff` | filesystem | Unified diff of pending changes, with paging. |
| `vfs_discard` | filesystem | Drop pending changes — the way out of a conflict. |
| `read_workspace_root` | workspace | Absolute path of the workspace root. |
| `execute_command` | shell | Run a shell command from the workspace root and return its output. On a remote workspace it runs on that host. Asynchronous: the call returns while the command runs. |
| `skill` | skills | List the installed [Agent Skills](https://agentskills.io), load one, or read a file it references. |
| `render_diagram` | diagram | Render PlantUML source to an image the chat buffer draws inline, and return the token to show it. |
| `subagent` | agents | Hand one self-contained task to a child agent that reads files and reports back. Asynchronous: the call returns while it works. |

### Images

A model that can see images does not need a screenshot described to it, so
`read_path` on a PNG, JPEG, GIF or WebP attaches the file to the
conversation instead of reading it as text.  The format is decided by the
file's own bytes, not its name: a screenshot saved without an extension
works, and a text file renamed to `.png` is still text.  Anything the model
does not claim to accept — or that is larger than
`gptel-yatools-media-size-limit` — is refused with a sentence saying which
of the two it was.

An attached image is sent with the request being answered, and stays
attached to the chat until you remove it, so the model can come back to it
in a later turn.  That also means it is paid for again on every request.

Attaching is nothing more than a `gptel-context` entry, so gptel's own
label already shows it: `[N files]` in the header line counts it, and
clicking that label opens the context buffer, where each attached image is
listed and can be removed one at a time.  `M-x
gptel-yatools-media-forget` is the shortcut for "all the images this
package attached, and nobody else's entries".

Two things about the manual route are worth knowing, because both fail
silently.  gptel only sends context media when `gptel-use-context` is
non-nil (the default, `system`), so a buffer with it set to nil sends the
text and drops the images.  And a model is only offered an image if gptel's
own model table says it accepts that MIME type — a model served locally or
through a proxy may not be in that table at all.

### The review UI

`file_sync` shows its diff in a buffer using
`gptel-yatools-write-diff-mode`: <kbd>C-c C-c</kbd> accepts,
<kbd>C-c C-k</kbd> rejects, <kbd>TAB</kbd> folds the file or hunk at point,
and <kbd>S-TAB</kbd> folds or unfolds every file.  Each file is headed by its
path and how much moved (`+12 -3`), so a folded file still says what it
changes, and the body is the same text `vfs_diff` shows the model.

### Search

A model that does not know the tree can only guess a path, and a guess costs
a failed call and a retry.  `glob` and `grep` answer "where is it?" instead.

`glob` matches file names by a shell wildcard.  A pattern with no slash in it
matches the name at any depth, so `*.el` finds every Emacs Lisp file in the
workspace; a pattern with a slash matches the path relative to the root, so
`src/**/*.c` walks only that subtree.  Results are one path per line with its
modification time, newest first, because the file you were just working on is
usually the one you want.

`grep` matches lines by an Emacs regexp, case-insensitively unless the pattern
contains a capital letter — `foo` finds `Foo`, `Foo` does not find `foo`.
Results are `path:line:text`, and the reply says how many lines it shows out of
how many files matched.  One file contributes at most twenty lines, and a file
that has more is named with its real count and a pointer at
`fetch_lines_from_file_using_regex`, which reads one known file whole and
without a cap.

The twenty-lines-per-file and two-hundred-lines-per-call limits keep the
files with **the most matches**, not the ones the tree happens to list first.
That matters because `readdir` order is not an order: a cap applied to it
would drop an arbitrary two dozen files, and the densest one is exactly what a
capped answer must not lose.  The reply names the files it left out, so a
short answer is never mistaken for a complete one.

A file larger than `gptel-yatools-search-max-file-size` is not read, and the
reply names it: `glob` still finds it, so a file too big to search can be
opened deliberately with `execute_command`.  Naming a directory in `PATH`
searches it even if it is on the skip list, which is how `.git/config` or
`.github/workflows` is searched on purpose.

Both search the **VFS as well as disk**, exactly as `read_path` reads it: a
file you just wrote with `write_file` is found before it is synced, and a line
you just wrote is matched instead of the disk line it shadows.  Those results
are marked `(pending)`, and the envelope's `vfs="true"` says the reply is not
all from disk.  A search that ignored the VFS would tell the model its own
file does not exist.

Nothing here needs `ripgrep` or `fd`.  Locally, a directory is listed once and
its entries are matched in Emacs, so the tools work on any machine Emacs runs
on.  On a remote workspace that would be a network round trip per file, so one
POSIX `sh` script walks the host and streams file metadata — and, for `grep`,
file contents — back through a single process.  The script transports; Emacs
still does the matching, which is what keeps one regexp dialect and one VFS
rule on both sides of the connection.  A tree too large for one transfer is
fetched in several, until the time budget runs out.

### Skills

An [Agent Skill](https://agentskills.io) is a directory with a `SKILL.md` in
it: YAML frontmatter naming the skill and saying when it applies, then
Markdown instructions, optionally with `scripts/`, `references/` and `assets/`
alongside.  The `skill` tool reads them progressively — called with no
arguments it returns just the name and description of every installed skill,
called with a name it returns that skill's instructions and file list, called
with a name and a file it returns one referenced file.

Skills may be grouped into subdirectories — `skills/engineering/code-review/`.
A directory holding a `SKILL.md` is a skill and is not searched further, so a
skill's own subdirectories are never mistaken for skills.  When the same name
occurs in two groups, both are listed by their path relative to the root
(`engineering/code-review`), and calling that path loads the intended one; the
bare name then reports the candidates instead of picking one.  Two roots
holding the same path would still collide, so a handle that is itself
ambiguous gains its root in parentheses —
`engineering/code-review (/path/to/root)` — and that whole line is the name to
call it by.  A skill that sits directly in its root has no path of its own to
show, so it gains the root in parentheses too: `review (/path/to/root)`.  A
skill's absolute directory works as a name too.

The agent only sees skills that exist **on disk**.  A `SKILL.md` that is still
waiting to be synced is not available yet, and a pending edit to one is not in
force until you accept it — so a skill cannot take effect before you have
reviewed it.  The optional `allowed-tools` field is shown to the model but not
enforced, and is labelled as advisory for that reason.

Every scan validates the frontmatter against the specification: a skill whose
`name` or `description` is missing or malformed is still listed, but cannot be
loaded until it is fixed.  `M-x gptel-yatools-skills` shows what was found,
where it came from, and which skills fail validation; <kbd>RET</kbd> opens the
`SKILL.md`.

#### Sending a skill yourself

The `skill` tool lets the model choose.  When you already know which skill
applies — or when the backend or model in use cannot call tools — send it
yourself:

- `M-x gptel-yatools-skills-add` — pick one or more skills (completion shows
  what each is for) and attach them to the gptel context, so they are sent
  with every request until removed.  The attachment is exactly what the
  `skill` tool would have returned: instructions, file list and absolute
  directory, so the model can run the skill's scripts.
- <kbd>C-u M-x gptel-yatools-skills-add</kbd> — insert the same text at point
  instead, as a one-off user turn you can see and edit before sending.  Use
  this when `gptel-use-context` is off.
- `M-x gptel-yatools-skills-remove` — stop sending them (empty input removes
  all).

While skills are attached, the header line shows `[Skills: N]` next to the
VFS pending count, where `N` is how many are attached; clicking it lists
their names.  Removing the context through gptel's own commands works too —
the indicator reflects `gptel-context`, not a copy.

### Diagrams

`render_diagram` turns PlantUML source into a picture in the chat buffer.
The model supplies the source; the tool renders it and hands back a token
such as `[diagram:fae844]`, which the model repeats on a line of its own and
the package draws over.  Nothing has to be saved for a diagram to survive:
the token is a prefix of the digest of the source, the source is in the tool
call in the transcript, and a missing image is rebuilt from it.

Rendering needs [PlantUML](https://plantuml.com); some diagram types also
need GraphViz.  Without PlantUML the tool says so and names the variable to
set, rather than failing obscurely.

The tool also carries a cheat sheet, one section per diagram type.  Called
with no arguments it lists the sections it has; called with `help` set to
one of them it returns that section.  The list is read from the sheet's own
`## ` headings, so a section you add is offered without any other edit.

In the buffer:

- `M-x gptel-yatools-diagram-toggle-inline` draws or undraws the pictures in
  this buffer; it is buffer-local and reversible, and the token text is never
  removed.
- `M-x gptel-yatools-diagram-open-at-point` opens the image outside Emacs —
  what the token is worth on a terminal frame, where nothing can be drawn.
- `M-x gptel-yatools-diagram-insert` renders the source you type and inserts
  its token, for a model that forgot to repeat the token it was handed.

Drawing needs a graphic frame; on a terminal the token stays as text and the
open command is the way to see the diagram.

### Subagents

`subagent` hands one self-contained task to a child agent.  The model writes
the brief; the child sees that brief and nothing else — not the conversation
it came from, not your attached files — reads what it needs, and replies.
The reply comes back as that tool call's result.

A child is a **reader**.  It gets `read_path`, `read_file_from_offset`,
`fetch_lines_from_file_using_regex`, `glob`, `grep`, `read_workspace_root` and
`skill`, and nothing else: it cannot write, cannot run a command, and cannot start another
subagent.  That restriction is why nothing needs reviewing afterwards — there
is nothing to lose.

Each call is confirmed before it starts, because a child spends tokens with
nobody watching.  Several children in one response run concurrently, so a
fan-out is one approval per child.  A child that hits a budget
(`gptel-yatools-subagent-max-turns`, `-max-tool-calls`, `-timeout`) is stopped
and says how far it got, and the answer quotes what it had.

The parent's tool result says more than the answer: the state, how long it
took, how many turns and tool calls, and **the files the child read**.  If the
child's reply was cut off by its own output limit, the result says so at the
top and calls itself incomplete.

While children run, the header line shows how many, and clicking the label —
or <kbd>C-c C-s</kbd> (`M-x gptel-yatools-subagents`) — lists them.

A child's buffer is hidden (` *gptel-yatools-subagent-*DeepSeek*-1`) but real:
<kbd>C-x b</kbd> followed by a space finds it, and it is a working `gptel-mode`
chat.  It is read-only while the child works and writable once it finishes,
which is also how it becomes yours:

- **Edit it** and it is detached: it stops dying with the chat that started
  it, and you are offered a rename so it can become an ordinary session.
- **Kill it** (<kbd>C-x k</kbd>) while it runs, and it is aborted — the
  parent's call is answered rather than left waiting.
- <kbd>C-c C-k</kbd> inside the child's buffer aborts that one child;
  <kbd>C-c C-k</kbd> in the parent cancels all of them.

A child is another agent with your permissions and your provider: the text it
reads is sent to the model, exactly as the parent's is.

### Long-running tools

`execute_command` and `subagent` are asynchronous: they start their work and
return, so Emacs stays usable while it runs.  The chat waits for them — gptel
does not send the next request until every tool call has reported — but you
can edit buffers, start other chats, or read this one meanwhile.

While something is running the header line shows how long:

```
 Running 1 command, 2 subagents... 14s (C-c C-k cancels)
```

Several commands or subagents issued in the same response run
**concurrently**; the status line counts them by kind and stops when the last
one finishes.  A model that needs one step to finish before the next starts
has to use separate calls, and the tool's description says so.

One honest limit: with a remote workspace, `make-process` has to establish
the TRAMP connection before it can return, so the boundary blocks for that
(about 3 s cold, under 1 s on a live connection) even though the command
itself does not.  Local commands do not block at all.

### Remote workspaces

A workspace can live on another machine.  Every path the tools use is an
ordinary Emacs file name, so a chat buffer whose `default-directory` (or
project root) is a TRAMP name — `/ssh:host:/repo`, `/docker:name:/src`,
`/sudo:root@host:/etc` — works: reads, writes, encoding detection, conflict
baselines, `vfs_diff`, the sync review, skills and the project root are all
performed by TRAMP on that host.  Nothing needs configuring; TRAMP is not a
dependency and is used only when a name already is remote.

The workspace is one machine, and a path never leaves it.  A relative path
is resolved against the root; an absolute one — `/etc/hostname`, `~/notes` —
is resolved against the root's *host*, so `read_path "/etc/hostname"` in a
container workspace reads the container's file.  A path that names a
different machine is refused rather than visited.

`execute_command` runs on the host too, under that host's shell rather than
your `shell-file-name`, which is a path on your machine.  Its `directory`
argument must be on the workspace's own machine: a relative path, or a full
path on that same host.  Anything else is refused before it is looked at, and
the refusal names both machines.

Two limits are deliberate:

- **The deadline covers the connection.**  Opening a TRAMP connection costs a
  second or two on the first call and comes out of the tool's `timeout`; a
  call that needs a real budget should say so.
- **Round trips are the cost.**  A directory listing asks the host about each
  entry, and `vfs_diff` reads every pending file, so these calls take longer
  than the same calls locally.  Nothing about their answers changes.

`render_diagram` is the one tool that does not follow the workspace: it
renders where its cache lives, so a remote workspace still gets its picture
drawn locally.  Point `gptel-yatools-diagram-cache-directory` at a remote path
and the render moves there instead, provided PlantUML is installed on that
host.

## License

MIT.  See [LICENSE](LICENSE).
