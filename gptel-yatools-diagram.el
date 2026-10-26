;;; gptel-yatools-diagram.el --- Diagrams in the chat buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

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

(defconst gptel-yatools-diagram--topics
  '("sequence" "class" "activity" "state" "component" "er" "mindmap"
    "c4" "style" "gotchas")
  "Topic names `render_diagram' answers to in its `help' argument.")

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
  "Return the cache name of SOURCE, without a directory or extension."
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

(defun gptel-yatools-diagram--token-files (token)
  "Return the cache SVGs whose name begins with TOKEN.

More than one is astronomically unlikely, and is treated as an
ambiguity rather than resolved by guesswork: the file names are the whole
mapping, so a collision has to be reported, not picked between."
  (file-expand-wildcards
   (expand-file-name (concat token "*.svg")
                     gptel-yatools-diagram-cache-directory)
   t))

(defun gptel-yatools-diagram--token-file (token)
  "Return the one cache SVG TOKEN names, or nil."
  (let ((files (gptel-yatools-diagram--token-files token)))
    (and (null (cdr files)) (car files))))

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

(defun gptel-yatools-diagram--run (files)
  "Render FILES, writing SVGs beside them.  Return (EXIT . STDERR).

One process serves every file, which is the whole point of the batch
path: a JVM start dominates a render, so ten diagrams cost one start
rather than ten.  A real process is polled rather than `call-process',
because only that can be interrupted when the call's deadline expires --
timers do not run while `call-process' waits."
  (let* ((executable (gptel-yatools-diagram--executable))
         (cache (gptel-yatools-diagram--ensure-cache-directory))
         (timeout (gptel-yatools--call-deadline))
         (profile gptel-yatools-plantuml-security-profile)
         (process-environment
          (if profile
              (cons (format "PLANTUML_SECURITY_PROFILE=%s" profile)
                    process-environment)
            process-environment))
         (outbuf (generate-new-buffer " *gptel-diagram-out*"))
         (process nil)
         (exit-code nil)
         (timed-out nil))
    (unwind-protect
        (progn
          (setq process
                (make-process
                 :name "gptel-diagram"
                 :buffer outbuf
                 :command (list shell-file-name shell-command-switch
                                (concat "exec 2>&1; exec "
                                        (mapconcat
                                         #'shell-quote-argument
                                         (append
                                          (list executable
                                                "-tsvg" "--no-error-image"
                                                "-o" cache
                                                "--graphviz-timeout"
                                                (number-to-string
                                                 (gptel-yatools-diagram--graphviz-timeout)))
                                          files)
                                         " ")))
                 :connection-type 'pipe
                 :noquery t
                 ;; The default sentinel appends "Process ... finished"
                 ;; to the buffer, where it would read as part of
                 ;; PlantUML's own message.  stderr is merged into stdout
                 ;; in the shell above for the same reason: with `:stderr'
                 ;; Emacs creates a pipe process whose sentinel writes
                 ;; into this very buffer.
                 :sentinel #'ignore))
          (let ((deadline (+ (float-time)
                             (- timeout
                                (min 0.5 (max 0.05 (* 0.1 timeout)))))))
            (while (and (process-live-p process)
                        (< (float-time) deadline))
              (accept-process-output process
                                     (min 0.2 (max 0.01
                                                   (- deadline (float-time))))))
            (if (process-live-p process)
                (setq timed-out t)
              (setq exit-code (process-exit-status process))))
          (when (and process (process-live-p process))
            ;; Emacs puts each subprocess in its own process group, so
            ;; signalling the negative pid stops the JVM and its children.
            (unless (ignore-errors
                      (signal-process (- (process-id process)) 'SIGKILL))
              (ignore-errors (signal-process process 'SIGKILL)))
            (accept-process-output process 0.5)
            (when (process-live-p process)
              (ignore-errors (delete-process process))))
          (when timed-out
            (error "PlantUML did not finish within %s seconds and was killed. The diagram may be too large or GraphViz may be stuck; simplify the source or raise the timeout argument."
                   timeout))
          (cons exit-code
                (with-current-buffer outbuf
                  (string-trim (buffer-substring-no-properties
                                (point-min) (point-max))))))
      (when (buffer-live-p outbuf) (kill-buffer outbuf)))))

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

(defun gptel-yatools-diagram--render (source)
  "Render SOURCE into the cache and return its SVG path.

Signals with the model-facing wording when PlantUML refuses the source."
  (let* ((svg (gptel-yatools-diagram--svg-file source))
         (file (gptel-yatools-diagram--write-source source)))
    (unless (file-exists-p svg)
      (let* ((result (gptel-yatools-diagram--run (list file)))
             (exit (car result))
             (stderr (cdr result)))
        (if (and (integerp exit) (zerop exit) (file-exists-p svg))
            nil
          ;; `--no-error-image' is honoured in file mode, but an image
          ;; written by an older failure is still a picture of an error.
          (ignore-errors (delete-file svg))
          (error "PlantUML could not render the diagram%s.\n%s%s"
                 (if (integerp exit) (format " (exit code %d)" exit) "")
                 (if (string-empty-p stderr)
                     "(no message)"
                   ;; PlantUML names the file it failed on, and that name
                   ;; is ours, not the model's: the cache path helps nobody
                   ;; and repeats a directory the model cannot use.
                   (string-trim
                    (replace-regexp-in-string
                     (regexp-quote (gptel-yatools-diagram--ensure-cache-directory))
                     "" stderr)))
                 (if-let* ((hint (gptel-yatools-diagram--hint stderr source)))
                     (concat "\n" hint)
                   "")))))
    svg))

(defun gptel-yatools-diagram--describe (svg)
  "Return a one-line description of SVG, with its dimensions if known."
  (let ((size (file-attribute-size (file-attributes svg)))
        (dimensions (gptel-yatools-diagram--dimensions svg)))
    (format "%s, %s"
            (or dimensions "SVG")
            (if (and size (> size 1024))
                (format "%.1f KB" (/ size 1024.0))
              (format "%d bytes" (or size 0))))))

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
tells the model what to ask for next."
  (let* ((topic (downcase (string-trim (or topic ""))))
         (sheet gptel-yatools-diagram-cheatsheet))
    (if (string-empty-p topic)
        (format "Ask again with one of: %s."
                (mapconcat #'identity gptel-yatools-diagram--topics ", "))
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
                    (mapconcat #'identity gptel-yatools-diagram--topics ", "))
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
  "Render PlantUML source to an image and return the exact line to put in your answer so the user sees it. Give the whole source in `source`; `@startuml`/`@enduml` are added if you omit them. One diagram per call. Local file includes are unavailable by default: use `!theme <name>` or a `<stdlib/…>` include instead. Pass `help` instead of `source` to get a compact syntax sheet for a diagram type. On a syntax error the tool returns PlantUML's line and message; fix the source and call again rather than describing the failure."
  :args '((:name "source"
                :type string
                :description "The complete PlantUML source of one diagram. `@startuml`/`@enduml` may be omitted."
                :optional t)
          (:name "help"
                 :type string
                 :description "A diagram type to get syntax for instead of rendering: \"sequence\", \"class\", \"activity\", \"state\", \"component\", \"er\", \"mindmap\", \"c4\", \"style\" or \"gotchas\". Omit `source`."
                 :optional t))
  (cond
   ((not (null help))
    (gptel-yatools-ok
     (gptel-yatools-diagram-cheatsheet-text help)
     :comment "Syntax reference. Nothing was rendered and nothing was written."))
   ((or (null source) (string-empty-p (string-trim source)))
    (error "The source is empty. Give the PlantUML source of one diagram, or pass help to get syntax for a diagram type."))
   ((> (gptel-yatools-diagram--start-count source) 1)
    (error "The source contains %d diagrams. One diagram per call; render them separately."
           (gptel-yatools-diagram--start-count source)))
   (t
    (let* ((hash (gptel-yatools-diagram--hash source))
           (svg (gptel-yatools-diagram--cache-file hash "svg"))
           (token (gptel-yatools-diagram--token source)))
      ;; A content-addressed name means this is the whole caching policy:
      ;; the file exists, so it already holds the picture this source
      ;; makes.  No metadata, no mtime, no invalidation.
      (unless (file-exists-p svg)
        (gptel-yatools--update-tool-status " Rendering diagram..." 'mode-line-emphasis)
        (gptel-yatools-diagram--render source))
      (gptel-yatools-ok
       (format "Rendered %s.\nTo show it, write this on its own line in your answer:\n[diagram:%s]"
               (gptel-yatools-diagram--describe svg) token)
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
  "Remove the overlays this module drew between BEG and END."
  (setq gptel-yatools-diagram--overlays
        (cl-delete-if (lambda (overlay)
                        (if (and beg end
                                 (or (< (overlay-end overlay) beg)
                                     (> (overlay-start overlay) end)))
                            nil
                          (delete-overlay overlay)
                          t))
                      gptel-yatools-diagram--overlays)))

(defun gptel-yatools-diagram--show-region (beg end)
  "Draw every resolvable token between BEG and END."
  (save-excursion
    (save-restriction
      (narrow-to-region beg end)
      (goto-char (point-min))
      (while (re-search-forward gptel-yatools-diagram--token-regexp nil t)
        (let ((token (match-string 1)))
          (when-let* ((file (gptel-yatools-diagram--token-file token))
                      ((file-exists-p file))
                      (image (gptel-yatools-diagram--image file)))
            (let ((overlay (make-overlay (match-beginning 0) (match-end 0))))
              (overlay-put overlay 'gptel-yatools-diagram token)
              (overlay-put overlay 'display image)
              ;; The picture goes when the text does, so deleting the line
              ;; cannot leave an orphan on screen.
              (overlay-put overlay 'evaporate t)
              (overlay-put overlay 'isearch-open-invisible t)
              (overlay-put overlay 'help-echo file)
              ;; The text stays: with images off, or on a terminal, the
              ;; token is what the user has, and `-open-at-point' resolves
              ;; it.
              (push overlay gptel-yatools-diagram--overlays))))))))

(defun gptel-yatools-diagram--refresh (&optional beg end)
  "Redraw the tokens in BEG..END, or in the whole buffer.

Idempotent by construction: the overlays this module drew are removed
before the scan, so a second pass draws the same picture once."
  (when gptel-yatools-diagram-inline
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
not an error."
  (when (and gptel-yatools-diagram-inline
             (display-images-p)
             (image-type-available-p 'svg))
    (let* ((sources (delete-dups (gptel-yatools-diagram--sources-in-buffer)))
           (missing (cl-remove-if
                     (lambda (source)
                       (file-exists-p (gptel-yatools-diagram--svg-file source)))
                     sources)))
      (when missing
        (let ((files (mapcar #'gptel-yatools-diagram--write-source missing)))
          (gptel-yatools-diagram--run files))))))

;;;; Hooks

(defun gptel-yatools-diagram--post-response (beg end)
  "Draw whatever the response between BEG and END introduced."
  (condition-case err
      (gptel-yatools-diagram--refresh beg end)
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
image when the inline one is scaled to the window."
  (interactive)
  (let* ((token (gptel-yatools-diagram--token-at-point))
         (files (and token (gptel-yatools-diagram--token-files token))))
    (cond
     ((null token)
      (user-error "Point is not on a diagram token"))
     ((null files)
      (user-error "No rendered diagram for [diagram:%s]; render it again or reopen the chat" token))
     ((cdr files)
      (user-error "[diagram:%s] is ambiguous: %d cache entries match"
                  token (length files)))
     (t (browse-url (browse-url-file-url (car files)))))))

(defun gptel-yatools-diagram-insert (source)
  "Render SOURCE and insert its token at point.

The manual repair for the one thing that can go wrong quietly: the model
forgets to repeat the token.  SOURCE is read from the minibuffer when
called interactively, and rendered first, so the token it inserts is not
a dead one."
  (interactive "sPlantUML source: ")
  (insert (format "[diagram:%s]"
                  (gptel-yatools-diagram--token source)))
  (when (and (display-images-p) (image-type-available-p 'svg))
    (gptel-yatools-diagram--render source)
    (gptel-yatools-diagram--refresh (line-beginning-position)
                                    (line-end-position))))

(defun gptel-yatools-diagram-clear-cache ()
  "Delete every rendered diagram and its source.

Safe by design: the durable copy of each diagram is the conversation, so
this costs a re-render, never data.  Nothing is swept automatically -- a
timer would have to decide what is still referenced, and the honest
answer is \"whatever a live buffer mentions\", which is expensive to
compute and wrong for saved chats that are not open."
  (interactive)
  (let ((dir gptel-yatools-diagram-cache-directory)
        (count 0))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\`[^.]"))
        (when (file-regular-p file)
          (delete-file file)
          (setq count (1+ count)))))
    (message "Deleted %d cached diagram file(s)" count)))

(provide 'gptel-yatools-diagram)
;;; gptel-yatools-diagram.el ends here
