I ranked these by **how often their absence costs a task**, not by gap size — which is why `dsh`'s flashiest features (teams, workflows, external runtimes) are nowhere on the list.

| # | Feature from `dsh` | Effort | Why it earns that rank |
|---|---|---|---|
| 1 | `glob` + `grep` with context, VFS-aware | ~120 lines | The model cannot find files. Every non-trivial task starts with "where is X" |
| 2 | Context budget, then compaction | S then L | Sessions die at the window with no warning |
| 3 | `job_list` / `job_output` / `job_kill` | ~80 lines | A timed-out build currently returns *nothing* |
| 4 | `todo_write` | ~60 lines | Keeps long runs honest; the medium makes it free |
| 5 | `ask_user_question` | M | The model has no way to ask anything |
| 6 | LSP navigation | L | Biggest raw gap, worst effort ratio |
| 7 | Sandboxed shell mode (`bwrap`) | M | Turns "do not enable this on untrusted repos" into a real option |
| 8 | VFS persistence across a killed buffer | M | Rare, but catastrophic when it bites |

## 1. File discovery — the highest impact by a wide margin

`dsh` gives the model `glob` (mtime-ordered, capped) and `grep` (ripgrep, 250 matches + a spill locator). `yatools` gives it `read_path`, `read_workspace_root`, and `fetch_lines_from_file_using_regex` — **a search that requires you to already know the file**. So the model guesses paths, fails, guesses again. That failure mode dominates every other inefficiency in the package.

This is cheap because the machinery already exists: `gptel-yatools--run-process` takes an **argv list** (not a shell string), runs it on the workspace's host with TRAMP handled, enforces the call deadline, and returns a plist (`gptel-yatools-common.el:802`). A `grep` tool is a wrapper around `rg --json`. So is `glob`, over `fd`.

**The trap, and it is a real one:** a search that reads disk only would break the package's central promise. The model writes a file, greps for it, and is told it does not exist — while `read_path` happily returns it. So the tool must merge VFS entries into the results and mark them pending, exactly as `gptel-yatools-vfs--directory-listing` already does for directory listings (`gptel-yatools-vfs.el:331`). Search VFS entries in Elisp, run `rg` for the rest, dedupe by truename, mark provenance `:mixed`.

## 2. Context budget — and a correction to what I told you earlier

My comparison doc scored compaction as `dsh`'s decisive win, and it is — as *implementation*. But I underrated how friendly the substrate is, so let me correct that: **gptel's history is the buffer.** `gptel--parse-buffer` parses it backwards from point (`gptel-request.el:2394`, `:2488`), and `gptel--parse-list-and-insert` exists to write conversation text back in a form gptel can re-parse. Compaction in Emacs is therefore *rewriting buffer text* — visible to the user, undoable with `C-/`, and reviewable. That is arguably better than `dsh`'s, which is a logged `surfaceOp: replace` the user never sees.

Two halves, and do the cheap one first:

- **Now (hours):** gptel already tracks authoritative per-request and cumulative token usage in `gptel--token-usage` (`gptel.el:980`) and formats it for the header line. `yatools` renders *every* tool result through one function (`gptel-yatools-common.el:1231`), so it can read that variable and append "context: 68% used" to the envelope — the model is told before it dies, not after. Note `gptel--num-messages-to-send` already exists as a crude turn-count cutoff; there is precedent for dropping history, just none for summarising it.
- **Then (a real project):** a `/compact` command that replaces a span with a summary, plus stale-tool-result pruning first — an envelope carrying 64 000 chars of grep output nobody will look at again is the cheapest possible thing to drop, and `dsh` does exactly this before compacting.

## 3. Job control — because a timed-out build returns nothing

This one is nearly free. `yatools` already has the registry: a buffer-local `gptel-yatools--jobs`, a job struct carrying `:output` (the buffer the process writes into), `:process`, `:started`, `:deadline`, `:kind`, and a header line that counts them (`gptel-yatools-common.el:294`, `:571`). The model sees none of it.

And the failure is worse than "cannot poll": on timeout, `gptel-yatools--job-expire` settles the job, and the result is `gptel-yatools--timeout-envelope` — the literal string *"Tool call timed out"* with **no output at all**, though the partial output is sitting in the job's `:output` buffer and the process was just killed. A 20-minute build at the 600 s async deadline yields a bare timeout.

Three tools over existing structures: `job_list` (the live jobs, kind, elapsed, deadline), `job_output` (read `:output`, with an offset so it can be called twice), `job_kill`. This is the single best effort-to-impact ratio on the list.

## 4–5. `todo_write`, then `ask_user_question`

`todo_write` is nearly free in this medium and I would not build it the way `dsh` did. `dsh` stores a session-owned checklist rendered by its UI; `yatools` should write a real `TODO` list into the org buffer the chat lives in. Then the human sees it in the same file, it costs no new state, it survives as text, and it gets a `C-c C-t` for free. It also gives you a progress signal during a long run, which the header line's "Running 1 command… 340s" does not.

`ask_user_question` matters because the model's only way to ask something today is prose in its reply — which ends the turn and burns the tool state it was holding. `dsh`'s version blocks with structured options and *logs* the decision. `yatools` gets the blocking for free (Emacs is the one environment where freezing the UI is socially acceptable), and should log the answer the same way it logs everything else.

## 6. LSP — biggest gap, worst ratio

`go_to_definition`, `find_references`, `diagnostics` against eglot. It is the largest raw capability difference in the matrix, but not the largest *impact*: regex search plus a fan-out of read-only subagents covers a surprising amount of navigation, whereas nothing covers discovery. If your work is mostly navigating unfamiliar code rather than writing it, swap this with #4.

## 7–8. The two that are safety and durability rather than capability

A `bwrap`-wrapped `execute_command` (mode `workspace-write`) — `dsh`'s Linux backend is bwrap/Landlock, you are already Linux-only, and it converts the README's "do not enable the shell tool on a repository you do not trust" into a setting instead of a warning. And VFS persistence: `dsh`'s session log survives a crash; `yatools`' pending writes die with the buffer. It prompts on kill, which is decent, but a dead Emacs loses unreviewed work.

## What I would not add, and why

- **Subagent writes.** No. The read-only child is the invariant that makes "nothing to review afterwards" true. The alternative — merging a child's VFS into the parent's — is a genuine design problem with no cheap answer, and the parent can already apply the child's findings with the diff reviewed.
- **MCP.** It would mean importing a second tool registry with its own lifecycle into a package whose entire virtue is being eight files. If you want MCP, wire an existing Emacs client and expose its tools as `define-tool` forms.
- **Teams, task boards, workflows, `run_code`, external runtimes, plugin-in-plugin self-modification.** All assume multi-process orchestration or a plugin tree. There is one Emacs, and `run_code`'s analogue is `M-x eval-expression`, which is a much bigger decision than a tool.
- **Web fetch/search as a first-class tool.** `execute_command` already reaches `curl`, with approval. A dedicated tool adds blast radius without adding capability.

If you want, I can take #1 to a ticket and implement it — it is self-contained, it has one hard design question (the VFS-merge), and it would make the other seven much easier to build on top of.
