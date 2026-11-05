;;; gptel-yatools-diagram.el --- Diagrams in the chat buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The `render_diagram' tool: PlantUML source goes in, a picture appears in
;; the chat buffer.
;;
;; The tool is a renderer, not a file writer.  The model supplies the
;; source and nothing else -- it names no path, chooses no location, and
;; cannot ask for anything to be persisted.  What it gets back is a token,
;; `[diagram:fae844]', which it re-emits on a line of its own; this module
;; finds that token in the buffer and puts an overlay in its place.  A
;; diagram the user wants in their repository is written as *source*,
;; through `write_file', with the review that already exists.  This module
;; therefore writes outside the VFS on purpose -- see ADR 0003, which says
;; when a tool may own a directory of its own: when nothing about it is
;; addressable by the model.
;;
;; The cache is content-addressed, which is what makes the tokens
;; recomputable instead of stored.  A file is `<hash>.svg' where `<hash>'
;; is the first 16 hex digits of the SHA-256 of the exact source, and the
;; `.puml' beside it holds that source, so a cache is self-describing.  The
;; token is the first 6 digits of the same hash.  Nothing anywhere maps a
;; token to a source: the token *is* a function of the source, so a
;; transcript can be re-read from the tool blocks and every token
;; recomputed, even if the model's own reply has been edited.
;;
;; Three things are worth knowing before changing this file.
;;
;; First, gptel renders nothing and folds what it does insert: a tool
;; result starts collapsed, and the link annotators skip responses.  So the
;; display path is ours from end to end -- `gptel-post-response-functions'
;; for new text, `gptel-mode-hook' for a file that was just opened.
;;
;; Second, there is no major mode to delegate to.  The default chat buffer
;; is `text-mode', which has no image renderer at all, and the token is not
;; a Markdown or Org link, so `markdown-display-inline-images' and
;; `org-display-inline-images' cannot draw it either.  One overlay serves
;; every mode, which is why it is written here rather than borrowed.
;;
;; Third, PlantUML can read files.  Under its default security profile
;; `!include' and `%load_json' reach anything the user can read, and the
;; result is drawn into the image.  `PLANTUML_SECURITY_PROFILE=SANDBOX'
;; closes that while keeping the bundled stdlib and themes, so it is the
;; default here -- a default, not a boundary, since the user can lift it
;; and the model can render around this tool entirely with
;; `execute_command'.  Refusals therefore name the setting and the way out.
;;
;; This module owns state -- the cache directory and the overlay list -- so
;; it earns a file by the rule ADR 0002 states.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'browse-url)
(require 'gptel)
(require 'gptel-yatools-common)

(declare-function gptel-yatools--update-tool-status "gptel-yatools" (message &optional face))
(declare-function org-unescape-code-in-string "org" (string))

(defgroup gptel-yatools-diagram nil
  "Diagrams rendered into a gptel chat buffer."
  :group 'gptel-yatools)

;;;; Configuration

(defcustom gptel-yatools-plantuml-command "plantuml"
  "The PlantUML executable to run.

A name is looked up on `exec-path'; an absolute path is used as given.
When it cannot be found the tool says so, naming this variable, rather
than failing in a way the model has to guess at."
  :type 'string
  :group 'gptel-yatools-diagram)

(defcustom gptel-yatools-plantuml-security-profile "SANDBOX"
  "Value for `PLANTUML_SECURITY_PROFILE' when rendering.

`SANDBOX' keeps `!include' and `%load_json' away from the filesystem and
the network while leaving the stdlib and the bundled themes available.
Any profile PlantUML accepts may be set here, or nil to pass no value at
all and take PlantUML's default.

This is a default, not a boundary: the model can render through
`execute_command' with whatever environment it likes, so a refusal that
repeats this setting's name is more honest than one that reads as a
wall."
  :type '(choice (const "SANDBOX") (const "LEGACY") (const "INTERNET")
                 (const "UNSECURE") (const nil) (string :tag "Other"))
  :group 'gptel-yatools-diagram)

(defcustom gptel-yatools-plantuml-graphviz-timeout 30
  "Ceiling in seconds for GraphViz layout, passed to `--graphviz-timeout'.

This bounds the one part of a render whose cost grows faster than the
model's input.  It is capped by the call's own remaining deadline, so a
short `timeout' argument cannot be outlived by the layout engine."
  :type 'integer
  :group 'gptel-yatools-diagram)

(defcustom gptel-yatools-diagram-cache-directory
  (expand-file-name "var/gptel-yatools/cache/" user-emacs-directory)
  "Directory holding rendered diagrams and their sources.

The directory is this module's alone.  Nothing in it is referenced by a
path the model can see or choose, which is what makes it safe for a tool
to write here without a review (ADR 0003).  It is disposable: every entry
can be rebuilt from the chat that produced it, so deleting it loses no
data, only time."
  :type 'directory
  :group 'gptel-yatools-diagram)

(defcustom gptel-yatools-diagram-cache-max-age-days 30
  "Delete cached diagrams that have not been rendered for this many days.

The cache would otherwise only ever be emptied by hand, so every diagram
a chat had ever produced stayed on disk for the life of the installation.

Nothing here tries to work out what is still *referenced*.  That is the
question a reference-tracking sweep would have to answer, and the honest
answer -- \"whatever a live buffer mentions\" -- is expensive to compute and
wrong for saved chats that are not open.  Age needs no reference map: the
transcript holds the source of every diagram a buffer mentions, and
`gptel-yatools-diagram--rebuild-missing' re-renders them all in one
PlantUML process when the chat is next opened.  So a deleted entry costs a
batch render, never data.

The entry's modification time is its render time, so a diagram that is
looked at every day still ages out and is rebuilt at most once per
window.  Touching files on read would be a write from the redisplay path.

nil disables the sweep.  See `gptel-yatools-diagram-clear-cache' for the
same thing on demand."
  :type '(choice (const :tag "Never sweep" nil)
                 (integer :tag "Days"))
  :group 'gptel-yatools-diagram)

(defconst gptel-yatools-diagram--sweep-idle-seconds 30
  "How long Emacs must be idle before the cache is swept once.")

(defvar gptel-yatools-diagram--cache-swept nil
  "Non-nil once this session has swept the cache.

Set before the sweep runs rather than after it: a sweep that fails because
the directory is unreadable would fail identically on the next idle
moment, and retrying it forever is worse than trying it once.")

(defvar gptel-yatools-diagram--sweep-timer nil
  "The idle timer that sweeps the cache, or nil when none is armed.")

(defun gptel-yatools-diagram--cache-files (&optional directory)
  "Return the regular files in the diagram cache DIRECTORY.

Subdirectories are left alone: this module only ever writes flat files,
and a directory a user put here is not the sweep's to remove."
  (let ((dir (or directory gptel-yatools-diagram-cache-directory))
        (files nil))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\`[^.]"))
        (when (file-regular-p file)
          (push file files))))
    (nreverse files)))

(defun gptel-yatools-diagram--sweep-cache (&optional directory now)
  "Delete cache entries in DIRECTORY not rendered within the window.

DIRECTORY defaults to `gptel-yatools-diagram-cache-directory' and NOW to
the current time; both exist so a test can pin the clock.  Return how
many files were deleted.

Never signals: the first sweep of a session runs from an idle timer,
where a signal is logged and nothing else, and the directory may not
exist yet or may not be ours to read."
  (let* ((days gptel-yatools-diagram-cache-max-age-days)
         (cutoff (- (or now (float-time))
                    (* 86400 (if (integerp days) days 0))))
         (count 0))
    (when (and (integerp days) (> days 0))
      (dolist (file (gptel-yatools-diagram--cache-files directory))
        (let ((attributes (ignore-errors (file-attributes file))))
          (when (and attributes
                     (< (float-time (file-attribute-modification-time attributes))
                        cutoff)
                     (ignore-errors (delete-file file) t))
            (setq count (1+ count))))))
    count))

(defun gptel-yatools-diagram--sweep-once-per-session ()
  "Sweep the cache, unless this session has already done so.

Return how many files were deleted, or 0 when the sweep was skipped."
  (if gptel-yatools-diagram--cache-swept
      0
    (setq gptel-yatools-diagram--cache-swept t)
    (condition-case err
        (gptel-yatools-diagram--sweep-cache)
      (error
       (message "gptel-yatools-diagram: could not sweep the cache: %s"
                (error-message-string err))
       0))))

(defun gptel-yatools-diagram--arm-cache-sweep (&optional seconds)
  "Arrange for the cache to be swept once, the next time Emacs is idle.

SECONDS is how long the idle period must last, for a test that would
rather not wait.  Returns the timer, or nil when nothing was armed.

An idle timer rather than a sweep at load time, for two reasons: loading
this module in a batch run must not delete a user's cache as a side effect
of `-l', and a sweep inside a render would charge a directory walk to a
tool call.  Nothing is armed in batch, where an idle timer would not fire
anyway."
  (unless noninteractive
    (when (timerp gptel-yatools-diagram--sweep-timer)
      (cancel-timer gptel-yatools-diagram--sweep-timer))
    (setq gptel-yatools-diagram--sweep-timer
          (run-with-idle-timer
           (or seconds gptel-yatools-diagram--sweep-idle-seconds)
           nil #'gptel-yatools-diagram--sweep-once-per-session))))

(defcustom gptel-yatools-diagram-inline t
  "Whether to draw rendered diagrams inline in a chat buffer.

Turned off, the token stays as the text the model wrote -- still the
thing `gptel-yatools-diagram-open-at-point' resolves, and still what a
later session renders.  The command `gptel-yatools-diagram-toggle-inline'
flips this in the current buffer."
  :type 'boolean
  :group 'gptel-yatools-diagram)

(defcustom gptel-yatools-diagram-cheatsheet
  "PlantUML syntax, in the smallest form that prevents a round trip.

Sections are `## <topic>' headings; `render_diagram' returns one by name.
This is a variable rather than a shipped file so that a user can correct
or extend it without touching the package, which is how gptel keeps its
system prompt.

## sequence

    @startuml
    Alice -> Bob: authentication request
    Bob --> Alice: authentication response
    alt success
      Alice -> Bob: another request
    end
    @enduml

    Participants: `participant Name`, `actor`, `database`, `boundary`,
    `control`, `entity`, `collections`.  Arrows: `->` sync, `-->` return,
    `->>` async, `-\\` short, `->x` lost.  Group blocks: `alt`/`else`/`end`,
    `opt`, `loop`, `par`, `group`, `break`.  Activate with `activate Bob`
    or `Bob -> Bob: self`.

## class

    @startuml
    class Order {
      +id: UUID
      +total: Money
      +submit(): void
    }
    Order \"1\" *-- \"0..*\" LineItem
    Order ..> Payment : uses
    @enduml

    Relationship syntax, which is where mistakes cluster:

      --   association        --|>  inheritance
      ..>  dependency         ..|>  realization
      *--  composition        o--   aggregation

    Each end takes a multiplicity: `\"1\"`, `\"0..*\"`, `\"1..n\"`, `\"*\"`.
    Add a label after a colon: `A \"1\" --> \"*\" B : contains`.  Class body
    members: `+public`, `-private`, `#protected`, `~package`; `{static}`
    and `{abstract}` modifiers.

## activity

    @startuml
    start
    :read the file;
    if (valid?) then (yes)
      :render;
    else (no)
      :report the error;
    endif
    stop
    @enduml

    Use the new syntax -- `start`/`stop`, `:action;`, `if`/`then`/`else`,
    `endif`, `while`/`endwhile`, `repeat`/`repeat while`, `fork`/`fork again`/`end fork`,
    `split`/`split again`/`end split`.  `-> label;` on its own line joins
    nodes.

## state

    @startuml
    [*] --> Idle
    Idle --> Running : start
    Running --> Idle : pause
    Running --> [*] : stop
    @enduml

    Compose with `state Parent { ... }`.  Concurrent regions with `--`
    inside a state.  `state x <<choice>>` for a diamond; `x --> y` from it
    with `[condition]` guards.

## component

    @startuml
    package \"Client\" {
      [Browser] as b
    }
    [Server] as s
    b --> s : HTTP
    @enduml

    Also `node`, `folder`, `frame`, `cloud`, `database`, `queue`.  A
    bracketed name `[Thing]` declares a component inline.

## er

    @startuml
    entity Order {
      * id : uuid
      --
      total : money
    }
    Order ||--o{ LineItem
    @enduml

    Cardinality glyphs: `||` exactly one, `|o` zero or one, `}|` one or
    more, `}o` zero or more.  Crow's foot points at the many end, so
    `Order ||--o{ LineItem` reads one order to many line items.

## mindmap

    @startmindmap
    * Root
    ** Branch
    *** Leaf
    @endmindmap

    `*` levels nest; `-` on the left-hand side, `+` on the right when
    using `left side`/`right side`.  Use `@startmindmap`/`@endmindmap`,
    not `@startuml`.

## c4

    @startuml
    !include <C4/C4_Container>
    Person(user, \"User\")
    System(sys, \"System\")
    Rel(user, sys, \"Uses\")
    @enduml

    The stdlib is inside the jar, so it works under the default security
    profile.  `!include <C4/C4_Container>` also pulls in the rest of C4.
    Available packages include `C4`, `archimate`, `aws`, `azure`, `k8s`,
    `bootstrap`, `material`, `cloudogu`, `domainstory`, `eda`.

## style

    !theme cerulean
    title Order flow
    skinparam backgroundColor #FFFFFF
    skinparam defaultFontName sans-serif

    `!theme <name>` and `!include <package/File>` read from the jar and
    keep working under the default profile.  `!theme <name>` pointing at a
    local `.puml' file, and `!include ./file.puml`, do not.

## gotchas

- One diagram per call.  Two `@startuml' blocks produce two concatenated
  documents, which is not an image.
- `@startuml`/`@enduml` may be omitted; the diagram type is detected.
- Local `!include` and local `!theme` are refused by the default security
  profile.  Inline the content, use a stdlib include, or change
  `gptel-yatools-plantuml-security-profile'.
- Plain text labels need no quoting, but `*`, `#` and `{` can start
  markup; wrap a label in quotes if it misbehaves.
- A missing `}` or a missing `end` is the most common syntax error."
  "PlantUML syntax reference the `render_diagram' tool returns on request.

The value is divided into `## <topic>' sections, one per diagram type,
plus `style' and `gotchas'; the tool's `help' argument names one and gets
that section back.  It is a variable rather than a file so that a user can
correct or extend it without touching the package."
  :type 'string
  :group 'gptel-yatools-diagram)

;;;; Content addressing

(defconst gptel-yatools-diagram--hash-length 16
  "Hex digits of the source digest used in a cache file name.")

(defconst gptel-yatools-diagram--token-length 6
  "Hex digits of the source digest used in a render token.")

(defconst gptel-yatools-diagram--token-regexp
  "\\[diagram:\\([0-9a-f]+\\)\\]"
  "Matcher for a render token, with the digits in group 1.")

(defun gptel-yatools-diagram--digest (source)
  "Return the SHA-256 of SOURCE as hex."
  (secure-hash 'sha256 source))

(defun gptel-yatools-diagram--hash (source)
  "Return the cache name of SOURCE, without a directory or extension.

The digest covers the SOURCE and nothing else -- not the PlantUML
executable, its version, the GraphViz layout engine or
`gptel-yatools-plantuml-security-profile'.  So the name addresses the
*request*, not the picture: it answers \"is this source's render here?\"
and not \"is this picture the one this PlantUML would draw today?\".

That is deliberate.  Those other inputs are configuration the user sets,
not something the model can vary per call, so folding them in would
change the token every time a setting moved and would break the one
property the design rests on: a token recomputed from the transcript
addresses the same file it always did.  The cost is that upgrading
PlantUML, or changing the security profile, can leave an older picture
in place for a source already rendered.  `gptel-yatools-diagram-clear-cache'
is the cure, and the whole cache is disposable by construction (ADR 0003).
The name is content-addressed rather than counted or dated so that nothing
has to map a token to a file: the token is the same prefix of the digest,
and a rebuild recomputes both from the transcript."
  (substring (gptel-yatools-diagram--digest source)
             0 gptel-yatools-diagram--hash-length))

(defun gptel-yatools-diagram--token (source)
  "Return the render token for SOURCE.

The token is a prefix of the cache name, so it can be resolved against
the cache by glob and recomputed from the source without any table
mapping one to the other."
  (substring (gptel-yatools-diagram--digest source)
             0 gptel-yatools-diagram--token-length))

(defun gptel-yatools-diagram--cache-file (hash extension)
  "Return the absolute path of the HASH entry with EXTENSION."
  (expand-file-name (concat hash "." extension)
                    gptel-yatools-diagram-cache-directory))

(defun gptel-yatools-diagram--svg-file (source)
  "Return the SVG cache path for SOURCE."
  (gptel-yatools-diagram--cache-file (gptel-yatools-diagram--hash source) "svg"))

(defun gptel-yatools-diagram--source-file (source)
  "Return the `.puml' cache path for SOURCE."
  (gptel-yatools-diagram--cache-file (gptel-yatools-diagram--hash source) "puml"))

(defun gptel-yatools-diagram--resolve-token (token)
  "Return what TOKEN names in the cache.

The answer is a plist whose `:kind' is one of:

  found      `:file' is the one cache SVG the digits name.
  missing    nothing in the cache matches.  Not an error: a token whose
             diagram was never rendered, or whose cache was emptied, is
             an ordinary thing to find in a buffer.
  ambiguous  `:files' are the several entries the digits match.  More
             than one is astronomically unlikely and is reported rather
             than resolved by guesswork -- the file names are the whole
             mapping, so a collision has to be surfaced, not picked
             between.

The glob happens once, here.  Drawing and opening both ask this, so they
cannot disagree about whether a token names a file; the only difference
between them is what each does with the answer."
  (let ((files (file-expand-wildcards
                (expand-file-name (concat token "*.svg")
                                  gptel-yatools-diagram-cache-directory)
                t)))
    (cond
     ((null files) (list :kind 'missing))
     ((cdr files) (list :kind 'ambiguous :files files))
     (t (list :kind 'found :file (car files))))))

(defun gptel-yatools-diagram--ensure-cache-directory ()
  "Create the cache directory if it does not exist."
  (let ((dir gptel-yatools-diagram-cache-directory))
    (unless (file-directory-p dir)
      (make-directory dir t)))
  gptel-yatools-diagram-cache-directory)

;;;; Running PlantUML

(defun gptel-yatools-diagram--executable ()
  "Return the PlantUML executable, or signal a message naming the setting."
  (let ((command gptel-yatools-plantuml-command))
    (or (and command (not (string-empty-p command))
             (if (file-name-absolute-p command)
                 (and (file-executable-p command) command)
               (executable-find command)))
        (error "PlantUML is needed to render a diagram, but %s was not found. Install it, or set gptel-yatools-plantuml-command to the executable path. Some diagram types also need GraphViz (dot)."
               (if command (format "%s" command) "no command is configured")))))

(defun gptel-yatools-diagram--graphviz-timeout ()
  "Return the GraphViz timeout for this call, in seconds.

The defcustom is a ceiling; the call's own deadline is the cap, so a
short `timeout' argument cannot be outlived by the layout engine."
  (let ((budget (gptel-yatools--call-deadline)))
    (max 1 (min gptel-yatools-plantuml-graphviz-timeout
                (if (numberp budget) (truncate budget) 1)))))

(defun gptel-yatools-diagram--run-directory ()
  "Return the directory PlantUML runs in: where the cache is.

`gptel-yatools--run-process' runs a command in `default-directory' unless
it is told otherwise, and a chat about a remote workspace has a *remote*
`default-directory'.  That is wrong here twice over: the renderer is found
on this machine, and the cache it writes into is a directory on this
machine (`user-emacs-directory').  Inheriting the workspace handed a local
executable path to the host's shell, which is `exec:
/usr/local/bin/plantuml: not found', exit 127, and no picture.

So the rule is: a subprocess runs where its artifacts live, not where the
chat's workspace happens to be.  For the renderer those are the same
directory, because PlantUML writes the SVG beside the source it was given.

Running it *here* is not a limitation to apologise for: the image is drawn
by this Emacs, from a cache this Emacs owns, and a remote host has no way
to send one back.  A user who points
`gptel-yatools-diagram-cache-directory` at a remote path gets a render on
that host instead -- which needs PlantUML there -- because the directory
decides, not a hardcoded rule about remote."
  (gptel-yatools-diagram--ensure-cache-directory))

(defun gptel-yatools-diagram--run (files)
  "Render FILES, writing SVGs beside them.  Return the process outcome.

One process serves every file, which is the whole point of the batch
path: a JVM start dominates a render, so ten diagrams cost one start
rather than ten.  The polling, the kill and the reap belong to
`gptel-yatools--run-process'; this function is the adapter that supplies
PlantUML's own environment and arguments, and the directory it runs in --
the cache's, not the workspace's, for the reason
`gptel-yatools-diagram--run-directory' gives."
  (let* ((executable (gptel-yatools-diagram--executable))
         (cache (gptel-yatools-diagram--ensure-cache-directory))
         (profile gptel-yatools-plantuml-security-profile)
         (process-environment
          (if profile
              (cons (format "PLANTUML_SECURITY_PROFILE=%s" profile)
                    process-environment)
            process-environment)))
    (gptel-yatools--run-process
     (append (list executable
                   "-tsvg" "--no-error-image"
                   "-o" cache
                   "--graphviz-timeout"
                   (number-to-string (gptel-yatools-diagram--graphviz-timeout)))
             files)
     :directory (gptel-yatools-diagram--run-directory))))

(defun gptel-yatools-diagram--cached (source)
  "Return SOURCE's cached SVG path, or nil when it has not been rendered.

This is the whole caching policy, and it is one line because the name is
the digest of the source: a file that exists already holds the picture
this source makes.  No metadata, no modification time, no invalidation --
`file-exists-p' is the question.

Everything that wants to know whether a render is needed asks here, so
the answer is the same wherever it is asked."
  (let ((svg (gptel-yatools-diagram--svg-file source)))
    (and (file-exists-p svg) svg)))

(defun gptel-yatools-diagram--failure (output source &optional exit)
  "Return the model-facing sentence for a failed render of SOURCE.

OUTPUT is what PlantUML said, EXIT its exit code when there was one.  The
sentence is written once, here, because both the single render and the
batch report it: one of them signals it and the other repeats it in the
echo area, and they must not learn to describe the same failure twice."
  (concat
   (format "PlantUML could not render the diagram%s.\n%s"
           (if (integerp exit) (format " (exit code %d)" exit) "")
           (if (string-empty-p output)
               "(no message)"
             ;; PlantUML names the file it failed on, and that name is
             ;; ours, not the model's: the cache path helps nobody and
             ;; repeats a directory the model cannot use.
             (replace-regexp-in-string
              (regexp-quote (gptel-yatools-diagram--ensure-cache-directory))
              "" output)))
   (if-let* ((hint (gptel-yatools-diagram--hint output source)))
       (concat "\n" hint)
     "")))

(defun gptel-yatools-diagram--render (source)
  "Render SOURCE into the cache and return its SVG path.

Signals with the model-facing wording when PlantUML refuses the source."
  (let* ((svg (gptel-yatools-diagram--svg-file source))
         (file (gptel-yatools-diagram--write-source source)))
    (unless (gptel-yatools-diagram--cached source)
      (let* ((outcome (gptel-yatools-diagram--run (list file)))
             (status (plist-get outcome :status))
             (exit (plist-get outcome :exit))
             (output (string-trim (plist-get outcome :output))))
        (cond
         ((eq status 'timed-out)
          (error "PlantUML did not finish within %s seconds and was killed. The diagram may be too large or GraphViz may be stuck; simplify the source or raise the timeout argument."
                 (gptel-yatools--call-deadline)))
         ((and (eq status 'exited) (integerp exit) (zerop exit)
               (gptel-yatools-diagram--cached source))
          nil)
         (t
          ;; `--no-error-image' is honoured in file mode, but an image
          ;; written by an older failure is still a picture of an error.
          (ignore-errors (delete-file svg))
          (error "%s" (gptel-yatools-diagram--failure output source exit))))))
    svg))

(defun gptel-yatools-diagram--ensure (source)
  "Return SOURCE's cache entry, rendering it first if it is not cached.

The entry is a plist: `:token' is the line the model repeats, `:svg' the
file to draw, and `:description' the one-line summary the tool replies
with.  Callers adapt an entry; none of them decides for itself whether a
render is needed.

A render that cannot be finished signals, with the wording the model
reads.  `gptel-yatools-diagram--ensure-many' is the batch version, which
reports rather than signals -- see the note there."
  (let ((svg (or (gptel-yatools-diagram--cached source)
                 (gptel-yatools-diagram--render source))))
    (list :token (gptel-yatools-diagram--token source)
          :svg svg
          :description (gptel-yatools-diagram--describe svg))))

(defun gptel-yatools-diagram--ensure-many (sources)
  "Put every one of SOURCES in the cache, in a single process.

Return `(:rendered N :failed M :reason STRING)'.  The cache hits cost one
`file-exists-p' each; what is missing is written and rendered together,
because a JVM start dominates a render, so re-opening a chat with twelve
diagrams should cost one start rather than twelve.

A failure is reported, never signalled.  The caller is a hook or a
command, not a tool call: there is no envelope waiting for a condition,
and a wrapped token is a survivable outcome -- so one sentence is the
right size for it, and `:reason' carries it."
  (let* ((sources (delete-dups sources))
         (missing (cl-remove-if #'gptel-yatools-diagram--cached sources))
         (failed nil)
         (reason nil))
    (when missing
      (let* ((files (mapcar #'gptel-yatools-diagram--write-source missing))
             (outcome (gptel-yatools-diagram--run files))
             (status (plist-get outcome :status))
             (output (string-trim (plist-get outcome :output))))
        (dolist (source missing)
          (unless (gptel-yatools-diagram--cached source)
            (push source failed)))
        (setq reason
              (cond
               ((eq status 'timed-out)
                (format "PlantUML did not finish within %s seconds and was killed."
                        (gptel-yatools--call-deadline)))
               (failed
                (gptel-yatools-diagram--failure output (car (last failed))))))))
    (list :rendered (- (length sources) (length failed))
          :failed (length failed)
          :reason reason)))

(defun gptel-yatools-diagram--hint (stderr source)
  "Return a sentence that helps with STDERR for SOURCE, or nil.

This is the cheapest teaching layer there is: it fires exactly when the
model got something wrong, and costs nothing in the requests it is not
part of.

SOURCE is consulted as well as STDERR, because PlantUML rarely says why
it refused an include: under the default profile a `!include' of a local
file comes back as a generic \"Some diagram description contains
errors\", so the directive in the source is the only evidence there is."
  (cond
   ((or (string-match-p "!include\\|!theme\\|Cannot open URL\\|Cannot load theme"
                        stderr)
        (string-match-p "^[ \t]*!\\(include\\|theme\\)" source))
    "Local include and theme directives read the filesystem and are refused by the default security profile. Inline the content, use a stdlib include such as !include <C4/C4_Container>, use !theme cerulean for a bundled theme, or change gptel-yatools-plantuml-security-profile.")
   ((string-match-p "Syntax Error\\|Cannot find\\|ERROR" stderr)
    "The usual causes are an unclosed brace, a missing end for an if/alt/while block, or two diagrams in one call.")
   (t nil)))

(defun gptel-yatools-diagram--start-count (source)
  "Return how many diagram documents SOURCE contains."
  (let ((count 0))
    (with-temp-buffer
      (insert source)
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*@start" nil t)
        (setq count (1+ count))))
    count))

(defun gptel-yatools-diagram--write-source (source)
  "Write SOURCE into the cache and return its path.

The name is the digest of the content, so a file that exists already
holds exactly this source: writing it again would be a no-op with a
syscall."
  (let ((file (gptel-yatools-diagram--source-file source)))
    (unless (file-exists-p file)
      (gptel-yatools-diagram--ensure-cache-directory)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region source nil file nil 'silent)))
    file))

(defun gptel-yatools-diagram--describe (svg)
  "Return a one-line description of SVG, with its dimensions if known."
  (let* ((attributes (file-attributes svg))
         (size (and attributes (file-attribute-size attributes)))
         (dimensions (gptel-yatools-diagram--dimensions svg)))
    (format "%s, %s"
            (or dimensions "SVG")
            (cond
             ((null size) "size unknown")
             ((> size 1024) (format "%.1f KB" (/ size 1024.0)))
             (t (format "%d bytes" size))))))

(defun gptel-yatools-diagram--dimensions (svg)
  "Return SVG's width and height as a string, or nil.

The attributes are searched for separately: PlantUML orders them
`height' first, and a regexp that insisted on `width' then `height'
matched nothing, which is how a rendered diagram came back as a bare
\"SVG\"."
  (when (file-readable-p svg)
    (with-temp-buffer
      (insert-file-contents svg nil 0 2000)
      (goto-char (point-min))
      (let ((width (save-excursion
                     (when (re-search-forward "width=\"\\([0-9.]+\\)" nil t)
                       (match-string 1))))
            (height (save-excursion
                      (when (re-search-forward "height=\"\\([0-9.]+\\)" nil t)
                        (match-string 1)))))
        (when (and width height)
          (format "%sx%s px" width height))))))

;;;; The cheat sheet

(defun gptel-yatools-diagram-cheatsheet-topics ()
  "Return the sections `gptel-yatools-diagram-cheatsheet' holds.

The names are read from the sheet's own `## <topic>' headings, so a user
who adds a section gets it listed, matched and offered without editing
anything else.  That is the reason the sheet is a variable, and the
reason there is no separate list to fall out of step with it."
  (let ((sheet gptel-yatools-diagram-cheatsheet)
        (topics nil)
        (start 0))
    (while (string-match "^##[ \t]+\\([^ \t\n]+\\)" sheet start)
      (push (match-string 1 sheet) topics)
      (setq start (match-end 0)))
    (nreverse topics)))

(defun gptel-yatools-diagram--dedent (text)
  "Return TEXT with its common leading indentation removed."
  (let* ((lines (split-string text "\n"))
         (indents (delq nil
                        (mapcar (lambda (line)
                                  (when (string-match "\\`\\([ \t]*\\)[^ \t\n]" line)
                                    (length (match-string 1 line))))
                                lines)))
         (width (if indents (apply #'min indents) 0)))
    (if (zerop width)
        text
      (mapconcat (lambda (line)
                   (let ((pattern (format "\\`[ \t]\\{0,%d\\}" width)))
                     (if (string-match pattern line)
                         (substring line (match-end 0))
                       line)))
                 lines "\n"))))

(defun gptel-yatools-diagram-cheatsheet-text (topic)
  "Return the cheat-sheet section named TOPIC, or the list of topics.

TOPIC is matched case-insensitively against the `## <topic>' headings of
`gptel-yatools-diagram-cheatsheet'.  An empty or unknown TOPIC returns the
topic list rather than the whole sheet, which keeps the reply small and
tells the model what to ask for next -- the same two-step the `skill'
tool uses, for the same reason: the list a model can see is the list that
exists."
  (let* ((topic (downcase (string-trim (or topic ""))))
         (sheet gptel-yatools-diagram-cheatsheet)
         (topics (gptel-yatools-diagram-cheatsheet-topics)))
    (if (string-empty-p topic)
        (format "Ask again with one of: %s."
                (mapconcat #'identity topics ", "))
      (let ((start (save-match-data
                     (when (string-match
                            (concat "^##[ \t]+"
                                    (regexp-quote topic)
                                    "\\(?:[ \t]*$\\)")
                            sheet)
                       (match-end 0)))))
        (if (null start)
            (format "No cheat sheet for %s. Ask again with one of: %s."
                    topic
                    (mapconcat #'identity topics ", "))
          (let* ((end (or (save-match-data
                            (when (string-match "^##[ \t]+" sheet start)
                              (match-beginning 0)))
                          (length sheet)))
                 (body (string-trim
                        (gptel-yatools-diagram--dedent
                         (substring sheet start end)))))
            (format "PlantUML %s, minimal form:\n\n%s" topic body)))))))

;;;; The tool

(gptel-yatools-define-tool gptel-yatools-render-diagram
  :name "render_diagram"
  :category "diagram"
  :description
  "Render PlantUML source to an image and return the exact line to put in your answer so the user sees it. Give the whole source in `source`; `@startuml`/`@enduml` are added if you omit them. One diagram per call. Local file includes are unavailable by default: use `!theme <name>` or a `<stdlib/…>` include instead.

Call it with neither argument and it lists the diagram types it has a cheat sheet for; pass `help` with one of those names to get that sheet, which is a compact reference for the syntax that most often goes wrong. Ask for the sheet before writing a diagram type you are not sure of rather than guessing and correcting afterwards. On a syntax error the tool returns PlantUML's line and message; fix the source and call again rather than describing the failure."
  :args '((:name "source"
                :type string
                :description "The complete PlantUML source of one diagram. `@startuml`/`@enduml` may be omitted."
                :optional t)
          (:name "help"
                 :type string
                 :description "A diagram type to get syntax for instead of rendering, named exactly as the list shows it (e.g. \"sequence\", \"class\", \"er\"). Omit it, and omit `source` too, to list the types available."
                 :optional t))
  (cond
   ;; No arguments at all is the index request: the list of sheets is
   ;; small, cheap, and the only way the model can learn what `help'
   ;; answers to.  Asking with an empty `help' is the same request, which
   ;; is what the `skill' tool does with an empty name.
   ((and (null help) (null source))
    (gptel-yatools-ok
     (gptel-yatools-diagram-cheatsheet-text "")
     :comment "Syntax topics. Nothing was rendered and nothing was written."))
   ((not (null help))
    (gptel-yatools-ok
     (gptel-yatools-diagram-cheatsheet-text help)
     :comment "Syntax reference. Nothing was rendered and nothing was written."))
   ;; A source that is present but empty is a mistake, not an index
   ;; request: the model meant to draw something and said nothing.
   ((string-empty-p (string-trim source))
    (error "The source is empty. Give the PlantUML source of one diagram, or call with no arguments to list the diagram types that have a syntax sheet."))
   ((> (gptel-yatools-diagram--start-count source) 1)
    (error "The source contains %d diagrams. One diagram per call; render them separately."
           (gptel-yatools-diagram--start-count source)))
   (t
    (unless (gptel-yatools-diagram--cached source)
      (gptel-yatools--update-tool-status " Rendering diagram..." 'mode-line-emphasis))
    (let ((entry (gptel-yatools-diagram--ensure source)))
      (gptel-yatools-ok
       (format "Rendered %s.\nTo show it, write this on its own line in your answer:\n[diagram:%s]"
               (plist-get entry :description)
               (plist-get entry :token))
       :comment "The diagram was rendered outside the workspace into a content-addressed cache. Nothing in the workspace changed and nothing was persisted.")))))

;;;; Drawing

(defvar-local gptel-yatools-diagram--overlays nil
  "Overlays this module has drawn in the current buffer.")

(defun gptel-yatools-diagram--max-width ()
  "Return a display width in pixels for an image, or nil."
  (ignore-errors
    (when (display-graphic-p)
      (let ((window (get-buffer-window (current-buffer) t)))
        (when (and window (window-font-width window))
          (* (window-font-width window) (window-width window)))))))

(defun gptel-yatools-diagram--image (file)
  "Return an image spec for FILE, or nil."
  (when (and (display-images-p) (image-type-available-p 'svg))
    (ignore-errors
      (create-image file 'svg nil :max-width (gptel-yatools-diagram--max-width)))))

(defun gptel-yatools-diagram--clear-overlays (&optional beg end)
  "Remove the overlays this module drew between BEG and END.

A dead overlay is dropped from the list without being asked for its
bounds.  `evaporate' deletes an overlay when the text under it is
deleted, and `overlay-start' answers nil for a deleted overlay: comparing
that with BEG signalled `wrong-type-argument number-or-marker-p nil',
which took the whole redraw with it -- so once any token had been
evaporated, no later diagram in that buffer was ever drawn."
  (setq gptel-yatools-diagram--overlays
        (cl-delete-if (lambda (overlay)
                        (cond
                         ((not (overlayp overlay)) t)
                         ((null (overlay-start overlay)) t)
                         ((and beg end
                               (or (< (overlay-end overlay) beg)
                                   (> (overlay-start overlay) end)))
                          nil)
                         (t (delete-overlay overlay) t)))
                      gptel-yatools-diagram--overlays)))

(defun gptel-yatools-diagram--show-region (beg end)
  "Draw every resolvable token between BEG and END.  Return how many.

A token that resolves to nothing, or to more than one file, is left as
text and said nothing about: this runs from
`gptel-post-response-functions', once per response, which is exactly how
a repeated complaint becomes noise.  `gptel-yatools-diagram-open-at-point'
is where the user asks, and there the answer is a sentence."
  (let ((drawn 0))
    (when (< beg end)
      (save-excursion
        (save-restriction
          (narrow-to-region beg end)
          (goto-char (point-min))
          (while (re-search-forward gptel-yatools-diagram--token-regexp nil t)
            (let* ((token (match-string 1))
                   (file (plist-get (gptel-yatools-diagram--resolve-token token)
                                    :file)))
              (when-let* ((image (and file
                                      (gptel-yatools-diagram--image file))))
                (let ((overlay (make-overlay (match-beginning 0)
                                             (match-end 0))))
                  (overlay-put overlay 'gptel-yatools-diagram token)
                  (overlay-put overlay 'display image)
                  ;; The picture goes when the text does, so deleting the
                  ;; line cannot leave an orphan on screen.
                  (overlay-put overlay 'evaporate t)
                  (overlay-put overlay 'isearch-open-invisible t)
                  (overlay-put overlay 'help-echo file)
                  ;; The text stays: with images off, or on a terminal, the
                  ;; token is what the user has, and `-open-at-point'
                  ;; resolves it.
                  (push overlay gptel-yatools-diagram--overlays)
                  (setq drawn (1+ drawn)))))))))
    drawn))

(defun gptel-yatools-diagram--refresh (&optional beg end)
  "Redraw the tokens in BEG..END, or in the whole buffer.
Return how many pictures were drawn.

Idempotent by construction: the overlays this module drew are removed
before the scan, so a second pass draws the same picture once."
  (if (not gptel-yatools-diagram-inline)
      0
    (gptel-yatools-diagram--clear-overlays beg end)
    (if (and beg end)
        (gptel-yatools-diagram--show-region beg end)
      (gptel-yatools-diagram--show-region (point-min) (point-max)))))

;;;; Rebuilding from the transcript

(defun gptel-yatools-diagram--sources-in-buffer ()
  "Return the PlantUML source of every `render_diagram' call in the buffer.

gptel writes each tool call into the buffer as its printed plist --
`(:name \"render_diagram\" :args (:source \"...\"))' -- so the source is
recoverable text.  Org buffers escape it with `org-escape-code-in-string'
to keep the block intact, and that prefixing is undone here; Markdown
buffers do not escape, so they are read as written.

The tool block is folded, not elided: this is the reason a diagram
survives its cache being deleted."
  (let ((sources nil))
    (save-excursion
      (goto-char (point-min))
      (while (search-forward
              "(:name \"render_diagram\" :args (" nil t)
        (let ((limit (min (point-max) (+ (point) 200))))
          (when (and (search-forward ":source " limit t)
                     (eq (char-after) ?\"))
            (let ((source (condition-case nil
                              (read (current-buffer))
                            (error nil))))
              (when (stringp source)
                (push (if (derived-mode-p 'org-mode)
                          (org-unescape-code-in-string source)
                        source)
                      sources)))))))
    (nreverse sources)))

(defun gptel-yatools-diagram--rebuild-missing ()
  "Render every diagram the buffer mentions whose SVG is missing.

One PlantUML process for all of them: re-opening a chat with twelve
diagrams should cost one JVM start, not twelve.  A source whose digest
matches no link is still rendered -- it is in the transcript, so it is
wanted -- and a token that matches no source is left alone: a mention is
not an error.

Nothing here decides what needs rendering: that is
`gptel-yatools-diagram--ensure-many's answer, and its `:reason' is what
gets said when some of them could not be rebuilt."
  (when (and gptel-yatools-diagram-inline
             (display-images-p)
             (image-type-available-p 'svg))
    (let ((result (gptel-yatools-diagram--ensure-many
                   (gptel-yatools-diagram--sources-in-buffer))))
      (when (> (plist-get result :failed) 0)
        (message "gptel-yatools-diagram: %d of %d diagrams could not be rebuilt. %s"
                 (plist-get result :failed)
                 (+ (plist-get result :rendered) (plist-get result :failed))
                 (or (plist-get result :reason) ""))))))

;;;; Hooks

(defun gptel-yatools-diagram--post-response (beg end)
  "Draw whatever the response between BEG and END introduced.

gptel calls this with two marker positions, but a response that has no
markers of its own -- a tool result round -- leaves them nil, and a
narrowing to nil signals.  Nil means \"the whole buffer\" here, and an
out-of-range position is clamped: drawing less is survivable, refusing to
draw at all is not."
  (condition-case err
      (gptel-yatools-diagram--refresh
       (and (integer-or-marker-p beg)
            (max (point-min) (min (point-max) beg)))
       (and (integer-or-marker-p end)
            (max (point-min) (min (point-max) end))))
    (error (message "gptel-yatools-diagram: %s" (error-message-string err)))))

(defun gptel-yatools-diagram--mode-hook ()
  "Arrange drawing for a chat buffer that just gained or lost `gptel-mode'."
  (if gptel-mode
      (progn
        (add-hook 'gptel-post-response-functions
                  #'gptel-yatools-diagram--post-response nil t)
        (when gptel-yatools-diagram-inline
          (condition-case err
              (gptel-yatools-diagram--rebuild-missing)
            (error (message "gptel-yatools-diagram: %s"
                            (error-message-string err))))
          (gptel-yatools-diagram--refresh)))
    (gptel-yatools-diagram--clear-overlays)
    (remove-hook 'gptel-post-response-functions
                 #'gptel-yatools-diagram--post-response t)))

(add-hook 'gptel-mode-hook #'gptel-yatools-diagram--mode-hook)

;;;; Commands

(defun gptel-yatools-diagram-toggle-inline (&optional arg)
  "Toggle drawing diagrams inline in this buffer.

With ARG, turn drawing on if ARG is positive.  This sets the
buffer-local value, so one chat can show its pictures while another does
not.  The token text is never removed, so turning drawing back on needs
no rendering."
  (interactive "P")
  (setq-local gptel-yatools-diagram-inline
              (if (null arg)
                  (not gptel-yatools-diagram-inline)
                (> (prefix-numeric-value arg) 0)))
  (if gptel-yatools-diagram-inline
      (progn
        (gptel-yatools-diagram--rebuild-missing)
        (gptel-yatools-diagram--refresh))
    (gptel-yatools-diagram--clear-overlays))
  (message "Diagram display %s"
           (if gptel-yatools-diagram-inline "on" "off")))

(defun gptel-yatools-diagram--token-at-point ()
  "Return the token on the line at point that spans point, or nil."
  (save-excursion
    (let ((here (point))
          (found nil))
      (goto-char (line-beginning-position))
      (while (and (not found)
                  (re-search-forward gptel-yatools-diagram--token-regexp
                                     (line-end-position) t))
        (when (and (<= (match-beginning 0) here)
                   (>= (match-end 0) here))
          (setq found (match-string 1))))
      found)))

(defun gptel-yatools-diagram-open-at-point ()
  "Open the diagram named by the token at point, outside Emacs.

This is what the token is worth when nothing can be drawn -- a terminal
frame, or drawing turned off.  It is also the way to get at the full-size
image when the inline one is scaled to the window.

The three answers `gptel-yatools-diagram--resolve-token' can give are
each said out loud here: this is where the user asked, so this is where
silence would be a fault rather than a mercy."
  (interactive)
  (let* ((token (gptel-yatools-diagram--token-at-point))
         (found (and token (gptel-yatools-diagram--resolve-token token))))
    (cond
     ((null token)
      (user-error "Point is not on a diagram token"))
     ((eq (plist-get found :kind) 'missing)
      (user-error "No rendered diagram for [diagram:%s]; render it again or reopen the chat" token))
     ((eq (plist-get found :kind) 'ambiguous)
      (user-error "[diagram:%s] is ambiguous: %d cache entries match"
                  token (length (plist-get found :files))))
     (t (browse-url (browse-url-file-url (plist-get found :file)))))))

(defun gptel-yatools-diagram-insert (source)
  "Render SOURCE and insert its token at point.

The manual repair for the one thing that can go wrong quietly: the model
forgets to repeat the token.  SOURCE is read from the minibuffer when
called interactively.

The render comes first, so the token is never a dead one: `--ensure'
signals when PlantUML refuses, and nothing has been inserted at that
point, so a source that cannot be drawn leaves the buffer as it was."
  (interactive "sPlantUML source: ")
  (let* ((entry (gptel-yatools-diagram--ensure source))
         (token (plist-get entry :token)))
    (insert (format "[diagram:%s]" token))
    (gptel-yatools-diagram--refresh (line-beginning-position)
                                    (line-end-position))
    (message "Inserted [diagram:%s] (%s)"
             token (plist-get entry :description))))

(defun gptel-yatools-diagram-clear-cache ()
  "Delete every rendered diagram and its source.

Safe by design: the durable copy of each diagram is the conversation, so
this costs a re-render, never data.  It is the same sweep as
`gptel-yatools-diagram--sweep-cache' with no age limit -- for the cases
age cannot cover, like upgrading PlantUML or changing the security
profile, where the old picture is still there but no longer right."
  (interactive)
  (let ((count (length (gptel-yatools-diagram--cache-files))))
    (dolist (file (gptel-yatools-diagram--cache-files))
      (ignore-errors (delete-file file)))
    (message "Deleted %d cached diagram file(s)" count)))

(provide 'gptel-yatools-diagram)

;; Armed at load time, and armed *here* rather than in an init file: the
;; sweep belongs to the module that owns the directory it sweeps, and a
;; user who never loads this module has no cache to sweep.  Idle, so it
;; never lands inside a render; once, because it is housekeeping.
(gptel-yatools-diagram--arm-cache-sweep)

;;; gptel-yatools-diagram.el ends here
