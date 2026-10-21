# gptel-yatools

Tools that give gptel's model a buffer-local virtual filesystem, a shell, and
Agent Skills it can discover and load.

## Language

### Skills

**Skill**:
A directory holding a `SKILL.md` — YAML frontmatter naming it and saying when
it applies, then Markdown instructions — plus any scripts and references it
ships with.
_Avoid_: Prompt, template

**Skill root**:
A directory searched for skills, listed in `gptel-yatools-skill-directories`.
Skills may sit in groups below a root.
_Avoid_: Skill path, skill location

**Skill handle**:
The name a skill is shown and called by.  It is the bare name unless that
name occurs under more than one root, in which case it is the skill's path
relative to its root -- and if that path occurs under more than one root
too, the path followed by the root in parentheses.  Discovery decides it
once and stores it on the skill, so nothing else has to work out which
names are ambiguous, and every handle names exactly one skill.
_Avoid_: Skill id, qualified name

**Skill catalog**:
The module that answers what the skill roots hold: which skills exist,
which one a name means, what each is called, and what loading one says.
It is also where the parse of a `SKILL.md` is cached -- by the text
itself, so two chats holding different pending copies of one file each
parse their own, and nothing has to invalidate the cache when a file
changes.
_Avoid_: Skill registry, skill index (that is the reply, not the module)

**Attached skill**:
A skill the user attached to the gptel context with
`gptel-yatools-skills-add`, so its text is sent with every request until
removed.
_Avoid_: Active skill, enabled skill, loaded skill

**Loaded skill**:
A skill whose text the model fetched with the `skill` tool.  Loading is a
single response and leaves no attachment behind, so it is not what the
header-line count reports.
_Avoid_: Attached skill, activated skill

### Paths

**Workspace root**:
The directory a relative path the model writes is resolved against, and
the base every path is shown relative to.  `project-current`'s root, or
the chat buffer's `default-directory` when there is no project.  Settled
once per tool call, so a tool that changes `default-directory` -- the
shell runner does, to run in a subdirectory -- cannot change what a path
means half way through.
_Avoid_: Project root, working directory, cwd

**Resolved path**:
An absolute path, made by `gptel-yatools--resolve-path` at the tool's
edge from the text the model wrote and the workspace root.  Past that
seam every function takes a resolved path and none of them interprets
it again, so one name means one file whichever tool receives it.
_Avoid_: Full path, absolute name, expanded path

### Tools

**Result**:
What a tool function returns: the body the model reads, the provenance
of that body, and an optional context comment.  Never formatted text,
and never a half-rendered envelope.
_Avoid_: Response, output, return value

**Provenance**:
Where a Result's body came from: `:disk` when every byte of it is what
is on disk, `:vfs` when it is pending state that is not on disk yet, and
`:mixed` when it blends the two -- a directory listing that merges disk
with VFS-only entries.  Carried as data on the Result and rendered once,
at the tool boundary, so a tool never describes its own provenance in
prose and cannot forget to.
_Avoid_: VFS flag, dirty flag, source

**Header-line label**:
The text a module contributes to gptel's right-hand indicator group: the
pending VFS count, the attached-skill count.  A module returns a string
from a function in `gptel-yatools-header-line-extra-functions` and never
touches `header-line-format`; the drawer in `gptel-yatools.el` renders
whatever the registry holds, because the alignment arithmetic is gptel's
own and belongs with the rest of the gptel adaptation.
_Avoid_: Header-line segment, indicator

**Tool function**:
The implementation half of a tool, named `gptel-yatools-<name>-tool`.  It
takes the tool's own arguments, including their optional ones, and returns
a Result.  It is the half to advise when what should change is what the
tool computes or reports.
_Avoid_: Tool handler, tool callback

**Announcement**:
What a slow tool says in the chat's status indicator while it runs --
"Executing command...".  Setting the text is not enough: `gptel`'s
status helper only flags the mode line, and Emacs repaints when it next
goes idle, which a tool call never does.  So announcing means setting
the text *and* redrawing, once, at the start of the call; the frame then
holds that status until the call returns.
_Avoid_: Status message, progress indicator

**Tool boundary**:
The one adapter that renders a Result into the envelope the model sees.
It sizes, truncates and escapes the text, and turns a signalled error or
an expired deadline into that same envelope, so a tool that fails and a
tool that succeeds reach the model the same way.

Concretely it is the other half of a tool, the function named
`gptel-yatools-<name>`: the one gptel calls, the one that takes the
trailing `timeout` argument.  Advise it to observe or replace a whole call,
including its timing and its wire format.
_Avoid_: Response builder, wrapper, formatter

**Tool definition**:
The single form that writes both halves and registers the tool, so that
the tool's model-facing description, its argument list and its Lisp
functions cannot drift apart.  `C-h f` on a tool shows the description the
model reads, generated from it.

### Pending changes

**VFS write interface**:
The two entry points that own everything about a pending write: whether
the target can be written, which encoding the sync will use, whether the
content fits that encoding, and the baseline a conflict is detected
against.  `write_file` and `write_file_diff` are argument adapters over
it, so a rule about writes has one home.
_Avoid_: Write helper, put function

**Pending change**:
A file's VFS content when it differs from disk, in text or in encoding.
Not every VFS entry is one: writing back what the disk already holds
leaves nothing pending, and an entry that stops differing -- disk
caught up with it -- is reaped the next time that file is read or
pending changes are enumerated, rather than lingering as a shadow of
disk.
_Avoid_: Dirty file, buffered file

**Review**:
The step between deciding to sync and writing: the pending changes are
shown as a diff, and the user accepts or rejects them.  Waived by
`gptel-yatools-sync-without-review`; the checks that refuse a conflicting
or unrepresentable file are not part of it and cannot be waived.
_Avoid_: Confirmation, approval (both also name gptel's own tool prompt)

**Sync outcome**:
What `gptel-yatools-vfs-sync` returns: a status, plus the files written and
the files refused with the reason for each.  The tool reply and the review
buffer are both renderings of it, so neither can describe a sync the other
did not perform.
_Avoid_: Sync result, report

**Refusal**:
The one answer to "can this file be written right now?": nil, or a kind
\(`:conflict` when disk moved on since the baseline, `:blocked` for every
other reason) and a reason in words.  Every consumer asks it -- the
partition that decides what the review shows, the diff header that says
so per file, and the write itself, which asks again because a review can
sit open for minutes.  One answer is what makes the set the user
approves the set that is applied.
_Avoid_: Sync blocker, check, validation
