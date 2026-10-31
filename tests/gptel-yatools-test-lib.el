;;; gptel-yatools-test-lib.el --- Shared helpers for the gptel-yatools tests  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Helpers shared by every test file of this package.  They are kept out of
;; the test files themselves so that each suite can be loaded on its own:
;; loading `gptel-yatools-vfs-tests.el' must not be a roundabout way of
;; loading the tests for the shell and Elisp tools.
;;
;; No helper here may prompt the user.  Each test runs synchronously in the
;; current Emacs, so a modal question (a coding system, "Save file?", a sync
;; confirmation) would block the user's session -- and in batch would read
;; from stdin and abort -- while also touching whatever buffer the user was
;; editing.  `gptel-yatools-test--noninteractive' turns prompts into errors,
;; and the helpers below keep file buffers private.
;;
;; Every test works in a throwaway temp directory and a private, buffer-local
;; VFS, so the real workspace and the real VFS are untouched.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'gptel-yatools)

;;;; Helpers

(defconst gptel-yatools-test--file
  (expand-file-name "gptel-yatools.el"
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory (or load-file-name buffer-file-name)))))
  "The package file these tests exercise.")

(defun gptel-yatools-test--run-batch (form)
  "Evaluate FORM in a fresh `emacs --batch -Q' and return (STATUS . OUTPUT).

Used for tests that need a *fresh* Emacs: what loading the package
does to gptel's global state cannot be observed in an Emacs whose
registry already holds the tools.  FORM is printed with `prin1' so it
travels intact.

The script re-creates this Emacs's `load-path', and puts this package's
directory first, so that everything resolves exactly as it does here."
  (let* ((dir (make-temp-file "gptel-batch-" t))
         (script (expand-file-name "probe.el" dir))
         (package-dir (file-name-directory gptel-yatools-test--file))
         (emacs (or (and invocation-directory invocation-name
                         (expand-file-name invocation-name invocation-directory))
                    (executable-find "emacs")
                    "emacs")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n"
                    ;; Re-create this Emacs's load-path, so gptel is found.
                    (format "(setq load-path (cons %S (quote %S)))\n"
                            package-dir load-path)
                    (format "%S\n" form)))
          (with-temp-buffer
            (let ((status (call-process emacs nil t nil "-Q" "--batch"
                                        "-l" script)))
              (cons status (buffer-string)))))
      (ignore-errors (delete-directory dir t)))))

(defun gptel-yatools-test--tool (name)
  "Return the callable implementing the gptel tool NAME.

The callable is the tool boundary itself: it renders the tool's result,
and turns a signalled error into the same envelope.  So a call made
through it returns exactly what the model would see, which is what tests
should assert on."
  (let ((tool (cl-find name gptel-yatools--tools
                       :key #'gptel-tool-name :test #'equal)))
    (unless tool (error "No such tool registered: %s" name))
    (gptel-tool-function tool)))

(defun gptel-yatools-test--should-be-enveloped (text)
  "Assert that TEXT is a tool envelope the model can actually be sent.

Every tool response must carry both tags, and must survive JSON
serialisation: a raw byte anywhere in it (a file name that does not
decode, say) used to make `json-serialize' refuse the whole request."
  (should (stringp text))
  (should (string-prefix-p "<tool_context " text))
  (should (string-match-p "<tool_response>" text))
  (should (string-suffix-p "</tool_response>" text))
  (should-not (cl-some (lambda (c) (eq (char-charset c) 'eight-bit))
                       (string-to-list text)))
  (should (condition-case nil (progn (json-serialize text) t)
            (error nil))))

(defun gptel-yatools-test--tool-spec (name)
  "Return the `gptel-tool' struct registered as NAME.

`gptel-yatools-test--tool' returns the callable inside it, which is what a
direct call needs; gptel's dispatcher, by contrast, takes the struct."
  (let ((tool (cl-find name gptel-yatools--tools
                       :key #'gptel-tool-name :test #'equal)))
    (unless tool (error "No such tool registered: %s" name))
    tool))

(defun gptel-yatools-test--preview (name arg-plist)
  "Return the confirmation text gptel would show for a call to NAME.

ARG-PLIST is the call's arguments as gptel receives them from the
model.  The text is produced by walking exactly the path gptel walks
when it renders a pending call: `gptel--map-tool-args' turns the plist
into the positional argument list the tool itself receives, and that
list -- not the plist -- is what the registered preview-setup function
is called with.  A preview that reads the plist instead of the list
renders every argument as nil, which is the failure this helper exists
to catch."
  (let* ((spec (gptel-yatools-test--tool-spec name))
         (setup (car (cdr (assoc name gptel--tool-preview-alist))))
         (arg-values (gptel--map-tool-args spec arg-plist)))
    (unless (functionp setup)
      (error "No preview registered for %s" name))
    (with-temp-buffer
      (funcall setup arg-values nil)
      (buffer-string))))

(defun gptel-yatools-test--raw (file)
  "Return FILE's bytes as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun gptel-yatools-test--write (file content)
  "Write CONTENT to FILE, replacing it, without coding prompts.

CONTENT is often a unibyte string holding arbitrary bytes (Latin-1
text, a BOM, binary data).  Letting `write-region' pick a coding
system for it makes Emacs ask the user to choose one, which a test
must never do; and choosing UTF-8 would corrupt the bytes.  Write
multibyte text as UTF-8 and unibyte bytes verbatim instead."
  (let ((coding-system-for-write
         (if (multibyte-string-p content) 'utf-8-unix 'no-conversion)))
    (with-temp-file file (insert content))))

(defvar gptel-yatools-test--dir nil
  "Root of the throwaway workspace the current test is running in.")

(defvar gptel-yatools-test--root nil
  "The workspace root the current test's tools resolve relative paths against.

Declared special so that `gptel-yatools-test--root-file' reads the
binding `gptel-yatools-test--in-dir' establishes, rather than a nil
global.")

(defun gptel-yatools-test--root-file (name)
  "Return NAME as a path under the fixture's workspace root.

A test that writes a file and then hands the tool a relative path has to
write it where that relative path points: the workspace root.  Spelling
that out through this helper keeps the tests honest about which base the
tools are supposed to use, instead of writing to `default-directory' and
hoping the two are the same directory."
  (expand-file-name name gptel-yatools-test--root))

(defun gptel-yatools-test--project-find (dir)
  "Return the throwaway workspace as a project when DIR is inside it.

Installed into `project-find-functions' by `gptel-yatools-test--in-dir'
so that the fixture has a real workspace root that is *not* the buffer's
`default-directory'.  A `transient' project is used rather than a `.git'
directory so the fixture does not depend on git being installed, and so
that it models what the tools actually read -- a root -- rather than
what happens to produce one."
  (when (and gptel-yatools-test--dir
             (string-prefix-p gptel-yatools-test--dir
                              (file-name-as-directory (expand-file-name dir))))
    (cons 'transient gptel-yatools-test--dir)))

(defmacro gptel-yatools-test--in-dir (&rest body)
  "Run BODY in a fresh temp workspace, from a subdirectory of its root.

`default-directory' is `sub/' inside the workspace root, not the root
itself.  That is the ordinary case -- you start a chat from a file in
`proj/src/' -- and it is the case the path tools used to get wrong: a
relative path the model writes means the workspace root, while the
buffer's own `default-directory' is somewhere else.  Splitting them here
means a tool that resolves against `default-directory' fails a test
instead of passing by coincidence.

The two bases are checked to be different, so a fixture that silently
collapsed them again could not quietly weaken every test in the suite.
Tests reach the root itself with `gptel-yatools-test--root' and the
buffer's own directory with `default-directory'."
  (declare (indent 0) (debug t))
  `(let* ((gptel-yatools-test--dir (file-name-as-directory
                                    (make-temp-file "gptel-yatools-test-" t)))
          (gptel-yatools-test--root gptel-yatools-test--dir)
          (gptel-yatools-test--subdir
           (expand-file-name "sub/" gptel-yatools-test--dir))
          (project-find-functions
           (cons #'gptel-yatools-test--project-find project-find-functions)))
     (make-directory gptel-yatools-test--subdir t)
     (let ((default-directory gptel-yatools-test--subdir))
       (when (equal (gptel-yatools--detect-workspace-root)
                    (file-name-as-directory default-directory))
         (error "test fixture: the workspace root (%S) and `default-directory' (%S) must differ, else the path tests test nothing"
                gptel-yatools-test--root default-directory))
       (unwind-protect (progn ,@body)
         (ignore-errors (delete-directory gptel-yatools-test--dir t))))))

(defmacro gptel-yatools-test--vfs (&rest body)
  "Run BODY with a fresh private VFS in the current buffer.

The table is bound with `let', so it is visible from buffers BODY creates
as well.  That is what most tests want, but a test that has to catch a
mistake about buffer-local state -- rendering a diff in the review buffer
instead of the caller's, say -- has to bind `gptel-yatools-vfs' itself."
  (declare (indent 0) (debug t))
  `(let ((gptel-yatools-vfs (make-hash-table :test #'equal)))
     (setq gptel-yatools-vfs--header-line-cache nil)
     ,@body))

(defmacro gptel-yatools-test--with-file (file content &rest body)
  "Write CONTENT to FILE, then run BODY in a buffer with a private VFS."
  (declare (indent 2) (debug t))
  `(progn
     (gptel-yatools-test--write ,file ,content)
     (with-temp-buffer
       (gptel-yatools-test--vfs ,@body))))

(defmacro gptel-yatools-test--with-open-buffer (file &rest body)
  "Visit FILE in a real buffer, run BODY in that buffer, then kill it.

BODY must run with the visited buffer current: tests use this macro
to make the file buffer dirty (`insert', `goto-char') and then check
what `file_sync' does with it.  Running BODY in whatever buffer ERT
happened to start in would edit that buffer instead -- including a
real gptel chat buffer -- and leave the file buffer untouched."
  (declare (indent 1) (debug t))
  `(let ((gptel-yatools-test--buf nil))
     (unwind-protect
         (progn
           (setq gptel-yatools-test--buf (find-file-noselect ,file))
           (with-current-buffer gptel-yatools-test--buf
             ,@body))
       (when (buffer-live-p gptel-yatools-test--buf)
         ;; Several tests deliberately leave the visiting buffer modified
         ;; (that is the condition they exercise).  Killing it without first
         ;; clearing the flag makes Emacs ask "Save file ...?", a modal
         ;; question in the middle of a test run.  The file is a throwaway
         ;; temp file, so drop the unsaved state instead.
         (with-current-buffer gptel-yatools-test--buf
           (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil))
           (kill-buffer gptel-yatools-test--buf))))))

(defmacro gptel-yatools-test--silencing-message (&rest body)
  "Run BODY with `message' made harmless, returning BODY's value."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
     ,@body))

(defmacro gptel-yatools-test--noninteractive (&rest body)
  "Run BODY with every user prompt turned into an error.

A test must never ask the user anything: in a batch run a modal
question reads from stdin and fails with `end-of-file', and in an
interactive session it steals focus and waits.  Turning prompts into
errors makes such a test fail immediately and point at the code path
that prompted, instead of hanging or corrupting the user's buffers."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'yes-or-no-p)
              (lambda (&rest args)
                (error "Test tried to ask the user a question: %S" args)))
             ((symbol-function 'y-or-n-p)
              (lambda (&rest args)
                (error "Test tried to ask the user a question: %S" args)))
             ((symbol-function 'read-string)
              (lambda (&rest args)
                (error "Test tried to read input from the user: %S" args)))
             ((symbol-function 'read-from-minibuffer)
              (lambda (&rest args)
                (error "Test tried to read input from the user: %S" args)))
             ((symbol-function 'completing-read)
              (lambda (&rest args)
                (error "Test tried to read input from the user: %S" args)))
             ((symbol-function 'select-safe-coding-system)
              (lambda (&rest args)
                (error "Test tried to make the user choose a coding system: %S"
                       args)))
             ((symbol-function 'kill-buffer--possibly-save)
              (lambda (&rest _) t)))
     ,@body))

(defun gptel-yatools-test--request-buffer (&optional name)
  "Return a fresh buffer that owns a buffer-local VFS, like a chat buffer.

The VFS is installed with `setq-local' and not with the `let'-based
`gptel-yatools-test--vfs' helper on purpose: a dynamic binding of an
automatically buffer-local variable is visible from every buffer, which
would hide exactly the bug these tests exist to catch."
  (let ((buffer (generate-new-buffer (or name " *gptel-yatools-test-request*"))))
    (with-current-buffer buffer
      (setq-local gptel-yatools-vfs (make-hash-table :test #'equal))
      (setq-local gptel-yatools-vfs--header-line-cache nil))
    buffer))

(defun gptel-yatools-test--kill-request-buffer (buffer)
  "Kill BUFFER without letting the unsynced-VFS guard ask a question."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (local-variable-p 'gptel-yatools-vfs) (clrhash gptel-yatools-vfs)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(defun gptel-yatools-test--accept-in (caller owner tool args)
  "Run TOOL with positional ARGS in OWNER, confirmed from CALLER.

The call goes through gptel's own dispatcher, `gptel--accept-tool-calls',
with a throwaway `gptel--fsm-last' pointing at OWNER -- the shape
`gptel--inspect-tool-calls' leaves behind.  Calling the tool function
directly would run in CALLER and pass even while the dispatch bug is
present, which is why no test in this section does that.

A tool that delivers asynchronously returns from the dispatcher before its
result exists, so the loop below waits for the callback.  It gives up
after a hard deadline rather than hanging the suite: a test that can wait
forever is not a test.

Returns whatever the tool returned, or signalled if it never returned."
  (with-current-buffer caller
    (let* ((result nil)
           (delivered nil)
           (gptel--fsm-last
            (gptel-make-fsm :state 'TOOL :info (list :buffer owner))))
      (gptel--accept-tool-calls
       (list (list tool args (lambda (value)
                               (setq result value delivered t)))))
      (let ((deadline (+ (float-time) 20)))
        (while (and (not delivered) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (unless delivered
        (error "The tool never delivered a result within 20 seconds"))
      result)))

(defun gptel-yatools-test--advice-count (symbol advice)
  "Return how many times ADVICE is installed on SYMBOL."
  (let ((count 0))
    (advice-mapc (lambda (installed &rest _)
                   (when (eq installed advice) (setq count (1+ count))))
                 symbol)
    count))

(defun gptel-yatools-test-run (&optional selector)
  "Run the gptel-yatools regression tests, never prompting the user.

SELECTOR defaults to every `gptel-yatools-test-' test.  Returns the ERT
stats object; inspect it or look at the *ert* buffer for failures."
  (interactive)
  (require 'ert)
  (gptel-yatools-test--noninteractive
    (ert-run-tests-batch (or selector "^gptel-yatools-test-"))))


(defun gptel-yatools-test--occurrences (string substring)
  "Return how many times SUBSTRING occurs in STRING."
  (let ((count 0)
        (position 0)
        (step (length substring)))
    (while (and position (setq position (string-match (regexp-quote substring)
                                                      string position)))
      (setq count (1+ count)
            position (+ position step)))
    count))

;;;; A remote workspace, without a network
;;
;; What makes a file name "remote" to Emacs is a handler in
;; `file-name-handler-alist', not its syntax.  So the remote-workspace
;; tests install a stand-in handler under a prefix no TRAMP method claims
;; and no real file has: the package cannot tell it from `/ssh:host:/',
;; and no test needs a connection.  The handler answers only the
;; questions these tests ask -- and sits exactly where it matters, between
;; `gptel-yatools--run-process' and `make-process'.
;;
;; This is a stand-in, not a TRAMP emulator.  It cannot prove how TRAMP
;; behaves; that was established against a real host and is recorded in
;; the README's remote-workspace section.  It does pin the two things this
;; package is responsible for: that a remote name is recognised, and that
;; a remote process is asked for the way TRAMP needs it.

(defvar gptel-yatools-test--remote-prefix "/gptel-test-remote:host:"
  "The remote file-name prefix the remote-workspace tests use.

The host part is a placeholder: the stand-in handler answers for any host
under this method, so a test can name a second machine
\(`gptel-yatools-test--remote-prefix-for') and check that the package
notices they are not the same one.")

(defconst gptel-yatools-test--remote-method "/gptel-test-remote:"
  "The method every stand-in host shares, up to the host name.")

(defun gptel-yatools-test--remote-prefix-for (host)
  "Return the stand-in prefix naming HOST."
  (concat gptel-yatools-test--remote-method host ":"))

(defun gptel-yatools-test--remote-connection (name)
  "Return the stand-in connection prefix of NAME, or nil.

That is the part `file-remote-p' reports for a real handler: the method
and host, ending at the colon before the local name."
  (when (string-prefix-p gptel-yatools-test--remote-method name)
    (when (string-match
           (concat "\\`\\(" (regexp-quote gptel-yatools-test--remote-method)
                   "[^:/]*:\\)")
           name)
      (match-string 1 name))))

(defvar gptel-yatools-test--remote-root nil
  "The temp directory the stand-in host maps its root onto.")

(defvar gptel-yatools-test--remote-executables '("/bin/sh" "/bin/ash" "ash")
  "The paths the stand-in host reports as executable.")

(defvar gptel-yatools-test--remote-process-args nil
  "The argument lists `make-process' received through the stand-in host.")

(defun gptel-yatools-test--remote-handler (operation &rest args)
  "Stand in for a TRAMP file-name handler, for OPERATION with ARGS.

Only what the remote-workspace tests need is answered.  The operations
Emacs requires a *name* answer for are implemented rather than left to a
fallback: a handler that returns nil for one of those is reported as
\"Invalid handler in `file-name-handler-alist'\", so `file-name-as-
directory' and friends are answered on the name's local part and given
the prefix back."
  (let ((local (lambda (name)
                 (if-let* ((prefix (gptel-yatools-test--remote-connection name)))
                     (string-remove-prefix prefix name)
                   name))))
    (pcase operation
      ('file-remote-p (gptel-yatools-test--remote-connection (car args)))
      ;; TRAMP answers this with a *local* directory so that a synchronous
      ;; `call-process' runs here instead of trying to chdir on the host;
      ;; `vfs_diff' depends on it, since it diffs local temp copies.
      ('unhandled-file-name-directory temporary-file-directory)
      ('file-executable-p
       (member (funcall local (car args))
               gptel-yatools-test--remote-executables))
      ((or 'file-name-directory 'file-name-as-directory)
       (let ((rest (funcall local (car args))))
         (concat (gptel-yatools-test--remote-connection (car args))
                 (file-name-as-directory (if (string-empty-p rest) "/" rest)))))
      ('file-name-nondirectory
       (file-name-nondirectory (funcall local (car args))))
      ('directory-file-name
       (concat (gptel-yatools-test--remote-connection (car args))
               (directory-file-name (funcall local (car args)))))
      ('expand-file-name
       ;; An absolute local name is returned unchanged, as TRAMP does:
       ;; that is how `expand-file-name' lets a local absolute path escape
       ;; a remote root, and what `execute_command' has to refuse.
       (let ((name (car args))
             (dir (car (cdr args))))
         (cond ((string-prefix-p gptel-yatools-test--remote-method name) name)
               ((file-name-absolute-p name) name)
               (t (concat (if (and dir (string-prefix-p
                                        gptel-yatools-test--remote-method dir))
                              dir
                            (or (and dir (gptel-yatools-test--remote-connection
                                          dir))
                                gptel-yatools-test--remote-prefix))
                          name)))))
      ('file-truename (car args))
      ('abbreviate-file-name (car args))
      ('file-relative-name (car args))
      ;; Nothing exists on the stand-in host except its root: that is what
      ;; makes the ancestor walk have to stop by itself.
      ('file-directory-p
       (let ((name (file-name-as-directory (car args))))
         (or (equal name (file-name-as-directory
                          (or (gptel-yatools-test--remote-connection (car args))
                              "")))
             (equal name (file-name-as-directory
                          (or gptel-yatools-test--remote-root ""))))))
      ('file-regular-p nil)
      ('file-exists-p
       (equal (file-name-as-directory (car args))
              (file-name-as-directory
               (or (gptel-yatools-test--remote-connection (car args)) ""))))
      ('make-directory t)
      ('make-process
       (push (copy-sequence args) gptel-yatools-test--remote-process-args)
       ;; Run it for real, but locally: the shell the package picks is
       ;; "/bin/sh", which also exists here, so the argv under test is
       ;; exercised end to end rather than only inspected.
       (let ((file-name-handler-alist nil)
             (default-directory (or gptel-yatools-test--remote-root
                                    temporary-file-directory)))
         (apply #'make-process args)))
      (_ nil))))

(defmacro gptel-yatools-test--with-remote (&rest body)
  "Run BODY in a workspace whose root is on a stand-in remote host.

The root is the stand-in prefix, `default-directory' is that root, and
the handler above is installed, so `file-remote-p' answers with a host --
which is the only signal the package has that it is on another machine."
  (declare (indent 0) (debug t))
  `(let* ((gptel-yatools-test--remote-root
           (file-name-as-directory (make-temp-file "gptel-test-remote-" t)))
          (gptel-yatools-test--remote-process-args nil)
          ;; A host is probed once; a test must not inherit the previous
          ;; test's answer.
          (gptel-yatools--remote-shell-cache (make-hash-table :test #'equal))
          (file-name-handler-alist
           (cons (cons (concat "\\`" (regexp-quote gptel-yatools-test--remote-method))
                       #'gptel-yatools-test--remote-handler)
                 file-name-handler-alist))
          (default-directory (file-name-as-directory
                              gptel-yatools-test--remote-prefix)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory gptel-yatools-test--remote-root t)))))

(defun gptel-yatools-test--stated-timeouts (text)
  "Return the seconds every \"N seconds\" in TEXT names, in order.

Used to compare what two audiences are told about a budget without
depending on how either sentence is phrased around the number.  Filled
prose breaks lines wherever the column ends, so the whitespace is
normalised first: a number and the word \"seconds\" are one fact even when
a newline falls between them."
  (let ((rest (and (stringp text)
                   (replace-regexp-in-string "[ \t\n]+" " " text)))
        (found nil))
    (while (and rest (string-match "\\([0-9]+\\) seconds" rest))
      (push (match-string 1 rest) found)
      (setq rest (substring rest (match-end 0))))
    (nreverse found)))

(provide 'gptel-yatools-test-lib)
;;; gptel-yatools-test-lib.el ends here
