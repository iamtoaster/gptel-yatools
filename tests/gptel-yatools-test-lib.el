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

(defmacro gptel-yatools-test--in-dir (&rest body)
  "Run BODY with `default-directory' in a fresh temp dir, then delete it."
  (declare (indent 0) (debug t))
  `(let* ((gptel-yatools-test--dir (file-name-as-directory
                                (make-temp-file "gptel-yatools-test-" t)))
          (default-directory gptel-yatools-test--dir))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory gptel-yatools-test--dir t)))))

(defmacro gptel-yatools-test--vfs (&rest body)
  "Run BODY with a fresh private VFS in the current buffer."
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

Returns whatever the tool returned."
  (with-current-buffer caller
    (let* ((result nil)
           (gptel--fsm-last
            (gptel-make-fsm :state 'TOOL :info (list :buffer owner))))
      (gptel--accept-tool-calls
       (list (list tool args (lambda (value) (setq result value)))))
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

(provide 'gptel-yatools-test-lib)
;;; gptel-yatools-test-lib.el ends here
