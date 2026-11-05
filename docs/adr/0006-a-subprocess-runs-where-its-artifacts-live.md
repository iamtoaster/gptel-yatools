# 0006 — A subprocess runs where its artifacts live

## Status

Accepted.

## Context

`render_diagram` renders a diagram by running PlantUML.  `execute_command`
runs a command.  Both go through `gptel-yatools--run-process`, and both
used to inherit `default-directory` for the process's working directory.

For the shell tool that is exactly right: the workspace is where the
command belongs, and ADR 0004 makes it run on the host that owns it.

For the diagram tool it is wrong, and in a remote workspace it fails
outright:

```
Error: PlantUML could not render the diagram (exit code 127).
/bin/sh: exec: line 2: /usr/local/bin/plantuml: not found
```

The workspace was `/docker:host:/tmp/work`, so `default-directory` was
remote; `--run-process` therefore asked for a handler-built process on the
host; and the executable it had found with `executable-find` — a path on
*this* machine — was handed to the host's shell, which has no such file.

The asymmetry underneath is not a bug in the caching: the cache lives on
this machine (`user-emacs-directory`, ADR 0003), the renderer is found on
this machine, and the SVG is drawn into a buffer on this machine.  Only
the working directory was remote, and it was remote by accident —
inheritance, not decision.

## Decision

**A subprocess runs in the directory its artifacts live in, and that is
stated at the call, not inherited.**

`gptel-yatools-diagram--run` passes `:directory` explicitly — the cache
directory — instead of letting `--run-process` fall back on
`default-directory`.  `gptel-yatools-diagram--run-directory` names the
rule and gives it one home.

The rule generalises rather than special-cases "remote": the directory
decides where the process runs, so a user who points
`gptel-yatools-diagram-cache-directory` at a remote path gets a render on
that host, provided PlantUML is installed there.  Nothing checks for
`file-remote-p` and nothing hardcodes "always local".

## Consequences

- A remote workspace renders diagrams again, and does so in under a
  second, because the render never leaves this machine.
- The renderer needs no remote shell, no connection and no round trip: it
  is now the ordinary local case, with the pipe connection and the local
  shell.
- Any future tool that spawns a process must answer "where do its
  artifacts live?" and pass that as `:directory`.  Inheriting
  `default-directory` is only correct for a tool whose subject *is* the
  workspace, which is the shell runner and nothing else.
- Two tests pin it: one records the `:directory` the runner is given in a
  remote workspace, the other renders end to end there and asserts that no
  process reached the host at all.  Both fail without the fix.
- ADR 0004's decision 2 ("the shell tool runs commands on the host that
  owns the workspace") now has its counterexample documented here rather
  than being weakened there: the shell tool is about the workspace, the
  diagram tool is about the cache.
