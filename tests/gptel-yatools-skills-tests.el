;;; gptel-yatools-skills-tests.el --- Tests for the Agent Skills tool  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Loaded on demand only, like the main suite.  See the usage notes at the
;; top of `gptel-yatools-tests.el'; this file shares its helpers, so loading
;; it loads the main suite too, and the two are run together:
;;
;;   emacs -Q --batch -L . -l gptel-yatools.el \
;;     -l tests/gptel-yatools-tests.el -l tests/gptel-yatools-skills-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; No test may prompt the user, and every one works in a throwaway temp
;; directory with the skill roots pointed at it, so the real configuration is
;; never touched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-yatools)
(require 'gptel-yatools-skills)

(defconst gptel-yatools-skills-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this test file, used to find its siblings.")

;; The temp-dir, VFS and tool-lookup helpers live in the shared test library.
(unless (featurep 'gptel-yatools-test-lib)
  ;; Loaded by path, not by feature: a suite has to work from a checkout
  ;; without the tests directory being on `load-path'.
  (load (expand-file-name "gptel-yatools-test-lib.el"
                          (file-name-directory
                           (or load-file-name buffer-file-name)))
        nil 'nosuffix))

;;;; Helpers

(defun gptel-yatools-skills-test--skill (root name &optional frontmatter body)
  "Create skill NAME under ROOT and return its directory.

FRONTMATTER, when given, replaces the `---' block's contents; BODY
replaces the Markdown below it.  The directory always gets a
`references/' file, so that activation has something to list."
  (let* ((dir (expand-file-name name root))
         (references (expand-file-name "references" dir)))
    (make-directory references t)
    (gptel-yatools-test--write
     (expand-file-name "REFERENCE.md" references)
     (format "Reference for %s.\n" name))
    (gptel-yatools-test--write
     (expand-file-name "SKILL.md" dir)
     (concat "---\n"
             (or frontmatter
                 (format "name: %s\ndescription: A skill that does %s. Use it for %s.\n"
                         name name name))
             "---\n\n"
             (or body (format "Follow the %s procedure.\n" name))))
    dir))

(defmacro gptel-yatools-skills-test--with-roots (roots &rest body)
  "Run BODY with `gptel-yatools-skill-directories' bound to ROOTS."
  (declare (indent 1) (debug t))
  `(let ((gptel-yatools-skill-directories ,roots))
     ,@body))

(defun gptel-yatools-skills-test--call (&rest args)
  "Call the `skill' tool with ARGS and return its response."
  (apply (gptel-yatools-test--tool "skill") args))

(defun gptel-yatools-skills-test--add (name &optional insert)
  "Add skill NAME with the manual-send path, returning what it sent.
INSERT is passed through: non-nil inserts at point instead of attaching."
  (gptel-yatools-skills--add-names (list name) insert))

(defmacro gptel-yatools-skills-test--indexed (root &rest body)
  "Run BODY in a temp VFS with ROOT as the only skill directory."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (gptel-yatools-test--vfs
       (gptel-yatools-skills-test--with-roots (list ,root)
         ,@body))))

;;;; 1. Discovery

(ert-deftest gptel-yatools-skills-test-tool-is-registered ()
  "The skill tool must be a normal tool of this package."
  (let ((tool (gptel-yatools-test--tool-spec "skill")))
    (should (equal (gptel-tool-category tool) "skills"))
    ;; Loading a skill is only a read, so it must not ask for confirmation.
    (should-not (gptel-tool-confirm tool))
    (should (equal (mapcar (lambda (arg) (plist-get arg :name))
                           (gptel-tool-args tool))
                   '("name" "file" "timeout")))))

(ert-deftest gptel-yatools-skills-test-roots-accept-functions ()
  "A function may stand in for one root, or for the whole list."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file ".agents/skills")))
      (gptel-yatools-skills-test--skill root "one")
      (should (string-match-p
               "one — "
               (gptel-yatools-skills-test--indexed (lambda () root)
                 (gptel-yatools-skills-test--call))))
      (should (string-match-p
               "one — "
               (with-temp-buffer
                 (gptel-yatools-test--vfs
                   (gptel-yatools-skills-test--with-roots (lambda () (list root))
                     (gptel-yatools-skills-test--call)))))))))

(ert-deftest gptel-yatools-skills-test-relative-root-uses-workspace ()
  "A relative root must resolve against the workspace, not `default-directory'."
  (gptel-yatools-test--in-dir
    (gptel-yatools-skills-test--skill
     (gptel-yatools-test--root-file ".agents/skills") "relative")
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (gptel-yatools-skills-test--with-roots '(".agents/skills")
          (should (string-match-p "relative — "
                                  (gptel-yatools-skills-test--call))))))))

(ert-deftest gptel-yatools-skills-test-broken-root-is-reported ()
  "A root that cannot be used must be reported, not silently skipped."
  (gptel-yatools-test--in-dir
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (gptel-yatools-skills-test--with-roots
            (list (lambda () (error "no project"))
                  (gptel-yatools-test--root-file "nope"))
          (let ((out (gptel-yatools-skills-test--call)))
            (should (string-match-p "No skills found" out))
            (should (string-match-p "no project" out))
            (should (string-match-p "do not exist" out))))))))

(ert-deftest gptel-yatools-skills-test-nested-skills-are-found ()
  "A skill inside a group directory must be found, listed and loadable."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (dir (gptel-yatools-skills-test--skill
                 (expand-file-name "engineering" root) "code-review")))
      ;; `--skill' puts the skill in ROOT/NAME, so this laid it out as
      ;; skills/engineering/code-review, the grouped arrangement.
      (gptel-yatools-skills-test--indexed root
        (let ((index (gptel-yatools-skills-test--call)))
          (should (string-match-p "code-review — " index))
          (should (string-match-p "1 skill available" index)))
        (let ((out (gptel-yatools-skills-test--call "code-review")))
          (should (string-match-p "Skill: code-review" out))
          (should (string-match-p "Follow the code-review procedure." out))
          (should (string-match-p
                   (regexp-quote (directory-file-name dir))
                   out)))))))

(ert-deftest gptel-yatools-skills-test-group-path-is-a-handle ()
  "A skill can be loaded by its path relative to the root."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill
       (expand-file-name "engineering" root) "tdd")
      (gptel-yatools-skills-test--indexed root
        (let ((out (gptel-yatools-skills-test--call "engineering/tdd")))
          (should (string-match-p "Skill: tdd" out)))
        ;; ... and by the bare name, since it is unique.
        (should (string-match-p "Skill: tdd"
                                (gptel-yatools-skills-test--call "tdd")))))))

(ert-deftest gptel-yatools-skills-test-ambiguous-name-is-refused ()
  "A name in two groups must be reported, not resolved to the first one."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill
       (expand-file-name "engineering" root) "review" nil "Engineering body.\n")
      (gptel-yatools-skills-test--skill
       (expand-file-name "productivity" root) "review" nil "Productivity body.\n")
      (gptel-yatools-skills-test--indexed root
        (let ((index (gptel-yatools-skills-test--call)))
          (should (string-match-p "2 skills available" index))
          ;; Both are listed, each by the path that identifies it.
          (should (string-match-p "engineering/review — " index))
          (should (string-match-p "productivity/review — " index))
          (should (string-match-p "occur more than once" index)))
        (let ((out (gptel-yatools-skills-test--call "review")))
          (should (string-match-p "matches 2 skills" out))
          (should (string-match-p "engineering/review" out))
          (should (string-match-p "productivity/review" out))
          ;; Neither body leaked: nothing was picked.
          (should-not (string-match-p "Engineering body" out))
          (should-not (string-match-p "Productivity body" out)))
        ;; Each path still loads exactly its own skill.
        (should (string-match-p
                 "Engineering body"
                 (gptel-yatools-skills-test--call "engineering/review")))
        (should (string-match-p
                 "Productivity body"
                 (gptel-yatools-skills-test--call "productivity/review")))))))

(ert-deftest gptel-yatools-skills-test-same-name-in-two-roots-is-ambiguous ()
  "Two roots holding one name each must be reported too, not deduplicated."
  (gptel-yatools-test--in-dir
    (let* ((first (gptel-yatools-test--root-file "a"))
           (second (gptel-yatools-test--root-file "b")))
      (gptel-yatools-skills-test--skill first "twice" nil "First.\n")
      (gptel-yatools-skills-test--skill second "twice" nil "Second.\n")
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (gptel-yatools-skills-test--with-roots (list first second)
            (should (string-match-p "2 skills available"
                                    (gptel-yatools-skills-test--call)))
            (let ((out (gptel-yatools-skills-test--call "twice")))
              (should (string-match-p "matches 2 skills" out))
              (should (string-match-p "twice" out)))))))))

(ert-deftest gptel-yatools-skills-test-overlapping-roots-list-a-skill-once ()
  "The same directory reached through two roots must not be listed twice."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (inner (expand-file-name "engineering" root)))
      (gptel-yatools-skills-test--skill inner "once")
      (with-temp-buffer
        (gptel-yatools-test--vfs
          ;; The second root is inside the first: every skill under it is
          ;; reachable both ways.
          (gptel-yatools-skills-test--with-roots (list root inner)
            (let ((index (gptel-yatools-skills-test--call)))
              (should (string-match-p "1 skill available" index))
              (should (= 1 (gptel-yatools-test--occurrences
                            index "once —"))))))))))

(ert-deftest gptel-yatools-skills-test-depth-limit-is-reported ()
  "A skill below the depth limit must be visible as a prune, not vanish."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      ;; skills/a/b/c/deep/SKILL.md: a skill at level 4.
      (gptel-yatools-skills-test--skill
       (expand-file-name "a/b/c" root) "deep")
      (gptel-yatools-skills-test--indexed root
        ;; `let' evaluates its init forms before binding, so the depth has to
        ;; be bound first and the call made in the body.
        (let ((gptel-yatools-skill-search-depth 2))
          (let ((index (gptel-yatools-skills-test--call)))
            (should (string-match-p "No skills found" index))
            (should (string-match-p "not searched deeper: a/b" index))
            (should (string-match-p "skill-search-depth" index))))
        ;; With the default depth it is found.
        (should (string-match-p "deep — " (gptel-yatools-skills-test--call)))
        (should (string-match-p "Skill: deep"
                                (gptel-yatools-skills-test--call "deep")))))))

(ert-deftest gptel-yatools-skills-test-skill-subdirectories-are-not-skills ()
  "A directory inside a skill must not be mistaken for a skill."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (dir (gptel-yatools-skills-test--skill root "outer")))
      ;; A nested SKILL.md inside a skill's own references directory.
      (make-directory (expand-file-name "references/inner" dir) t)
      (gptel-yatools-test--write (expand-file-name "references/inner/SKILL.md" dir)
                                 "---\nname: inner\ndescription: Inner.\n---\n")
      (gptel-yatools-skills-test--indexed root
        (let ((index (gptel-yatools-skills-test--call)))
          (should (string-match-p "1 skill available" index))
          (should-not (string-match-p "inner" index)))))))

;;;; 2. The index

(ert-deftest gptel-yatools-skills-test-index-is-name-and-description ()
  "The no-argument call must be the cheap metadata layer."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "beta" nil "Beta body.\n")
      (gptel-yatools-skills-test--skill root "alpha" nil "Alpha body.\n")
      (gptel-yatools-skills-test--indexed root
        (let ((out (gptel-yatools-skills-test--call)))
          (should (string-match-p "2 skills available" out))
          ;; Both skills, alphabetically, name first.
          (should (string-match-p "alpha — A skill that does alpha" out))
          (should (string-match-p "beta — A skill that does beta" out))
          (should (< (string-match "alpha —" out) (string-match "beta —" out)))
          ;; Metadata only: the instructions are not in the index.
          (should-not (string-match-p "Beta body" out))
          (should-not (string-match-p "REFERENCE.md" out)))))))

;;;; 3. Loading a skill

(ert-deftest gptel-yatools-skills-test-activation-includes-body-and-files ()
  "Loading must return the instructions, the file tree and the directory."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill
       root "pdf-processing"
       (concat "name: pdf-processing\n"
               "description: Extract PDF text. Use for PDFs.\n"
               "license: Apache-2.0\n"
               "compatibility: Needs qpdf\n"
               "metadata:\n"
               "  author: example-org\n"
               "  version: \"1.0\"\n"
               "allowed-tools: Bash(git:*) Read\n")
       "Step one: run scripts/extract.py.\n")
      (gptel-yatools-skills-test--indexed root
        (let ((out (gptel-yatools-skills-test--call "pdf-processing")))
          (should (string-match-p "Skill: pdf-processing" out))
          (should (string-match-p "Description: Extract PDF text" out))
          (should (string-match-p "License: Apache-2.0" out))
          (should (string-match-p "Compatibility: Needs qpdf" out))
          (should (string-match-p "Allowed tools: Bash(git:\\*) Read" out))
          (should (string-match-p "author: example-org" out))
          (should (string-match-p "version: 1\\.0" out))
          ;; The absolute directory, so scripts can be run from it.
          (should (string-match-p
                   (regexp-quote (directory-file-name
                                  (expand-file-name "pdf-processing" root)))
                   out))
          ;; The file tree, one level into `references/'.
          (should (string-match-p "references/" out))
          (should (string-match-p "REFERENCE.md" out))
          ;; And the instructions themselves.
          (should (string-match-p "Step one: run scripts/extract.py." out)))))))

(ert-deftest gptel-yatools-skills-test-name-mismatch-warns-but-loads ()
  "A `name' that disagrees with the directory is a warning, not a refusal."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill
       root "on-disk" "name: something-else\ndescription: Mismatched.\n")
      (gptel-yatools-skills-test--indexed root
        (let ((out (gptel-yatools-skills-test--call "on-disk")))
          (should (string-match-p "does not match the directory name" out))
          (should (string-match-p "Follow the on-disk procedure." out)))
        (should (string-match-p "on-disk — Mismatched."
                                (gptel-yatools-skills-test--call)))))))

(ert-deftest gptel-yatools-skills-test-invalid-skill-is-listed-not-loadable ()
  "A skill without a valid `description' must be visible but refused."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "broken" "name: broken\n")
      (gptel-yatools-skills-test--skill root "fine")
      (gptel-yatools-skills-test--indexed root
        (let ((index (gptel-yatools-skills-test--call)))
          (should (string-match-p "broken — (no description)" index))
          (should (string-match-p "cannot be loaded" index)))
        (let ((out (gptel-yatools-skills-test--call "broken")))
          (should (string-match-p "cannot be loaded" out))
          (should (string-match-p "`description' field is missing" out))
          ;; Nothing of the refused skill leaks into the response.
          (should-not (string-match-p "Follow the broken procedure" out)))
        (should (string-match-p "Follow the fine procedure."
                                (gptel-yatools-skills-test--call "fine")))))))

(ert-deftest gptel-yatools-skills-test-no-frontmatter-is-a-problem ()
  "A `SKILL.md' without a frontmatter block must be reported as such."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (dir (gptel-yatools-skills-test--skill root "bare")))
      (gptel-yatools-test--write (expand-file-name "SKILL.md" dir)
                                 "# Just a heading\n")
      (gptel-yatools-skills-test--indexed root
        (should (string-match-p
                 "does not start with a `---' YAML frontmatter block"
                 (gptel-yatools-skills-test--call "bare")))))))

(ert-deftest gptel-yatools-skills-test-unknown-name-lists-the-alternatives ()
  "An unknown name must tell the model what it could have asked for."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "real")
      (gptel-yatools-skills-test--indexed root
        (let ((out (gptel-yatools-skills-test--call "imaginary")))
          (should (string-match-p "no skill named \"imaginary\"" out))
          (should (string-match-p "Available skills: real" out)))))))

(ert-deftest gptel-yatools-skills-test-name-validation-ignores-case-folding ()
  "An uppercase `name' must be rejected even with `case-fold-search' on."
  (let ((frontmatter (list (cons "name" "Upper-Case")
                           (cons "description" "Has an uppercase name."))))
    (should (plist-get (gptel-yatools-skills--validate frontmatter "Upper-Case")
                       :problems))))

(ert-deftest gptel-yatools-skills-test-non-mapping-frontmatter-is-reportable ()
  "Frontmatter that is not a mapping must be described, not signal.

YAML happily parses a bare list or a bare scalar, so the frontmatter
reaches the renderers as a vector or a string; every lookup has to
survive that."
  (dolist (frontmatter (list ["a" "b"] "scalar" '("a" "b")))
    (let ((checked (gptel-yatools-skills--validate frontmatter "dir")))
      (should (string-match-p "not a key/value mapping"
                              (car (plist-get checked :problems)))))
    (should-not (gptel-yatools-skills--field frontmatter "name"))
    (should-not (gptel-yatools-skills--metadata-lines frontmatter))
    (should (string-match-p "(no description)"
                            (gptel-yatools-skills--index-line
                             (list :name "dir" :frontmatter frontmatter
                                   :problems '("broken")))))))

(ert-deftest gptel-yatools-skills-test-index-truncates-long-descriptions ()
  "One bad description must not crowd out the rest of the index."
  (let* ((long (make-string 5000 ?x))
         (line (gptel-yatools-skills--index-line
                (list :name "verbose"
                      :frontmatter (list (cons "description" long))))))
    (should (<= (length line) (+ gptel-yatools-skills--index-description-limit 20)))
    (should (string-suffix-p "…" line))))

(ert-deftest gptel-yatools-skills-test-invalid-yaml-is-one-problem ()
  "A broken YAML block must be reported once, not also as an empty one."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (dir (gptel-yatools-skills-test--skill root "unparsable")))
      (gptel-yatools-test--write (expand-file-name "SKILL.md" dir)
                                 "---\nname: [unclosed\n---\n\nBody.\n")
      (gptel-yatools-skills-test--indexed root
        (let ((out (gptel-yatools-skills-test--call "unparsable")))
          (should (string-match-p "not valid YAML" out))
          (should-not (string-match-p "frontmatter is empty" out)))))))

;;;; 4. Reading a file the skill references

(ert-deftest gptel-yatools-skills-test-file-is-readable ()
  "A relative path inside the skill must be returned."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "reader")
      (gptel-yatools-skills-test--indexed root
        (let ((out (gptel-yatools-skills-test--call
                    "reader" "references/REFERENCE.md")))
          (should (string-match-p "Reference for reader." out))
          (should (string-match-p "File: references/REFERENCE.md" out)))))))

(ert-deftest gptel-yatools-skills-test-file-cannot-escape-the-skill ()
  "Absolute paths, `..' segments and escaping symlinks must be refused."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (dir (gptel-yatools-skills-test--skill root "contained"))
           (outside (gptel-yatools-test--root-file "outside.txt")))
      (gptel-yatools-test--write outside "secret\n")
      (make-symbolic-link outside (expand-file-name "link.txt" dir))
      (gptel-yatools-skills-test--indexed root
        (dolist (file (list "../outside.txt"
                            outside
                            "references/../../outside.txt"
                            "link.txt"))
          (let ((out (gptel-yatools-skills-test--call "contained" file)))
            (should (string-match-p "not a readable file inside the skill" out))
            (should-not (string-match-p "secret" out))))))))

(ert-deftest gptel-yatools-skills-test-file-needs-a-name ()
  "`file' without `name' is a mistake worth explaining, not a crash."
  (gptel-yatools-skills-test--indexed nil
    (let ((out (gptel-yatools-skills-test--call nil "references/REFERENCE.md")))
      (should (string-match-p "needs both `name' and `file'" out)))))

;;;; 5. Interplay with the rest of the package

(ert-deftest gptel-yatools-skills-test-pending-vfs-copy-wins ()
  "A pending edit to `SKILL.md' must be what the tool reads."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (dir (gptel-yatools-skills-test--skill root "edited")))
      (gptel-yatools-skills-test--indexed root
        (gptel-yatools-vfs-put
         (expand-file-name "SKILL.md" dir)
         "---\nname: edited\ndescription: Edited copy.\n---\n\nUnsynced body.\n")
        (let ((out (gptel-yatools-skills-test--call "edited")))
          (should (string-match-p "Unsynced body." out))
          (should-not (string-match-p "Follow the edited procedure." out)))))))

;;;; 5b. The parse cache

(ert-deftest gptel-yatools-skills-test-parse-cache-keeps-two-chats-apart ()
  "Two chats holding different pending copies must each parse their own.

The cache is global and keyed by content, so this is the property that
makes it safe: identical text shares a parse, different text cannot.
Keying by path instead would hand the first chat's parse to the second,
which is the cross-chat leak the buffer-local VFS exists to prevent."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (dir (gptel-yatools-skills-test--skill root "shared"))
           (path (expand-file-name "SKILL.md" dir)))
      (gptel-yatools-skills-test--with-roots (list root)
        ;; Chat A holds one pending version...
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (gptel-yatools-vfs-put
             path "---\nname: shared\ndescription: From chat A.\n---\n\nBody A.\n")
            (let ((out (gptel-yatools-skills-test--call "shared")))
              (should (string-match-p "Body A." out))
              (should (string-match-p "From chat A." out)))))
        ;; ...chat B holds a different one, at the same path.
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (gptel-yatools-vfs-put
             path "---\nname: shared\ndescription: From chat B.\n---\n\nBody B.\n")
            (let ((out (gptel-yatools-skills-test--call "shared")))
              (should (string-match-p "Body B." out))
              (should (string-match-p "From chat B." out))
              (should-not (string-match-p "Body A." out)))))
        ;; And a third chat with no pending copy sees disk, not either cache.
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (let ((out (gptel-yatools-skills-test--call "shared")))
              (should (string-match-p "Follow the shared procedure." out))
              (should-not (string-match-p "Body A." out)))))))))

(ert-deftest gptel-yatools-skills-test-parse-cache-is-not-invalidated-by-reload ()
  "The cache must be free to keys it does not own.

Nothing calls into it to invalidate: a changed file is simply a key that
was never seen.  This pins that down, because it is the reason the VFS
needs no hook to keep the catalog honest."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (dir (gptel-yatools-skills-test--skill root "drifting"))
           (path (expand-file-name "SKILL.md" dir)))
      (gptel-yatools-skills-test--indexed root
        (should (string-match-p "Follow the drifting procedure."
                                (gptel-yatools-skills-test--call "drifting")))
        ;; The file changes on disk, with no cache call in between.
        (gptel-yatools-test--write
         path "---\nname: drifting\ndescription: Rewritten.\n---\n\nNew body.\n")
        (let ((out (gptel-yatools-skills-test--call "drifting")))
          (should (string-match-p "New body." out))
          (should-not (string-match-p "Follow the drifting procedure." out)))))))

(ert-deftest gptel-yatools-skills-test-parse-cache-does-not-grow-forever ()
  "Editing a skill repeatedly must not grow the cache without bound."
  (gptel-yatools-test--in-dir
    (let* ((root (gptel-yatools-test--root-file "skills"))
           (dir (gptel-yatools-skills-test--skill root "churn"))
           (path (expand-file-name "SKILL.md" dir)))
      (gptel-yatools-skills-test--indexed root
        (dotimes (i (+ gptel-yatools-skills--parse-cache-limit 20))
          (gptel-yatools-test--write
           path (format "---\nname: churn\ndescription: Version %d.\n---\n\nBody %d.\n"
                        i i))
          (gptel-yatools-skills-test--call "churn"))
        (should (<= (hash-table-count gptel-yatools-skills--parse-cache)
                    gptel-yatools-skills--parse-cache-limit))
        ;; And the newest version is still the one served, parsed or not.
        (should (string-match-p
                 (format "Body %d\\." (1- (+ gptel-yatools-skills--parse-cache-limit 20)))
                 (gptel-yatools-skills-test--call "churn")))))))

(ert-deftest gptel-yatools-skills-test-tool-survives-a-reload ()
  "Reloading the package must not drop the tool from its list.

The tool is built by a function that the main file calls inside its own
tool list; anything that appended to the list as a side effect of loading
would vanish here, because the reload resets the list while the skill
library stays loaded."
  (load gptel-yatools-test--file nil t)
  (should (cl-find "skill" gptel-yatools--tools
                   :key #'gptel-tool-name :test #'equal))
  (should (= 1 (length (cl-remove-if-not
                        (lambda (tool) (equal (gptel-tool-name tool) "skill"))
                        gptel-yatools--tools)))))

(ert-deftest gptel-yatools-skills-test-listing-command-shows-what-it-found ()
  "`gptel-yatools-skills' must show the discovered skills and their status."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "good")
      (gptel-yatools-skills-test--skill root "bad" "name: bad\n")
      (gptel-yatools-skills-test--with-roots (list root)
        (gptel-yatools-skills)
        (unwind-protect
            (with-current-buffer "*gptel skills*"
              (should (derived-mode-p 'gptel-yatools-skills-list-mode))
              (should (string-match-p "good" (buffer-string)))
              (should (string-match-p "invalid" (buffer-string)))
              ;; RET has something to visit.
              (goto-char (point-min))
              (let ((skill (tabulated-list-get-id)))
                (should (equal (plist-get skill :name) "bad"))
                (should (file-regular-p (plist-get skill :path)))))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer "*gptel skills*")))))))

(ert-deftest gptel-yatools-skills-test-malformed-description-does-not-crash ()
  "A description that is not a string must not break the views that show it.

`description: [one, two]' is a YAML list: validation correctly marks the
skill invalid, but the browser is where an invalid skill is meant to be
seen.  `tabulated-list-print' signalled `wrong-type-argument listp' and
the completion annotation signalled `wrong-type-argument stringp'."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill
       root "listy" "name: listy\ndescription: [one, two]\n")
      (gptel-yatools-skills-test--indexed root
        (let* ((found (gptel-yatools-skills--discover))
               (skill (car (plist-get found :skills)))
               (candidates (gptel-yatools-skills--candidates
                            (plist-get found :skills))))
          ;; The field is malformed, and validation says so.
          (should (plist-get skill :problems))
          ;; Every rendering of it survives.
          (should (stringp (gptel-yatools-skills--payload skill)))
          (should (stringp (gptel-yatools-skills--index-line skill)))
          (let* ((table (gptel-yatools-skills--completion-table candidates))
                 (annotate (cdr (assq 'annotation-function
                                      (funcall table "" nil 'metadata)))))
            (should (stringp (or (funcall annotate (caar candidates)) ""))))))
      ;; And the browser prints the invalid skill instead of erroring.
      (gptel-yatools-skills-test--indexed root
        (gptel-yatools-skills)
        (unwind-protect
            (with-current-buffer "*gptel skills*"
              (should (string-match-p "listy" (buffer-string)))
              (should (string-match-p "invalid" (buffer-string))))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer "*gptel skills*")))))))

;;; 6. Sending a skill by hand

(ert-deftest gptel-yatools-skills-test-payload-matches-what-the-tool-returns ()
  "The manual payload must be what the tool would have returned."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "shared")
      (gptel-yatools-skills-test--indexed root
        (let* ((skill (car (plist-get (gptel-yatools-skills--discover) :skills)))
               (payload (gptel-yatools-skills--payload skill))
               (response (gptel-yatools-skills-test--call "shared")))
          (should (string-match-p "Skill: shared" payload))
          (should (string-match-p "Follow the shared procedure." payload))
          (should (string-match-p "REFERENCE.md" payload))
          ;; The tool wraps the same text, so the body appears once there.
          (should (string-match-p (regexp-quote "Follow the shared procedure.")
                                  response))
          (should (= 1 (gptel-yatools-test--occurrences
                        response "Follow the shared procedure."))))))))

(ert-deftest gptel-yatools-skills-test-add-attaches-to-the-context ()
  "Adding a skill must put its text in `gptel-context', once."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "sent")
      (gptel-yatools-skills-test--indexed root
        (let ((gptel-context nil))
          (unwind-protect
              (progn
                (should (gptel-yatools-skills-test--add "sent"))
                (should (= 1 (length gptel-context)))
                (let* ((buffer (car (car gptel-context)))
                       (text (with-current-buffer buffer (buffer-string))))
                  (should (buffer-live-p buffer))
                  (should (string-match-p "Follow the sent procedure." text))
                  ;; The indicator follows gptel's own state, and shows the
                  ;; count rather than the names, which can be long.
                  (should (equal (gptel-yatools-skills--attached-names)
                                 '("sent")))
                  (let ((label (gptel-yatools-skills--header-line-label)))
                    (should (equal label "[Skills: 1]"))
                    ;; The names are still reachable through the tooltip.
                    (should (string-match-p "1 skill attached"
                                            (get-text-property 0 'help-echo
                                                               label)))))
                ;; Adding it again replaces the copy instead of doubling it.
                (should (gptel-yatools-skills-test--add "sent"))
                (should (= 1 (length gptel-context))))
            (dolist (entry gptel-context)
              (when (buffer-live-p (car entry)) (kill-buffer (car entry))))))))))

(ert-deftest gptel-yatools-skills-test-header-line-counts-skills ()
  "The header-line label must show how many skills are attached, not their names."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "first")
      (gptel-yatools-skills-test--skill root "second")
      (gptel-yatools-skills-test--indexed root
        (let ((gptel-context nil))
          (unwind-protect
              (progn
                (gptel-yatools-test--silencing-message
                  (gptel-yatools-skills--add-names (list "first" "second")))
                (let ((label (gptel-yatools-skills--header-line-label)))
                  (should (equal label "[Skills: 2]"))
                  ;; Neither name survives in the label itself.
                  (should-not (string-match-p "first" label))
                  (should-not (string-match-p "second" label))
                  (should (string-match-p "2 skills attached"
                                          (get-text-property 0 'help-echo
                                                             label)))))
            (dolist (entry gptel-context)
              (when (buffer-live-p (car entry)) (kill-buffer (car entry))))))))))

(ert-deftest gptel-yatools-skills-test-remove-detaches ()
  "Removing a skill must drop it from the context and kill its buffer."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "gone")
      (gptel-yatools-skills-test--indexed root
        (let ((gptel-context nil))
          (unwind-protect
              (progn
                (gptel-yatools-skills-test--add "gone")
                (let ((buffer (car (car gptel-context))))
                  (gptel-yatools-test--silencing-message
                    (gptel-yatools-skills-remove (list "gone")))
                  (should-not (buffer-live-p buffer)))
                (should-not gptel-context)
                (should-not (gptel-yatools-skills--attached-names))
                (should-not (gptel-yatools-skills--header-line-label)))
            (dolist (entry gptel-context)
              (when (buffer-live-p (car entry)) (kill-buffer (car entry))))))))))

(ert-deftest gptel-yatools-skills-test-add-with-prefix-inserts-instead ()
  "With a prefix argument the text must land in the buffer, not the context."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "inline")
      (gptel-yatools-skills-test--indexed root
        (let ((gptel-context nil))
          (with-temp-buffer
            (gptel-yatools-skills-test--add "inline" 'insert)
            (should (string-match-p "The following skill is active" (buffer-string)))
            (should (string-match-p "Follow the inline procedure." (buffer-string))))
          (should-not gptel-context))))))

(ert-deftest gptel-yatools-skills-test-add-refuses-unknown-and-invalid ()
  "An unknown or unusable skill must not reach the context."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "fine")
      (gptel-yatools-skills-test--skill root "broken" "name: broken\n")
      (gptel-yatools-skills-test--indexed root
        (let ((gptel-context nil))
          (gptel-yatools-test--silencing-message
            (should-not (gptel-yatools-skills-test--add "imaginary"))
            (should-not (gptel-yatools-skills-test--add "broken")))
          (should-not gptel-context))))))

(ert-deftest gptel-yatools-skills-test-add-completes-by-path-when-ambiguous ()
  "The completion candidates must identify each skill when names clash.

Discovery decides the handle once, so no caller has to work out which
names are ambiguous in order to show one."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill (expand-file-name "a" root) "clash")
      (gptel-yatools-skills-test--skill (expand-file-name "b" root) "clash")
      (gptel-yatools-skills-test--indexed root
        (let* ((skills (plist-get (gptel-yatools-skills--discover) :skills))
               (candidates (gptel-yatools-skills--candidates skills)))
          (should (equal (mapcar #'car candidates) '("a/clash" "b/clash")))
          (should (equal (gptel-yatools-skills-handle
                          (cdr (assoc "a/clash" candidates)))
                         "a/clash"))
          ;; The handle is on the skill itself, decided at discovery.
          (should (equal (gptel-yatools-skills-handle (car skills)) "a/clash"))
          ;; A unique name keeps its bare name as the handle.
          (gptel-yatools-skills-test--skill (expand-file-name "c" root) "solo")
          (let ((solo (cl-find "solo"
                               (plist-get (gptel-yatools-skills--discover) :skills)
                               :key (lambda (skill) (plist-get skill :name))
                               :test #'equal)))
            (should (equal (gptel-yatools-skills-handle solo) "solo"))))))))

(ert-deftest gptel-yatools-skills-test-indicator-follows-gptels-own-removal ()
  "Removing the context in gptel's own way must clear the indicator too.

The indicator reads `gptel-context' rather than a list of its own, so
there is no second state to fall out of sync."
  (gptel-yatools-test--in-dir
    (let ((root (gptel-yatools-test--root-file "skills")))
      (gptel-yatools-skills-test--skill root "borrowed")
      (gptel-yatools-skills-test--indexed root
        (let ((gptel-context nil)
              (buffer nil))
          (unwind-protect
              (progn
                (gptel-yatools-test--silencing-message
                  (gptel-yatools-skills-test--add "borrowed"))
                (should (equal (gptel-yatools-skills--attached-names) '("borrowed")))
                (setq buffer (car (car gptel-context)))
                (require 'gptel-context)
                (gptel-yatools-test--silencing-message
                  (gptel-context-remove buffer))
                (should-not (gptel-yatools-skills--attached-names))
                (should-not (gptel-yatools-skills--header-line-label)))
            ;; gptel's own removal drops the entry but leaves the buffer;
            ;; kill it here so this test does not leak one whose
            ;; `default-directory' is a temp directory about to vanish.
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(provide 'gptel-yatools-skills-tests)
;;; gptel-yatools-skills-tests.el ends here
