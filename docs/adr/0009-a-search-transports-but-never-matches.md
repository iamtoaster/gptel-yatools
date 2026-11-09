# 0009 — A search transports, and never matches, on a remote host

## Status

Accepted.

## Context

`read_path` and `fetch_lines_from_file_using_regex` both need the path
first, so a model that does not know the tree can only guess one: a failed
call, a second guess, a third.  That loop cost more than every other
inefficiency in the package put together, which is why `glob` and `grep`
exist.

Locally the answer is easy.  One `directory-files-and-attributes` call lists
a directory — name, type, size and modification time for every entry — and
the matching happens in Elisp.  No `rg`, no `fd`, nothing to install, and one
regexp dialect.  A few thousand files are milliseconds.

A workspace on another machine changes the arithmetic, not the requirement.
Every question asked of a remote filesystem is a command and a wait, so a
walk that asks per entry costs a round trip per entry: a few thousand files
is a few thousand round trips, minutes of them, ending in a bare timeout
envelope.  ADR 0004 already settled what a subprocess is for such a
workspace — it runs on the host — and ADR 0006 says it runs where its
artifacts live, which for a search is the tree being searched.

Two ways to spend one round trip per chunk instead of per file were
considered.

**Match on the host** — `grep -E`, or a `find … -exec grep` pipeline.  It
transfers only hits, so one trip usually finishes the tree.  It also imports
a second pattern dialect (POSIX ERE, not the Emacs regexp `grep` documents),
a second case rule (no smart-case without extra flags), and a second matcher
for the pending entries this side holds — which cannot be on the host at all,
because they are not on disk yet.  A user would then have two regexps to keep
straight depending on where their repository happens to live.

**Transport and match here** — a script walks the host and streams file
metadata, and file contents for `grep`; Emacs matches.  Costs bytes rather
than CPU: one trip for a small tree, several for a large one, and a byte
budget to bound each.

## Decision

1. **The script is a courier, never a matcher.** It reports a path, a size, a
   modification time, and — for `grep` — the bytes. It never decides whether
   anything matched. Emacs does, in one place, so a local and a remote
   workspace share the regexp dialect, the smart-case rule, the binary and
   size skips, and the VFS merge.
2. **Records are NUL-separated and contents are read by size.** Path, size,
   mtime, then either `-` or exactly `size` bytes. No file name can forge a
   record, and a NUL inside a file is data rather than a delimiter. A
   mis-shaped record ends the parse and is reported rather than half read.
3. **The script walks `.`, and Emacs rebases what comes back.** A process on
   the host runs in its own directory, so `.` means the same tree to the
   script as the file name means to Emacs — over TRAMP, and over the stand-in
   handler the tests use. Passing the path instead would work for one and not
   the other.
4. **One process cannot carry a whole tree, so it is chunked.** A chunk stops
   at a byte budget (`-remote-chunk-bytes`) or a record count
   (`-remote-chunk-records`, for metadata-only transfers, where no content
   sets the size), always between records, and reports how many files it
   consumed and whether it reached the end. The next chunk starts at that
   count. Chunks are asked for until the tree is exhausted or
   `-seconds-limit` is spent, which is what turns truncation into
   completeness: only a tree too large for the *time* budget ends partial.
5. **The transport stays under the job output limit.** Transfers are bounded
   well below `gptel-yatools--job-output-limit`, because past it the process
   filter cuts the stream and injects a truncation marker, which would break
   records apart mid-field.
6. **A local walk and the courier answer in the same shape.** Both produce a
   list of candidates plus `:files`, `:stopped` and `:failed`, and everything
   above that — matching, ranking, marking, reporting — is shared. A tool
   cannot tell where the files live except by what it is told when a limit
   bites.
7. **A cap keeps the densest files, and the reply counts only what it
   shows.** Matches are ranked by how many a file holds before the line limit
   is applied, because `readdir` order is not an order: a cap applied to it
   drops an arbitrary subset, and the file with the most matches is exactly
   what a capped answer must not lose. The page is cut to exactly the limit,
   in the middle of a file if need be, so the number of lines shown and the
   number reported are the same number. What was left out is named.
8. **A skipped file is reported, never dropped.** A file over
   `-max-file-size`, or one that is not a regular file, contributes a skip
   reason, which the reply turns into a sentence naming the largest few and
   what to do about them. `glob` has no skip reasons at all: it reads names,
   so no file is too large to be found, and a file too big to search can be
   opened deliberately.
9. **Nothing writes.** A search has no spill file, no cache, no index. ADR
   0003 allows a tool an opaque directory only for output that is derived,
   disposable and unreviewable as text; search results are exactly the text a
   user would want to review, and a locator for them would be a second way to
   read a file. So a search that cannot finish says so instead.

## Consequences

- A remote `grep` transfers contents, so it is bounded by bytes as well as
  by matches. For a large tree that is several trips; for a tree larger than
  the time budget it is an honest partial answer naming where it stopped.
  `glob` transfers nothing but metadata and is bounded by record count.
- The dialect is one. A pattern that works locally works remotely, including
  smart-case, `[[:upper:]]` as a case test, and the fact that a pending entry
  shadows disk in both.
- The script depends on `wc`, `head` and `stat` on the host, and on `-c`
  (GNU) or `-f` (BSD) `stat`. It is POSIX `sh` otherwise, and it does not use
  `set -e` or `pipefail`. A host missing those degrades to `:failed` with the
  shell's own message, which the model is shown, rather than to an empty
  result.
- The skip list is explicit rather than `.gitignore`-aware. Honouring ignore
  files means parsing them at every level and getting nested precedence and
  negation right in Elisp, for a benefit a defcustom already covers.
- Ranking by density costs a full walk before anything is shown, bounded by
  the same seconds and file budgets. That is the price of a cap that is a
  selection rather than an accident.
- Every budget is a defcustom and every budget ends in a sentence the model
  is told. A search that stops silently is worse than one that fails: it
  teaches the model that a file does not exist.
- The walk and the courier are testable without a network: the stand-in
  handler from ADR 0004 makes a name remote, and the courier's `sh` runs for
  real against a temp tree, so the record protocol is exercised end to end
  rather than inspected.
