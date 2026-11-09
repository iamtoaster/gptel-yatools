;;; gptel-yatools-shell.el --- Shell and workspace tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vladislav Slobodenyuk

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
;; A command runs against the disk and only *reports* on the VFS.

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'gptel-yatools-common)
(require 'gptel-yatools-vfs)

(declare-function gptel-yatools--update-tool-status "gptel-yatools" (message &optional face))

(defun gptel-yatools-shell--command-result (output)
  "Return the result for a finished command whose combined output is OUTPUT.

When VFS entries are pending, the envelope's comment warns that the command
ran against disk."
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

(defun gptel-yatools-shell--refusal (sentence)
  "Return the result for a call refused before any command was started.

SENTENCE is what the model is told."
  (gptel-yatools-ok sentence
                   :provenance :disk
                   :comment "No command was run."))

;;-------------------------------------------------------------------------
;; Command runner
;;-------------------------------------------------------------------------
(defun gptel-yatools-shell--where (directory)
  "Return DIRECTORY as a command report should name it.

A local directory reads as a workspace-relative path; a remote one names
the host, as `gptel-yatools--connection-label' reports it."
  (let ((label (gptel-yatools--connection-label directory)))
    (if label
        (format "%s on the remote host %s"
                (gptel-yatools--display-path directory)
                label)
      (gptel-yatools--display-path directory))))

(defun gptel-yatools-shell--run-command (command directory)
  "Start COMMAND in DIRECTORY and return a job for it.

DIRECTORY is resolved against the workspace root when non-empty; empty or
nil means the root itself.  A DIRECTORY on another machine is refused
rather than run there.

The result always carries a body: the exit code and combined output, or
why the command could not be started.  The command is killed when it
outlives the current tool deadline.  It is started, not waited for: the
job goes back to the boundary."
  (let* ((root (gptel-yatools--workspace-root))
         (timeout (gptel-yatools--call-deadline))
         (target-directory (if (and directory (not (string-empty-p directory)))
                               (expand-file-name directory root)
                             root))
         (shown-directory (gptel-yatools-shell--where target-directory))
         ;; Asked before anything tests whether the target exists, since
         ;; that would open a connection to a host the user never named.
         (elsewhere (gptel-yatools--elsewhere-sentence
                     root target-directory "command runs")))
    (cond
     (elsewhere
      (gptel-yatools-shell--refusal elsewhere))
     ((not (file-directory-p target-directory))
      (gptel-yatools-shell--refusal
       (format "Error: working directory does not exist: %s"
               shown-directory)))
     ((string-empty-p (string-trim command))
      (gptel-yatools-shell--refusal "Error: command is empty."))
     (t
      (gptel-yatools--spawn-process
       command
       :directory target-directory
       :timeout timeout
       :description "command"
       :result
       (lambda (outcome)
         ;; Runs when the command has finished, in the buffer that owns
         ;; the call.  The pending-VFS warning is computed now, because
         ;; it explains the output the model is about to read.
         ;;
         ;; The command may have changed files on disk, so the cached
         ;; header-line count must not outlive it.
         (gptel-yatools-vfs-disk-moved-externally)
         (gptel-yatools-shell--command-result
          (gptel-yatools-shell--outcome-text outcome shown-directory timeout))))))))

(defun gptel-yatools-shell--outcome-text (outcome shown-directory timeout)
  "Return the model-facing text for a finished command's OUTCOME.

SHOWN-DIRECTORY is where the command ran, as it should be named, and
TIMEOUT the budget it was given."
  (let ((output (plist-get outcome :output))
        (exit (plist-get outcome :exit)))
    (pcase (plist-get outcome :status)
      ('start-error
       (format "Failed to start command in %s.\nError: %s"
               shown-directory (string-trim output)))
      ('timed-out
       (format "Command killed in %s: it exceeded its %s second timeout and was terminated. It did not finish, so do not assume it completed. Partial output:\n%s"
               shown-directory timeout
               (if (string-empty-p output) "(no output)" output)))
      ((and 'exited (guard (and (integerp exit) (zerop exit))))
       (format "Command succeeded in %s (exit code 0).\nOutput:\n%s"
               shown-directory
               (if (string-empty-p output) "(no output)" output)))
      ((and 'exited (guard (integerp exit)))
       (format "Command failed in %s (exit code %d).\nOutput:\n%s"
               shown-directory exit
               (if (string-empty-p output) "(no output)" output)))
      (_
       (format "Command terminated by signal in %s: %s\nOutput:\n%s"
               shown-directory exit
               (if (string-empty-p output) "(no output)" output))))))


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
  :async t
  :preview '("command" "directory" "timeout")
  :description
  "Execute a shell command and return its exit status and combined stdout/stderr output. The user is ALWAYS prompted to confirm the exact command before it runs. The command runs against DISK, not the VFS. The call returns as soon as the command has started: this tool runs in the background, so the result arrives later and a returned call does not mean the command has finished. The chat waits for it -- you will get the result before your next turn -- but do not assume completion in the meantime. Commands issued in one response may run concurrently, so put dependent steps in separate calls. When the workspace root is on a remote host (a TRAMP path such as /ssh:host:/repo), the command runs there, under that host's shell, not on your machine; DIRECTORY must then be workspace-relative or a path on that same host. DIRECTORY may never name a different machine, local or remote: a command approved for a workspace has to run where that workspace is. If any VFS files have uncommitted changes, a warning is prepended to the XML context (listing the pending paths): missing files or stale content in the output may be because changes are pending in the VFS. Use vfs_diff to inspect pending changes and file_sync to apply them. On failure the exit code and output are returned as plain text (not signaled as an Elisp error), so you can read the failure and adapt. If the command outlives the tool timeout it is killed and its partial output is returned instead."
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
;; gptel truncates every string argument at 256 characters, so the `:preview'
;; of the definition above names the arguments to show instead.
;;-------------------------------------------------------------------------

(provide 'gptel-yatools-shell)
;;; gptel-yatools-shell.el ends here
