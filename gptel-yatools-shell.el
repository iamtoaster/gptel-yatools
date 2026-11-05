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

(defun gptel-yatools-shell--refusal (sentence)
  "Return the result for a call refused before any command was started.

SENTENCE is what the model is told.  The comment is deliberately not the
command runner's: nothing ran, so nothing was read from disk and there is
no output for a VFS warning to qualify.  Saying \"Command ran against
disk\" here made a claim about an execution that never happened, and it
contradicted the body it was attached to."
  (gptel-yatools-ok sentence
                   :provenance :disk
                   :comment "No command was run."))

;;-------------------------------------------------------------------------
;; Command runner
;;-------------------------------------------------------------------------
(defun gptel-yatools-shell--where (directory)
  "Return DIRECTORY as a command report should name it.

A local directory reads as a workspace-relative path, exactly as before.
A remote one names the host as well, because that is the one fact the
model must not be left to infer: the command ran *there*, not on the
machine Emacs is running on, and a report that says only \".\" cannot be
told apart from the local case.

The host is named through `gptel-yatools--connection-label', the same
function `gptel-yatools-shell--machine' uses, so a report and a refusal
cannot disagree about which machine they mean."
  (let ((label (gptel-yatools--connection-label directory)))
    (if label
        (format "%s on the remote host %s"
                (gptel-yatools--display-path directory)
                label)
      (gptel-yatools--display-path directory))))

(defun gptel-yatools-shell--shell (directory)
  "Return the shell a command in DIRECTORY is handed to, as (PROGRAM . SWITCH).

`shell-file-name' and `shell-command-switch' describe the shell on *this*
machine.  A remote workspace has its own, and a local path there names
nothing: the adapter used to hand the runner
`(shell-file-name shell-command-switch COMMAND)', which on a host without
that path is `exec: /run/…/zsh: not found' and exit 127."
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

A command is approved for a workspace, so it has to run where that
workspace is.  Two paths are on the same machine when their connections
are `equal' -- see `gptel-yatools--connection' -- or when neither is
remote at all; anything else would run the command somewhere the user did
not approve it for.

The check runs before anything asks whether DIRECTORY exists: asking that
of a path on another host would open a connection to a machine the user
never named."
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
  "Run COMMAND (in DIRECTORY if non-empty) and return a result.

The result always carries a body: the command's exit code and combined
output, or a description of why it could not be started.

The command is killed once it outlives the current tool timeout
\(the call's deadline, or `gptel-yatools-timeout'), so a hung command
cannot block Emacs forever.  The spawner, the kill and the reap are
`gptel-yatools--spawn-process's, in `gptel-yatools-common.el': this
function is the adapter that turns an outcome into the sentence the
model reads.

The command is started, not waited for: the job goes back to the
boundary, which either waits for it or hands the answer to gptel's
callback, depending on whether the tool is declared `:async'.

A command runs where its workspace is, so a DIRECTORY on a different
machine is refused rather than quietly run there: `expand-file-name' lets
an absolute path replace the workspace root, and a command approved for a
workspace would then touch a file system nobody named.  See
`gptel-yatools-shell--elsewhere'."
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
         (shown-directory (gptel-yatools-shell--where target-directory))
         ;; Resolved first because it is the first thing that can go
         ;; wrong: a DIRECTORY on another machine must not even be asked
         ;; whether it exists, since that question opens a connection.
         (elsewhere (gptel-yatools-shell--elsewhere root target-directory)))
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
      (let ((shell (gptel-yatools-shell--shell target-directory)))
        (gptel-yatools--spawn-process
         ;; The spawner merges stderr and closes stdin for every caller, so
         ;; this adapter supplies nothing but the command itself and the
         ;; directory -- the shell is this machine's locally and the
         ;; host's remotely.
         (list (car shell) (cdr shell) command)
         :directory target-directory
         :timeout timeout
         :description "command"
         :result
         (lambda (outcome)
           ;; Runs when the command has finished, in the buffer that owns
           ;; the call -- minutes later, for an asynchronous one.  The
           ;; pending-VFS warning is computed now, not at call time,
           ;; because it explains the output the model is about to read.
           ;;
           ;; The command may also have changed files on disk, which can
           ;; change which pending entries still differ, so the cached
           ;; header-line count must not outlive it.
           (gptel-yatools-vfs-disk-moved-externally)
           (gptel-yatools-shell--command-result
            (gptel-yatools-shell--outcome-text outcome shown-directory timeout)))))))))

(defun gptel-yatools-shell--outcome-text (outcome shown-directory timeout)
  "Return the model-facing text for a finished command's OUTCOME.

SHOWN-DIRECTORY is where the command ran, as it should be named, and
TIMEOUT the budget it was given.  Every sentence here says what happened
rather than what was hoped for: a killed command is not a failed one, and
a command that never started says why."
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
;; gptel renders a pending tool call with `gptel--format-tool-call', which
;; truncates every string argument at 256 characters.  For `execute_command'
;; that is the wrong failure: a command is approved on its text, so a long
;; one could be approved on a harmless prefix.  It also escapes a newline,
;; which matters just as much here, because an inline script arrives as
;; one -- see `gptel-yatools--printable-block'.
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
