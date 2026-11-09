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
  "Return the result for a finished command whose combined output is OUTPUT."
  (gptel-yatools-ok
   output
   :provenance :disk
   :comment "Command ran against disk."))

(defun gptel-yatools-shell--pending-refusal (paths)
  "Return the result refusing to run while PATHS are pending in the VFS.

The command would read disk, not the VFS, so the model would be handed an
answer describing files that are about to change -- and would run the same
command again after syncing to find out.  Refusing says so once, before
anything runs, and names the three ways out."
  (gptel-yatools-ok
   (format "\
Error: no command was run: %d file(s) are pending in the VFS (%s).

A command reads DISK, so its output would describe the files as they
were before your changes, not as you have written them -- which is how
the same command gets run twice.  Nothing here is broken: these changes
simply are not on disk yet.

Resolve the VFS first:
  vfs_diff    show what is pending
  file_sync   review the diffs and write them to disk
  vfs_discard drop the pending changes instead"
           (length paths)
           (mapconcat #'gptel-yatools--display-path paths ", "))
   :provenance :vfs
   :comment "No command was run: the VFS holds changes that are not on disk yet."))

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

(defun gptel-yatools-shell--shell (directory)
  "Return the shell a command in DIRECTORY is handed to, as (PROGRAM . SWITCH).

`shell-file-name' and `shell-command-switch' describe this machine's shell;
a remote workspace has its own."
  (if (file-remote-p directory)
      (cons (gptel-yatools--remote-shell directory) "-c")
    (cons shell-file-name shell-command-switch)))

(defun gptel-yatools-shell--machine (path)
  "Return PATH's machine as a phrase fit for a sentence."
  (let ((label (gptel-yatools--connection-label path)))
    (if label
        (format "the remote host %s" label)
      "this machine")))

(defun gptel-yatools-shell--elsewhere (root target)
  "Return why TARGET is not on the same machine as ROOT, or nil.

Two paths are on the same machine when `gptel-yatools--connection' reports
the same connection for both.  Asked before anything tests whether TARGET
exists, since that would open a connection to a host the user never named."
  (unless (equal (gptel-yatools--connection root)
                 (gptel-yatools--connection target))
    (let ((here (gptel-yatools-shell--machine root))
          (there (gptel-yatools-shell--machine target)))
      (format "Error: the workspace is on %s, but DIRECTORY resolves to %s, which is on %s. Give DIRECTORY relative to the workspace root, or as a path on %s, so the command runs where the workspace is."
              here
              (gptel-yatools--display-path target)
              there
              here))))

(defun gptel-yatools-shell--run-command (command directory)
  "Start COMMAND in DIRECTORY and return a job for it.

DIRECTORY is resolved against the workspace root when non-empty; empty or
nil means the root itself.  A DIRECTORY on another machine is refused
rather than run there, and so is any command while the VFS holds changes
that are not on disk yet: see `gptel-yatools-shell--pending-refusal'.

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
         (pending (gptel-yatools-vfs-pending-paths))
         (elsewhere (gptel-yatools-shell--elsewhere root target-directory)))
    (cond
     (pending
      (gptel-yatools-shell--pending-refusal pending))
     (elsewhere
      (gptel-yatools-shell--refusal elsewhere))
     ((not (file-directory-p target-directory))
      (gptel-yatools-shell--refusal
       (format "Error: working directory does not exist: %s"
               shown-directory)))
     ((string-empty-p (string-trim command))
      (gptel-yatools-shell--refusal "Error: command is empty."))
     (t
      (let ((shell (gptel-yatools-shell--shell target-directory)))
        (gptel-yatools--spawn-process
         (list (car shell) (cdr shell) command)
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
            (gptel-yatools-shell--outcome-text outcome shown-directory timeout)))))))))

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
  "Execute a shell command and return its exit status and combined stdout/stderr output. The user is ALWAYS prompted to confirm the exact command before it runs. The command runs against DISK, not the VFS. If the VFS holds changes that are not on disk yet, the command is REFUSED before it starts, with the pending paths named: a command would answer from the old content, so call vfs_diff to inspect, file_sync to write the changes to disk, or vfs_discard to drop them, and then run the command. The call returns as soon as the command has started: this tool runs in the background, so the result arrives later and a returned call does not mean the command has finished. The chat waits for it -- you will get the result before your next turn -- but do not assume completion in the meantime. Commands issued in one response may run concurrently, so put dependent steps in separate calls. When the workspace root is on a remote host (a TRAMP path such as /ssh:host:/repo), the command runs there, under that host's shell, not on your machine; DIRECTORY must then be workspace-relative or a path on that same host. DIRECTORY may never name a different machine, local or remote: a command approved for a workspace has to run where that workspace is. On failure the exit code and output are returned as plain text (not signaled as an Elisp error), so you can read the failure and adapt. If the command outlives the tool timeout it is killed and its partial output is returned instead."
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
