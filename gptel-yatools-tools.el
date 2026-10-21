;;; gptel-yatools-tools.el --- Shell, Elisp and workspace tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The tools that are neither filesystem nor skill tools: locating the
;; workspace root, running a shell command in it, and evaluating one Emacs
;; Lisp form.  The VFS lives in `gptel-yatools-vfs.el' and Agent Skills in
;; `gptel-yatools-skills.el'; what holds the three together -- the shared
;; response envelope, the path and argument helpers, the timeout guard -- is
;; in `gptel-yatools.el', which loads this file and collects its tools.
;;
;; The command runner is here rather than with the VFS because a command
;; runs against the disk and only *reports* on the VFS: when changes are
;; pending, its output carries a warning listing them.

;;; Code:

(require 'cl-lib)
(require 'gptel)

;; Defined in `gptel-yatools.el', which loads this file: see the comment
;; there about the direction of the dependency.
(defvar gptel-yatools--current-timeout)
(declare-function gptel-yatools--workspace-root "gptel-yatools" ())
(declare-function gptel-yatools--display-path "gptel-yatools" (path))
(declare-function gptel-yatools--resolve-timeout "gptel-yatools" (value))
(declare-function gptel-yatools--truncate "gptel-yatools" (string))
(declare-function gptel-yatools--xml-escape "gptel-yatools" (s))
(declare-function gptel-yatools--escape-raw-bytes "gptel-yatools" (string))
(declare-function gptel-yatools--require-string "gptel-yatools" (value what))
(declare-function gptel-yatools--make-tool "gptel-yatools" (&rest slots))
(declare-function gptel-yatools--update-tool-status "gptel-yatools" (message &optional face))
(declare-function gptel-yatools-vfs--changed-paths "gptel-yatools-vfs" ())
(declare-function gptel-yatools-vfs--invalidate-header-line "gptel-yatools-vfs" ())

(defun gptel-yatools--wrap-command-output (output)
  "Wrap command OUTPUT, warning the LLM about pending VFS changes.

When any VFS entries are pending, a warning is prepended to the
result describing the split between the VFS and disk; otherwise a
context tag recording that the command ran against disk (with no
pending VFS changes) is included so the XML envelope is uniform."
  (let* ((changed (gptel-yatools-vfs--changed-paths))
         (output (gptel-yatools--truncate output)))
    (if changed
        (format "<tool_context vfs=\"true\" comment=\"%s\"/>\n<tool_response>\n%s\n</tool_response>"
                (gptel-yatools--xml-escape
                 (format "WARNING: %d VFS file(s) have uncommitted changes (%s). \
The command ran against DISK, not the VFS. Missing files, stale content, or unexpected results in the output below may be \
because changes are pending in the VFS. Run vfs_diff to inspect, file_sync to apply."
                         (length changed)
                         (mapconcat #'gptel-yatools--display-path changed ", ")))
                output)
      (format "<tool_context vfs=\"false\" comment=\"Command ran against disk. VFS has no pending changes.\"/>\n<tool_response>\n%s\n</tool_response>"
              output))))

;;-------------------------------------------------------------------------
;; Command runner
;;-------------------------------------------------------------------------
(defun gptel-yatools-tools--run-command (command directory)
  "Run COMMAND (in DIRECTORY if non-empty) and return a wrapped string.

The result is always a string: an XML envelope containing the
command's exit code and combined output, or an error description
if the command could not be started.

The command is killed once it outlives the current tool timeout
\(`gptel-yatools--current-timeout', or `gptel-yatools-timeout'), so a
hung command cannot block Emacs forever.  `call-process' cannot be
interrupted -- timers do not run while it waits -- which is why this
uses a real process and polls it instead."
  (let* ((root (gptel-yatools--workspace-root))
         (timeout (or gptel-yatools--current-timeout
                      (gptel-yatools--resolve-timeout nil)))
         (target-directory (if (and directory (not (string-empty-p directory)))
                               (expand-file-name directory root)
                             root))
         ;; Every message below names the directory it ran in, so make
         ;; that name workspace-relative like the other tools' paths.
         ;; This must run before `default-directory' is rebound: the
         ;; display helper derives the workspace root from it, and a
         ;; missing target directory would otherwise become its own root.
         (shown-directory (gptel-yatools--display-path target-directory))
         (default-directory target-directory))
    (cond
     ((not (file-directory-p default-directory))
      (gptel-yatools--wrap-command-output
       (format "Error: working directory does not exist: %s"
               shown-directory)))
     ((string-empty-p (string-trim command))
      (gptel-yatools--wrap-command-output "Error: command is empty."))
     (t
      (let ((outbuf (generate-new-buffer " *gptel-exec-output*")))
        (unwind-protect
            (let ((exit-code nil) (start-error nil) (timed-out nil)
                  (process nil))
              (unwind-protect
                  (condition-case err
                      (progn
                        (setq process
                              (make-process
                               :name "gptel-exec"
                               :buffer outbuf
                               :command (list shell-file-name
                                              shell-command-switch
                                              ;; Merge stderr into stdout
                                              ;; in the shell itself: with
                                              ;; `:stderr' Emacs creates a
                                              ;; pipe process whose default
                                              ;; sentinel appends "Process
                                              ;; ... finished" to this very
                                              ;; buffer.
                                              (concat "exec 2>&1; " command))
                               :connection-type 'pipe
                               :noquery t
                               :sentinel #'ignore))
                        ;; A command that reads stdin (`cat', a pager, an
                        ;; interactive program) would otherwise wait
                        ;; forever for input that never arrives.
                        (ignore-errors (process-send-eof process))
                        ;; Stop a little early so that the kill and reap
                        ;; below still fit inside the tool deadline and
                        ;; report the partial output, rather than being
                        ;; cut short by the tool-level timer.  The margin
                        ;; scales down for short timeouts so that a
                        ;; caller asking for one second still gets most
                        ;; of it.
                        (let ((deadline (+ (float-time)
                                           (- timeout
                                              (min 0.5
                                                   (max 0.05
                                                        (* 0.1 timeout)))))))
                          (while (and (process-live-p process)
                                      (< (float-time) deadline))
                            (accept-process-output
                             process
                             (min 0.2 (max 0.01
                                           (- deadline
                                              (float-time))))))
                          (if (process-live-p process)
                              (setq timed-out t)
                            (setq exit-code
                                  (process-exit-status process)))))
                    (error (setq start-error (error-message-string err))))
                ;; Killing the shell is not enough: it may ignore SIGINT,
                ;; and it may have started children.  Emacs puts each
                ;; subprocess in its own process group, so signalling the
                ;; negative pid stops the whole tree.  This also runs when
                ;; the tool-level timer unwound us out of the polling loop.
                (when (and process (process-live-p process))
                  (unless (ignore-errors
                            (signal-process (- (process-id process))
                                            'SIGKILL))
                    (ignore-errors (signal-process process 'SIGKILL)))
                  (accept-process-output process 0.5)
                  (when (process-live-p process)
                    (ignore-errors (delete-process process)))))
              (let ((output
                     (with-current-buffer outbuf
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))
                ;; The command may have changed files on disk, which can
                ;; change which pending entries still differ, so the cached
                ;; header-line count must not outlive it.
                (gptel-yatools-vfs--invalidate-header-line)
                (gptel-yatools--wrap-command-output
                 (cond
                  (start-error
                   (format "Failed to start command in %s.\nError: %s"
                           shown-directory start-error))
                  (timed-out
                   (format "Command killed in %s: it exceeded its %s second timeout and was terminated. It did not finish, so do not assume it completed. Partial output:\n%s"
                           shown-directory timeout
                           (if (string-empty-p output)
                               "(no output)" output)))
                  ((and (integerp exit-code) (zerop exit-code))
                   (format "Command succeeded in %s (exit code 0).\nOutput:\n%s"
                           shown-directory
                           (if (string-empty-p output)
                               "(no output)" output)))
                  ((integerp exit-code)
                   (format "Command failed in %s (exit code %d).\nOutput:\n%s"
                           shown-directory exit-code
                           (if (string-empty-p output)
                               "(no output)" output)))
                  (t
                   (format "Command terminated by signal in %s: %s\nOutput:\n%s"
                           shown-directory exit-code
                           (if (string-empty-p output)
                               "(no output)" output)))))))
          (when (buffer-live-p outbuf)
            (kill-buffer outbuf))))))))


;;-------------------------------------------------------------------------
;; The tools
;;-------------------------------------------------------------------------
(defun gptel-yatools-tools--tools ()
  "Return the tools defined in this file, in declaration order.

Each one already carries the shared TIMEOUT argument and the deadline
guard; `gptel-yatools.el' appends this list to `gptel-yatools--tools'."
  (list
   ;; 1. Read workspace root
   (gptel-yatools--make-tool
    :name "read_workspace_root"
    :function (lambda ()
                (gptel-yatools--workspace-root))
    :description "Return the absolute path of the current workspace root. Use it to resolve relative paths."
    :args nil
    :category "workspace")


   ;; 5. Execute a shell command (always against disk)
   (gptel-yatools--make-tool
    :name "execute_command"
    :function
    (lambda (command &optional directory)
      (gptel-yatools--require-string command "command")
      (when directory
        (gptel-yatools--require-string directory "directory"))
      (gptel-yatools--update-tool-status " Executing command..."
                                         'mode-line-emphasis)
      (gptel-yatools-tools--run-command command directory))
    :description
    "Execute a shell command and return its exit status and combined stdout/stderr output. The user is ALWAYS prompted to confirm the exact command before it runs. The command runs against DISK, not the VFS. If any VFS files have uncommitted changes, a warning is prepended to the XML context (listing the pending paths): missing files or stale content in the output may be because changes are pending in the VFS. Use vfs_diff to inspect pending changes and file_sync to apply them. On failure the exit code and output are returned as plain text (not signaled as an Elisp error), so you can read the failure and adapt. If the command outlives the tool timeout it is killed and its partial output is returned instead."
    :args (list '(:name "command"
                        :type string
                        :description "The shell command to run. Executed via `shell-file-name' with `shell-command-switch' (typically /bin/sh -c).")
                '(:name "directory"
                        :type string
                        :description "Optional working directory, relative to the workspace root or absolute. Defaults to the workspace root."
                        :optional t))
    :confirm t
    :category "shell")


   ;; 11. Execute arbitrary Elisp
   (gptel-yatools--make-tool
    :name "execute_elisp"
    :function
    (lambda (code)
      (cond
       ((not (stringp code))
        "Error: code must be a string.")
       ((string-empty-p (string-trim code))
        "Error: code is empty.")
       (t
        (let ((outbuf (generate-new-buffer " *gptel-elisp-output*"))
              (result nil)
              (error-msg nil)
              (printed ""))
          (unwind-protect
              (progn
                (condition-case err
                    (with-temp-buffer
                      (insert code)
                      (goto-char (point-min))
                      (read (current-buffer))
                      (skip-chars-forward " \t\n\r")
                      (unless (eobp)
                        (error "Trailing content after the first Lisp form")))
                  (error
                   (setq error-msg
                         (format "Parse error: %s"
                                 (error-message-string err)))))
                (unless error-msg
                  (gptel-yatools--update-tool-status
                   " Evaluating Elisp..." 'mode-line-emphasis)
                  (condition-case err
                      (let ((standard-output outbuf)
                            (default-directory
                             (gptel-yatools--workspace-root)))
                        (setq result
                              (save-excursion
                                (with-temp-buffer
                                  (insert code)
                                  (goto-char (point-min))
                                  (eval (read (current-buffer)) t)))))
                    (error
                     (setq error-msg
                           (format "Eval error: %s"
                                   (error-message-string err))))))
                (setq printed
                      (with-current-buffer outbuf
                        (buffer-substring-no-properties
                         (point-min) (point-max))))
                ;; This response, like every other tool's, is pasted
                ;; into the model's context: an unbounded `princ' loop
                ;; must not blow up the request.  Escaping keeps raw
                ;; bytes from breaking JSON serialisation.
                (gptel-yatools--truncate
                 (gptel-yatools--escape-raw-bytes
                  (cond
                   (error-msg
                    (format "%s\n\nPrinted output:\n%s\n(no value returned)"
                            error-msg
                            (if (string-empty-p printed) "(none)" printed)))
                   (t
                    (format "Elisp evaluation succeeded.\n\nPrinted output:\n%s\n\nReturn value:\n%s"
                            (if (string-empty-p printed) "(none)" printed)
                            (condition-case err
                                (let ((print-length 200)
                                      (print-level 30))
                                  (prin1-to-string result))
                              (error
                               (format "<unprintable value: %s>"
                                       (error-message-string err))))))))))
            (when (buffer-live-p outbuf)
              (kill-buffer outbuf)))))))
    :description
    "Evaluate a single Emacs Lisp form in the running Emacs. The user is ALWAYS prompted to confirm the exact form before it runs. The form is read with `read', so write it as Lisp source (e.g. `(buffer-name)' or `(+ 1 2)'), not as a quoted string. Returns the printed value of the form plus anything written to `standard-output' by the form. Parse errors, evaluation errors, and unprintable return values are reported as plain text (not signaled), so you can read the error and adapt. `default-directory' is bound to the workspace root during evaluation. Only one form is allowed per call."
    :args (list '(:name "code"
                        :type string
                        :description "A single Emacs Lisp form to evaluate, e.g. \"(buffer-list)\" or \"(+ 1 2)\"."))
    :confirm t
    :category "elisp")

))

(provide 'gptel-yatools-tools)
;;; gptel-yatools-tools.el ends here
