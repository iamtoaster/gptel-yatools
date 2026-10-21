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
      (let ((out (gptel-yatools--respond
                  (gptel-yatools-ok (string-to-multibyte
                                     (unibyte-string 233 0 255))))))
        (gptel-yatools-test--should-be-enveloped out)))))

(ert-deftest gptel-yatools-test-command-output-is-json-serialisable ()
  "Command output with raw bytes must not break the request either."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "raw.bin")))
      (gptel-yatools-test--write file (unibyte-string 99 97 102 233 10))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (let ((out (funcall (gptel-yatools-test--tool "execute_command")
                              (format "cat %s" file))))
            (should (condition-case nil (progn (json-serialize out) t)
                      (error nil)))))))))


;;;; 21/22/23. Response size limits

(ert-deftest gptel-yatools-test-escape-raw-bytes-leaves-clean-text-alone ()
  "Ordinary text must come back untouched, ASCII or not."
  (dolist (text '("" "abc" "a\nb\n" "héllo ✓ 日本語"))
    (should (equal (gptel-yatools--escape-raw-bytes text) text))))

(ert-deftest gptel-yatools-test-escape-raw-bytes-still-escapes-raw-bytes ()
  "The fast path must not let an undecodable byte through."
  (should (equal (gptel-yatools--escape-raw-bytes
                  (string-to-multibyte (unibyte-string 97 255 98)))
                 "a\\xffb"))
  (should (equal (gptel-yatools--escape-raw-bytes
                  (string-to-multibyte (unibyte-string 97 128 98)))
                 "a\\x80b"))
  (let ((out (gptel-yatools--escape-raw-bytes
              (concat "héllo "
                      (string-to-multibyte (unibyte-string 233))))))
    ;; The text around the raw byte survives, and the result serialises.
    (should (string-prefix-p "héllo " out))
    (should (string-match-p "\\\\xe9" out))
    (should (condition-case nil (progn (json-serialize out) t)
              (error nil)))))

(ert-deftest gptel-yatools-test-truncate-fast-path-matches-the-general-path ()
  "The cheap path must return exactly what the full walk returns.

`gptel-yatools--truncate-slow' is the reference implementation: every
response used to take that path, so the fast path is only correct if
the two agree on every shape of input."
  (let* ((line-limit gptel-yatools--output-line-limit)
         (char-limit gptel-yatools--output-char-limit)
         (cases (list ""
                       "abc\n"
                       "héllo ✓\n"
                       (make-string 10 ?x)
                       (make-string char-limit ?x)
                       (make-string (1+ char-limit) ?x)
                       (mapconcat #'number-to-string
                                  (number-sequence 1 line-limit) "\n")
                       (mapconcat #'number-to-string
                                  (number-sequence 1 (1+ line-limit)) "\n")
                       (concat (make-string 100 ?x) "\n"
                               (string-to-multibyte (unibyte-string 255))))))
    (dolist (case cases)
      (should (equal (gptel-yatools--truncate case)
                     (gptel-yatools--truncate-slow case))))))

(ert-deftest gptel-yatools-test-large-read-is-not-slow ()
  "Reading a large file must not rewalk bytes that need no escaping.

Escaping used to cost about a microsecond per character, so a 64 kB
read spent ~55 ms before its response even existed -- a visible pause
between tool calls, repeated for every large read.  The bound is loose
and takes the best of five runs, so a loaded machine does not make it
flake: the escaping alone now takes a fraction of a millisecond, while
the old code missed the bound by a factor of two."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "big.txt")))
      (gptel-yatools-test--write
       file (make-string 64000 ?x))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (let ((best most-positive-fixnum))
            (dotimes (_ 5)
              (let ((start (float-time)))
                (funcall (gptel-yatools-test--tool "read_path") file)
                (setq best (min best (- (float-time) start)))))
            (should (< best 0.025))))))))

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
  "A nil or numeric path/command must yield a readable, enveloped error.

The tool signals; the boundary renders it.  What the model must never
see is a raw condition string such as `error Wrong type argument'."
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
               (out (apply (gptel-yatools-test--tool name) args)))
          (should (string-match-p "must be a string" out))
          (gptel-yatools-test--should-be-enveloped out))))))


;;;; 40. A tool's output was unbounded

(ert-deftest gptel-yatools-test-command-output-is-truncated ()
  "A command printing megabytes must not return a 300k-character response."
  (skip-unless (executable-find "sh"))
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (let ((out (funcall (gptel-yatools-test--tool "execute_command")
                          "i=0; while [ $i -lt 30000 ]; do printf 0123456789; i=$((i+1)); done")))
        (should (stringp out))
        (should (<= (length out) (+ gptel-yatools--output-char-limit 1000)))
        (should (string-match-p "truncated" out))
        (gptel-yatools-test--should-be-enveloped out)))))


;;;; 42. Loading the package must not depend on how gptel was loaded

(ert-deftest gptel-yatools-test-load-registers-without-enabling ()
  "Requiring the package must register every tool and enable none.

The tools have to be listed by `gptel-menu', which reads gptel's
registry, but nothing may be added to `gptel-tools': which tools a chat
sends is the user's decision, made with `gptel-yatools-enable'.

The probe reports whether every tool is registered and carries a
deadline, rather than how many there are: a count pins the number of
tools, so adding or removing one would fail a test about something else."
  (skip-unless (executable-find "emacs"))
  (let ((result
         (gptel-yatools-test--run-batch
          `(progn
             (require 'cl-lib)
             (require 'gptel-yatools)
             (princ (format "tools=%d enabled=%s all-registered=%s all-timeouts=%s\n"
                            (length gptel-yatools--tools)
                            gptel-tools
                            (cl-every (lambda (tool)
                                        (gptel-get-tool (gptel-tool-name tool)))
                                      gptel-yatools--tools)
                            (cl-every
                             (lambda (tool)
                               (equal (plist-get
                                       (car (last (gptel-tool-args tool)))
                                       :name)
                                      "timeout"))
                             gptel-yatools--tools)))))))
    (should (equal (car result) 0))
    (should (string-match-p "enabled=nil all-registered=t all-timeouts=t"
                            (cdr result)))
    ;; Not vacuous: an empty tool list would satisfy the two `every' checks.
    (should (string-match-p "tools=[1-9][0-9]*" (cdr result)))))

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
                    (files '("gptel-yatools-common.el"
                             "gptel-yatools-vfs.el"
                             "gptel-yatools-shell.el"
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


;;;; 46b. One name means one file, whichever tool receives it

(ert-deftest gptel-yatools-test-one-name-is-one-file ()
  "Every tool must resolve a relative path against the workspace root.

The buffer's `default-directory' is `sub/' of the workspace root here,
as it is when a chat is started from a file in `proj/src/'.  Resolving
against it instead -- which half the filesystem tools used to do --
made `write_file \"p.txt\"' store a file that `read_path \"p.txt\"'
could not find, and made `vfs_diff' report no pending change for a path
that was sitting in the VFS."
  (gptel-yatools-test--in-dir
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (let* ((tool (lambda (name) (gptel-yatools-test--tool name)))
               (written (funcall (funcall tool "write_file") "p.txt" "x\n"))
               (root-file (gptel-yatools-test--root-file "p.txt")))
          ;; The write landed at the workspace root, not in sub/.
          (should (equal (gptel-yatools-vfs-get root-file) "x\n"))
          (should (string-match-p "Wrote p.txt to the VFS" written))
          ;; Every reader agrees with it, and none of them reports that
          ;; the file does not exist.
          (dolist (name '("read_path"
                          "read_file_from_offset"
                          "fetch_lines_from_file_using_regex"))
            (let ((out (pcase name
                         ("read_path" (funcall (funcall tool name) "p.txt"))
                         ("read_file_from_offset"
                          (funcall (funcall tool name) "p.txt" 1 10))
                         (_ (funcall (funcall tool name) "p.txt" "x")))))
              (should (string-match-p "x" out))
              (should-not (string-match-p "does not exist" out))
              (should (string-match-p "vfs=\"true\"" out))))
          ;; And the diff tools find the pending change by that name.
          (should (string-match-p "p.txt"
                                  (funcall (funcall tool "vfs_diff") "p.txt")))
          (should-not (string-match-p "no pending VFS change"
                                      (funcall (funcall tool "vfs_diff") "p.txt")))
          ;; A path outside the workspace root is still absolute-only.
          (should (string-match-p
                   "Removed pending VFS change for p.txt"
                   (funcall (funcall tool "vfs_discard") "p.txt")))
          (should-not (gptel-yatools-vfs-get root-file)))))))


(ert-deftest gptel-yatools-test-vfs-refuses-a-relative-path ()
  "The VFS interface takes resolved paths only.

A relative path crossing that seam is a bug in this package, and is
reported as one rather than quietly resolved against whichever buffer
happens to be current -- which is how the tools came to disagree about
what a single name meant."
  (gptel-yatools-test--in-dir
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (should-error (gptel-yatools-vfs-get "relative.txt") :type 'error)
        (should-error (gptel-yatools-vfs-read "relative.txt") :type 'error)
        (should-error (gptel-yatools-vfs-put "relative.txt" "x") :type 'error)
        (should-error (gptel-yatools-vfs-remove "relative.txt") :type 'error)
        (should-error (gptel-yatools-vfs-pending-p "relative.txt") :type 'error)
        (should-error (gptel-yatools-vfs-discard-pending "relative.txt")
                      :type 'error)
        ;; An absolute path is accepted, and lands at that path.
        (let ((full (gptel-yatools-test--root-file "ok.txt")))
          (gptel-yatools-vfs-put full "x\n")
          (should (equal (gptel-yatools-vfs-get full) "x\n")))))))


(ert-deftest gptel-yatools-test-shell-keeps-the-workspace-root ()
  "Rebinding `default-directory' inside a call must not move the root.

The shell runner rebinds `default-directory' to run in a subdirectory.
If the root were recomputed after that, a message about a missing
directory would be rendered relative to a different base -- and a
tool that resolved a path afterwards would resolve it elsewhere."
  (gptel-yatools-test--in-dir
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (make-directory (expand-file-name "inside" gptel-yatools-test--root) t)
        (let ((out (funcall (gptel-yatools-test--tool "execute_command")
                            "pwd" "inside")))
          ;; It ran in the requested subdirectory...
          (should (string-match-p "inside" out))
          ;; ...and the root it reports paths against is still the root.
          (should (string-match-p (regexp-quote gptel-yatools-test--root)
                                  (gptel-yatools--detect-workspace-root)))
          ;; A tool called afterwards still resolves against the root.
          (should (equal (gptel-yatools--resolve-path "x")
                         (gptel-yatools-test--root-file "x"))))))))


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
                  "vfs_discard" "skill"))
    (should (cl-find name gptel-yatools--tools
                     :key #'gptel-tool-name :test #'equal))))


;;;; 48. Tool calls could block Emacs forever

(ert-deftest gptel-yatools-test-every-tool-declares-a-timeout ()
  "Every tool must accept TIMEOUT and tell the model not to raise it.

The guidance lives in the argument's description, which is where a model
looks when deciding whether to pass one.  It is stated once per tool: a
copy appended to the description as well would be re-sent on every
request, and had to be re-appended on every reload to stay in step."
  (dolist (tool gptel-yatools--tools)
    (unless (gptel-tool-async tool)
      (let* ((description (gptel-tool-description tool))
             (args (gptel-tool-args tool))
             (timeout (car (last args))))
        (should (equal (plist-get timeout :name) "timeout"))
        (should (= 1 (cl-count-if (lambda (arg)
                                    (equal (plist-get arg :name) "timeout"))
                                  args)))
        (should (plist-get timeout :optional))
        ;; The default is named, so the model can reason about splitting a
        ;; call, and it is the configured one.
        (should (string-match-p
                 (format "default (%d seconds)" (gptel-yatools--resolve-timeout nil))
                 (plist-get timeout :description)))
        (should (string-match-p "Do not raise it unless"
                                (plist-get timeout :description)))
        ;; Nothing repeats it at the end of the description.
        (should (= 0 (gptel-yatools-test--occurrences description "Timeouts: ")))))))

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

(ert-deftest gptel-yatools-test-timeout-arg-is-added-once ()
  "A registered tool must carry exactly one TIMEOUT argument.

`gptel--make-tool' plus `gptel-yatools--register-tool' is used instead of
the macro so a probe tool can be registered and then removed again
without leaving it in gptel's registry for the rest of the run."
  (let ((gptel-yatools--tools nil))
    (unwind-protect
        (let ((tool (gptel-yatools--register-tool
                     :name "probe_tool"
                     :category "probe"
                     :description "Probe."
                     :function (lambda (x) x)
                     :args (list (list :name "x" :type 'string :description "x")))))
          (should (= 1 (cl-count-if (lambda (arg)
                                      (equal (plist-get arg :name) "timeout"))
                                    (gptel-tool-args tool))))
          (should (equal gptel-yatools--tools (list tool))))
      (setf (alist-get "probe" gptel--known-tools nil nil #'equal) nil))))

(ert-deftest gptel-yatools-test-timeout-arg-tracks-the-setting ()
  "Changing the timeout must update what the model is told, without reloading.

The argument is the only place the default is named, so a stale number
there would have the model reasoning about a limit that is not in force.
`:set' runs only through `customize-set-variable', which is the path the
user takes; a plain `setq' deliberately does not go through it."
  (let ((tool (gptel--make-tool
               :name "probe_tool"
               :description "Probe."
               :function (lambda (x) x)
               :args (list (list :name "x" :type 'string :description "x")
                           (gptel-yatools--timeout-arg))))
        (original gptel-yatools-timeout))
    (unwind-protect
        (let ((gptel-yatools--tools (list tool)))
          (customize-set-variable 'gptel-yatools-timeout 30)
          (should (string-match-p
                   "default (30 seconds)"
                   (plist-get (car (last (gptel-tool-args tool)))
                              :description))))
      (customize-set-variable 'gptel-yatools-timeout original))))

(ert-deftest gptel-yatools-test-registering-an-async-tool-is-refused ()
  "An asynchronous tool cannot cross the boundary, so registering one must fail.

Its result arrives long after the call returns, so there is no Result for
the boundary to render -- and a deadline around the call would only
mislabell it as timed out while it still runs."
  (gptel-yatools-test--noninteractive
    (let ((gptel-yatools--tools nil))
      (unwind-protect
          (progn
            (should-error (gptel-yatools--register-tool
                           :name "probe_async"
                           :category "probe"
                           :description "Probe."
                           :async t
                           :function (lambda (_callback) nil))
                          :type 'error)
            ;; The refusal must happen before the tool reaches gptel's
            ;; registry; otherwise the model can still call a tool that
            ;; cannot return a Result.
            (should-not (alist-get "probe_async"
                                   (alist-get "probe" gptel--known-tools
                                              nil nil #'equal)
                                   nil nil #'equal)))
        (setf (alist-get "probe" gptel--known-tools nil nil #'equal) nil)))))


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
    (let ((file (gptel-yatools-test--root-file "f.txt"))
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
    (let ((file (gptel-yatools-test--root-file "f.txt"))
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
    (let ((file (gptel-yatools-test--root-file "f.txt"))
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
    (let* ((file (gptel-yatools-test--root-file "f.txt"))
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
    (let ((file (gptel-yatools-test--root-file "f.txt"))
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
    (let ((file (gptel-yatools-test--root-file "f.txt"))
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
    (let ((file (gptel-yatools-test--root-file "f.txt"))
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

(ert-deftest gptel-yatools-test-announcement-redraws-the-frame ()
  "Announcing a running command must redraw, not just set the string.

`gptel--update-status' only flags the mode line; Emacs redraws when it
next goes idle.  A tool call never goes idle -- the shell runner polls
`accept-process-output' until the command exits -- so a status set
without an explicit redisplay is correct in the buffer and invisible on
screen.  Measured on a terminal frame: 0 redisplays over a two-second
command without it, 1 with it."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (gptel-yatools-test--chat-with-header-line)
      ;; `let*' so the advice closes over REDISPLAYS: a plain `let' evaluates
      ;; its initialiser before the binding exists, and the counter becomes a
      ;; free variable that the assertion never reads.
      (let* ((redisplays 0)
             (advice (lambda (orig &rest args)
                       (setq redisplays (1+ redisplays))
                       (apply orig args))))
        (advice-add 'redisplay :around advice)
        (unwind-protect
            (progn
              (funcall (gptel-yatools-test--tool "execute_command") "true")
              (should (= redisplays 1)))
          (advice-remove 'redisplay advice))))))

(ert-deftest gptel-yatools-test-announcement-is-quiet-outside-a-chat ()
  "A tool run outside a chat buffer must not redraw anything.

`redisplay' is what makes the announcement visible, so it must not be
reached when there is no gptel buffer to announce into -- a tool called
from `eval', a test, or a hook has no status indicator to update."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (let* ((redisplays 0)
             (advice (lambda (orig &rest args)
                       (setq redisplays (1+ redisplays))
                       (apply orig args))))
        (advice-add 'redisplay :around advice)
        (unwind-protect
            (progn
              (gptel-yatools--update-tool-status " Working..." 'mode-line-emphasis)
              (should (= redisplays 0)))
          (advice-remove 'redisplay advice))))))

;;;; 44b. One place draws the header line, and modules only contribute labels

(ert-deftest gptel-yatools-test-header-line-draws-from-the-registry ()
  "The drawer must render whatever the registry holds, and nothing else.

Label-drawing belongs with the rest of the gptel adaptation, not in a
tool module: it reads gptel's own `:align-to' layout.  Modules take part
by adding a function to
`gptel-yatools-header-line-extra-functions', which is exactly what the
VFS and the skills module now do -- neither is a special case."
  (let ((gptel-yatools-header-line-extra-functions
         (list (lambda () "[one]")
               (lambda () nil)                  ; contributes nothing
               (lambda () (error "broken"))      ; must not break redisplay
               (lambda () "[two]"))))
    (cl-letf (((symbol-function 'gptel-yatools--header-line-rhs)
               (lambda () "info")))
      (let ((rendered (gptel-yatools--header-line-rendered)))
        (should (string-match-p "\\[one\\] \\[two\\] info" rendered))
        ;; The alignment offset is parenthesised, or the group collapses.
        (should (string-match-p "(- right" (format "%S" (get-text-property
                                                        0 'display rendered))))))))

(ert-deftest gptel-yatools-test-vfs-contributes-a-label-not-a-drawer ()
  "The VFS must join the registry, and no longer draw the header line."
  (should (memq #'gptel-yatools-vfs--header-line-label
                gptel-yatools-header-line-extra-functions))
  (should (fboundp 'gptel-yatools--header-line-rendered))
  ;; The drawing functions are the glue file's, not the filesystem module's.
  (dolist (name '(gptel-yatools--header-line-rendered
                  gptel-yatools--extend-header-line))
    (should (equal (file-name-nondirectory
                    (or (symbol-file name 'defun) ""))
                   "gptel-yatools.el")))
  (dolist (gone '(gptel-yatools-vfs--header-line-with-vfs
                  gptel-yatools-vfs--header-line-rhs
                  gptel-yatools-vfs--extend-header-line))
    (should-not (fboundp gone)))
  ;; And the advice is installed, by the glue file, exactly once.
  (should (advice-member-p #'gptel-yatools--extend-header-line
                           'gptel-use-header-line))
  (with-temp-buffer
    (gptel-yatools-test--chat-with-header-line)
    (let ((gptel-use-header-line t))
      (gptel-yatools--extend-header-line)
      (gptel-yatools--extend-header-line)
      (should (= 1 (cl-count gptel-yatools--header-line-segment
                             header-line-format :test #'equal)))
      (should (equal (nth 2 header-line-format)
                     gptel-yatools--header-line-segment)))))


;;;; Tool boundary: one response shape, one place that renders it

(ert-deftest gptel-yatools-test-every-tool-returns-an-envelope ()
  "No tool may return bare text, and every reply must survive JSON.

Calling each tool for real would run shell commands and touch the disk,
so this checks the boundary itself: whatever a tool returns or signals,
the function installed in the registry renders an envelope."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (let ((gptel-yatools-test--ok (gptel-yatools-ok "body")))
        (dolist (tool gptel-yatools--tools)
          (let ((result
                 (gptel-yatools--call-tool
                  (gptel-tool-name tool)
                  (lambda (&rest _) gptel-yatools-test--ok)
                  nil)))
            (should (string-match-p "body" result))
            (gptel-yatools-test--should-be-enveloped result))))
      ;; A tool that signals is enveloped too, including the raw bytes an
      ;; error message can carry (a file name that does not decode).
      (dolist (thunk (list (lambda () (error "plain failure"))
                           (lambda ()
                             (error "raw name: %s"
                                    (string-to-multibyte (unibyte-string 105 233))))))
        (let ((out (gptel-yatools--call-tool "probe" thunk nil)))
          (gptel-yatools-test--should-be-enveloped out)
          (should (string-match-p "Error: " out)))))))

(ert-deftest gptel-yatools-test-ok-derives-the-comment-from-the-provenance ()
  "The context comment is derived from :provenance unless the caller overrides it."
  (should (string-match-p
           "virtual filesystem"
           (gptel-yatools-result-comment
            (gptel-yatools-ok "body" :provenance :vfs))))
  (should (string-match-p
           "mixes pending"
           (gptel-yatools-result-comment
            (gptel-yatools-ok "body" :provenance :mixed))))
  (should (string-match-p
           "disk"
           (gptel-yatools-result-comment (gptel-yatools-ok "body"))))
  (should (equal (gptel-yatools-result-comment
                  (gptel-yatools-ok "body" :provenance :vfs :comment "custom"))
                 "custom"))
  ;; An unknown provenance is a bug in the caller, not a comment to guess at.
  (should-error (gptel-yatools-ok "body" :provenance :maybe) :type 'error))

(ert-deftest gptel-yatools-test-provenance-reaches-the-wire ()
  "Provenance decides the envelope's vfs attribute, and only :disk is false."
  (dolist (pair '((:disk . "vfs=\"false\"")
                  (:vfs . "vfs=\"true\"")
                  (:mixed . "vfs=\"true\"")))
    (should (string-match-p
             (cdr pair)
             (gptel-yatools--respond
              (gptel-yatools-ok "body" :provenance (car pair)))))))

(ert-deftest gptel-yatools-test-directory-listing-marks-pending-entries ()
  "A merged directory listing must say which of its rows are pending.

Reporting the merged listing as a description of disk is what let the
model believe a VFS-only file already existed."
  (gptel-yatools-test--in-dir
    (gptel-yatools-test--write (gptel-yatools-test--root-file "on-disk.txt")
                               "here\n")
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (gptel-yatools-vfs-put
         (gptel-yatools-test--root-file "only-in-vfs.txt") "new\n")
        (let ((out (funcall (gptel-yatools-test--tool "read_path") ".")))
          ;; The disk-only row is unremarkable...
          (should (string-match-p "file\ton-disk\\.txt$" out))
          ;; ...the VFS-only row says so, and the reply says it is mixed.
          (should (string-match-p "file\tonly-in-vfs\\.txt\t(pending)" out))
          (should (string-match-p "vfs=\"true\"" out))
          (should (string-match-p "mixes pending" out)))
        (gptel-yatools-vfs-discard-pending)
        ;; A directory with nothing pending stays a description of disk.
        (let ((out (funcall (gptel-yatools-test--tool "read_path") ".")))
          (should (string-match-p "vfs=\"false\"" out))
          (should-not (string-match-p "(pending" out)))))))

(ert-deftest gptel-yatools-test-directory-listing-marks-shadowed-files ()
  "A disk entry whose content a pending write shadows is marked as such."
  (gptel-yatools-test--in-dir
    (gptel-yatools-test--write (gptel-yatools-test--root-file "f.txt") "old\n")
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (gptel-yatools-vfs-put (gptel-yatools-test--root-file "f.txt") "new\n")
        (let ((out (funcall (gptel-yatools-test--tool "read_path") ".")))
          (should (string-match-p "file\tf\\.txt\t(pending change)" out))
          (should (string-match-p "vfs=\"true\"" out)))))))

(ert-deftest gptel-yatools-test-a-wrong-shaped-result-is-reported-not-signalled ()
  "A tool returning something that is not a result must not kill the call.

Signalling here would bypass the envelope, which is the one thing the
boundary exists to prevent."
  (let ((out (gptel-yatools--call-tool "probe" (lambda (&rest _) "bare text") nil)))
    (should (string-match-p "internal error" out))
    (gptel-yatools-test--should-be-enveloped out)))

(ert-deftest gptel-yatools-test-timeout-is-an-envelope-and-a-condition ()
  "An expired deadline must reach the model in the same envelope.

A real tool is used rather than a probe, so the deadline is exercised
through the same boundary the model's calls go through: the boundary
renders the timeout like any other failure."
  (skip-unless (executable-find "sh"))
  (with-temp-buffer
    (gptel-yatools-test--vfs
      ;; Two arguments: the command and its working directory, then the
      ;; boundary's own TIMEOUT.
      (let ((out (funcall #'gptel-yatools-execute-command
                          "sleep 5" nil 1)))
        (should (string-match-p "1 second timeout" out))
        (gptel-yatools-test--should-be-enveloped out))))
  (should-error (gptel-yatools--call-with-timeout
                 (lambda () (sleep-for 5)) nil 1)
                :type 'gptel-yatools-timeout-error))

(ert-deftest gptel-yatools-test-tool-functions-are-named-and-adviseable ()
  "Both halves of a tool must be named functions, not closures.

An anonymous closure cannot be advised, cannot be found with `C-h f' and
does not appear by name in a backtrace, which is what a tool's definition
has to support."
  (dolist (tool gptel-yatools--tools)
    (let ((name (gptel-tool-name tool)))
      (should (fboundp (gptel-tool-function tool)))
      (should (symbolp (gptel-tool-function tool)))
      ;; The implementation the boundary calls, derived from the same name.
      (should (fboundp (intern (format "%s-tool"
                                       (gptel-tool-function tool)))))))
  ;; And the boundary is what gptel is registered with.
  (should (eq (gptel-tool-function (cl-find "read_path" gptel-yatools--tools
                                            :key #'gptel-tool-name :test #'equal))
              #'gptel-yatools-read-path)))

(ert-deftest gptel-yatools-test-advice-survives-a-reload ()
  "Advice on a tool function must survive reloading its module.

Advice attaches to the symbol, so it outlives the `defun' that a reload
re-evaluates; a closure built at load time would silently lose it."
  ;; `let*' so the advice closes over CALLS: in a plain `let' its
  ;; initialiser is evaluated before the binding exists, and the counter
  ;; becomes a free variable.
  (let* ((calls 0)
         (advice (lambda (fn &rest args)
                   (setq calls (1+ calls))
                   (apply fn args))))
    (advice-add 'gptel-yatools-read-workspace-root-tool :around advice)
    (unwind-protect
        (progn
          (gptel-yatools-test--in-dir
            (should (stringp (gptel-yatools-read-workspace-root)))
            (should (= calls 1))
            ;; Reload the module that defines it: the advice is still there.
            (load (expand-file-name "gptel-yatools-shell.el"
                                    (file-name-directory gptel-yatools-test--file))
                  nil t)
            (should (stringp (gptel-yatools-read-workspace-root)))
            (should (= calls 2))))
      (advice-remove 'gptel-yatools-read-workspace-root-tool advice))))

(ert-deftest gptel-yatools-test-tool-docstrings-show-the-model-text ()
  "`C-h f' on a tool must show the description the model is given.

The docstring is generated from the definition, so it cannot drift from
what the model reads, and it is the same words rather than a summary of
them."
  (dolist (tool gptel-yatools--tools)
    (let* ((symbol (gptel-tool-function tool))
           (doc (documentation symbol))
           (description (gptel-tool-description tool)))
      (should (stringp doc))
      ;; Whole description present, modulo the whitespace filling adds.
      (should (string-match-p
               (regexp-quote (car (split-string description "[.]")))
               (replace-regexp-in-string "[ \t\n]+" " " doc)))
      ;; Every argument is documented, including the deadline.
      (dolist (arg (gptel-tool-args tool))
        (should (string-match-p (regexp-quote (plist-get arg :name)) doc)))
      ;; And it points at the macro that wrote it.
      (should (string-match-p "gptel-yatools-define-tool" doc)))))

(ert-deftest gptel-yatools-test-an-error-is-not-prefixed-twice ()
  "A tool that writes \"Error: ...\" must not reach the model as \"Error: Error: ...\"."
  (let ((out (gptel-yatools--call-tool
              "probe" (lambda (&rest _) (error "Error: nothing was written")) nil)))
    (should (string-match-p "Error: nothing was written" out))
    (should-not (string-match-p "Error: Error:" out))
    (gptel-yatools-test--should-be-enveloped out))
  ;; A condition that does not phrase itself as an error still gets the word.
  (let ((out (gptel-yatools--call-tool
              "probe" (lambda (&rest _) (error "Wrong type argument: listp, 5")) nil)))
    (should (string-match-p "Error: Wrong type argument: listp, 5" out))))

(ert-deftest gptel-yatools-test-page-text-stops-at-the-size-budget ()
  "A page must fit the response budget, and say what it showed."
  (let* ((wide (make-string (1+ gptel-yatools--output-char-limit) ?x))
         (text (mapconcat #'identity (list "one" wide "three") "\n"))
         (page (gptel-yatools--page-text text 1 10)))
    (should (= (plist-get page :start) 1))
    ;; Only the first line fits, so the page is one line, not three.
    (should (= (plist-get page :end) 1))
    (should (plist-get page :partial))
    (should (< (length (plist-get page :text))
               gptel-yatools--output-char-limit))))

(ert-deftest gptel-yatools-test-page-text-reports-the-last-page ()
  "The last page must say it is the last one, not that nothing follows."
  (let ((page (gptel-yatools--page-text "a\nb\nc" 3 10)))
    (should (equal (plist-get page :text) "c"))
    (should (= (plist-get page :end) (plist-get page :total)))
    ;; A page that does not start at line 1 is still partial: the caller
    ;; needs to know the excerpt is not the whole text.
    (should (plist-get page :partial))
    (should-not (plist-get page :past-end)))
  (let ((page (gptel-yatools--page-text "a\nb\nc" 9 10)))
    (should (plist-get page :past-end))
    (should (equal (plist-get page :text) ""))))



(provide 'gptel-yatools-tests)
;;; gptel-yatools-tests.el ends here
