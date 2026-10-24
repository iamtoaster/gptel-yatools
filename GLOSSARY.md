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
Resolving a name is one answer, not two: an outcome of `loaded`,
`ambiguous`, `unknown` or `invalid`, with a one-line summary and a full
detail text.  The `skill' tool and the commands that send a skill by
hand both adapt that same outcome, so they cannot disagree about a name
-- and deciding loadability is part of resolving, not a second question
each caller asks for itself.
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

**Printable text**:
A string safe to put on a line the user or the model will read: every
control and invisible character written as `<U+XXXX>`.  Paths are always
printed this way, because a path is what the review heading is made of
and a newline in a file name would otherwise add headings of its own.
Tool bodies get the same treatment for the invisible characters only, via
`gptel-yatools--escape-raw-bytes`.
_Avoid_: Sanitised string, cleaned path

**Write policy**:
The targets no write is allowed to touch, whatever the model asks for and
whatever the review would show: the Emacs startup files,
`.dir-locals.el`, and the package's own source.  Enforced in the VFS write
interface so every writing tool inherits it.
_Avoid_: Deny list, blocklist

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
model reads, generated from it.  The same argument list is what the
boundary checks values against, and what the preview reads positions
from, so a tool's arguments are stated once and every half follows.

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
caught up with it -- is dropped rather than left shadowing disk with a
copy that says nothing new.  Whether an entry is a pending change is
`gptel-yatools-vfs-pending`'s answer, and no other function decides it.
_Avoid_: Dirty file, buffered file

**Pending-change module**:
The module that answers whether a VFS entry is a pending change, lists
the ones that are, and drops the ones disk has caught up with.  It
answers two questions, deliberately: `entry` ("is there an entry here?",
no disk read) and `pending` ("…and does it still differ?").  Keeping the
cheap question public is a decision with a reason behind it -- see
docs/adr/0001-pending-ness-keeps-a-cheap-predicate.md.
_Avoid_: VFS layer, storage

**Shadowed path**:
A path that has a VFS entry.  It is *not* necessarily a pending change:
an entry whose content disk now holds shadows nothing, and only the next
lookup will notice.  The distinction exists because structural checks --
can this be written?, is an ancestor a file?, does this path hold
pending children? -- need the cheap answer and must not pay a disk read
for it.
_Avoid_: Dirty path, virtual path

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

**Text-file reader**:
The module that answers what text is at a path, and where it came from.
It answers with a kind -- text, binary, missing, a directory, a special
file, unreadable -- rather than signalling or returning a rendered
string, so a tool can turn each case into its own message while the
wording of a refusal is written once.  It owns the binary policy: a tool
never decides for itself whether content is text, and never builds its
own notice.

A tool does not ask it the three-way question itself: it crosses
`gptel-yatools-vfs-with-text', which calls the tool's own framing when
there is text and returns the ready refusal when there is not.  So the
dispatch is written once, and a refusal travels as a Result -- with the
provenance it was read with -- rather than as a signal that would be
rendered as a statement about disk.
_Avoid_: Read helper, file loader

**Refusal**:
The one answer to "can this file be written right now?": nil, or a kind
\(`:conflict` when disk moved on since the baseline, `:blocked` for every
other reason) and a reason in words.  Every consumer asks it -- the
partition that decides what the review shows, the diff header that says
so per file, and the write itself, which asks again because a review can
sit open for minutes.  One answer is what makes the set the user
approves the set that is applied.  The partition carries the reason out
with the path, so nobody asks a second time for what it was just told.
_Avoid_: Sync blocker, check, validation

**Sync report**:
What a sync did, composed once: sections in the order they are read --
synced, conflicts, blocked, failed -- each holding paths or (path .
reason) entries.  The tool reply renders every section and the echo-area
line renders the counts, so the two adapters cannot disagree about the
same sync; an empty section is left out rather than printed as a blank.
_Avoid_: Sync summary, sync result (that is the outcome, not its
composition)

**Preview**:
The one-line confirmation gptel shows for a pending tool call, built
from the tool's own `:preview' declaration and its `:args', so the
arguments are read by name in the positions the definition states.  It
exists because gptel's default formatter truncates every string argument
at 256 characters: a command could otherwise be approved on a harmless
prefix.  Every value is printed through the printable-text rule, so a
command spanning lines cannot add lines that read like the rest of the
prompt.
_Avoid_: Confirmation prompt, tool-call renderer
