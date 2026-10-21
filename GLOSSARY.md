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
