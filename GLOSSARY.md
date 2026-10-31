# gptel-yatools

Tools that give gptel's model a buffer-local virtual filesystem, a shell,
Agent Skills it can discover and load, and diagrams it can draw in the chat
buffer.

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
name occurs more than once, in which case it is the skill's path relative
to its root -- and if that path occurs under more than one root too, or
is the bare name itself (the skill sits directly in its root), the path
followed by the root in parentheses.  Discovery decides it once and
stores it on the skill, so nothing else has to work out which names are
ambiguous, and every handle names exactly one skill.
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

**Remote workspace**:
A workspace root that is a TRAMP file name (`/ssh:host:/repo`).  Every
path the tools use is still an ordinary Emacs file name, so the VFS, the
encoding policy, the conflict baselines and the sync are performed on the
host by file-name handlers, and no tool has a remote special case.  The
one thing that does not follow a name by itself is a subprocess, so
`execute_command` runs on the host only because `gptel-yatools--run-process`
asks for a handler-built process, names the host's own shell and kills the
host's pid.  Its deadline covers the connection, and a structural walk
has to stop at `/ssh:host:/` -- a root that `file-name-directory` calls
its own parent.
_Avoid_: Remote project, TRAMP mode, remote buffer

**Connection**:
The machine a path lives on, as an identity rather than a name:
`gptel-yatools--connection` returns TRAMP's method, user, host, port and
hop chain, or the handler prefix for a backend that is not TRAMP's, or
nil for a local path.  It exists because `file-remote-p` answers with the
last hop alone, so `/ssh:a|sudo:root@b:/x` and `/ssh:c|sudo:root@b:/x`
look identical although they leave from different machines.  A tool that
accepts a path deciding *where* to act compares connections; one that
merely reads a path does not.
_Avoid_: Host, remote id, target machine

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

**Job**:
Work a tool body has started and not yet finished: the process, the
buffer that owns the call, the deadline, and a function of the outcome
plist returning the Result to report.  A body that has real work to wait
for returns a job instead of a Result; the boundary decides whether to
wait for it or hand it to gptel's callback.  A job concludes exactly
once, because gptel counts a tool result every time the callback runs.
A job does nothing until it is made live by the job registrar.
_Avoid_: Task, future, promise, handle

**Job registrar**:
The one place that makes a job live: `gptel-yatools--make-job-live` puts
it in its buffer's job registry, installs that buffer's kill hook, arms
its deadline timer and starts the status line counting it.  Everything a
running job has in common comes from here, so a tool whose work is not a
process -- a subagent, whose work is a request -- inherits the same
cancellation, deadline and status by handing its job to the registrar,
instead of setting up the four steps of its own.  The job's own function
slots say only what stopping *its* work means and how its outcome is read.
A job is registered at the moment it can be stopped, and not before.
_Avoid_: Job setup, job factory (it does not make the job; it makes it
live), registration point

**Asynchronous tool**:
A tool whose `:async` key is set, so gptel calls its boundary with a
callback first and the envelope is delivered later instead of returned.
It is the same body, the same Result and the same envelope as a
synchronous tool; only the delivery differs.  A direct call passes the
tool's own first argument instead of a callback and is answered
synchronously, so `eval`, hooks and tests still read an envelope.
_Avoid_: Background tool, non-blocking tool, deferred tool

**Cancellation**:
Killing the jobs a buffer has running and moving its request to gptel's
abort state.  It exists because nothing else can do it: `gptel-abort`
finds a request by its network process, which has finished by the time a
tool is running, and `C-g` has no stack to interrupt once the call has
returned.  It kills first and aborts second — delivering a "cancelled"
result instead would invite the model to retry.  A subagent is one of
those jobs, in its parent's registry, so `C-c C-k` there stops the
children the buffer started as well as the commands.
_Avoid_: Abort (that is gptel's, and it cannot see a tool call), stop,
interrupt

**Provenance**:
Where a Result's body came from: `:disk` when every byte of it is what
is on disk, `:vfs` when it is pending state that is not on disk yet,
`:mixed` when it blends the two -- a directory listing that merges disk
with VFS-only entries -- and `:derived` when it is another model's
conclusion about what it read, which is neither.  Carried as data on the
Result and rendered once, at the tool boundary, so a tool never describes
its own provenance in prose and cannot forget to.
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

It is also where a job is either waited for or handed to gptel's
callback, which is the whole difference between a synchronous and an
asynchronous tool: the rendering, sizing, escaping and error handling are
the same on both paths.
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
The confirmation gptel shows for a pending tool call, built from the
tool's own `:preview' declaration and its `:args', so the arguments are
read by name in the positions the definition states.  It exists because
gptel's default formatter truncates every string argument at 256
characters: a command could otherwise be approved on a harmless prefix.
Every value is quoted through the printable-text rule, with two
exceptions: a line break and a tab survive, because a here-document's
shape, a script's indentation and a subagent's brief are what the user is
judging.  Everything else invisible is still spelled out.
_Avoid_: Confirmation prompt, tool-call renderer

### Diagrams

**Render token**:
The handle a diagram is addressed by -- `[diagram:fae844]` -- which the
model re-emits on a line of its own and this package draws over.  It is
not a link: it has no link type, no mouse binding of its own, and neither
Org nor Markdown knows it exists.  It is *computed*, never stored: the
digits are a prefix of the digest of the exact source, so the token for
any tool call can be recomputed from the transcript and nothing has to map
one to the other.
_Avoid_: Diagram link, render id, handle (that is a skill's)

**Diagram cache**:
The one directory `render_diagram` writes: `<hash>.svg` and `<hash>.puml`
named by the digest of the source alone -- the *request*, not the picture
that comes back, since the executable, its version and the security
profile are outside the digest.  So a source always finds its render
without any bookkeeping, and a changed source is a different name; but a
changed PlantUML is not, which is why the directory is disposable and
`gptel-yatools-diagram-clear-cache` is its only maintenance.  Nothing in
it is reachable by a path the model chooses, which is what lets it be
written without a review -- see
docs/adr/0003-a-tool-may-own-an-opaque-directory.md.

The cache is also where the renderer runs, because it is what the render
produces: the process's directory is the cache's, not the chat's
workspace's, so a remote workspace still gets its picture drawn locally.
See docs/adr/0006-a-subprocess-runs-where-its-artifacts-live.md.
_Avoid_: Image store, diagram folder

**Rebuild**:
What happens when a token's file is missing: the tool blocks in the buffer
are read back for their `:args`, each source is hashed to recompute its
cache name, and only the missing ones are rendered -- in a single PlantUML
process, since a JVM start dominates a render.  It is why deleting the
cache, or copying a chat to another machine, costs time and not data.
A rebuild that fails says so in one sentence; it is a hook and a command,
not a tool call, so there is no envelope to carry a condition.

**Token resolution**:
What a render token means in the cache, answered once per token: `found`
with the one file, `missing` with nothing, or `ambiguous` with the files
that match.  Drawing and opening both ask it, so they cannot disagree
about whether a token names a file; what they do with the answer differs
on purpose.  Drawing leaves an unresolved token as text and says nothing,
because it runs once per response and a repeated complaint is noise;
`gptel-yatools-diagram-open-at-point` says all three answers out loud,
because that is where the user asked.
_Avoid_: Token lookup, diagram handle

**Cheat sheet**:
The PlantUML reference `render_diagram` answers from: a defcustom divided
into `## <topic>' sections, one per diagram type plus `style' and
`gotchas'.  A call with no arguments lists the sections and a call with
`help' returns one, the two-step the `skill' tool uses.  The list is read
from the sheet's own headings rather than kept beside them, so a section a
user adds is offered without any other edit.
_Avoid_: Syntax reference, prompt fragment

**Subagent**:
A second gptel request, in its own hidden buffer, that the model started
with the `subagent` tool and whose answer arrives as that tool's result.
It is a reader: `gptel-yatools-subagent-tools` offers read-only tools and
no `subagent`, so nothing it does can be lost and it cannot recurse.  It
sees the task and nothing else — no conversation, no attached context.
Its buffer runs gptel's own `gptel-send` state machine, so the status
line, the request inspector and the drawn transcript work there exactly
as in a chat you started yourself.
_Avoid_: Child agent, worker, assistant, helper, delegate

**Child record**:
The one struct that describes a subagent — its buffer, parent, task,
state, turns, tool calls and the paths it read.  Every lookup goes through
it; the buffer name is decoration built from it, and nothing parses
meaning back out of a name.
_Avoid_: Subagent object, agent state

**Detached child**:
A subagent the user has taken over by editing its buffer after it
finished.  It leaves the parent's record list, stops dying with the parent
chat, and is offered a rename so it can become an ordinary session.  It is
detached whether or not the rename is accepted: a child that is yours is
not also the parent's.
_Avoid_: Adopted buffer, promoted subagent, released child
