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

## Installation

### straight.el

```elisp
(use-package gptel-yatools
  :after gptel
  :straight (:type git :host github :repo "USER/gptel-yatools")
  :config (gptel-yatools-enable-all))
```

Until the repository is public, point straight.el at a checkout:

```elisp
(use-package gptel-yatools
  :after gptel
  :straight (:local-repo "/path/to/gptel-yatools")
  :config (gptel-yatools-enable-all))
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
(gptel-yatools-enable-all)         ; every tool
(gptel-yatools-enable "filesystem") ; one category
(gptel-yatools-enable "write_file" "file_sync") ; by name
```

Enabled tools are prepended to `gptel-tools` and replace earlier entries with
the same name, so calling an enable function twice (or re-evaluating your
config) does not send a tool twice.  Both functions are also commands, so
`M-x gptel-yatools-enable` lets you pick categories and tools interactively.
Picking tools in `gptel-menu` works too and is buffer-local; the enable
functions set the value through `customize-set-variable`, so a chat buffer
with its own `gptel-tools` keeps it.

### Timeouts

Tool calls run synchronously inside gptel's request handler, so a tool that
blocks blocks Emacs.  Every tool takes an optional `timeout` argument, and
carries a deadline that aborts it when it expires; `gptel-yatools-timeout`
(default 120) sets the default.  Time spent waiting for you — reading a
`file_sync` diff, confirming `execute_command` — does not count against it.
Timers only run while Emacs waits for input, so the deadline bounds calls that
block on I/O, not purely CPU-bound work.

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
| `execute_command` | shell | Run a shell command from the workspace root and return its output. |
| `skill` | skills | List the installed [Agent Skills](https://agentskills.io), load one, or read a file it references. |

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

The review UI is `gptel-yatools-write-diff-mode`, a minor mode with
<kbd>C-c C-c</kbd> / <kbd>C-c C-k</kbd> bound to accept and reject, active in
the buffer where `file_sync` shows its diff.

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
call it by.  A skill's absolute directory works as a name too, which is what
the loaded skill's `Directory:` line hands the model.

The scan is cheap after the first call: the directories are walked every
time, so a skill added or removed is noticed immediately, but the YAML
frontmatter is parsed once per distinct `SKILL.md` text and then cached. On
a root of 38 skills that is 400 ms for the first `skill` call and about
20 ms afterwards.  The cache is keyed by the text, not the path, so a
pending VFS copy of a `SKILL.md` gets its own parse and never leaks into
another chat's index.

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

## Tests

169 ERT tests, no network, no prompts, every one of them in a throwaway temp
directory:

```sh
emacs -Q --batch -L . -l gptel-yatools.el \
  -l tests/gptel-yatools-tests.el -l tests/gptel-yatools-vfs-tests.el \
  -l tests/gptel-yatools-skills-tests.el \
  -f ert-run-tests-batch-and-exit
```

`gptel` and `yaml` must be on `load-path` (any straight.el/MELPA install is
enough).

Interactively: `M-x load-file RET tests/gptel-yatools-tests.el RET`, then
`M-x ert RET gptel-yatools-test- RET`.

## License

MIT.  See [LICENSE](LICENSE).
