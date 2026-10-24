;;; gptel-yatools-shell.el --- Shell and workspace tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The tools that are neither filesystem nor skill tools: locating the
;; workspace root, and running a shell command in it.  The kit these tools
;; are built from -- the Result, the boundary, the deadline, and the macro
;; that writes both functions -- is `gptel-yatools-common.el'.  The VFS
;; lives in `gptel-yatools-vfs.el' and Agent Skills in
;; `gptel-yatools-skills.el'.
;;
;; The command runner is here rather than with the VFS because a command
;; runs against the disk and only *reports* on the VFS: when changes are
;; pending, its output carries a warning listing them.

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'gptel-yatools-common)
(require 'gptel-yatools-vfs)

(declare-function gptel-yatools--update-tool-status "gptel-yatools" (message &optional face))

(defun gptel-yatools-shell--command-result (output)
  "Return the result for a finished command whose combined output is OUTPUT.

When any VFS entries are pending, the envelope's comment warns the model
that the command ran against disk, not the VFS: a file it expected to
find may only exist in the pending changes, and one it read may be
stale.  That warning is the whole reason a command result carries the
VFS flag, since the output itself always describes the disk."
  (let ((changed (gptel-yatools-vfs-pending-paths)))
    (gptel-yatools-ok
     output
     :provenance (if changed :vfs :disk)
     :comment
     (if changed
         (format "WARNING: %d VFS file(s) have uncommitted changes (%s). The command ran against DISK, not the VFS. Missing files, stale content, or unexpected results in the output below may be because changes are pending in the VFS. Run vfs_diff to inspect, file_sync to apply."
                 (length changed)
                 (mapconcat #'gptel-yatools--display-path changed ", "))
       "Command ran against disk. VFS has no pending changes."))))

;;-------------------------------------------------------------------------
;; Command runner
;;-------------------------------------------------------------------------
(defun gptel-yatools-shell--run-command (command directory)
  "Run COMMAND (in DIRECTORY if non-empty) and return a result.

The result always carries a body: the command's exit code and combined
output, or a description of why it could not be started.

The command is killed once it outlives the current tool timeout
\(the call's deadline, or `gptel-yatools-timeout'), so a hung command
cannot block Emacs forever.  `call-process' cannot be interrupted --
timers do not run while it waits -- which is why this uses a real
process and polls it instead."
  (let* ((root (gptel-yatools--workspace-root))
         ;; Ask for the root once, before `default-directory' is rebound
         ;; below: a relative path and a message must both mean the
         ;; directory the call started in, not the subdirectory it runs
         ;; in.  The call's context already pins it, so there is nothing
         ;; to re-bind here.
         (timeout (gptel-yatools--call-deadline))
         (target-directory (if (and directory (not (string-empty-p directory)))
                               (expand-file-name directory root)
                             root))
         (shown-directory (gptel-yatools--display-path target-directory))
         (default-directory target-directory))
    (cond
     ((not (file-directory-p default-directory))
      (gptel-yatools-shell--command-result
       (format "Error: working directory does not exist: %s"
               shown-directory)))
     ((string-empty-p (string-trim command))
      (gptel-yatools-shell--command-result "Error: command is empty."))
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
                (gptel-yatools-vfs-disk-moved-externally)
                (gptel-yatools-shell--command-result
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
(gptel-yatools-define-tool gptel-yatools-read-workspace-root
  :name "read_workspace_root"
  :category "workspace"
  :description
  "Return the absolute path of the current workspace root. Use it to resolve relative paths."
  :args nil
  (gptel-yatools-ok (gptel-yatools--workspace-root)))

(gptel-yatools-define-tool gptel-yatools-execute-command
  :name "execute_command"
  :category "shell"
  :confirm t
  :preview '("command" "directory" "timeout")
  :description
  "Execute a shell command and return its exit status and combined stdout/stderr output. The user is ALWAYS prompted to confirm the exact command before it runs. The command runs against DISK, not the VFS. If any VFS files have uncommitted changes, a warning is prepended to the XML context (listing the pending paths): missing files or stale content in the output may be because changes are pending in the VFS. Use vfs_diff to inspect pending changes and file_sync to apply them. On failure the exit code and output are returned as plain text (not signaled as an Elisp error), so you can read the failure and adapt. If the command outlives the tool timeout it is killed and its partial output is returned instead."
  :args '((:name "command"
                :type string
                :description "The shell command to run. Executed via `shell-file-name' with `shell-command-switch' (typically /bin/sh -c).")
          (:name "directory"
                 :type string
                 :description "Optional working directory, relative to the workspace root or absolute. Defaults to the workspace root."
                 :optional t))
  (gptel-yatools--update-tool-status " Executing command..." 'mode-line-emphasis)
  (gptel-yatools-shell--run-command command directory))

;;-------------------------------------------------------------------------
;; What the user is asked to approve
;;
;; gptel renders a pending tool call with `gptel--format-tool-call', which
;; truncates every string argument at 256 characters.  For `execute_command'
;; that is the wrong failure: a command is approved on its text, so a long
;; one could be approved on a harmless prefix.
;;
;; The fix used to live here, as a renderer written by hand and registered
;; against `gptel--tool-preview-alist'.  It is now the `:preview' line of
;; the definition above, which is where the argument order it has to agree
;; with is declared -- see `gptel-yatools--preview-line' in
;; `gptel-yatools-common.el'.  Keeping it there means adding an argument
;; cannot leave the confirmation reading the wrong position, which is
;; exactly what it did once.
;;-------------------------------------------------------------------------

(provide 'gptel-yatools-shell)
;;; gptel-yatools-shell.el ends here
