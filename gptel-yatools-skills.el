;;; gptel-yatools-skills.el --- Agent Skills for gptel-yatools  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Agent Skills (https://agentskills.io) package instructions as a directory
;; of files: a `SKILL.md' whose YAML frontmatter names the skill and says when
;; it applies, and whose Markdown body holds the instructions themselves, plus
;; optional `scripts/', `references/' and `assets/' directories that the model
;; opens only when a task calls for it.
;;
;; This file implements the `skill' tool, which follows the same progressive
;; disclosure as the format itself:
;;
;; 1. Called with no arguments it returns the index -- one line per skill,
;;    name and description -- the cheap layer an agent can consult for every
;;    request.
;; 2. Called with a name it returns that skill's instructions, the list of
;;    files it ships with, and its absolute directory, which is how the model
;;    reaches the scripts.
;; 3. Called with a name and a file it returns one referenced file.
;;
;; Every scan validates the frontmatter against the published specification.
;; A skill whose `name' or `description' is missing or malformed is still
;; listed, but cannot be loaded, so a typo in a skill is reported rather than
;; silently producing an empty or wrong skill.  The optional fields
;; (`license', `compatibility', `metadata', `allowed-tools') are shown to the
;; model verbatim and otherwise left uninterpreted: `allowed-tools' is
;; explicitly experimental in the specification, and gptel has no per-skill
;; tool allowlist to map it onto.
;;
;; This file is loaded by `gptel-yatools.el', which puts the tool in
;; `gptel-yatools--tools'.  It calls helpers that file defines, so it cannot be
;; loaded on its own before it.

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'subr-x)
(require 'yaml)

;; `gptel-yatools.el' requires this file, so requiring it back would be a
;; cycle.  These declarations tell the byte compiler what the helpers are;
;; at runtime they are already defined, because the tool is only built once
;; the rest of the package has been loaded.
(declare-function gptel-yatools--make-tool "gptel-yatools" (&rest slots))
(declare-function gptel-yatools--workspace-root "gptel-yatools" ())
(declare-function gptel-yatools-vfs--effective-content "gptel-yatools-vfs" (path))
(declare-function gptel-yatools--wrap "gptel-yatools" (from-vfs comment body))
(declare-function gptel-yatools--require-string "gptel-yatools" (value what))
(declare-function gptel-yatools--binary-p "gptel-yatools" (string))
(declare-function gptel-yatools--binary-notice "gptel-yatools" (path content from-vfs))
(declare-function gptel-yatools-vfs-get "gptel-yatools-vfs" (path))
(defvar gptel-context)
;; Declared with a value as well as its definition in `gptel-yatools.el':
;; this file is loaded both after that one and, at compile time, on its own,
;; and `add-to-list' below needs the variable to be bound either way.
(defvar gptel-yatools-header-line-extra-functions nil
  "See `gptel-yatools.el'.")

(defcustom gptel-yatools-skill-directories
  (list ".agents/skills"
        (expand-file-name "skills" user-emacs-directory))
  "Where the `skill' tool looks for Agent Skills.

Each element is either a directory name or a function of no arguments
returning one.  The value as a whole may also be a function returning a
list of them, which is the convenient way to make the roots depend on
project-local state:

  (setq gptel-yatools-skill-directories
        (lambda () (list (if (project-current) \".agents/skills\"))))

Relative names are resolved against the workspace root, so
\".agents/skills\" means the root of the project being worked on;
absolute names and names starting with \"~\" are used as they are.  The
directories are scanned in order and each skill is listed once, even
when two roots overlap.

Skills need not sit directly inside a root: they are looked for at most
`gptel-yatools-skill-search-depth' levels down, so a root can group
them, as in `skills/engineering/code-review/SKILL.md'.

`user-emacs-directory' is read when this file is loaded, which is after
`early-init.el' has had its say, so the default value follows a
relocated Emacs directory."
  :type '(choice
          (repeat :tag "Directories" (choice string function))
          (function :tag "Function returning directories"))
  :group 'gptel-yatools)

(defcustom gptel-yatools-skill-search-depth 4
  "How many directory levels below a skill root the `skill' tool searches.

A skill sitting directly inside a root is at level 1, so the default of
4 finds `skills/engineering/code-review/SKILL.md' -- and would still
find it in two more directories of grouping.  The cap keeps a root that
accidentally points at something large from turning into a full tree
walk on every tool call.

A directory that is not a skill, has subdirectories, and sits at the
limit is reported in the tool's response rather than skipped in
silence, so a skill nested too deeply is visible instead of missing."
  :type 'natnum
  :group 'gptel-yatools)

(defconst gptel-yatools-skills--tree-deep-directories '("scripts" "references" "assets")
  "Directories in a skill whose contents are listed one level deep.

These three are the conventions the specification recommends, and the
place a skill keeps the code and documentation the model is meant to
load.  Anything deeper is summarised by a count instead of a listing,
which keeps the activation response small.")

(defconst gptel-yatools-skills--name-regexp
  "\\`[a-z0-9]+\\(?:-[a-z0-9]+\\)*\\'"
  "Regexp matching a valid skill `name' field.

Besides the allowed characters this rules out a leading or trailing
hyphen and consecutive hyphens, which the specification forbids.")

;;-------------------------------------------------------------------------
;; Discovering skills
;;-------------------------------------------------------------------------
(defun gptel-yatools-skills--roots ()
  "Return (ROOTS . PROBLEMS) for `gptel-yatools-skill-directories'.

ROOTS is a list of absolute directory names in priority order.  A
function in the configuration -- the whole value or a single element --
is called here, and if it signals, the failure lands in PROBLEMS instead
of taking the whole tool down: a broken root must not make every other
skill invisible without saying why."
  (let* ((problems nil)
         (raw (condition-case err
                  (if (functionp gptel-yatools-skill-directories)
                      (funcall gptel-yatools-skill-directories)
                    gptel-yatools-skill-directories)
                (error
                 (push (format "`gptel-yatools-skill-directories' failed: %s"
                               (error-message-string err))
                       problems)
                 nil)))
         (roots nil))
    (dolist (entry (if (listp raw) raw (list raw)))
      (let ((path (condition-case err
                      (cond
                       ((functionp entry) (funcall entry))
                       ((stringp entry) entry)
                       (t (error "Expected a string or a function, got %S" entry)))
                    (error
                     (push (format "a skill directory function failed: %s"
                                   (error-message-string err))
                           problems)
                     nil))))
        (when (and (stringp path) (not (string-empty-p (string-trim path))))
          (push (file-name-as-directory
                 (expand-file-name path (gptel-yatools--workspace-root)))
                roots))))
    (cons (nreverse roots) (nreverse problems))))

(defun gptel-yatools-skills--frontmatter (text)
  "Return (FRONTMATTER . BODY) for TEXT, or nil if it has no frontmatter.

The block between the opening line, which must be `---', and the next
line that is exactly `---' is the frontmatter; BODY is everything after
the closing line.  Trailing whitespace and CR from a CRLF file are
allowed on either delimiter line.  Both delimiters are dropped."
  (let* ((lines (split-string text "\n")))
    (when (and lines (string-match-p "\\`---[ \t\r]*\\'" (car lines)))
      (let ((rest (cdr lines))
            (front nil)
            (found nil))
        (while (and rest (not found))
          (if (string-match-p "\\`---[ \t\r]*\\'" (car rest))
              (setq found t)
            (push (car rest) front))
          (setq rest (cdr rest)))
        (when found
          (cons (mapconcat #'identity (nreverse front) "\n")
                (mapconcat #'identity rest "\n")))))))

(defun gptel-yatools-skills--parse-frontmatter (yaml)
  "Return YAML, a frontmatter block, parsed as an alist.

Keys are strings, so `metadata' keeps its own keys intact, and scalar
values stay strings even when they look like numbers (\"1.0\").  An
empty block yields nil, which the validator reports as an empty
frontmatter rather than as an obscure failure."
  (when (and (stringp yaml) (not (string-empty-p (string-trim yaml))))
    (yaml-parse-string yaml
                       :object-type 'alist
                       :object-key-type 'string
                       :string-values t)))

(defun gptel-yatools-skills--field (frontmatter key)
  "Return KEY's value in FRONTMATTER, or nil.

FRONTMATTER comes from YAML, so it is only an alist when the author
wrote a mapping: a list, a vector or a bare string is a broken skill
that must still be *described* without tripping over `alist-get', which
signals on anything but a list."
  (when (and (listp frontmatter) (cl-every #'consp frontmatter))
    (alist-get key frontmatter nil nil #'equal)))

(defun gptel-yatools-skills--validate (frontmatter dirname)
  "Return a plist of :problems and :warnings for FRONTMATTER in DIRNAME.

Problems make the skill unloadable: they are the specification's
required fields, `name' and `description', missing or malformed.  The
optional fields are only checked for their type and length, because
refusing to load a skill over a 501-character `compatibility' line
would cost more than the mistake does.

A `name' that disagrees with the directory name is a warning, not a
problem: the directory is what lookups use, and the mismatch is the
most common authoring slip of all."
  (let ((problems nil)
        (warnings nil))
    (cond
     ((null frontmatter)
      (push "the `SKILL.md' frontmatter is empty" problems))
     ((or (not (listp frontmatter))
          (not (cl-every #'consp frontmatter)))
      (push "the `SKILL.md' frontmatter is not a key/value mapping" problems))
     (t
      (let ((name (gptel-yatools-skills--field frontmatter "name")))
        (cond
         ((null name)
          (push "the required `name' field is missing" problems))
         ((not (stringp name))
          (push "the `name' field is not a string" problems))
         (t
          (when (> (length name) 64)
            (push (format "the `name' field is %d characters long; at most 64 are allowed"
                          (length name))
                  problems))
          ;; `case-fold-search' would otherwise let "Upper-Case" through.
          (unless (let ((case-fold-search nil))
                    (string-match-p gptel-yatools-skills--name-regexp name))
            (push (format "the `name' field %S may only contain lowercase letters, digits and single hyphens, and may not start or end with one"
                          name)
                  problems))
          (unless (equal name dirname)
            (push (format "the `name' field %S does not match the directory name %S"
                          name dirname)
                  warnings)))))
      (let ((description (gptel-yatools-skills--field frontmatter "description")))
        (cond
         ((null description)
          (push "the required `description' field is missing" problems))
         ((not (stringp description))
          (push "the `description' field is not a string" problems))
         ((string-empty-p (string-trim description))
          (push "the `description' field is empty" problems))
         ((> (length description) 1024)
          (push (format "the `description' field is %d characters long; at most 1024 are allowed"
                        (length description))
                problems))))
      (dolist (field '("license" "allowed-tools"))
        (let ((value (gptel-yatools-skills--field frontmatter field)))
          (unless (or (null value) (stringp value))
            (push (format "the `%s' field is not a string" field) warnings))))
      (let ((compatibility (gptel-yatools-skills--field frontmatter "compatibility")))
        (when (and compatibility (not (stringp compatibility)))
          (push "the `compatibility' field is not a string" warnings))
        (when (and (stringp compatibility) (> (length compatibility) 500))
          (push (format "the `compatibility' field is %d characters long; at most 500 are allowed"
                        (length compatibility))
                warnings)))
      (let ((metadata (gptel-yatools-skills--field frontmatter "metadata")))
        (when (and metadata
                   (not (and (listp metadata)
                             (cl-every (lambda (pair)
                                         (and (consp pair)
                                              (stringp (car pair))
                                              (or (null (cdr pair))
                                                  (stringp (cdr pair)))))
                                       metadata))))
          (push "the `metadata' field is not a mapping of string keys to string values"
                warnings)))))
    (list :problems (nreverse problems)
          :warnings (nreverse warnings))))

(defun gptel-yatools-skills--read (dir root)
  "Return a skill plist for the skill directory DIR, found under ROOT.

The plist carries the parsed frontmatter, the body, the validation
result, and where the `SKILL.md' came from -- a pending VFS copy, if
there is one, wins over the file on disk just as it does for `read_path'.
The directory name, not the `name' field, is the skill's identity."
  (let* ((dirname (file-name-nondirectory (directory-file-name dir)))
         (path (expand-file-name "SKILL.md" dir))
         (effective (gptel-yatools-vfs--effective-content path))
         (text (car-safe effective))
         (from-vfs (cdr-safe effective))
         (split (and text (gptel-yatools-skills--frontmatter text)))
         (frontmatter nil)
         (problems nil))
    (cond
     ((null text)
      (push "`SKILL.md' could not be read" problems))
     ((null split)
      (push "`SKILL.md' does not start with a `---' YAML frontmatter block" problems))
     (t
      (setq frontmatter
            (condition-case err
                (gptel-yatools-skills--parse-frontmatter (car split))
              (error
               (push (format "the frontmatter is not valid YAML: %s"
                             (error-message-string err))
                     problems)
               nil)))))
    (let ((checked (if problems
                       ;; The file itself is unreadable or unparseable, so
                       ;; there are no fields to check: adding "the
                       ;; frontmatter is empty" to the real reason would only
                       ;; bury it.
                       (list :problems nil :warnings nil)
                     (gptel-yatools-skills--validate frontmatter dirname))))
      (list :name dirname
            :relative (gptel-yatools-skills--relative dir root)
            :directory (file-name-as-directory (expand-file-name dir))
            :root (file-name-as-directory (expand-file-name root))
            :path path
            :frontmatter frontmatter
            :body (cdr-safe split)
            :from-vfs from-vfs
            :problems (append (nreverse problems) (plist-get checked :problems))
            :warnings (plist-get checked :warnings)))))

(defun gptel-yatools-skills--skill-directory-p (dir)
  "Return non-nil if DIR holds a `SKILL.md'.

A pending VFS copy counts, so a skill being authored in the buffer is
found before its `SKILL.md' exists on disk."
  (let ((path (expand-file-name "SKILL.md" dir)))
    (or (gptel-yatools-vfs-get path)
        (file-regular-p path))))

(defun gptel-yatools-skills--subdirectories (dir)
  "Return (SUBDIRECTORIES . ERROR) for DIR.

Dot entries are skipped, and an unreadable directory yields its error
string instead of signalling: one unreadable directory must not cost
every other skill."
  (let ((entries (condition-case err
                     (directory-files dir t "\\`[^.]")
                   (file-error (error-message-string err)))))
    (if (stringp entries)
        (cons nil entries)
      (cons (cl-remove-if-not #'file-directory-p entries) nil))))

(defun gptel-yatools-skills--relative (dir root)
  "Return DIR's path relative to ROOT, `/'-separated, for use as a handle."
  (let ((rel (file-relative-name
              (directory-file-name (expand-file-name dir))
              (file-name-as-directory (expand-file-name root)))))
    (if (string-empty-p rel)
        "."
      (replace-regexp-in-string "\\\\" "/" rel))))

(defun gptel-yatools-skills--walk (root)
  "Return a plist of the skills found under ROOT.

The walk descends at most `gptel-yatools-skill-search-depth' levels, a
skill directly inside ROOT being level 1.  A directory that holds a
`SKILL.md' is a skill and is not descended into: a skill ships whatever
subdirectories it likes, and those are its own.

The plist holds :skills (directories), :pruned (directories that were
not descended into because they hit the limit) and :notes (directories
that could not be read)."
  (let ((limit (max 0 gptel-yatools-skill-search-depth))
        (queue (list (cons root 0)))
        (skills nil)
        (pruned nil)
        (notes nil))
    (while queue
      (let* ((item (pop queue))
             (dir (car item))
             (depth (cdr item)))
        (if (gptel-yatools-skills--skill-directory-p dir)
            (push dir skills)
          (let* ((listed (gptel-yatools-skills--subdirectories dir))
                 (children (car listed)))
            (when (cdr listed)
              (push (format "cannot read %s: %s" dir (cdr listed)) notes))
            (cond
             ((null children) nil)
             ((>= depth limit) (push dir pruned))
             (t (dolist (child children)
                  (push (cons child (1+ depth)) queue))))))))
    (list :skills (nreverse skills)
          :pruned (nreverse pruned)
          :notes (nreverse notes))))

(defun gptel-yatools-skills--discover ()
  "Return a plist describing the skills found in the configured roots.

The plist holds :skills (ordered by name), :notes (broken roots,
unreadable directories and directories cut off by the depth limit),
:missing (roots that do not exist) and :roots (every root considered).
A missing root is ordinary -- most projects have no `.agents/skills' --
so it is only mentioned when nothing was found at all, while a root that
fails for another reason is always reported: silently dropping a set of
skills is what makes an agent answer \"there is no skill for that\" with
confidence.

A skill reachable through two roots that resolve to the same directory
is read once; two *different* skills that happen to share a name are
both kept, since with grouped skills that is a plausible arrangement.
Resolving the duplicates is the caller's problem, see
`gptel-yatools-skills--lookup'."
  (let* ((collected (gptel-yatools-skills--roots))
         (roots (car collected))
         (notes (cdr collected))
         (missing nil)
         (seen (make-hash-table :test #'equal))
         (skills nil))
    (dolist (root roots)
      (if (not (file-directory-p root))
          (push root missing)
        (let ((walked (gptel-yatools-skills--walk root)))
          (setq notes (append (nreverse (plist-get walked :notes)) notes))
          (dolist (dir (plist-get walked :pruned))
            (push (format "not searched deeper: %s (skills are looked for at most %d level(s) below a root; raise `gptel-yatools-skill-search-depth' to go further)"
                          (gptel-yatools-skills--relative dir root)
                          gptel-yatools-skill-search-depth)
                  notes))
          (dolist (dir (plist-get walked :skills))
            (let ((identity (or (ignore-errors (file-truename dir)) dir)))
              (unless (gethash identity seen)
                (puthash identity t seen)
                (push (gptel-yatools-skills--read dir root) skills)))))))
    (list :skills (sort skills
                        (lambda (a b)
                          (let ((na (plist-get a :name))
                                (nb (plist-get b :name)))
                            (if (equal na nb)
                                (string-lessp (plist-get a :relative)
                                              (plist-get b :relative))
                              (string-lessp na nb)))))
          :notes (nreverse notes)
          :missing (nreverse missing)
          :roots roots)))

(defun gptel-yatools-skills--lookup (skills name)
  "Resolve NAME against SKILLS.

NAME is either a bare skill name or a path relative to a root -- the
path is what the index shows for a name that is not unique.  Returns
\(:skill SKILL) for a single match, (:ambiguous MATCHES) when a bare
name matches more than one skill, or nil when nothing matches.

An ambiguous name is never resolved to \"the first one\": with skills
grouped into directories, one name in two groups is a reasonable
arrangement, and picking silently would hide a whole skill."
  (let* ((wanted (string-trim name))
         (by-path (cl-remove-if-not
                   (lambda (skill) (equal (plist-get skill :relative) wanted))
                   skills))
         (by-name (cl-remove-if-not
                   (lambda (skill) (equal (plist-get skill :name) wanted))
                   skills))
         (matches (if by-path by-path by-name)))
    (pcase (length matches)
      (0 nil)
      (1 (list :skill (car matches)))
      (_ (list :ambiguous matches)))))

(defun gptel-yatools-skills--duplicate-names (skills)
  "Return the names that occur more than once in SKILLS."
  (let ((counts (make-hash-table :test #'equal))
        (duplicates nil))
    (dolist (skill skills)
      (let ((name (plist-get skill :name)))
        (if (> (gethash name counts 0) 0)
            (cl-pushnew name duplicates :test #'equal)
          (puthash name 1 counts))))
    duplicates))

;;-------------------------------------------------------------------------
;; Rendering
;;-------------------------------------------------------------------------
(defun gptel-yatools-skills--tree (dir)
  "Return a one-level file tree of the skill directory DIR.

Top-level entries are listed, and the conventional `scripts/',
`references/' and `assets/' directories are expanded one level.  A
deeper directory is shown as one line with the number of entries it
holds, which is enough for the model to know that it exists."
  (let ((lines nil))
    (dolist (entry (ignore-errors (directory-files dir t "\\`[^.]")))
      (let ((name (file-name-nondirectory (directory-file-name entry))))
        (if (not (file-directory-p entry))
            (push name lines)
          (push (concat name "/") lines)
          (when (member name gptel-yatools-skills--tree-deep-directories)
            (dolist (child (ignore-errors (directory-files entry t "\\`[^.]")))
              (let ((child-name (file-name-nondirectory (directory-file-name child))))
                (if (file-directory-p child)
                    (push (format "  %s/ (%d entries)" child-name
                                  (length (ignore-errors
                                            (directory-files child t "\\`[^.]"))))
                          lines)
                  (push (format "  %s" child-name) lines))))))))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun gptel-yatools-skills--metadata-lines (frontmatter)
  "Return the rendering of FRONTMATTER's `metadata' map, as a list of lines."
  (let ((metadata (gptel-yatools-skills--field frontmatter "metadata"))
        (lines nil))
    (when (and metadata (listp metadata) (cl-every #'consp metadata))
      (push "Metadata:" lines)
      (dolist (pair metadata)
        (push (format "  %s: %s" (car pair) (cdr pair)) lines)))
    (nreverse lines)))

(defun gptel-yatools-skills--notes-section (notes)
  "Return a `Notes:' section for NOTES, or nil when there are none."
  (when notes
    (concat "Notes:\n"
            (mapconcat (lambda (note) (format "  - %s" note)) notes "\n"))))

(defconst gptel-yatools-skills--index-description-limit 200
  "How much of a description the index shows.

The index is meant to cost ~100 tokens per skill, and a broken file can
carry a description of any length.  Truncating keeps one bad skill from
crowding every other one out of the list.")

(defun gptel-yatools-skills--index-line (skill &optional ambiguous-names)
  "Return the index line for SKILL.

AMBIGUOUS-NAMES is the list from
`gptel-yatools-skills--duplicate-names'; a skill whose name is on it is
shown by its path instead, which is the only handle that identifies it
on its own."
  (let ((description (gptel-yatools-skills--field (plist-get skill :frontmatter)
                                                  "description"))
        (problems (plist-get skill :problems)))
    (concat (if (member (plist-get skill :name) ambiguous-names)
                (plist-get skill :relative)
              (plist-get skill :name))
            " — "
            (if (and (stringp description)
                     (not (string-empty-p (string-trim description))))
                (let ((text (string-trim description)))
                  (if (> (length text) gptel-yatools-skills--index-description-limit)
                      (concat (substring text 0 gptel-yatools-skills--index-description-limit)
                              "…")
                    text))
              "(no description)")
            (when problems
              (format "  [cannot be loaded: %s]" (car problems))))))

(defun gptel-yatools-skills--respond-index (found)
  "Return the tool response listing every skill in FOUND."
  (let* ((skills (plist-get found :skills))
         (notes (plist-get found :notes))
         (missing (plist-get found :missing))
         (roots (plist-get found :roots))
         (ambiguous (gptel-yatools-skills--duplicate-names skills)))
    (gptel-yatools--wrap
     nil
     "Skill index."
     (mapconcat
      #'identity
      (delq nil
            (list
             (if skills
                 (format "%d skill%s available. Call this tool with `name' to load one, or with `name' and `file' to read a file it references."
                         (length skills) (if (= (length skills) 1) "" "s"))
               (format "No skills found. Searched: %s"
                       (if roots
                           (mapconcat #'identity roots ", ")
                         "(no skill directories configured)")))
             (and skills
                  (mapconcat (lambda (skill)
                               (gptel-yatools-skills--index-line skill ambiguous))
                             skills "\n"))
             (and ambiguous
                  (format "Some names occur more than once; those skills are shown with their path relative to the skill directory, which is also the name to load them by: %s."
                          (mapconcat #'identity ambiguous ", ")))
             (and missing (not skills)
                  (format "These configured directories do not exist: %s"
                          (mapconcat #'identity missing ", ")))
             (gptel-yatools-skills--notes-section notes)))
      "\n\n"))))

(defun gptel-yatools-skills--respond-ambiguous (name matches)
  "Return the tool response for NAME, which matches more than one skill."
  (gptel-yatools--wrap
   nil
   "Ambiguous skill name."
   (mapconcat
    #'identity
    (list
     (format "Error: %S matches %d skills, so it does not identify one." name (length matches))
     (concat "Call this tool again with one of these paths -- each is relative to a skill directory and is usable as `name':\n"
             (mapconcat (lambda (skill)
                          (format "  - %s" (plist-get skill :relative)))
                        matches "\n")))
    "\n\n")))

(defun gptel-yatools-skills--respond-unknown (found name)
  "Return the tool response for a call naming NAME, which FOUND does not hold."
  (let ((skills (plist-get found :skills)))
    (gptel-yatools--wrap
     nil
     "No such skill."
     (mapconcat
      #'identity
      (delq nil
            (list
             (format "Error: no skill named %S." name)
             (if skills
                 (format "Available skills: %s. Call this tool without arguments for the full index."
                         (mapconcat (lambda (skill) (plist-get skill :relative))
                                    skills ", "))
               "No skills are available at all; call this tool without arguments to see where it looked.")
             (gptel-yatools-skills--notes-section (plist-get found :notes))))
      "\n\n"))))

(defun gptel-yatools-skills--respond-invalid (skill)
  "Return the tool response explaining why SKILL cannot be loaded."
  (gptel-yatools--wrap
   nil
   "Skill is not valid."
   (mapconcat
    #'identity
    (delq nil
          (list
           (format "Error: the skill in %s cannot be loaded because its `SKILL.md' does not satisfy the Agent Skills specification."
                   (directory-file-name (plist-get skill :directory)))
           (concat "Problems:\n"
                   (mapconcat (lambda (problem) (format "  - %s" problem))
                              (plist-get skill :problems) "\n"))
           (gptel-yatools-skills--notes-section (plist-get skill :warnings))))
    "\n\n")))

(defun gptel-yatools-skills--payload (skill)
  "Return SKILL's text as it should be handed to the model.

This is the whole of what activating a skill means: what it is, where
it lives, what it ships with, and its instructions.  Both the `skill'
tool and the commands that send a skill by hand render this, so the two
cannot drift apart."
  (let* ((frontmatter (plist-get skill :frontmatter))
         (body (or (plist-get skill :body) ""))
         (header (list (format "Skill: %s" (plist-get skill :name)))))
    (dolist (field '(("description" . "Description")
                     ("license" . "License")
                     ("compatibility" . "Compatibility")
                     ("allowed-tools" . "Allowed tools")))
      (let ((value (gptel-yatools-skills--field frontmatter (car field))))
        (when (and (stringp value) (not (string-empty-p (string-trim value))))
          (setq header (append header (list (format "%s: %s" (cdr field) value)))))))
    (setq header (append header
                         (gptel-yatools-skills--metadata-lines frontmatter)
                         (list (format "Directory: %s"
                                       (directory-file-name
                                        (plist-get skill :directory))))))
    (mapconcat
     #'identity
     (delq nil
           (list
            (mapconcat #'identity header "\n")
            (concat "Files in the skill directory (paths are relative to it):\n"
                    (gptel-yatools-skills--tree (plist-get skill :directory)))
            (concat "--- SKILL.md ---\n"
                    (string-trim body "[\n\r]+" "[ \t\n\r]+"))
            "Run any script the skill ships with from that directory, for example with execute_command and the absolute path as its `directory' argument."
            (gptel-yatools-skills--notes-section (plist-get skill :warnings))))
     "\n\n")))

(defun gptel-yatools-skills--respond-skill (skill)
  "Return the tool response that loads SKILL: header, files, and body."
  (gptel-yatools--wrap
   (plist-get skill :from-vfs)
   "Skill loaded."
   (gptel-yatools-skills--payload skill)))

(defun gptel-yatools-skills--resolve-file (skill file)
  "Return FILE's absolute path inside SKILL, or nil if it escapes it.

FILE has to be relative and has to land inside the skill directory:
`..' segments and symlinks that point elsewhere are refused.  Absolute
names are refused too, since they can only be a mistake about what the
path is relative to.  A pending VFS copy is accepted on the strength of
the lexical check alone, because it does not exist on disk yet to have
a truename."
  (let* ((dir (file-name-as-directory (expand-file-name (plist-get skill :directory))))
         (full (expand-file-name file dir)))
    (cond
     ((not (string-prefix-p dir full)) nil)
     ((gptel-yatools-vfs-get full) full)
     ((not (file-regular-p full)) nil)
     (t
      (let ((true (ignore-errors (file-truename full)))
            (true-dir (ignore-errors
                        (file-name-as-directory (file-truename dir)))))
        (and true true-dir (string-prefix-p true-dir true) full))))))

(defun gptel-yatools-skills--respond-file (skill file)
  "Return the tool response that reads FILE from SKILL."
  (let ((full (gptel-yatools-skills--resolve-file skill file)))
    (if (null full)
        (gptel-yatools--wrap
         nil
         "File is not inside the skill."
         (format "Error: %S is not a readable file inside the skill directory. Pass a path relative to the skill root, like \"references/REFERENCE.md\" or \"scripts/extract.py\"."
                 file))
      (let* ((effective (gptel-yatools-vfs--effective-content full))
             (content (car-safe effective))
             (from-vfs (cdr-safe effective)))
        (cond
         ((null content)
          (gptel-yatools--wrap
           nil
           "Unreadable skill file."
           (format "Error: %s could not be read." full)))
         ((gptel-yatools--binary-p content)
          (gptel-yatools--binary-notice full content from-vfs))
         (t
          (gptel-yatools--wrap
           from-vfs
           "Skill file read."
           (format "File: %s\nSkill: %s\n\n%s"
                   file (plist-get skill :name) content))))))))

;;-------------------------------------------------------------------------
;; The tool
;;-------------------------------------------------------------------------
(defun gptel-yatools-skills--run (&optional name file)
  "Implement the `skill' tool: index, load one skill, or read one of its files."
  (when name (gptel-yatools--require-string name "name"))
  (when file (gptel-yatools--require-string file "file"))
  (let* ((present (and (stringp name) (not (string-empty-p (string-trim name)))))
         (found (gptel-yatools-skills--discover))
         (resolved (and present
                        (gptel-yatools-skills--lookup (plist-get found :skills) name))))
    (cond
     ((and file (not present))
      (gptel-yatools--wrap
       nil
       "Missing skill name."
       "Error: reading a skill file needs both `name' and `file', since `file' is relative to the skill's own directory."))
     ((not present)
      (gptel-yatools-skills--respond-index found))
     ((plist-get resolved :ambiguous)
      (gptel-yatools-skills--respond-ambiguous name (plist-get resolved :ambiguous)))
     ((null resolved)
      (gptel-yatools-skills--respond-unknown found name))
     ((plist-get (plist-get resolved :skill) :problems)
      (gptel-yatools-skills--respond-invalid (plist-get resolved :skill)))
     (file
      (gptel-yatools-skills--respond-file (plist-get resolved :skill) file))
     (t
      (gptel-yatools-skills--respond-skill (plist-get resolved :skill))))))

(defun gptel-yatools-skills--tool ()
  "Return the `skill' tool.

A function rather than a variable so that `gptel-yatools.el' can build
it inside its own tool list: reloading that file re-evaluates the list
from scratch, and a tool this file pushed onto it as a side effect would
not come back."
  (gptel-yatools--make-tool
   :name "skill"
   :function #'gptel-yatools-skills--run
   :description
   "List, load and read Agent Skills: directories that package instructions, scripts and reference files for one kind of task.

Call it with no arguments for the skill index: one line per installed skill, with its name and a description of what it does and when to use it. The index is cheap, so consult it whenever a task might already have a skill; load only the skills whose description actually matches.

Call it again with the matching `name' to load that skill. You then get its full instructions, the list of files it ships with, and its absolute directory. The instructions are authoritative: follow them rather than improvising. Run any script it lists from that directory, for example with execute_command and the absolute path as its `directory' argument.

Skills may be grouped into subdirectories, so the same name can exist in more than one group; the index then shows such a skill by its path relative to the skill directory (e.g. \"engineering/code-review\"), and calling it by that path always works.

Use `file' together with `name' to read one of the files the skill lists, such as \"references/REFERENCE.md\" or \"scripts/extract.py\". The path is relative to the skill directory and may not point outside it."
   :args (list '(:name "name"
                       :type string
                       :description "Name of the skill to load, exactly as the index lists it: either a bare skill name or a path relative to the skill directory when the index shows one. Omit it to list the available skills."
                       :optional t)
               '(:name "file"
                       :type string
                       :description "Optional file inside the named skill, relative to the skill directory, e.g. \"references/REFERENCE.md\". Requires `name'."
                       :optional t))
   :category "skills"))

;;-------------------------------------------------------------------------
;; Sending a skill by hand
;;
;; The `skill' tool is the model's way in: it lists, then loads what it
;; decided it needs.  These commands are the user's way in, for the cases
;; where waiting for the model to choose is the wrong thing -- you know the
;; skill applies, or the backend or model in use cannot call tools at all.
;;
;; Sending means attaching the skill's text to the gptel context, which
;; travels with every request until it is removed.  The text is held in a
;; buffer rather than a file so that it carries what activation carries --
;; directory and file list included -- and so that nothing temporary is left
;; on disk.
;;-------------------------------------------------------------------------
(defvar-local gptel-yatools-skills--attached nil
  "Name of the skill this context buffer was created for, or nil.

Set in the buffers the manual-send commands attach to the gptel context.
It is what lets the header-line indicator find them again, so what it
shows always matches what gptel will actually send: removing the context
through gptel's own commands takes the buffer with it.")

(defun gptel-yatools-skills--attached-buffers ()
  "Return the context buffers this package attached to `gptel-context'."
  (cl-remove-if-not (lambda (source)
                      (and (buffer-live-p source)
                           (buffer-local-value 'gptel-yatools-skills--attached
                                               source)))
                    (mapcar (lambda (entry) (car (ensure-list entry)))
                            gptel-context)))

(defun gptel-yatools-skills--attached-names ()
  "Return the names of the skills currently attached to the context."
  (mapcar (lambda (buffer)
            (buffer-local-value 'gptel-yatools-skills--attached buffer))
          (gptel-yatools-skills--attached-buffers)))

(defun gptel-yatools-skills--handle (skill &optional ambiguous)
  "Return the name to show for SKILL: its path when its name is not unique.

AMBIGUOUS is the list of names that occur more than once, from
`gptel-yatools-skills--duplicate-names'.  Passing it in keeps callers
from rescanning the skill directories once per skill."
  (if (member (plist-get skill :name) ambiguous)
      (plist-get skill :relative)
    (plist-get skill :name)))

(defun gptel-yatools-skills--payload-buffer (skill &optional ambiguous)
  "Return a new buffer holding SKILL's payload, marked with its handle."
  (let* ((handle (gptel-yatools-skills--handle skill ambiguous))
         (buffer (generate-new-buffer (format "*gptel skill: %s*" handle))))
    (with-current-buffer buffer
      (insert (gptel-yatools-skills--payload skill))
      (setq-local gptel-yatools-skills--attached handle)
      (goto-char (point-min)))
    buffer))

(defun gptel-yatools-skills--detach (buffer)
  "Remove BUFFER from the gptel context and kill it."
  (when (buffer-live-p buffer)
    (setq gptel-context (assq-delete-all buffer gptel-context))
    (kill-buffer buffer)))

(defun gptel-yatools-skills--attach (skill &optional ambiguous)
  "Attach SKILL to the gptel context, replacing an earlier copy of it.

Re-attaching is what you do after editing a skill, so the old copy has
to go rather than pile up to be sent twice."
  (let ((handle (gptel-yatools-skills--handle skill ambiguous)))
    (dolist (buffer (gptel-yatools-skills--attached-buffers))
      (when (equal (buffer-local-value 'gptel-yatools-skills--attached buffer)
                   handle)
        (gptel-yatools-skills--detach buffer)))
    (let ((buffer (gptel-yatools-skills--payload-buffer skill ambiguous)))
      ;; `gptel-context' accepts `(BUFFER)' entries directly, so no
      ;; overlay is needed and nothing in the chat buffer is touched.
      (push (list buffer) gptel-context)
      buffer)))

(defun gptel-yatools-skills--insert (skill)
  "Insert SKILL's payload at point, as text in the current buffer."
  (let ((start (point)))
    (insert (format "The following skill is active for this request.\n\n%s\n"
                    (gptel-yatools-skills--payload skill)))
    (goto-char start)))

(defun gptel-yatools-skills--candidates (skills)
  "Return an alist of (DISPLAY . SKILL) for completion over SKILLS.

DISPLAY is the handle, which is unique: when two skills would show the
same handle their roots are appended to tell them apart."
  (let ((ambiguous (gptel-yatools-skills--duplicate-names skills))
        (seen (make-hash-table :test #'equal))
        (result nil))
    (dolist (skill skills)
      (let* ((handle (gptel-yatools-skills--handle skill ambiguous))
             (display (if (gethash handle seen)
                          (format "%s (%s)" handle
                                  (directory-file-name (plist-get skill :root)))
                        handle)))
        (puthash handle t seen)
        (push (cons display skill) result)))
    (nreverse result)))

(defun gptel-yatools-skills--resolve (candidates name)
  "Return the skill NAME refers to, or nil.

NAME is what completion returned: a display string from CANDIDATES, or
free text the user typed, which is looked up the way the tool would."
  (or (cdr (assoc name candidates))
      (pcase (gptel-yatools-skills--lookup
              (mapcar #'cdr candidates) name)
        (`(:skill ,skill) skill)
        (_ nil))))

(defun gptel-yatools-skills--add-names (names &optional insert)
  "Add the skills called NAMES, or insert them at point if INSERT is non-nil.

This is the work behind `gptel-yatools-skills-add', split out so it can
be called (and tested) without a prompt.  Returns the list of skills
actually sent."
  (require 'gptel-context)
  (let* ((found (gptel-yatools-skills--discover))
         (skills (plist-get found :skills))
         (ambiguous (gptel-yatools-skills--duplicate-names skills))
         (candidates (gptel-yatools-skills--candidates skills))
         (sent nil))
    (dolist (name names)
      (let ((skill (gptel-yatools-skills--resolve candidates name)))
        (cond
         ((null skill)
          (message "gptel: no skill named %S; %s" name
                   (if skills "run `gptel-yatools-skills-add' to pick one"
                     "no skills were found at all")))
         ((plist-get skill :problems)
          (message "gptel: %s cannot be used: %s"
                   (gptel-yatools-skills--handle skill ambiguous)
                   (car (plist-get skill :problems))))
         (t
          (if insert
              (gptel-yatools-skills--insert skill)
            (gptel-yatools-skills--attach skill ambiguous))
          (push skill sent)))))
    (when (and sent (not insert))
      (message "gptel: sending %s with each request (`gptel-yatools-skills-remove' to stop)"
               (mapconcat (lambda (skill)
                            (gptel-yatools-skills--handle skill ambiguous))
                          (nreverse sent) ", ")))
    (nreverse sent)))

(defun gptel-yatools-skills--completion-table (candidates)
  "Return a completion table over CANDIDATES, annotated with descriptions.

CANDIDATES is the alist from `gptel-yatools-skills--candidates'.  The
annotation is what makes the choice possible without loading each skill
first, which is the point of the index.  Typing a name that is not on
the list is allowed: the caller resolves it the way the tool does."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata
          (annotation-function
           . ,(lambda (candidate)
                (when-let* ((skill (cdr (assoc candidate candidates)))
                            (description
                             (gptel-yatools-skills--field
                              (plist-get skill :frontmatter) "description")))
                  (concat "  " (truncate-string-to-width
                                description 80 nil nil t))))))
      (complete-with-action action (mapcar #'car candidates) string predicate))))

;;;###autoload
(defun gptel-yatools-skills-add (names &optional insert)
  "Send Agent Skills to the model with the next request.

With no prefix argument the skills are attached to the gptel context,
so they travel with every request until removed with
`gptel-yatools-skills-remove' or gptel's own context commands.

With a prefix argument they are inserted at point instead: the text
becomes part of the conversation and is sent once, which is useful when
you want to see and edit exactly what is being sent, or when
`gptel-use-context' is off.

NAMES is a list of skills, completed from everything
`gptel-yatools-skill-directories' holds."
  (interactive
   (let* ((skills (plist-get (gptel-yatools-skills--discover) :skills))
          (candidates (gptel-yatools-skills--candidates skills))
          (chosen (completing-read-multiple
                   "Skill (comma separated): "
                   (gptel-yatools-skills--completion-table candidates))))
     (list chosen current-prefix-arg)))
  (gptel-yatools-skills--add-names names insert))

;;;###autoload
(defun gptel-yatools-skills-remove (names)
  "Stop sending skills previously added with `gptel-yatools-skills-add'."
  (interactive
   (list (completing-read-multiple
          "Skill to stop sending (comma separated, empty for all): "
          (gptel-yatools-skills--attached-names))))
  (let ((attached (gptel-yatools-skills--attached-buffers)))
    (if (null attached)
        (message "gptel: no skills are attached to the context")
      (let ((wanted (delq nil (mapcar (lambda (name)
                                        (unless (string-empty-p name) name))
                                      names))))
        (dolist (buffer attached)
          (let ((name (buffer-local-value 'gptel-yatools-skills--attached buffer)))
            (when (or (null wanted) (member name wanted))
              (gptel-yatools-skills--detach buffer))))
        (message "gptel: skills now sent: %s"
                 (let ((left (gptel-yatools-skills--attached-names)))
                   (if left (mapconcat #'identity left ", ") "none")))))))

(defun gptel-yatools-skills--header-line-label ()
  "Return the header-line label counting the skills attached to the context.

The names used to be spelled out here, which cost more room the more
skills were attached.  Only the count is shown now; the names are one
click, or one `help-echo', away."
  (when-let* ((names (gptel-yatools-skills--attached-names)))
    (let ((count (length names)))
      (propertize
       (buttonize
        (format "[Skills: %d]" count)
        (lambda (&rest _)
          (message "Skills sent with each request: %s"
                   (mapconcat #'identity (gptel-yatools-skills--attached-names)
                              ", "))))
       'mouse-face 'highlight
       'help-echo (format "%d skill%s attached to the gptel context; click to list them"
                          count (if (= count 1) "" "s"))))))

(unless (memq #'gptel-yatools-skills--header-line-label
              gptel-yatools-header-line-extra-functions)
  (add-to-list 'gptel-yatools-header-line-extra-functions
               #'gptel-yatools-skills--header-line-label))

;;-------------------------------------------------------------------------
;; Interactive browsing
;;
;; A skill is a plain directory of files, so nothing about it can be debugged
;; through a chat: you need to see which skills were discovered, from where,
;; and which ones fail validation.  This buffer is that view, and RET opens
;; the `SKILL.md' to edit.
;;-------------------------------------------------------------------------
(defvar gptel-yatools-skills-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'gptel-yatools-skills-visit)
    map)
  "Keymap for `gptel-yatools-skills-list-mode'.")

(defun gptel-yatools-skills-visit ()
  "Visit the `SKILL.md' of the skill on the current line."
  (interactive)
  (let ((skill (tabulated-list-get-id)))
    (if (not (and skill (plist-get skill :path)))
        (user-error "No skill on this line")
      (find-file (plist-get skill :path)))))

(defun gptel-yatools-skills--status (skill)
  "Return a short status string for SKILL."
  (cond ((plist-get skill :problems) "invalid")
        ((plist-get skill :warnings) "warning")
        (t "ok")))

(define-derived-mode gptel-yatools-skills-list-mode tabulated-list-mode "Skills"
  "Major mode for browsing the Agent Skills found on disk.

Each skill is listed with its validation status; RET visits its
`SKILL.md'.  The header line names any root that could not be read.

\\{gptel-yatools-skills-list-mode-map}"
  (setq tabulated-list-format [("Name" 30 t)
                               ("Status" 9 t)
                               ("Description" 0 nil)
                               ("Directory" 40 t)])
  (setq tabulated-list-padding 2)
  (let* ((found (gptel-yatools-skills--discover))
         (skills (plist-get found :skills))
         (ambiguous (gptel-yatools-skills--duplicate-names skills)))
    (setq tabulated-list-entries
          (mapcar (lambda (skill)
                    (list skill
                          (vector (if (member (plist-get skill :name) ambiguous)
                                      (plist-get skill :relative)
                                    (plist-get skill :name))
                                  (gptel-yatools-skills--status skill)
                                  (or (gptel-yatools-skills--field
                                       (plist-get skill :frontmatter)
                                       "description")
                                      "")
                                  (directory-file-name
                                   (plist-get skill :directory)))))
                  skills))
    (setq header-line-format
          (when-let* ((notes (plist-get found :notes)))
            (concat " " (mapconcat #'identity notes "; ")))))
  (tabulated-list-init-header))

;;;###autoload
(defun gptel-yatools-skills ()
  "Browse the Agent Skills found in `gptel-yatools-skill-directories'."
  (interactive)
  (let ((buffer (get-buffer-create "*gptel skills*")))
    (with-current-buffer buffer
      (gptel-yatools-skills-list-mode)
      (tabulated-list-print t)
      (goto-char (point-min)))
    (pop-to-buffer buffer)))

(provide 'gptel-yatools-skills)
;;; gptel-yatools-skills.el ends here
