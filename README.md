# gptel-yatools

Extra [gptel](https://github.com/karthink/gptel) tools — "yet another tools".

The centrepiece is a small, **buffer-local virtual filesystem** layered over
the real one: the model reads files through it, writes are buffered until you
review and sync them, and every pending change is shown as a unified diff
before it touches the disk.  Around it sit the tools a coding assistant needs:
workspace-relative paths, line-addressed reads, regexp search and shell
commands.

Nothing is destructive without a visible step: a write is only buffered, and
`file_sync` refuses to go to disk while a file changed underneath you.

That review is the only control there is, so it is worth knowing what it
assumes.  `gptel-yatools` runs with **your** permissions: it can read any file
you can read and run any command you can run, and the text it reads is sent to
the model's provider.  `execute_command` asks before it runs anything and
`file_sync` shows a diff before it writes; those two prompts are the whole of
the protection.  A command you approve keeps running after the call returns,
so the confirmation line says `[runs in the background]`, and <kbd>C-c C-k</kbd>
(or `M-x gptel-abort`) is how you stop it.  Do not enable the shell tool on a
repository you do not trust, and do not set
`gptel-yatools-sync-without-review` unless you have read what it waives.

What you are shown is what will happen.  File names and file contents are
displayed with anything invisible made visible, so a diff cannot describe
itself as something other than what it is, and the confirmation for
`execute_command` shows the whole command rather than its first few hundred
characters — with its line breaks and indentation intact, so an inline
script reads as the script it is.  A few files are off-limits to the agent entirely — your Emacs
startup files, `.dir-locals.el`, and the package's own source — because a
change to one of those would run the next time Emacs starts.

## Installation

### straight.el

```elisp
(use-package gptel-yatools
  :after gptel
  :straight (:type git :host github :repo "USER/gptel-yatools")
  :config (gptel-yatools-enable "filesystem"))  ; add "shell" when you want it
```

Until the repository is public, point straight.el at a checkout:

```elisp
(use-package gptel-yatools
  :after gptel
  :straight (:local-repo "/path/to/gptel-yatools")
  :config (gptel-yatools-enable "filesystem"))   ; add "shell" when you want it
```

### package-vc or plain `load-path`

```elisp
(package-vc-install '(gptel-yatools :url "https://github.com/USER/gptel-yatools"))
```

or clone the repository and `(add-to-list 'load-path "/path/to/gptel-yatools")`.
`gptel` and `yaml` are hard dependencies; nothing else is required.

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

### Timeouts

Every tool takes an optional `timeout` argument and carries a deadline that
aborts it when it expires.  There are two defaults, because there are two
kinds of tool:

- `gptel-yatools-timeout` (120 s) bounds a **synchronous** call.  It blocks
  Emacs for as long as it runs, so this is also how long your editor is
  unavailable.
- `gptel-yatools-async-timeout` (600 s) bounds an **asynchronous** one.
  The call returns immediately, so this is about not leaving a runaway
  command behind, not about your patience.

Time spent waiting for you — reading a `file_sync` diff, confirming
`execute_command` — does not count against either.

### Long-running commands

`execute_command` is asynchronous: it starts the command and returns, so
Emacs stays usable while the command runs.  The chat waits for it — gptel
does not send the next request until every tool call has reported — but you
can edit buffers, start other chats, or read this one meanwhile.

While something is running the header line shows how long:

```
 Running 1 command, 2 subagents... 14s (C-c C-k cancels)
```

Several commands or subagents issued in the same response run
**concurrently**; the status line counts them by kind and stops when the
last one finishes.  A model that needs one step to finish before the next
starts has to use separate calls, and the tool's description says so.

<kbd>C-c C-k</kbd> in a `gptel-mode` buffer (`M-x
gptel-yatools-cancel-tool-calls`) kills every command and subagent that
buffer started and stops the request.  `M-x gptel-abort` does the same,
because gptel's own abort cannot see a tool call: it looks the request up
by its network process, which has finished by the time a tool is running.
Rebind `C-c C-k` in your config if it is in your way — this package sets it
in `gptel-mode-map`, so a later binding wins.

`execute_command` and `subagent` are the asynchronous tools.  Everything
else answers from memory or from a quick disk read, and waiting for it is
cheaper than the bookkeeping needed to deliver it later.  But the machinery
belongs to the tool kit, not to those two: a new tool gets the same
delivery, deadline, cancellation and status line by adding `:async t` to
its definition, and the body stays exactly as it is.

One honest limit: with a remote workspace, `make-process` has to establish
the TRAMP connection before it can return, so the boundary blocks for that
(about 3 s cold, under 1 s on a live connection) even though the command
itself does not.  Local commands do not block at all.

### Remote workspaces

A workspace can live on another machine.  Every path the tools use is an
ordinary Emacs file name, so a chat buffer whose `default-directory` (or
project root) is a TRAMP name — `/ssh:host:/repo`, `/docker:name:/src`,
`/sudo:root@host:/etc` — works: reads, writes, encoding detection,
conflict baselines, `vfs_diff`, the sync review, skills and the project
root are all performed by TRAMP on that host.  Nothing needs configuring;
TRAMP is not a dependency and is used only when a name already is remote.

A tool call in a remote workspace waits for the connection to be free.
gptel runs tool calls from its response loop, which can land inside
another TRAMP file operation, and TRAMP refuses a second call into a
connection it is already using (`Forbidden reentrant call of Tramp`) —
which gptel then reports as a *missing file*, so the model is told the
file is not there when the connection was merely busy.  That is what a
fan-out of subagents produced.  The wait is a condition rather than a
sleep, so any number of calls take their turn;
`gptel-yatools-remote-tool-delay` is the interval and
`gptel-yatools-remote-tool-tries` the bound.  Local workspaces are
unaffected.

The workspace is one machine, and a path never leaves it.  A relative path
is resolved against the root; an absolute one — `/etc/hostname`,
`~/notes` — is resolved against the root's *host*, so `read_path
"/etc/hostname"` in a container workspace reads the container's file.  This
matters more than it sounds: `expand-file-name` ignores the root for an
absolute name, so before this rule the same call quietly read *your own*
computer, and the reply looked perfectly ordinary.  A path that names a
different machine is refused rather than visited.

`execute_command` runs on the host too — under that host's shell, not your
`shell-file-name`, which is a path on your machine and would be
`exec: …: not found`.  The exit-status line says where the command ran:

```
Command succeeded in . on the remote host /ssh:host: (exit code 0).
```

Two limits are deliberate:

- **`directory` must be on the workspace's own machine.**  A relative
  path (resolved against the root) or a full path on that same host both
  work; anything else is refused before it is even looked at, and the
  refusal names both machines:

  ```
  Error: the workspace is on the remote host docker:gy-a, but DIRECTORY
  resolves to /docker:gy-b:/tmp/other, which is on the remote host
  docker:gy-b. Give DIRECTORY relative to the workspace root, or as a
  path on the remote host docker:gy-a, so the command runs where the
  workspace is.
  ```

  Refusing *this* machine was the obvious case; refusing another *server*
  is the same hole with a longer reach.  The check compares connections
  rather than host names, because `file-remote-p` reports only the last hop
  of `/ssh:a|sudo:root@b:/x`, so two names that reach `b` through
  different jump hosts are correctly told apart.
- **The deadline covers the connection.**  Opening a TRAMP connection
  costs a second or two on the first call and comes out of the tool's
  `timeout`; a call that needs a real budget should say so.

Round trips are the cost of a remote workspace: a directory listing asks
the host about each entry, and `vfs_diff` reads every pending file, so
these calls take longer than the same calls locally.  Nothing about their
answers changes.

What each tool does there is recorded in
[ADR 0004](docs/adr/0004-a-remote-workspace-runs-on-its-host.md), including
the measured facts it rests on (TRAMP echoes its wrapper script through a
`pipe` connection; `(process-id)` is the local ssh client's pid; a remote
kill has to go through `signal-process`).

`render_diagram` is the exception, and deliberately: it renders where its
cache lives rather than where the workspace lives, so a remote workspace
still gets its picture drawn locally (see
[ADR 0006](docs/adr/0006-a-subprocess-runs-where-its-artifacts-live.md)).
The rule is "a subprocess runs where its artifacts are", and only
`execute_command` has the workspace as its artifact.

#### Checking it by hand

The suite tests remote behaviour against a stand-in file-name handler, so
no test needs a network.  To exercise a real host, any container will do:

```sh
docker run -d --name gptel-tramp-check alpine sleep 3600
```

then open a buffer with `default-directory` at
`/docker:gptel-tramp-check:/tmp/`, enable the filesystem and shell tools,
and ask for a diff before and after a `write_file`, plus
`execute_command "pwd; hostname"` — `pwd` must be `/tmp` and `hostname`
the container's id, not your machine's.  `execute_command "sleep 600"`
with a short `timeout` should report a timeout *and* leave nothing running
on the host (`docker exec gptel-tramp-check ps -eo args | grep sleep`).

### Syncing unattended

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
the model still has to call `file_sync`.

## Tools

| Tool | Category | Purpose |
| --- | --- | --- |
| `read_path` | filesystem | Read a file, or list a directory; pending VFS copies win over disk. |
| `read_file_from_offset` | filesystem | Read `lines` lines starting at a 1-based `offset`. |
| `fetch_lines_from_file_using_regex` | filesystem | Return matching lines, each prefixed with its line number. |
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

The virtual filesystem is buffer-local, so two chats never see each other's
pending writes, and a request's tools run in the buffer that owns it rather
than in whichever buffer happens to be current.  A relative path means the
same file in every tool: it is resolved against the workspace root once, at
the tool's edge, so a write and the read that follows it cannot disagree.

Every reply says where it came from.  A read of a pending copy, a diff, a
directory listing that merges disk with VFS-only entries — each carries that
fact to the model, and a merged listing marks the rows that are not on disk
yet.  A pending copy the disk catches up with stops being pending: it is
reaped the next time that file is read or the pending changes are listed, so
nothing keeps shadowing disk with a copy that says nothing new.
Conflicts — a file that changed on disk after it was read, a target
that has become a FIFO, a pending write to a file whose parent is now a
regular file, a coding system the text cannot be represented in — are
reported instead of silently resolved, and are decided by one function, so
the files the review offers to sync are exactly the files the sync writes.

The review UI is `gptel-yatools-write-diff-mode`, a minor mode active in the
buffer where `file_sync` shows its diff: <kbd>C-c C-c</kbd> accepts and
<kbd>C-c C-k</kbd> rejects, <kbd>TAB</kbd> folds the file or hunk at point, and
<kbd>S-TAB</kbd> folds or unfolds every file.  Each file is headed by its path
and how much moved (`+12 -3`), so a folded file still says what it changes,
and the body is the same text `vfs_diff` shows the model.

Faces are painted onto the text as it is inserted, the way a magit buffer
does it, rather than left to font-lock on redisplay: a diff is highlighted
the moment it appears, and folding is an overlay, so the text the user
approves is exactly the text that was shown, and it is shown in the order it
is stored even when it contains direction-changing characters.

Two limits you do not have to police yourself: a file whose name contains a
control character cannot be written, and overwriting a file that changed on
disk since it was read asks you first.

### Skills

An [Agent Skill](https://agentskills.io) is a directory with a `SKILL.md` in
it: YAML frontmatter naming the skill and saying when it applies, then
Markdown instructions, optionally with `scripts/`, `references/` and `assets/`
alongside.  The `skill` tool reads them progressively — called with no
arguments it returns just the name and description of every installed skill,
called with a name it returns that skill's instructions and file list, called
with a name and a file it returns one referenced file.

Skills are looked up in `gptel-yatools-skill-directories`, which defaults to
`.agents/skills` in the workspace root and `skills/` under your Emacs
directory (`user-emacs-directory`).  Relative entries are resolved against the
workspace root.  Same-named skills in different roots are all kept, never
merged: the ambiguity is reported, not resolved by picking one.  An entry
may be a function, and so may the whole list, which makes roots that depend on
the current project easy to express:

```elisp
(setq gptel-yatools-skill-directories
      (list ".agents/skills"
            (lambda () (expand-file-name "skills" user-emacs-directory))))
```

Skills may be grouped into subdirectories — `skills/engineering/code-review/`
— and are found up to `gptel-yatools-skill-search-depth` levels below a root
(4 by default; a directory cut off by the limit is reported rather than
silently skipped).  A directory holding a `SKILL.md` is a skill and is not
searched further, so a skill's own subdirectories are never mistaken for
skills.  When the same name occurs in two groups, both are listed by their
path relative to the root (`engineering/code-review`), and calling that path
loads the intended one; the bare name then reports the candidates instead of
picking one.  Two roots holding the same path would still collide, so a handle
that is itself ambiguous gains its root in parentheses —
`engineering/code-review (/path/to/root)` — and that whole line is the name to
call it by.  A skill that sits directly in its root has no path of its own to
show, so it gains the root in parentheses too: `review (/path/to/root)`.  A
skill's absolute directory works as a name too, which is what the loaded
skill's `Directory:` line hands the model.

The scan is cheap after the first call: the directories are walked every
time, so a skill added or removed is noticed immediately, but the YAML
frontmatter is parsed once per distinct `SKILL.md` text and then cached. On
a root of 38 skills that is 400 ms for the first `skill` call and about
20 ms afterwards.  The cache is keyed by the text, not the path, so two
skills can never be handed each other's parse.

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
call in the transcript, and a missing image is rebuilt from it — one
PlantUML process for however many are missing.

Rendering needs [PlantUML](https://plantuml.com); some diagram types also
need GraphViz.  Without PlantUML the tool says so and names the variable to
set, rather than failing obscurely.

The tool also carries a cheat sheet, one section per diagram type.  Called
with no arguments it lists the sections it has; called with `help` set to
one of them it returns that section — a compact reference for the syntax
that most often goes wrong.  The sheet is the defcustom
`gptel-yatools-diagram-cheatsheet`, and the list of sections is read from
its own `## ` headings, so a section you add is offered without any other
edit.

```elisp
(setq gptel-yatools-plantuml-command "plantuml"        ; or an absolute path
      gptel-yatools-plantuml-security-profile "SANDBOX")
```

Images go to `gptel-yatools-diagram-cache-directory`
(`~/.emacs.d/var/gptel-yatools/cache/`), as `<hash>.svg` beside the
`<hash>.puml` source.  That directory is the one place this package writes
without a review, because the model cannot name a path in it and nothing
there is data: see [ADR 0003](docs/adr/0003-a-tool-may-own-an-opaque-directory.md).

It does not grow for ever: the first time Emacs is idle in a session,
entries not rendered within `gptel-yatools-diagram-cache-max-age-days`
(30) are deleted.  That costs nothing you can lose — the transcript holds
the source of every diagram a buffer mentions, and re-opening the chat
re-renders them all in one PlantUML run.  Set it to `nil` to keep
everything, or use `M-x gptel-yatools-diagram-clear-cache` to empty the
cache now — the cure for the cases age cannot cover, like upgrading
PlantUML or changing the security profile.

Rendering happens **where the cache is**, which normally means on this
machine — including when the chat is about a remote workspace: the cache
is local, the renderer is found locally, and the picture is drawn by this
Emacs, so nothing about a diagram needs the remote host.  Point the cache
at a remote path and the render moves there instead, provided PlantUML is
installed on that host.  See
[ADR 0006](docs/adr/0006-a-subprocess-runs-where-its-artifacts-live.md).

The security profile is a **default, not a boundary**.  Under `SANDBOX` the
renderer cannot read a file or fetch a URL — `!include ./theme.puml` and
`!theme mytheme` are refused — while `!theme cerulean` and
`!include <C4/C4_Container>` keep working, because those come out of the
PlantUML jar.  Set the variable to `"LEGACY"` (or `nil`) to allow local
includes; the tool's refusal messages say so too.  This is not containment:
the model can render through `execute_command` if the shell tool is enabled,
and with tool confirmations off the shell is unrestricted anyway.  It is a
sensible default for a path nobody is watching.

In the buffer:

- `M-x gptel-yatools-diagram-toggle-inline` draws or undraws the pictures in
  this buffer; it is buffer-local and reversible, and the token text is never
  removed.
- `M-x gptel-yatools-diagram-open-at-point` opens the image outside Emacs —
  what the token is worth on a terminal frame, where nothing can be drawn.
- `M-x gptel-yatools-diagram-insert` renders the source you type and inserts
  its token, the manual repair for a model that forgot to repeat the token
  the tool handed it.

Drawing needs a graphic frame; on a terminal the token stays as text and the
open command is the way to see the diagram.

### Subagents

`subagent` hands one self-contained task to a child agent.  The model writes
the brief; the child sees that brief and nothing else — not the conversation
it came from, not your attached files — reads what it needs, and replies.
The reply comes back as that tool call's result.

A child is a **reader**.  It gets `read_path`, `read_file_from_offset`,
`fetch_lines_from_file_using_regex`, `read_workspace_root` and `skill`, and
nothing else: it cannot write, cannot run a command, and cannot start
another subagent.  That one restriction is why nothing needs reviewing
afterwards — there is nothing to lose.  The list is
`gptel-yatools-subagent-tools`; adding a writing tool to it invalidates the
rest of the design, so think before you do.

Each call is confirmed before it starts, because a child spends tokens with
nobody watching.  Several children in one response run concurrently, so a
fan-out is one approval per child.  The budgets are
`gptel-yatools-subagent-max-turns` (50), `-max-tool-calls` (150) and
`-timeout` (1800 s); a child that hits one is stopped and says how far it
got, and the answer quotes what it had.  `gptel-yatools-subagent-model`
runs children on a cheaper model without touching the parent's.

The parent's tool result says more than the answer: the state, how long it
took, how many turns and tool calls, and **the files the child read**.  That
last list is what turns "no problems found" into something you can judge,
and the reply is marked `:derived` — another model's conclusion, not a
description of disk.  If the child's reply was cut off by its own output
limit, the result says so at the top and calls itself incomplete: gptel
records `:stop-reason` and never reads it, so without that a half-sentence
would arrive looking like a finding.

While children run, the chatbot's header line shows how many and clicking
the label — or <kbd>C-c C-s</kbd> (`M-x gptel-yatools-subagents`) — lists
them.  gptel's own status text cannot do this: a click on it opens the
request inspector, so the count is a label of its own.

A child's buffer is hidden (` *gptel-yatools-subagent-*DeepSeek*-1`) but
real: <kbd>C-x b</kbd> followed by a space finds it, and it is a working
`gptel-mode` chat.  It is read-only while the child works — editing a
transcript mid-run would change what gets sent on its next turn — and
writable once it finishes, which is also how it becomes yours:

- **Edit it** and it is detached: it stops dying with the chat that started
  it, and you are offered a rename so it can become an ordinary session.
  Declining keeps the hidden name; the detaching stands either way.
- **Kill it** (<kbd>C-x k</kbd>) while it runs, and it is aborted — the
  parent's call is answered rather than left waiting forever.
- <kbd>C-c C-k</kbd> inside the child's buffer aborts that one child;
  <kbd>C-c C-k</kbd> in the parent cancels all of them.

A child is another agent with your permissions and your provider: the text
it reads is sent to the model, exactly as the parent's is.

#### Retrying a child from your config

Whether a failed child is worth retrying is a policy, not a mechanism, so
the policy lives in your config.  Three hooks say what happened, and three
functions let a policy act without advising anything private:

| | |
| --- | --- |
| `gptel-yatools-subagent-started-functions` | called with the record after each request is issued |
| `gptel-yatools-subagent-failed-functions` | called with the record and gptel's info before a failure settles; **returning non-nil claims it** |
| `gptel-yatools-subagent-settled-functions` | called with the record after it settles, for any reason |
| `gptel-yatools-subagent-buffer-p` | is this buffer a child? |
| `gptel-yatools-subagent-insert` | write into a child without taking it over |
| `gptel-yatools-subagent-retry` | run a settled (or claimed-failed) child again, in place |

The failure hook is the one that changes anything.  Claiming a failure
means the child is *not* settled and the parent is told nothing: its tool
call goes on waiting inside the budget it was given, and running out of
that budget is what finally makes the failure a timeout.  A retry in the
middle of it is therefore invisible to the parent, which is what you want
for a dropped connection or a 429:

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

Pass `gptel-yatools-subagent-retry` a second argument to append an
instruction before re-sending — `"Continue exactly where you stopped."` —
which is what you want when the failed attempt had already streamed part of
its answer: the partial reply stays in the transcript, still marked as a
response, so the model carries on instead of starting over.

Claiming is a promise.  A failure you claim and never follow up leaves the
child running until its deadline, so either retry it or stop it.

## Tests

ERT, no network, no prompts, every test in a throwaway temp directory:

```sh
emacs -Q --batch -L . -l gptel-yatools.el \
  -l tests/gptel-yatools-tests.el -l tests/gptel-yatools-vfs-tests.el \
  -l tests/gptel-yatools-skills-tests.el \
  -l tests/gptel-yatools-diagram-tests.el \
  -l tests/gptel-yatools-agents-tests.el \
  -f ert-run-tests-batch-and-exit
```

The diagram tests that need PlantUML are skipped when it is not installed;
the rest — content addressing, the transcript reader, the overlay, the
refusals — run either way.  `gptel` and `yaml` must be on `load-path` (any
straight.el/MELPA install is enough).

Interactively: `M-x load-file RET tests/gptel-yatools-tests.el RET`, then
`M-x ert RET gptel-yatools-test- RET`.

## License

MIT.  See [LICENSE](LICENSE).
