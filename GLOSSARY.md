# gptel-yatools

Tools that give gptel's model a buffer-local virtual filesystem, a shell and
Emacs Lisp, and Agent Skills it can discover and load.

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
The name a skill is shown and called by.  It is the bare name unless that name
occurs under more than one root, in which case it is the skill's path relative
to its root.
_Avoid_: Skill id, qualified name

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

### Tools

**Result**:
What a tool function returns: the body the model reads, a flag saying
whether it reflects pending VFS state, and an optional context comment.
Never formatted text, and never a half-rendered envelope.
_Avoid_: Response, output, return value

**Tool boundary**:
The one adapter that renders a Result into the envelope the model sees.
It sizes, truncates and escapes the text, and turns a signalled error or
an expired deadline into that same envelope, so a tool that fails and a
tool that succeeds reach the model the same way.
_Avoid_: Response builder, wrapper, formatter

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
leaves nothing pending.
_Avoid_: Dirty file, buffered file
