;;; gptel-yatools-tests.el --- Tests for the package glue and shared tools  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The glue every tool leans on: the response envelope and its size limits,
;; the timeout guard, the registry and enabling, the buffer that owns a tool
;; call, and the shell and Elisp tools.
;;
;; The filesystem tests are in `gptel-yatools-vfs-tests.el', Agent Skills in
;; `gptel-yatools-skills-tests.el', and the helpers all three use in
;; `gptel-yatools-test-lib.el'.  Loaded on demand only -- deliberately NOT
;; part of the package, which is evaluated whenever a chat starts.
;;
;; Usage, from the repository root:
;;
;;   emacs -Q --batch -L . -L <dir-with-gptel> -L <dir-with-yaml> \
;;     -l gptel-yatools.el \
;;     -l tests/gptel-yatools-tests.el \
;;     -l tests/gptel-yatools-vfs-tests.el \
;;     -l tests/gptel-yatools-skills-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; Interactively: `M-x load-file RET tests/gptel-yatools-test-lib.el RET', then
;; the suite you want, then `M-x ert RET RET'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-yatools)
(unless (featurep 'gptel-yatools-test-lib)
  ;; Loaded by path, not by feature: a suite has to work from a checkout
  ;; without the tests directory being on `load-path'.
  (load (expand-file-name "gptel-yatools-test-lib.el"
                          (file-name-directory
                           (or load-file-name buffer-file-name)))
        nil 'nosuffix))

;;;; 6. Reloading doubled the tool list

(ert-deftest gptel-yatools-test-tools-have-no-duplicates ()
  "Each tool must be defined exactly once."
  (should (equal (length gptel-yatools--tools)
                 (length (delete-dups
                          (mapcar #'gptel-tool-name gptel-yatools--tools))))))


;;;; 8. Raw bytes made the response unserialisable (request died)

(ert-deftest gptel-yatools-test-responses-are-json-serialisable ()
  "A response carrying raw bytes must be escaped and serialisable."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (let ((out (gptel-yatools--wrap
                  nil "probe"
                  (string-to-multibyte (unibyte-string 233 0 255)))))
        (should-not (cl-some (lambda (c) (eq (char-charset c) 'eight-bit))
                             (string-to-list out)))
        (should (condition-case nil (progn (json-serialize out) t)
                  (error nil)))))))

(ert-deftest gptel-yatools-test-command-output-is-json-serialisable ()
  "Command output with raw bytes must not break the request either."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "raw.bin" default-directory)))
      (gptel-yatools-test--write file (unibyte-string 99 97 102 233 10))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (let ((out (funcall (gptel-yatools-test--tool "execute_command")
                              (format "cat %s" file))))
            (should (condition-case nil (progn (json-serialize out) t)
                      (error nil)))))))))


;;;; 21/22/23. Response size limits

(ert-deftest gptel-yatools-test-truncate-caps-lines ()
  "Long output must be capped and say how much was withheld."
  (let* ((text (mapconcat #'number-to-string (number-sequence 1 3000) "\n"))
         (out (gptel-yatools--truncate text)))
    (should (< (length out) (+ gptel-yatools--output-char-limit 1000)))
    (should (string-match-p "first 2000 of 3000 lines" out))))

(ert-deftest gptel-yatools-test-truncate-caps-after-escaping ()
  "The size cap must hold once raw bytes are expanded to \\xNN."
  (let* ((raw (string-to-multibyte
               (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert (make-string 30000 255))
                 (buffer-string))))
         (out (gptel-yatools--truncate raw)))
    (should (<= (length out) (+ gptel-yatools--output-char-limit 400)))
    (should (string-match-p "truncated" out))))

(ert-deftest gptel-yatools-test-truncate-leaves-small-text-alone ()
  "A short response must be returned verbatim, with no banner."
  (should (equal (gptel-yatools--truncate "abc\n") "abc\n"))
  (should (equal (gptel-yatools--truncate "") "")))

(ert-deftest gptel-yatools-test-truncate-tolerates-nil ()
  "A nil body must not signal."
  (should (equal (gptel-yatools--truncate nil) "")))

(ert-deftest gptel-yatools-test-hard-cut-keeps-escapes-intact ()
  "A cut must not leave a half-written \\xNN escape."
  (should (equal (gptel-yatools--hard-cut "ab\\xffcd" 4) "ab"))
  (should (equal (gptel-yatools--hard-cut "ab\\xffcd" 6) "ab\\xff"))
  (should (equal (gptel-yatools--hard-cut "abc" 2) "ab")))


;;;; 37. Missing/wrong-typed required tool arguments

(ert-deftest gptel-yatools-test-non-string-tool-arguments-are-clean ()
  "A nil or numeric path/command must yield a readable error."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (dolist (case '(("read_path" (nil))
                      ("read_file_from_offset" (nil 1 1))
                      ("fetch_lines_from_file_using_regex" (nil "x"))
                      ("execute_command" (nil))
                      ("write_file" (nil "x"))
                      ("write_file_diff" (nil "a" "b"))
                      ("file_sync" (42))
                      ("vfs_diff" (42))
                      ("vfs_discard" (42))))
        (let* ((name (car case))
               (args (cadr case))
               (err (should-error
                     (apply (gptel-yatools-test--tool name) args))))
          (should (string-match-p "must be a string" (cadr err))))))))


;;;; 40. `execute_elisp' output was unbounded

(ert-deftest gptel-yatools-test-execute-elisp-output-is-truncated ()
  "A `princ' loop must not return a 300k-character tool response."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (let ((out (funcall (gptel-yatools-test--tool "execute_elisp")
                          "(dotimes (_ 30000) (princ \"abcdefghij\"))")))
        (should (stringp out))
        (should (<= (length out) (+ gptel-yatools--output-char-limit 1000)))
        (should (string-match-p "truncated" out))
        (should (condition-case nil (progn (json-serialize out) t)
                  (error nil)))))))


;;;; 42. Loading the package must not depend on how gptel was loaded

(ert-deftest gptel-yatools-test-load-registers-without-enabling ()
  "Requiring the package must register every tool and enable none.

The tools have to be listed by `gptel-menu', which reads gptel's
registry, but nothing may be added to `gptel-tools': which tools a chat
sends is the user's decision, made with `gptel-yatools-enable'."
  (skip-unless (executable-find "emacs"))
  (let ((result
         (gptel-yatools-test--run-batch
          `(progn
             (require 'cl-lib)
             (require 'gptel-yatools)
             (princ (format "tools=%d enabled=%s registered=%d timeouts=%d\n"
                            (length gptel-yatools--tools)
                            gptel-tools
                            (length (cl-remove-if-not
                                     (lambda (tool)
                                       (gptel-get-tool (gptel-tool-name tool)))
                                     gptel-yatools--tools))
                            (cl-count-if
                             (lambda (tool)
                               (equal (plist-get
                                       (car (last (gptel-tool-args tool)))
                                       :name)
                                      "timeout"))
                             gptel-yatools--tools)))))))
    (should (equal (car result) 0))
    (should (string-match-p "tools=12 enabled=nil registered=12 timeouts=12"
                            (cdr result)))))

(ert-deftest gptel-yatools-test-package-compiles-without-warnings ()
  "The package must byte-compile, without a single warning.

This is the test the old `setf' workaround was written for: an accessor
the compiler cannot resolve becomes a call to an undefined
\`(setf ...)' function, which the compiler reports.  Compiling with
warnings promoted to errors pins that down for every accessor, not just
the one that used to break.

Both
modules are compiled too, main file last, and the copies are put on
`load-path' first so that the `require' inside the main file picks up
the just-compiled modules rather than the source ones."
  (skip-unless (executable-find "emacs"))
  (let ((result
         (gptel-yatools-test--run-batch
          `(progn
             (require 'bytecomp)
             (let* ((dir (make-temp-file "gptel-yatools-elc-" t))
                    (package-dir (file-name-directory ,gptel-yatools-test--file))
                    (files '("gptel-yatools-vfs.el"
                             "gptel-yatools-tools.el"
                             "gptel-yatools-skills.el"
                             "gptel-yatools.el")))
               (unwind-protect
                   (progn
                     (dolist (file files)
                       (copy-file (expand-file-name file package-dir)
                                  (expand-file-name file dir) nil 'silent))
                     (add-to-list 'load-path dir)
                     (let ((byte-compile-error-on-warn t))
                       (dolist (file files)
                         (unless (byte-compile-file (expand-file-name file dir))
                           (error "Could not compile %s" file))))
                     (princ "compiled\n"))
                 (ignore-errors (delete-directory dir t))))))))
    (should (equal (car result) 0))
    (should (string-match-p "compiled" (cdr result)))))

(ert-deftest gptel-yatools-test-enable-all-is-idempotent ()
  "Enabling every tool twice must not send any tool twice."
  (let ((gptel-tools nil))
    (gptel-yatools-enable-all)
    (let ((once (length gptel-tools)))
      (gptel-yatools-enable-all)
      (should (= (length gptel-tools) once)))
    (should (= (length gptel-tools) (length gptel-yatools--tools)))
    (should (= (length gptel-tools)
               (length (delete-dups
                        (mapcar #'gptel-tool-name gptel-tools)))))))

(ert-deftest gptel-yatools-test-enable-one-category ()
  "Enabling a category must add exactly that category's tools."
  (let ((gptel-tools nil))
    (gptel-yatools-enable "filesystem")
    (should (equal (sort (mapcar #'gptel-tool-name gptel-tools) #'string<)
                   (sort (mapcar #'gptel-tool-name
                                 (cl-remove-if-not
                                  (lambda (tool)
                                    (equal (gptel-tool-category tool)
                                           "filesystem"))
                                  gptel-yatools--tools))
                         #'string<)))
    (should (< (length gptel-tools) (length gptel-yatools--tools)))))

(ert-deftest gptel-yatools-test-enable-keeps-other-tools ()
  "Enabling this package's tools must not drop anyone else's."
  (let* ((foreign (gptel--make-tool :name "foreign_tool" :description "x"
                                    :function #'ignore :args nil))
         (gptel-tools (list foreign)))
    (gptel-yatools-enable "shell")
    (should (memq foreign gptel-tools))
    (should (cl-find "execute_command" gptel-tools
                     :key #'gptel-tool-name :test #'equal))))


;;;; 45. A trailing newline was counted as an extra line

(ert-deftest gptel-yatools-test-truncate-line-count-ignores-trailing-newline ()
  "Text of exactly the line limit must survive; counts must be real."
  (let* ((text (concat (mapconcat #'number-to-string
                                  (number-sequence 1 gptel-yatools--output-line-limit)
                                  "\n")
                       "\n"))
         (longer (concat text "2501\n")))
    (should (equal (gptel-yatools--truncate text) text))
    (should (string-match-p
             (format "first %d of %d lines"
                     gptel-yatools--output-line-limit
                     (1+ gptel-yatools--output-line-limit))
             (gptel-yatools--truncate longer)))))


;;;; 46. Messages mixed absolute and workspace-relative paths

(ert-deftest gptel-yatools-test-tool-messages-use-relative-paths ()
  "Paths in tool messages must be relative to the workspace root."
  (gptel-yatools-test--in-dir
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (funcall (gptel-yatools-test--tool "write_file") "p" "x\n")
        (let ((ancestor (funcall (gptel-yatools-test--tool "write_file")
                                 "p/child" "y\n"))
              (missing (funcall (gptel-yatools-test--tool "execute_command")
                                "true" "no/such"))
              (here (funcall (gptel-yatools-test--tool "execute_command")
                             "true")))
          (should (string-match-p "cannot write p/child: ancestor p"
                                  ancestor))
          (should-not (string-match-p (regexp-quote default-directory)
                                      ancestor))
          (should (string-match-p "does not exist: no/such" missing))
          ;; The workspace root itself is ".", not an empty string.
          (should (string-match-p "succeeded in \\. " here)))))))


;;;; 47. Buffer-local variables must stay special when compiled

(ert-deftest gptel-yatools-test-variables-are-declared-special ()
  "Variables that other files `let'-bind must be declared at top level.

A `defvar' hidden inside the quoted `use-package' body is invisible to
the byte compiler, which then binds the variable lexically and leaves
the real (buffer-local or global) value untouched."
  (dolist (symbol '(gptel-yatools-vfs gptel-yatools-vfs--header-line-cache
                   gptel-yatools--current-timeout gptel-yatools--timeout-suspended))
    (should (special-variable-p symbol))))


;;;; Invariants any future edit must not break

(ert-deftest gptel-yatools-test-all-tools-present ()
  "Every documented tool must stay registered."
  (dolist (name '("read_workspace_root" "read_path" "read_file_from_offset"
                  "fetch_lines_from_file_using_regex" "execute_command"
                  "write_file" "write_file_diff" "file_sync" "vfs_diff"
                  "vfs_discard" "execute_elisp" "skill"))
    (should (cl-find name gptel-yatools--tools
                     :key #'gptel-tool-name :test #'equal))))


;;;; 48. Tool calls could block Emacs forever

(ert-deftest gptel-yatools-test-every-tool-declares-a-timeout ()
  "Every tool must accept TIMEOUT and tell the model not to raise it."
  (dolist (tool gptel-yatools--tools)
    (unless (gptel-tool-async tool)
      (let ((description (gptel-tool-description tool))
            (args (gptel-tool-args tool)))
        (should (equal (plist-get (car (last args)) :name) "timeout"))
        (should (= 1 (cl-count-if (lambda (arg)
                                    (equal (plist-get arg :name) "timeout"))
                                  args)))
        ;; Exactly one note: installed twice, it must not pile up.
        (should (= 1 (gptel-yatools-test--occurrences description "Timeouts: ")))
        (should (string-match-p "do not raise the timeout unless"
                                description))))))

(ert-deftest gptel-yatools-test-timeout-resolution ()
  "The default timeout must be used unless the model overrides it."
  (should (= (gptel-yatools--resolve-timeout nil) gptel-yatools-timeout))
  (should (= (gptel-yatools--resolve-timeout 45) 45))
  (should (= (gptel-yatools--resolve-timeout "30") 30))
  ;; Unusable values fall back on the default instead of signalling.
  (should (= (gptel-yatools--resolve-timeout :json-false) gptel-yatools-timeout))
  (should (= (gptel-yatools--resolve-timeout 0) gptel-yatools-timeout))
  ;; A non-numeric setting must not break every tool call either.
  (let ((gptel-yatools-timeout "not a number"))
    (should (= (gptel-yatools--resolve-timeout nil) 120))))

(ert-deftest gptel-yatools-test-timeout-kills-command ()
  "A command that outlives the timeout must be killed, keeping its output."
  (let ((start (float-time))
        (out (funcall (gptel-yatools-test--tool "execute_command")
                      "echo started; sleep 20; echo finished" nil 1)))
    (should (string-match-p "1 second timeout" out))
    (should (string-match-p "started" out))
    (should-not (string-match-p "finished" out))
    (should (< (- (float-time) start) 10))))

(ert-deftest gptel-yatools-test-timeout-aborts-elisp ()
  "A form that outlives the timeout must be abandoned."
  (let ((out (funcall (gptel-yatools-test--tool "execute_elisp")
                      "(progn (sleep-for 20) 'finished)" 1)))
    (should (string-match-p "did not finish within its 1 second timeout" out))
    ;; The form never ran to completion: no evaluation report is returned.
    (should-not (string-match-p "Return value:" out))
    (should-not (string-match-p "Printed output:" out))))

(ert-deftest gptel-yatools-test-timeout-ignores-user-wait ()
  "Time the tool spends waiting for the user must not count."
  (should (eq (gptel-yatools--call-with-timeout
               (lambda ()
                 (let ((gptel-yatools--timeout-suspended t))
                   (sleep-for 2))
                 'reviewed)
               nil 1)
              'reviewed)))

(ert-deftest gptel-yatools-test-timeout-leaves-no-timer ()
  "A finished call must cancel its deadline timer."
  (gptel-yatools-test--in-dir
    (let ((before (length timer-list)))
      (dotimes (_ 5)
        (funcall (gptel-yatools-test--tool "read_workspace_root")))
      (should (= (length timer-list) before)))))

(ert-deftest gptel-yatools-test-timeout-install-is-idempotent ()
  "Installing the timeout twice must not duplicate the argument or the note.

`gptel--make-tool' is used instead of `gptel-make-tool' because the
latter also registers the tool in `gptel--known-tools', which the
suite must not pollute."
  (let ((tool (gptel--make-tool
               :name "probe_tool"
               :description "Probe."
               :function (lambda (x) x)
               :args (list (list :name "x" :type 'string :description "x")))))
    (gptel-yatools--install-timeout tool)
    (gptel-yatools--install-timeout tool)
    (should (= 1 (cl-count-if (lambda (arg)
                                (equal (plist-get arg :name) "timeout"))
                              (gptel-tool-args tool))))
    (should (= 1 (gptel-yatools-test--occurrences
                  (gptel-tool-description tool) "Timeouts: ")))
    ;; The guard must still pass the real arguments through.
    (should (equal (funcall (gptel-tool-function tool) "value" 5) "value"))))

(ert-deftest gptel-yatools-test-timeout-skips-async-tools ()
  "An asynchronous tool must be left exactly as it was.

Its result arrives long after the call returns, so wrapping it in a
deadline would only mislabel it as timed out while it still runs."
  (let* ((function (lambda (callback x) (funcall callback x)))
         (tool (gptel--make-tool
                :name "async_probe_tool"
                :async t
                :description "Probe."
                :function function
                :args (list (list :name "x" :type 'string :description "x")))))
    (gptel-yatools--install-timeout tool)
    (should (eq (gptel-tool-function tool) function))
    (should (equal (mapcar (lambda (arg) (plist-get arg :name))
                           (gptel-tool-args tool))
                   '("x")))))


;;;; 50. Tool calls must run in the buffer that owns the request

;; `gptel-yatools-vfs' and `default-directory' are buffer-local, so a tool call that
;; runs in another buffer silently uses that buffer's fresh, empty VFS and
;; resolves relative paths against that buffer's directory.  gptel anchors
;; the automatic path and the minibuffer confirmation path, but
;; `gptel--accept-tool-calls' is also reached from the
;; `*gptel-tool-calls*' inspection buffer, which is where the VFS used to be
;; lost.

(ert-deftest gptel-yatools-test-tool-call-runs-in-request-buffer ()
  "A write confirmed from another buffer must land in the chat's VFS."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (gptel-yatools-test--noninteractive
              (gptel-yatools-test--accept-in
               inspect chat (gptel-yatools-test--tool-spec "write_file")
               (list :path "f.txt" :content "new\n")))
            (should (equal (with-current-buffer chat (gptel-yatools-vfs-get file))
                           "new\n"))
            (should-not (with-current-buffer inspect (gptel-yatools-vfs-get file)))
            (should (equal (with-current-buffer chat
                             (gptel-yatools-vfs--changed-paths))
                           (list file))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-file-sync-runs-in-request-buffer ()
  "`file_sync' confirmed elsewhere must see the chat's pending changes.

Reporting \"no pending changes\" here is not a cosmetic difference: it
tells the model the work is done when nothing was written at all."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (with-current-buffer chat (gptel-yatools-vfs-put file "pending\n"))
            (let* ((noninteractive t)
                   (out (gptel-yatools-test--silencing-message
                          (gptel-yatools-test--noninteractive
                            (gptel-yatools-test--accept-in
                             inspect chat
                             (gptel-yatools-test--tool-spec "file_sync") nil)))))
              ;; Non-interactive Emacs cannot show the review, so the sync is
              ;; refused -- but only after finding the pending file.
              (should-not (string-match-p "no pending changes" out))
              (should (string-match-p "non-interactively" out))
              (should (equal (gptel-yatools-vfs--disk-content file) "orig\n"))
              (should (with-current-buffer chat (gptel-yatools-vfs-get file)))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-command-warns-about-request-buffer-vfs ()
  "`execute_command' confirmed elsewhere must report the chat's VFS state.

The XML provenance tag promises the model that the command ran against
disk and says whether pending VFS changes may explain the output.  Read
from the wrong buffer it claims there are none."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (with-current-buffer chat (gptel-yatools-vfs-put file "pending\n"))
            (let ((out (gptel-yatools-test--silencing-message
                         (gptel-yatools-test--noninteractive
                           (gptel-yatools-test--accept-in
                            inspect chat
                            (gptel-yatools-test--tool-spec "execute_command")
                            (list :command "true"))))))
              (should (string-match-p "vfs=\"true\"" out))
              (should (string-match-p "WARNING" out))
              (should (string-match-p "f.txt" out))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-auto-tool-call-uses-request-buffer ()
  "The unconfirmed path must also run in the request buffer.

gptel re-enters `(plist-get info :buffer)' itself here; this test pins
that down, so a future gptel change that drops the wrapper is noticed
rather than silently losing the VFS."
  (gptel-yatools-test--in-dir
    (let* ((file (expand-file-name "f.txt" default-directory))
           (chat (gptel-yatools-test--request-buffer))
           (decoy (gptel-yatools-test--request-buffer " *gptel-yatools-test-decoy*"))
           (tool (gptel-yatools-test--tool-spec "write_file"))
           (tool-call (list :name "write_file"
                            :args (list :path "f.txt" :content "auto\n")))
           (info (list :buffer chat :tools (list tool)
                       :tool-use (list tool-call)
                       :callback (lambda (&rest _) nil)
                       ;; `gptel--handle-tool-use' only requires a non-nil
                       ;; backend here; the request state is synthetic and no
                       ;; network call is made.
                       :backend 'gptel-yatools-test-backend
                       :data nil))
           (fsm (gptel-make-fsm :state 'TOOL :info info)))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            ;; Only the transition is stubbed: the tool itself must run.
            (cl-letf (((symbol-function 'gptel--fsm-transition)
                       (lambda (&rest _) nil)))
              (with-current-buffer decoy
                (gptel-yatools-test--noninteractive
                  (gptel--handle-tool-use fsm))))
            (should (equal (with-current-buffer chat (gptel-yatools-vfs-get file))
                           "auto\n"))
            (should-not (with-current-buffer decoy (gptel-yatools-vfs-get file))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer decoy)))))

(ert-deftest gptel-yatools-test-inspect-accept-runs-in-request-buffer ()
  "Accepting from `*gptel-tool-calls*' must not use that buffer's VFS.

This drives the real inspection command, so it also covers the
`quit-window' and `gptel--fsm-last' plumbing that a synthetic call
would skip."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (let ((tool-call (list (gptel-yatools-test--tool-spec "write_file")
                                   (list :path "f.txt" :content "inspected\n")
                                   (lambda (&rest _) nil))))
              (with-current-buffer inspect
                (setq gptel--fsm-last
                      (gptel-make-fsm
                       :state 'TOOL
                       :info (list :buffer chat
                                   :tool-display (list (list tool-call) nil))))
                (gptel-yatools-test--noninteractive
                  (gptel--inspect-accept-tool-calls))))
            (should (equal (with-current-buffer chat (gptel-yatools-vfs-get file))
                           "inspected\n"))
            (should-not (with-current-buffer inspect (gptel-yatools-vfs-get file))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-inspection-buffer-forgets-stale-vfs ()
  "A reused inspection buffer must not keep an old VFS.

`gptel--inspect-tool-calls' reuses `*gptel-tool-calls*' with
`erase-buffer', so a table left there by an earlier session would keep
its entries, and the kill guard would then ask about files nobody
touched from that buffer."
  (let ((chat (gptel-yatools-test--request-buffer))
        (inspect (get-buffer-create "*gptel-tool-calls*")))
    (unwind-protect
        (progn
          (with-current-buffer inspect
            ;; A *reused* inspection buffer is already in `lisp-data-mode',
            ;; so gptel skips the mode switch (and its
            ;; `kill-all-local-variables') on the second use.  Emulate that:
            ;; with the mode already set, buffer-local state survives.
            (lisp-data-mode)
            (setq-local gptel-yatools-vfs (make-hash-table :test #'equal))
            (puthash (expand-file-name "stale.txt" temporary-file-directory)
                     (list :content "x\n" :baseline "y\n" :coding 'utf-8-unix
                           :baseline-coding 'utf-8-unix)
                     gptel-yatools-vfs))
          (gptel-yatools-test--noninteractive
            (gptel--inspect-tool-calls
             (list (list (gptel-yatools-test--tool-spec "read_path")
                         (list :path "x") (lambda (&rest _) nil)))
             (list :buffer chat :tool-use nil :tools gptel-yatools--tools)))
          (with-current-buffer inspect
            (should-not (local-variable-p 'gptel-yatools-vfs))
            (should-not (local-variable-p 'gptel-yatools-vfs--header-line-cache))))
      (gptel-yatools-test--kill-request-buffer chat)
      (let ((kill-buffer-query-functions nil)) (kill-buffer inspect)))))

(ert-deftest gptel-yatools-test-tool-call-on-dead-owner-is-refused ()
  "A tool call whose chat buffer is gone must fail, not run elsewhere.

gptel itself raises `Selecting deleted buffer' in this situation; the
point of the check is that the tool never runs against some unrelated
buffer's VFS or directory."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (gptel-yatools-test--kill-request-buffer chat)
            (let ((err (should-error
                        (gptel-yatools-test--noninteractive
                          (gptel-yatools-test--accept-in
                           inspect chat
                           (gptel-yatools-test--tool-spec "write_file")
                           (list :path "f.txt" :content "nowhere\n")))
                        :type 'user-error)))
              (should (string-match-p "no longer exists"
                                      (error-message-string err))))
            (should (equal (gptel-yatools-vfs--disk-content file) "orig\n"))
            (should-not (with-current-buffer inspect (gptel-yatools-vfs-get file))))
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-tool-calls-do-not-share-a-vfs ()
  "Anchoring the dispatcher must not merge two chats' VFS tables."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (first (gptel-yatools-test--request-buffer))
          (second (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (with-current-buffer second (gptel-yatools-vfs-put file "for-second\n"))
            (gptel-yatools-test--noninteractive
              (gptel-yatools-test--accept-in
               inspect first (gptel-yatools-test--tool-spec "write_file")
               (list :path "f.txt" :content "for-first\n")))
            (should (equal (with-current-buffer first (gptel-yatools-vfs-get file))
                           "for-first\n"))
            (should (equal (with-current-buffer second (gptel-yatools-vfs-get file))
                           "for-second\n"))
            (should (equal (with-current-buffer first
                             (gptel-yatools-vfs--changed-paths))
                           (list file)))
            (should (equal (with-current-buffer second
                             (gptel-yatools-vfs--changed-paths))
                           (list file))))
        (dolist (buffer (list first second inspect))
          (gptel-yatools-test--kill-request-buffer buffer))))))

(ert-deftest gptel-yatools-test-dispatch-advice-is-installed-once ()
  "Reloading the package must not stack dispatch advices.

Reloading in place is normal while developing, and the tool list is
rebuilt on every load, so every advice the file installs has to survive
that.  `advice-add' happens to ignore an identical second advice, but
the count is what pins the guarantee down."
  (load gptel-yatools-test--file nil t)
  (load gptel-yatools-test--file nil t)
  (should (= 1 (gptel-yatools-test--advice-count
                'gptel--accept-tool-calls
                #'gptel-yatools--accept-tool-calls-in-owner)))
  (should (= 1 (gptel-yatools-test--advice-count
                'gptel--inspect-tool-calls
                #'gptel-yatools--forget-inspection-vfs)))
  (should (advice-member-p #'gptel-yatools--accept-tool-calls-in-owner
                           'gptel--accept-tool-calls)))


;;;; 44. Long-running tools announce themselves in the gptel status line

(defun gptel-yatools-test--chat-with-header-line ()
  "Turn the current buffer into a minimal gptel chat for status tests.

The buffer needs only the two things `gptel--update-status' looks at:
`gptel-mode' and a three-element `header-line-format'.  Element 1 is
the status slot that gptel rewrites in place."
  (setq-local gptel-mode t)
  (setq-local header-line-format '("" " status" " info")))

(ert-deftest gptel-yatools-test-execute-command-announces-itself ()
  "`execute_command' must say that it is running before it does."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (gptel-yatools-test--chat-with-header-line)
      (let ((out (funcall (gptel-yatools-test--tool "execute_command")
                          "printf hello")))
        (should (string-match-p "hello" out))
        (should (equal (nth 1 header-line-format)
                       " Executing command..."))))))

(ert-deftest gptel-yatools-test-execute-elisp-announces-itself ()
  "`execute_elisp' must say that it is evaluating before it does."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (gptel-yatools-test--chat-with-header-line)
      (let ((out (funcall (gptel-yatools-test--tool "execute_elisp")
                          "(+ 1 2)")))
        (should (string-match-p "3" out))
        (should (equal (nth 1 header-line-format)
                       " Evaluating Elisp..."))))))



(provide 'gptel-yatools-tests)
;;; gptel-yatools-tests.el ends here
