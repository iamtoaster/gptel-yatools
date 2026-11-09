;;; gptel-yatools-common.el --- What every gptel-yatools tool is  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The kit a tool is built from: the Result it returns, the boundary that
;; renders it, the deadline that aborts it, and the macro that defines it.
;;
;; This file is what the tool modules require, so it must not depend on any
;; of them.  It is loaded first, before the filesystem, shell and skill
;; tools; only `gptel-yatools.el' comes after, holding the gptel plumbing
;; that makes a call run in the buffer that owns the request.
;;
;; A tool is four things, and `gptel-yatools-define-tool' writes all four
;; from one definition:
;;
;; 1. An implementation function, `NAME-tool', which takes the tool's
;;    arguments and returns a `gptel-yatools-result'.  It says what it
;;    found; it never formats, truncates or escapes anything.
;; 2. A boundary function, `NAME', which gptel calls.  It adds the optional
;;    TIMEOUT argument, checks each argument against the type the
;;    definition declares for it, enforces the deadline, renders the Result
;;    into the envelope the model sees, and turns a signalled error into
;;    that same envelope.
;; 3. The `gptel-tool' struct, registered in gptel's registry and in this
;;    package's own list.
;; 4. A confirmation renderer, for a tool that asks for one with
;;    `:preview'.  gptel's own formatter truncates every string argument at
;;    256 characters, which is the wrong failure for a call whose arguments
;;    are what the user is approving.
;;
;; Both functions are named, so both can be advised, traced and found with
;; `C-h f'.  Advice on `NAME-tool' sees the tool's own arguments and can
;; rewrite its Result; advice on `NAME' sees everything, including the
;; deadline, and can stand in for the whole call.
;;
;; This file is one module with four interfaces, each meant to be crossed at
;; one seam rather than reached into:
;;
;;   respond   `gptel-yatools--respond' (render a Result), and
;;             `gptel-yatools-page' (the size budget, for a tool that pages
;;             its own output).  Sizing, truncation, raw-byte escaping and
;;             the envelope all live behind these; no tool does any of it
;;             itself, and no tool calls `--truncate', `--envelope' or
;;             `--escape-raw-bytes' directly.
;;
;;   call      `gptel-yatools--call-with-timeout' and the accessors that
;;             read the `gptel-yatools-call' it binds: `--call-root',
;;             `--call-deadline', `--call-suspended-p', and
;;             `--with-deadline-suspended' for the one field that moves.
;;             Everything a call settles once -- root, deadline, the pause
;;             for a user who is reading a diff -- is asked for here.
;;             The argument checks run just inside it, generated from the
;;             tool's `:args', so a wrong-typed value is refused with an
;;             envelope and a sentence rather than a raw condition.
;;
;;   define    `gptel-yatools-define-tool', which writes the implementation,
;;             the boundary and the preview from one definition and
;;             registers the tool, and `gptel-yatools-enable' /
;;             `-enable-all', which decide what is sent.  The definition is
;;             the only place a tool's name, arguments, model-facing
;;             description and confirmation are written down.
;;
;;   run       `gptel-yatools--run-process' (run an argv under a deadline
;;             and say what happened).  Two tool modules run subprocesses --
;;             the shell runner and the diagram renderer -- and both need
;;             the same four rules: merge stderr, close stdin, keep the
;;             output even when the process is killed, and kill the whole
;;             process group.  The rules live here so that a caller cannot
;;             get one of them wrong, and so that a fix to a hung process
;;             is a fix in one place.  See "Running a process" below.
;;
;; See the README for the tool list and for installation instructions.

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'project)

;; TRAMP is not a dependency: it is loaded by Emacs whenever a remote file
;; name is read, and a workspace is remote only when it already is.  These
;; two functions are the only ones this package calls, and both are asked
;; behind a `fboundp' guard.
(declare-function tramp-dissect-file-name "tramp" (file &optional nested))
(declare-function tramp-get-method-parameter "tramp" (vec key))
(declare-function tramp-tramp-file-p "tramp" (name))
(declare-function tramp-file-name-hop "tramp" (vec))
(declare-function tramp-file-name-method "tramp" (vec))
(declare-function tramp-file-name-user "tramp" (vec))
(declare-function tramp-file-name-host "tramp" (vec))
(declare-function tramp-file-name-port "tramp" (vec))
(declare-function tramp-file-name-localname "tramp" (vec))

(defgroup gptel-yatools nil
  "Extra tools for gptel."
  :group 'gptel
  :prefix "gptel-yatools-")

;; Declared here so the functions below can refer to it; the `defcustom'
;; that gives it a value and a setter is further down, once the setter
;; exists -- `defcustom' calls its `:set' as it defines the variable.
(defvar gptel-yatools-timeout)
(defvar gptel-yatools-async-timeout)

(cl-defstruct (gptel-yatools-call (:constructor gptel-yatools--make-call))
  "The facts about the tool call in progress.

  ROOT      the workspace root, settled once at the boundary.
  DEADLINE  seconds the call may run for.
  SUSPENDED non-nil while the call is waiting for the user, whose time
            does not count against DEADLINE.

ROOT and DEADLINE are read-only once bound.  SUSPENDED moves only through
`gptel-yatools--with-deadline-suspended'."
  (root nil)
  (deadline nil)
  (suspended nil))

(defvar gptel-yatools--call nil
  "The `gptel-yatools-call' in progress, or nil outside a tool call.

Bound by `gptel-yatools--call-with-timeout'.")

(defun gptel-yatools--call-root ()
  "Return the workspace root of the call in progress.

Outside a call, detect one with `gptel-yatools--detect-workspace-root'.
Inside one, the root settled at the boundary, even if the tool rebinds
`default-directory'."
  (or (and gptel-yatools--call (gptel-yatools-call-root gptel-yatools--call))
      (gptel-yatools--detect-workspace-root)))

(defun gptel-yatools--call-deadline ()
  "Return the deadline in seconds of the call in progress.

Falls back on `gptel-yatools-timeout' outside a call."
  (or (and gptel-yatools--call
           (gptel-yatools-call-deadline gptel-yatools--call))
      (gptel-yatools--resolve-timeout nil)))

(defun gptel-yatools--call-suspended-p ()
  "Return non-nil while the call in progress is waiting for the user."
  (and gptel-yatools--call
       (gptel-yatools-call-suspended gptel-yatools--call)))

;;-------------------------------------------------------------------------
;; Running a process
;;
;; Two tool modules run subprocesses, and neither of them wants to know how
;; one is polled, killed and reaped.  The four rules below are the same for
;; both:
;;
;;   - stderr is merged into stdout in the shell, because with `:stderr'
;;     Emacs creates a pipe process whose default sentinel appends
;;     "Process ... finished" to the very buffer being read as output;
;;   - stdin is closed at once, because a process that reads it (a pager,
;;     `cat', an interactive program) waits forever for input that never
;;     comes;
;;   - output is returned even when the process is killed, because partial
;;     output is how the model learns what the command got as far as;
;;   - the kill is the whole process group, because Emacs puts each
;;     subprocess in one and the shell may ignore SIGINT while its children
;;     carry on.
;;
;; A real process is polled rather than `call-process' because only that
;; can be interrupted when the call's deadline expires: timers do not run
;; while `call-process' waits.
;;
;; When the workspace is remote -- a TRAMP name such as "/ssh:host:/repo"
;; -- two of those rules mean something different, and getting either
;; wrong is silent rather than loud:
;;
;;   - the program is the *remote* shell, because `shell-file-name' names a
;;     file on this machine.  Asking a container for this machine's shell
;;     is a command that never starts;
;;   - the kill goes through `signal-process' on the process object, which
;;     TRAMP translates into a remote `kill'.  A remote process's id is the
;;     id of the local ssh/docker client, so the process-group kill used
;;     for local commands signals a group here and leaves the command
;;     running on the host.
;;
;; Everything else -- merging stderr, closing stdin, keeping the output of
;; a process that was killed -- is the same on a remote host, because it is
;; the shell we ask the host to run that does it.
;;-------------------------------------------------------------------------

(defconst gptel-yatools--remote-shell-candidates '("/bin/sh" "/bin/ash" "ash")
  "Shells to try, in order, when a command runs on a remote host.

Consulted after the host's own `tramp-remote-shell', which is a default
rather than a guarantee.")

(defvar gptel-yatools--remote-shell-cache (make-hash-table :test #'equal)
  "The shell found on each remote host, keyed by connection.

Caches a probe that costs one round trip per candidate.")

(defun gptel-yatools--remote-shell-declared (directory)
  "Return the shell DIRECTORY's TRAMP method declares, or nil."

  (when (fboundp 'tramp-dissect-file-name)
    (ignore-errors
      (let ((shell (tramp-get-method-parameter
                    (tramp-dissect-file-name directory) 'tramp-remote-shell)))
        (and (stringp shell) shell)))))

(defun gptel-yatools--connection (path)
  "Return a value identifying the machine PATH lives on, or nil for this one.

Two paths are on the same machine when their connections are `equal'.

`file-remote-p' alone cannot answer it: for a multi-hop name it returns
only the last hop, so \"/ssh:a|sudo:root@b:/etc/\" and
\"/ssh:c|sudo:root@b:/etc/\" look alike although they leave from different
machines.  TRAMP's dissection keeps the hop, so the identity is method,
user, host, port and the hop chain.  A name handled by something other
than TRAMP falls back on the prefix `file-remote-p' gives."
  (when-let* ((remote (file-remote-p path)))
    (or (and (fboundp 'tramp-tramp-file-p)
             (tramp-tramp-file-p path)
             (ignore-errors
               (let ((v (tramp-dissect-file-name path)))
                 (list (tramp-file-name-hop v)
                       (tramp-file-name-method v)
                       (tramp-file-name-user v)
                       (tramp-file-name-host v)
                       (tramp-file-name-port v)))))
        (list remote))))

(defun gptel-yatools--connection-label (path)
  "Return the connection PATH lives on as a short string, or nil if local.

Of the form \"ssh:a|sudo:root@b\", built from
`gptel-yatools--connection'."
  (pcase (gptel-yatools--connection path)
    (`(,hop ,method ,user ,host ,port)
     (concat hop method ":"
             (and user (concat user "@"))
             host
             (and port (concat "#" port))))
    (`(,prefix) (string-remove-suffix ":" prefix))))

(defun gptel-yatools--remote-shell (directory)
  "Return the shell to run a remote command with on DIRECTORY's host.

DIRECTORY is a remote file name; the answer is an absolute path on that
host.  Each candidate is tested with `file-executable-p' on the host,
including the shell the TRAMP method declares, which is a default rather
than a promise.  When none can be asked, the first candidate is returned."
  (let ((remote (file-remote-p directory)))
    (or (gethash remote gptel-yatools--remote-shell-cache)
        (let* ((candidates
                (delete-dups
                 (delq nil (cons (gptel-yatools--remote-shell-declared directory)
                                 gptel-yatools--remote-shell-candidates))))
               (found (cl-find-if
                       (lambda (shell)
                         (file-executable-p (concat remote shell)))
                       candidates)))
          (puthash remote (or found (car candidates))
                   gptel-yatools--remote-shell-cache)))))
;;-------------------------------------------------------------------------

;;-------------------------------------------------------------------------
;; Jobs: work a tool has started and not yet finished
;;
;; A tool that hands its work to a process returns a job instead of a
;; Result: the body says what to run and how to read the outcome, and the
;; boundary decides whether to wait for it.  That decision is the only
;; difference between a synchronous and an asynchronous tool.
;;
;; A job concludes exactly once, since a deadline timer and a process
;; sentinel can both fire and gptel counts a tool result every time its
;; callback runs.
;;
;; `gptel-yatools--make-job-live' is the only place a job becomes live: it
;; registers it, installs the kill hook, arms the deadline and starts the
;; status line.  It starts nothing -- the work is already running -- and a
;; job is registered at the moment it can be stopped.  See ADR 0005.
;;-------------------------------------------------------------------------

(defconst gptel-yatools--job-output-limit 1000000
  "Characters of output a running job will hold before it stops reading.

A ceiling far above the envelope limit, so ordinary truncation is
unaffected but a command that loops for its whole budget cannot fill the
buffer.")

(cl-defstruct (gptel-yatools-job (:constructor gptel-yatools--make-job))
  "Work a tool has started and not yet finished.

A process job leaves the function slots nil; a job that is not a process
supplies `outcome-function' and `cancel'.

KIND       a symbol naming the work in the status line: `command' or
           `subagent'.
PROCESS    the process, or nil when it could not be started or when the
           work is not a process.
BUFFER     the buffer that owns the call.
OUTPUT     the buffer the process writes into.
RESULT     a function of the outcome plist returning the Result to report.
REMOTE     non-nil when the process runs on a TRAMP host.
STARTED    `float-time' at which the job was spawned.
DEADLINE   `float-time' after which the job is killed, or nil for none.
CONCLUDE   a function of the outcome plist, run exactly once.
TIMER      the deadline timer, cancelled when the job concludes.
TIMED-OUT  non-nil once the deadline has fired.
START-ERROR the message when the process could not be started.
DELIVERED  non-nil once CONCLUDE has run.
SETTLED    non-nil once the work has finished, delivered or not.
OUTCOME    the outcome plist recorded when the job settled.
DATA       whatever the job's own functions need.
OUTCOME-FUNCTION a function of JOB returning the outcome plist, for work
           that is not a process.
CANCEL     a function of JOB and a reason, stopping the work without
           concluding it.  REASON is `cancelled' or `timed-out'."
  (process nil)
  (buffer nil)
  (output nil)
  (result nil)
  (remote nil)
  (started nil)
  (deadline nil)
  (description "process")
  (conclude nil)
  (timer nil)
  (timed-out nil)
  (start-error nil)
  (delivered nil)
  (kind 'command)
  (settled nil)
  (outcome nil)
  (data nil)
  (outcome-function nil)
  (cancel nil))

(defvar-local gptel-yatools--jobs nil
  "The jobs this buffer has started and not yet concluded, newest first.

Buffer-local: a job's result is rendered against the VFS of the chat that
started it.  Emptied by `gptel-yatools-cancel-tool-calls'.")

(defun gptel-yatools--jobs-live (&optional buffer)
  "Return the jobs still running for BUFFER, or for the current buffer."
  (let ((jobs (if buffer
                  (and (buffer-live-p buffer)
                       (buffer-local-value 'gptel-yatools--jobs buffer))
                gptel-yatools--jobs)))
    (cl-remove-if #'gptel-yatools-job-delivered jobs)))

;;-------------------------------------------------------------------------
;; Saying that something is running
;;
;; gptel already shows "Calling tool (...)"; what it does not show is how
;; long the call has been running.
;;
;; One timer per buffer, not per job: it runs while any job in that buffer
;; is live, so two parallel commands share one clock.  It only runs when the
;; header line is in use, because `gptel--update-status' otherwise falls
;; through to `message'.
;;-------------------------------------------------------------------------

(defvar-local gptel-yatools--jobs-timer nil
  "The timer that ticks this buffer's running-tool status, or nil.")

(defconst gptel-yatools--jobs-tick-interval 1.0
  "Seconds between refreshes of the running-tool status.")

(declare-function gptel--update-status "gptel" (msg &optional face))
(declare-function gptel--fsm-transition "gptel-request" (machine &optional new-state))

(defun gptel-yatools--job-kind-name (kind count)
  "Return the word describing COUNT jobs of KIND.

A `command' job is a command, a `subagent' job a subagent, and any other
KIND prints itself."
  (let ((word (pcase kind
                ('command "command")
                ('subagent "subagent")
                (_ (format "%s" kind)))))
    (if (= count 1) word (concat word "s"))))

(defun gptel-yatools--job-counts-by-kind (jobs)
  "Return (KIND . COUNT) for each kind in JOBS.

Commands first, then subagents, then anything else alphabetically."
  (let ((counts (cl-loop for job in jobs
                         for kind = (gptel-yatools-job-kind job)
                         for cell = (assq kind counts)
                         if cell do (setcdr cell (1+ (cdr cell)))
                         else collect (cons kind 1) into counts
                         finally return counts)))
    (cl-sort counts
             (lambda (a b)
               (let ((rank (lambda (kind)
                             (pcase kind
                               ('command 0)
                               ('subagent 1)
                               (_ 2)))))
                 (if (= (funcall rank (car a)) (funcall rank (car b)))
                     (string< (format "%s" (car a)) (format "%s" (car b)))
                   (< (funcall rank (car a)) (funcall rank (car b)))))))))

(defun gptel-yatools--jobs-status-text (jobs)
  "Return the status line for JOBS, or nil when there are none."
  (when jobs
    (let* ((oldest (apply #'min (mapcar #'gptel-yatools-job-started jobs)))
           (elapsed (max 0 (truncate (- (float-time) oldest))))
           (counts (gptel-yatools--job-counts-by-kind jobs))
           (what (mapconcat (lambda (cell)
                              (format "%d %s" (cdr cell)
                                      (gptel-yatools--job-kind-name (car cell)
                                                                    (cdr cell))))
                            counts ", ")))
      (format " Running %s... %ds (C-c C-k cancels)" what elapsed))))

(defun gptel-yatools--jobs-tick (buffer)
  "Refresh BUFFER's running-tool status, or stop ticking when nothing runs."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((jobs (gptel-yatools--jobs-live)))
        (cond
         ((null jobs)
          (when (timerp gptel-yatools--jobs-timer)
            (cancel-timer gptel-yatools--jobs-timer)
            (setq gptel-yatools--jobs-timer nil)))
         ((not (and (bound-and-true-p gptel-mode) gptel-use-header-line))
          nil)
         ((fboundp 'gptel--update-status)
          (gptel--update-status (gptel-yatools--jobs-status-text jobs)
                                'mode-line-emphasis)))))))

(defun gptel-yatools--jobs-note-change ()
  "Start or stop this buffer's ticking status, as its jobs come and go."
  (let ((jobs (gptel-yatools--jobs-live)))
    (if (and jobs
             (bound-and-true-p gptel-mode)
             gptel-use-header-line)
        (unless (timerp gptel-yatools--jobs-timer)
          (setq gptel-yatools--jobs-timer
                (run-with-timer 0 gptel-yatools--jobs-tick-interval
                                #'gptel-yatools--jobs-tick (current-buffer))))
      (when (timerp gptel-yatools--jobs-timer)
        (cancel-timer gptel-yatools--jobs-timer)
        (setq gptel-yatools--jobs-timer nil)))
    ;; No status is set when nothing is running: gptel's own handlers move
    ;; the status on to "Waiting..." or "Ready".
    nil))

;;-------------------------------------------------------------------------
;; Cancelling
;;
;; Nothing else can stop a running tool: `C-g' has nothing to interrupt, and
;; `gptel-abort' looks the request up by its network process, which has
;; finished by the time a tool runs.
;;
;; The jobs are killed first and the request stopped second: delivering a
;; "cancelled" result instead would let the model retry the command.
;;-------------------------------------------------------------------------

(defun gptel-yatools--abort-request (&optional buffer)
  "Move BUFFER's gptel request to its abort state, when it has one.

The state machine is held in the chat buffer in `gptel--fsm-last', by
`gptel--update-tool-call', before the tool runs."
  (with-current-buffer (or buffer (current-buffer))
    (let ((fsm (bound-and-true-p gptel--fsm-last)))
      (when (gptel-fsm-p fsm)
        (ignore-errors (gptel--fsm-transition fsm 'ABRT))))))

(defun gptel-yatools--cancel-jobs (&optional buffer)
  "Kill every job BUFFER has running, delivering nothing.  Return how many."
  (let ((jobs (gptel-yatools--jobs-live (or buffer (current-buffer)))))
    (mapc #'gptel-yatools--job-abandon jobs)
    (length jobs)))

(defvar-local gptel-yatools--cancel-function nil
  "Function to stop this buffer's work when it started no jobs of its own.

Set by a module whose buffer runs work belonging to another buffer's tool
call, such as a subagent buffer.  `gptel-yatools-cancel-tool-calls' calls
it when the buffer has no live jobs.")

(defun gptel-yatools-cancel-tool-calls (&optional buffer)
  "Kill BUFFER's running tool calls and stop its request.

Signals a `user-error' when there is nothing to stop, unless the buffer set
`gptel-yatools--cancel-function'."
  (interactive)
  (let* ((buffer (or buffer (current-buffer)))
         (count (gptel-yatools--cancel-jobs buffer)))
    (cond
     ((> count 0)
      (gptel-yatools--abort-request buffer)
      (message "Cancelled %d tool call%s" count (if (= count 1) "" "s")))
     ((and (buffer-live-p buffer)
           (buffer-local-value 'gptel-yatools--cancel-function buffer))
      (with-current-buffer buffer
        (funcall gptel-yatools--cancel-function)))
     (t
      (user-error "No tool call is running in %s" (buffer-name buffer))))))

(defun gptel-yatools--job-filter (process chunk)
  "Record CHUNK as PROCESS's output, up to the job's ceiling.

A filter rather than `:buffer', so a command that prints without end
cannot grow a buffer without end."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((room (- gptel-yatools--job-output-limit (buffer-size))))
          (when (> room 0)
            (goto-char (point-max))
            (insert (if (> (length chunk) room)
                        (concat (substring chunk 0 room)
                                "\n[... output truncated: the command printed more than this while it was still running ...]\n")
                      chunk))))))))

(defun gptel-yatools--job-outcome (job)
  "Return JOB's outcome as the plist `gptel-yatools--run-process' returns.

The keys are `:status', `:exit' and `:output', plus `:timed-out' when the
deadline is what ended it.  A process that never started reports why in
`:output'."
  (let* ((process (gptel-yatools-job-process job))
         (start-error (gptel-yatools-job-start-error job))
         (timed-out (gptel-yatools-job-timed-out job))
         (exit (and process (not timed-out) (not start-error)
                    (ignore-errors (process-exit-status process))))
         (output (or start-error
                     (let ((buffer (gptel-yatools-job-output job)))
                       (if (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (buffer-substring-no-properties
                              (point-min) (point-max)))
                         "")))))
    (list :status (cond (start-error 'start-error)
                        (timed-out 'timed-out)
                        (t 'exited))
          :exit (and (not timed-out) (not start-error) exit)
          :timed-out (and timed-out t)
          :output output)))

(defun gptel-yatools--job-release (job)
  "Forget JOB: cancel its timer, unlist it and drop its output buffer."
  (let ((timer (gptel-yatools-job-timer job)))
    (when (timerp timer) (cancel-timer timer))
    (setf (gptel-yatools-job-timer job) nil))
  (let ((buffer (gptel-yatools-job-buffer job)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq gptel-yatools--jobs (delq job gptel-yatools--jobs))
        (gptel-yatools--jobs-note-change))))
  (let ((output (gptel-yatools-job-output job)))
    (when (buffer-live-p output) (kill-buffer output))
    (setf (gptel-yatools-job-output job) nil)))

(defun gptel-yatools--kill-buffer-jobs ()
  "Abandon this buffer's jobs when the buffer itself is killed.

A job's Result has nowhere to go once the chat that started it is gone,
and a process left running would be one nothing could reach."
  (dolist (job (gptel-yatools--jobs-live))
    (gptel-yatools--job-abandon job)))

(defun gptel-yatools--make-job-live (job)
  "Make JOB live in the buffer that owns it, and return JOB.

Registers it in its buffer's job list, installs the buffer's kill hook,
arms the deadline timer and starts the status line.  See ADR 0005.

Starts nothing: the caller's work is already running.  `--spawn-process'
calls this after `make-process' returns, since that can block while TRAMP
opens a connection, and TRAMP runs timers while it waits.

JOB must already carry its BUFFER, STARTED and DEADLINE; a nil deadline
arms no timer."
  (let ((buffer (gptel-yatools-job-buffer job)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (push job gptel-yatools--jobs)
        ;; Idempotent for an identical function: a buffer that starts a
        ;; second job must not stack the hook.
        (add-hook 'kill-buffer-hook #'gptel-yatools--kill-buffer-jobs nil t)
        (gptel-yatools--jobs-note-change))))
  (let ((deadline (gptel-yatools-job-deadline job)))
    (when deadline
      (setf (gptel-yatools-job-timer job)
            (run-at-time (max 0.01 (- deadline (float-time)))
                         nil #'gptel-yatools--job-expire job))))
  job)

(defun gptel-yatools--job-stop (job reason)
  "Stop JOB's work, without concluding it, because of REASON.

A process job is killed.  Any other kind is stopped by the function its
body supplied, which is told REASON: `cancelled' or `timed-out'."
  (let ((cancel (gptel-yatools-job-cancel job)))
    (if cancel
        (funcall cancel job reason)
      (gptel-yatools--kill-process (gptel-yatools-job-process job)
                                   (gptel-yatools-job-remote job)))))

(defun gptel-yatools--job-read-outcome (job)
  "Return JOB's outcome, read by the function its body supplied if any."
  (let ((reader (gptel-yatools-job-outcome-function job)))
    (if (functionp reader)
        (funcall reader job)
      (gptel-yatools--job-outcome job))))

(defun gptel-yatools--job-settle (job &optional outcome)
  "Record JOB's OUTCOME, or read it, and deliver it once.

Does nothing if JOB has already settled, which is what keeps a late
sentinel or a deadline kill from delivering a second result.  A job can
settle before its conclusion is attached, so recording the outcome and
delivering it are separate steps."
  (unless (or (null job) (gptel-yatools-job-settled job))
    (setf (gptel-yatools-job-settled job) t
          (gptel-yatools-job-outcome job)
          (or outcome (gptel-yatools--job-read-outcome job)))
    (gptel-yatools--job-deliver job)))

(defun gptel-yatools--job-deliver (job)
  "Hand JOB's recorded outcome to its conclusion, once."
  (let ((conclude (gptel-yatools-job-conclude job)))
    (unless (or (null conclude) (gptel-yatools-job-delivered job))
      (setf (gptel-yatools-job-delivered job) t)
      (gptel-yatools--job-release job)
      (funcall conclude (gptel-yatools-job-outcome job)))))

(defun gptel-yatools--job-conclude-with (job function)
  "Set JOB's conclusion to FUNCTION, delivering at once if JOB is ready.

A process that could not be started has no sentinel to report it, and a
child request can answer before this is called."
  (setf (gptel-yatools-job-conclude job) function)
  (when (or (gptel-yatools-job-start-error job)
            (gptel-yatools-job-settled job))
    ;; `--job-settle' records the outcome if it is not recorded yet -- the
    ;; start error is one that has to be read -- and `--job-deliver' then
    ;; delivers whatever is recorded, which `--job-settle' alone would not
    ;; do for a job that settled before this call.
    (gptel-yatools--job-settle job)
    (gptel-yatools--job-deliver job))
  job)

(defun gptel-yatools--job-abandon (job)
  "Stop JOB without delivering anything, and mark it concluded.

A cancelled job reports no result: the request it belonged to is being
aborted.  An answer recorded but not yet delivered is dropped too."
  (unless (or (null job) (gptel-yatools-job-delivered job))
    (setf (gptel-yatools-job-settled job) t
          (gptel-yatools-job-delivered job) t)
    (gptel-yatools--job-stop job 'cancelled)
    (gptel-yatools--job-release job)))

(defun gptel-yatools--job-expire (job)
  "Stop JOB because its deadline has passed, and conclude it as timed out.

Runs on a timer, where a signal is only logged, so the failure of the stop
itself is ignored."
  (unless (or (gptel-yatools-job-delivered job)
              (gptel-yatools-job-settled job))
    (setf (gptel-yatools-job-timed-out job) t)
    (ignore-errors (gptel-yatools--job-stop job 'timed-out))
    (gptel-yatools--job-settle job)))

(defun gptel-yatools--job-sentinel (process _event)
  "Conclude the job PROCESS belongs to, once PROCESS has stopped."
  (unless (process-live-p process)
    (let ((job (process-get process 'gptel-yatools-job)))
      (when job (gptel-yatools--job-settle job)))))

(defun gptel-yatools--kill-process (process remote)
  "Kill PROCESS and give it a moment to be reaped.

REMOTE says PROCESS was started through a file-name handler's shell and
has to be killed on the host.  A local process is killed with its whole
process group, so the shell's children go with it; a remote one by
`signal-process' on the process object, which TRAMP turns into a remote
`kill' -- its pid is the local ssh/docker client's, so a group signal
there would leave the command running on the host."
  (when (and process (process-live-p process))
    (if remote
        (ignore-errors (signal-process process 'SIGKILL))
      (unless (ignore-errors
                (signal-process (- (process-id process)) 'SIGKILL))
        (ignore-errors (signal-process process 'SIGKILL))))
    (accept-process-output process 0.5)
    (when (process-live-p process)
      (ignore-errors (delete-process process)))))

(cl-defun gptel-yatools--spawn-process (argv &key directory timeout
                                            result description coding)
  "Start ARGV in the background and return a `gptel-yatools-job'.

ARGV is a list of strings: the program and its arguments, not a shell
command.  stderr is merged into stdout, stdin is closed at once, and a
remote DIRECTORY gets the host's own shell through a handler-built process.

DIRECTORY defaults to `default-directory'; a caller working on a remote
tree passes that tree's directory (ADR 0006).

RESULT is a function of the outcome plist returning the Result to report,
DESCRIPTION names the work in the header line, and TIMEOUT is the budget in
seconds, defaulting to the call's deadline less a margin so the kill lands
inside it.

CODING decodes the output, and nil keeps the default.  `binary' reads the
bytes undecoded, which a caller parsing a byte protocol needs: an offset
counted in characters does not match a length the program wrote in bytes.

Returns without waiting: the sentinel reports the exit, and the deadline
timer kills a process that does not finish."
  (let* ((directory (or directory default-directory))
         (timeout (or timeout (gptel-yatools--call-deadline)))
         (remote (file-remote-p directory))
         (default-directory directory)
         (program (if remote
                      (gptel-yatools--remote-shell directory)
                    shell-file-name))
         (switch (if remote "-c" shell-command-switch))
         (margin (if remote
                     (min 1.5 (max 0.2 (* 0.25 timeout)))
                   (min 0.5 (max 0.05 (* 0.1 timeout)))))
         (started (float-time))
         (output (generate-new-buffer " *gptel-job*"))
         (job (gptel-yatools--make-job
               :kind 'command
               :buffer (current-buffer)
               :output output
               :result result
               :remote (and remote t)
               :started started
               :description (or description "process")
               :deadline (- (+ started timeout) margin))))
    (condition-case err
        (let ((process
               (make-process
                :name "gptel-job"
                :buffer output
                :command (list program switch
                               (concat "exec 2>&1; exec "
                                       (mapconcat #'shell-quote-argument
                                                  argv " ")))
                ;; Only a handler-built process runs on the host.  Without
                ;; this flag the command starts here, in "~".
                :file-handler (and remote t)
                ;; TRAMP's `pipe' path rewrites the command into a heredoc
                ;; fed to /dev/tty, and the tty echoes that wrapper into
                ;; the buffer read as output; only the tty path returns the
                ;; command's own bytes.
                :connection-type (unless remote 'pipe)
                :filter #'gptel-yatools--job-filter
                :noquery t
                :sentinel #'gptel-yatools--job-sentinel)))
          (when coding
            (set-process-coding-system process coding coding))
          (setf (gptel-yatools-job-process job) process)
          (process-put process 'gptel-yatools-job job)
          (ignore-errors (process-send-eof process))
          ;; Registered only now, with a process to kill: see
          ;; `gptel-yatools--make-job-live'.
          (gptel-yatools--make-job-live job)
          job)
      (error
       (setf (gptel-yatools-job-start-error job) (error-message-string err))
       (kill-buffer output)
       (setf (gptel-yatools-job-output job) nil)
       ;; Not registered: there is no work to stop, and the boundary
       ;; delivers the start error from START-ERROR alone.
       job))))

(defun gptel-yatools--await-job (job)
  "Wait for JOB to conclude and return its outcome plist.

The synchronous delivery path: the same job and rules, waited for on the
stack.  A process job is waited on through its process; any other kind is
waited on for whatever concludes it, the deadline timer running while
`accept-process-output' waits.  `quit' or a signalled error abandons the
job through the `unwind-protect'."
  (let ((outcome nil)
        (done nil))
    (unwind-protect
        (progn
          (gptel-yatools--job-conclude-with
           job (lambda (o) (setq outcome o done t)))
          (let ((process (gptel-yatools-job-process job)))
            (while (and (not done) (or (null process) (process-live-p process)))
              ;; The deadline timer concludes the job while we wait; the
              ;; check here is only for a job whose process has already
              ;; gone but whose conclusion has not run yet.  A nil process
              ;; means the work is not a process, so wait for any event.
              (accept-process-output process 0.05))
            (while (and (not done) process)
              (accept-process-output process 0.01)))
          outcome)
      (unless done
        (gptel-yatools--job-abandon job)))))

(cl-defun gptel-yatools--run-process (argv &key directory timeout coding)
  "Run ARGV under a deadline and return a plist describing what happened.

ARGV is a list of strings: the program and its arguments, not a shell
command.  DIRECTORY defaults to `default-directory', and TIMEOUT to the
call's deadline, both in the sense `gptel-yatools--spawn-process' gives
them.  CODING is that function's too: `binary' keeps the output as bytes.

The answer is always a plist, never a signal:

  (:status exited      :exit CODE :output STRING)
  (:status timed-out   :exit nil  :output STRING)
  (:status start-error :exit nil  :output STRING)

stderr is merged into stdout, stdin is closed, and the output of a process
that timed out is kept.  The kill signals the whole process group; on a
remote host that is the remote one, killed through TRAMP.

Starts the process with `gptel-yatools--spawn-process' and waits for it."
  (gptel-yatools--await-job
   (gptel-yatools--spawn-process argv :directory directory :timeout timeout
                                 :coding coding)))

(defmacro gptel-yatools--with-deadline-suspended (&rest body)
  "Run BODY without counting its time against the call's deadline.

The only way SUSPENDED moves.  Cleared however BODY exits, `quit'
included."
  (declare (indent 0) (debug t))
  `(let ((call gptel-yatools--call))
     (when call
       (setf (gptel-yatools-call-suspended call) t))
     (unwind-protect
         (progn ,@body)
       (when call
         (setf (gptel-yatools-call-suspended call) nil)))))

(defvar gptel-yatools--tools nil
  "The tools defined by this package, in declaration order.

Each element is a `gptel-tool' struct.  `gptel-yatools--register-tool'
appends to it, replacing an entry of the same name in place so that
reloading a module neither duplicates nor reorders its tools.")

(defvar gptel-yatools-header-line-extra-functions nil
  "Functions that contribute a label to gptel's header line.

Each is called with no arguments while the header line is rendered and
returns a propertized string, or nil to contribute nothing.  They run on
every redisplay, so they must be cheap, and modules append rather than
prepend.")

;;-------------------------------------------------------------------------
;; Paths
;;
;; Two kinds of argument reach a tool as text and mean a path: one the model
;; wrote, relative to the workspace root, and one this package already
;; resolved.  Turning the first into the second happens in one function,
;; `gptel-yatools--resolve-path', at the tool's edge; the VFS takes absolute
;; paths only.
;;-------------------------------------------------------------------------
(defun gptel-yatools--workspace-root ()
  "Return the root relative paths are resolved against.

The root settled at the call's boundary, or one detected from the current
buffer outside a call."
  (gptel-yatools--call-root))

(defun gptel-yatools--detect-workspace-root ()
  "Return the workspace root implied by the current buffer, ignoring any pin.

`project-current's root, or `default-directory' when there is no project."
  (let ((proj (project-current)))
    (if proj
        (file-name-as-directory (expand-file-name (project-root proj)))
      (file-name-as-directory (expand-file-name default-directory)))))

(defun gptel-yatools--remote-prefix (path)
  "Return the part of PATH that names the machine it is on, or nil if local.

Taken as \"PATH minus its local name\", which keeps the whole hop chain:
`file-remote-p' returns only the last hop, so
\"/ssh:a|sudo:root@b:/etc/\" answers \"/sudo:root@b:\" alone."
  (when (file-remote-p path)
    (or (and (fboundp 'tramp-tramp-file-p)
             (tramp-tramp-file-p path)
             (ignore-errors
               (let* ((local (tramp-file-name-localname
                              (tramp-dissect-file-name path))))
                 (and (stringp local)
                      (string-suffix-p local path)
                      (substring path 0 (- (length path) (length local)))))))
        (file-remote-p path))))

(defun gptel-yatools--resolve-path (path)
  "Return PATH as an absolute path, resolved against the workspace root.

The one place a path the model wrote becomes a path this package acts on;
everything past it takes absolute paths.

In a remote workspace, an absolute path -- \"/etc/hostname\", \"~/notes\" --
is resolved against the root's machine, not this one, and a path naming a
different machine is refused."
  (let* ((root (gptel-yatools--workspace-root))
         (prefix (gptel-yatools--remote-prefix root)))
    (cond
     ((file-remote-p path)
      (unless (equal (gptel-yatools--connection root)
                     (gptel-yatools--connection path))
        (error "Error: the workspace is on %s, but %s is on %s.  Give a path relative to the workspace root, or an absolute path on %s, so the tool acts where the workspace is"
               (gptel-yatools--connection-label root)
               (gptel-yatools--display-path path)
               (gptel-yatools--connection-label path)
               (gptel-yatools--connection-label root)))
      path)
     ((and prefix (file-name-absolute-p path))
      (concat prefix path))
     (t (expand-file-name path root)))))

(defconst gptel-yatools--invisible-char-regexp
  "[\u061c\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]"
  "Regexp matching characters that are drawn as nothing or reorder text.

Bidi controls and zero-width characters.  Newlines and tabs are not
included: they are legitimate in text and mean what they look like.")

(defconst gptel-yatools--control-char-regexp
  "[\x00-\x1f\x7f\u061c\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]"
  "Regexp matching every character that may not be displayed verbatim.

`gptel-yatools--invisible-char-regexp' plus the C0 controls and DEL,
newline included, for text that has to stay on one line: a newline in a
file name would forge a line of a review heading.

Text meant to be read line by line goes through
`gptel-yatools--block-char-regexp' instead.")

(defconst gptel-yatools--block-char-regexp
  "[\x00-\x08\x0b-\x1f\x7f\u061c\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]"
  "Like `gptel-yatools--control-char-regexp', but newline and tab are allowed.

For text a human reads: a here-document's line breaks and a script's
indentation are content.  A carriage return is still escaped, since it
says nothing a reader can see.")

(defun gptel-yatools--escape-chars (string regexp)
  "Return STRING with every match of REGEXP written as <U+XXXX>.

STRING is returned unchanged when it holds no match."
  (if (null (string-match-p regexp string))
      string
    (replace-regexp-in-string
     regexp
     (lambda (m) (format "<U+%04X>" (string-to-char m)))
     string t t)))

(defun gptel-yatools--printable-string (string)
  "Return STRING with every invisible character written as <U+XXXX>.

Newline included, so the result is always one line.  For paths;
`gptel-yatools--printable-block' is for text a human reads line by line."
  (gptel-yatools--escape-chars string gptel-yatools--control-char-regexp))

(defun gptel-yatools--printable-block (string)
  "Return STRING with its invisible characters spelled out, newlines kept.

For text a model wrote to be read rather than compared: a multi-line
shell command, the brief handed to a subagent.  Keeping the line breaks
and tabs is the point -- they are what the user is being asked to
approve."
  (gptel-yatools--escape-chars string gptel-yatools--block-char-regexp))

(defun gptel-yatools--display-path (path)
  "Return PATH relative to the workspace root, escaped for display.

The absolute path when PATH is outside the workspace, and \".\" for the
root itself.  Control characters are written as <U+XXXX>, so the result is
one line: a newline in a file name would otherwise forge a line of the
review heading it appears in."
  (gptel-yatools--printable-string
   (let ((root (gptel-yatools--workspace-root)))
     (cond
      ((equal path root) ".")
      ((string-prefix-p root path)
       (substring path (length root)))
      (t path)))))

(defun gptel-yatools--integer-value (value)
  "Return VALUE as an integer, or nil when it names no number.

Integers pass through, other numbers are truncated toward zero, and a
string is read as the number it begins with -- \"7 items\" names 7.  A
string holding no digit is nil, so the caller can tell \"two\" from \"2\"."
  (cond
   ((integerp value) value)
   ((numberp value)
    (condition-case nil (truncate value) (error nil)))
   ((and (stringp value) (string-match-p "[0-9]" value))
    (let ((n (string-to-number value)))
      (and (numberp n) (truncate n))))
   (t nil)))

(defun gptel-yatools--coerce-integer (value default &optional minimum)
  "Return VALUE coerced to an integer, or DEFAULT if that is impossible.

The result is never below MINIMUM (default 0).  Tool arguments come from
JSON, where a model may send 1.0, \"2\" or nil for a declared integer."
  (let* ((minimum (or minimum 0))
         (n (gptel-yatools--integer-value value)))
    (if (and (integerp n) (>= n minimum))
        n
      (max minimum (or default minimum)))))

(defun gptel-yatools--require-string (value what)
  "Signal a readable error unless VALUE is a string.

WHAT names the argument in the message."
  (unless (stringp value)
    (error "Error: %s must be a string" what))
  value)

(defun gptel-yatools--flag-p (value)
  "Interpret VALUE as a JSON-ish boolean flag.

False only for nil, `:json-false', 0, and the strings \"false\", \"no\"
and \"0\" -- so an `overwrite' sent as \"false\" does not discard a
conflict."
  (not (or (null value)
           (eq value :json-false)
           (and (numberp value) (zerop value))
           (and (stringp value)
                (member (downcase (string-trim value))
                        '("false" "no" "0" ""))))))

(defun gptel-yatools--checked-arg (value type name optional)
  "Return VALUE as the TYPE that argument NAME is declared with.

OPTIONAL says the model may leave the argument out, and then nil passes
through untouched, so the tool's own defaulting stays in charge.

Strings are refused rather than converted when they are not strings;
integers and booleans are converted, since JSON gives a model several ways
to spell two and false.  A value that names no integer is left alone for
the body to refuse.

TYPE is the declared type from a tool's `:args'."
  (if (and (null value) optional)
      nil
    (pcase type
      ('string (gptel-yatools--require-string value name))
      ('integer (or (gptel-yatools--integer-value value) value))
      ('boolean (gptel-yatools--flag-p value))
      (_ value))))

;;-------------------------------------------------------------------------
;; Making a response safe to send
;;
;; A tool's answer can be too large for the context window, or hold bytes
;; that do not decode, which `json-serialize' refuses outright.  Both are
;; handled here, once.
;;-------------------------------------------------------------------------
(defconst gptel-yatools--output-char-limit 64000
  "Maximum number of characters a single tool response may contain.

Tool output is pasted into the model's context, so an unbounded read
of a large file costs a whole context window in one call.")

(defconst gptel-yatools--output-line-limit 2000
  "Maximum number of lines a single tool response may contain.")

(defun gptel-yatools--xml-escape (s)
  "Escape S for inclusion in an XML attribute."
  (replace-regexp-in-string
   "[<>&\"]"
   (lambda (m) (pcase m ("<" "&lt;") (">" "&gt;")
                      ("&" "&amp;") ("\"" "&quot;")))
   s))

(defconst gptel-yatools--raw-byte-regexp "[\x3FFF80-\x3FFFFF]"
  "Regexp matching an undecodable raw byte in a multibyte string.

Byte 0x80-0xFF read by `string-to-multibyte' becomes #x3FFF00+BYTE, whose
charset is `eight-bit'.  Found with a regexp rather than a per-character
loop, which would cost about a microsecond per character.")

(defun gptel-yatools--escape-raw-bytes (string)
  "Return STRING with undecodable bytes and invisible characters escaped.

Raw bytes are written as \\xNN, since `json-serialize' refuses a string
holding them and the whole request would die; bidi controls and zero-width
characters are written as <U+XXXX>.

Text with neither is returned unchanged."
  (let ((s (if (multibyte-string-p string)
               string
             (string-to-multibyte string))))
    (gptel-yatools--escape-invisible-chars
     (if (null (string-match-p gptel-yatools--raw-byte-regexp s))
         s
       (let (parts)
         (dotimes (i (length s))
           (let ((c (aref s i)))
             (push (if (eq (char-charset c) 'eight-bit)
                       (format "\\x%02x" (logand c #xFF))
                     (char-to-string c))
                   parts)))
         (apply #'concat (nreverse parts)))))))

(defun gptel-yatools--escape-invisible-chars (string)
  "Return STRING with bidi and zero-width characters written as <U+XXXX>."
  (if (null (string-match-p gptel-yatools--invisible-char-regexp string))
      string
    (replace-regexp-in-string
     gptel-yatools--invisible-char-regexp
     (lambda (m) (format "<U+%04X>" (string-to-char m)))
     string t t)))


(defun gptel-yatools--hard-cut (string limit)
  "Return STRING cut to LIMIT characters, without splitting a \\xNN escape.

A bare trailing backslash and the prefixes \"\\x\" and \"\\xa\" are dropped
with it, so no partial escape is left behind."
  (let ((cut (substring string 0 (min limit (length string)))))
    (if (string-match "\\\\\\(x[0-9a-f]?\\)?\\'" cut)
        (substring cut 0 (match-beginning 0))
      cut)))

(defun gptel-yatools--within-limits-p (string)
  "Return non-nil if STRING needs no truncation.

That is within `gptel-yatools--output-char-limit' characters and
`gptel-yatools--output-line-limit' lines.  The line scan stops at the
limit, so a large response is not split."
  (and (<= (length string) gptel-yatools--output-char-limit)
       (let ((limit gptel-yatools--output-line-limit)
             (newlines 0)
             (pos 0)
             (more t))
         (while (and more (<= newlines limit))
           (let ((next (string-search "\n" string pos)))
             (if next
                 (setq newlines (1+ newlines)
                       pos (1+ next))
               (setq more nil))))
         ;; `more' is still t when the limit was passed, which means the
         ;; count is a lower bound and the answer is no.
         (and (not more)
              (<= (if (string-suffix-p "\n" string) newlines (1+ newlines))
                  limit)))))

(defun gptel-yatools--truncate (string)
  "Return STRING made safe and bounded for a tool response.

Capped to the line and character limits, with non-UTF-8 bytes escaped.  The
size limit is applied again after escaping, since one raw byte becomes
four characters.  A note is appended whenever anything was cut.

Text already within both limits and free of raw bytes is returned as it
is, which is nearly every call."
  (let ((string (if (stringp string) string "")))
    (if (gptel-yatools--within-limits-p string)
        (let ((escaped (gptel-yatools--escape-raw-bytes string)))
          (if (= (length escaped) (length string))
              escaped
            (gptel-yatools--truncate-slow string)))
      (gptel-yatools--truncate-slow string))))

(defun gptel-yatools--line-count (string)
  "Return the number of lines in STRING.

A trailing newline does not start another line, so \"a\\nb\\n\" holds two
lines and \"\" holds none -- the answer `count-lines' gives for the same
text in a buffer."
  (if (string-empty-p string)
      0
    (let ((newlines 0)
          (pos 0))
      (while (setq pos (string-search "\n" string pos))
        (setq newlines (1+ newlines)
              pos (1+ pos)))
      (if (string-suffix-p "\n" string)
          newlines
        (1+ newlines)))))

(defun gptel-yatools--map-lines (text function)
  "Call FUNCTION with each line of TEXT and its 1-based number.

FUNCTION is called as (FUNCTION NUMBER LINE), and its value is ignored.
LINE is the line's text without properties and without the newline that
ends it, so a trailing carriage return stays on the line it ends.  A
trailing newline does not start another line, so \"a\\nb\\n\" reaches
FUNCTION twice and \"\" reaches it not at all.

The lines are found in a temporary buffer, which is current while FUNCTION
runs: it must not depend on the caller's buffer.  Nothing about matching
is bound here, so a FUNCTION that matches a regexp obeys the caller's
`case-fold-search'."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let ((number 0))
      (while (not (eobp))
        (setq number (1+ number))
        (funcall function number
                 (buffer-substring-no-properties
                  (line-beginning-position) (line-end-position)))
        (forward-line 1)))))

(defun gptel-yatools--truncate-slow (string)
  "Return STRING cut to the response limits, with a note saying what was cut.

This is the general path behind `gptel-yatools--truncate'; it assumes
nothing about STRING and walks all of it."
  (let* ((total-chars (length string))
         ;; `split-string' keeps an empty field after a trailing
         ;; newline so that the pieces rejoin into the original text;
         ;; `gptel-yatools--line-count' knows that field is not a line.
         (lines (split-string string "\n"))
         (total-lines (gptel-yatools--line-count string))
         (kept (if (> total-lines gptel-yatools--output-line-limit)
                   (cl-subseq lines 0 gptel-yatools--output-line-limit)
                 lines))
         (result (mapconcat #'identity kept "\n"))
         (note (when (> total-lines gptel-yatools--output-line-limit)
                 (format "first %d of %d lines"
                         gptel-yatools--output-line-limit total-lines))))
    (when (> (length result) gptel-yatools--output-char-limit)
      (setq result (substring result 0 gptel-yatools--output-char-limit))
      (setq note (format "%s%d of %d characters"
                         (if note (concat note ", ") "")
                         gptel-yatools--output-char-limit total-chars)))
    (let ((escaped (gptel-yatools--escape-raw-bytes result)))
      (when (> (length escaped) gptel-yatools--output-char-limit)
        (setq escaped (gptel-yatools--hard-cut escaped
                                                   gptel-yatools--output-char-limit))
        (setq note (or note "escaped output hit the size limit")))
      (if note
          (concat escaped
                  (format "\n\n[... truncated: showed %s. Narrow the request to see more — e.g. read_file_from_offset with offset/lines, vfs_diff with path/offset/lines, a narrower regex, or a targeted shell command. ...]"
                          note))
        escaped))))

(defun gptel-yatools--escape-envelope-body (body)
  "Return BODY with the starts of the two envelope tags neutralised.

The envelope is a string, so the only thing separating tool output from
harness chrome is that the output cannot spell the chrome.  Only the two
tag starts are escaped, not every \"<\", so that diffs stay readable."
  (replace-regexp-in-string
   "<\\(/?tool_\\(?:context\\|response\\)\\)"
   "&lt;\\1"
   body))

(defun gptel-yatools--envelope (provenance comment body)
  "Return BODY wrapped in the tool context/response XML envelope.

PROVENANCE becomes the context tag's `vfs' attribute, false only for a
wholly-on-disk reply.  COMMENT is the context tag's note, escaped for an
attribute.  BODY is not escaped wholesale -- that would break the page
size `vfs_diff' reports -- so `gptel-yatools--escape-envelope-body'
neutralises the two tags a reply could forge.  Both are then truncated, so
nothing is sent that cannot be serialised."
  (format "<tool_context vfs=\"%s\" comment=\"%s\"/>\n<tool_response>\n%s\n</tool_response>"
          (gptel-yatools--provenance-attr provenance)
          (gptel-yatools--xml-escape (gptel-yatools--escape-raw-bytes comment))
          (gptel-yatools--truncate
           (gptel-yatools--escape-envelope-body body))))

;;-------------------------------------------------------------------------
;; The tool boundary
;;
;; A tool function says what it found and returns a Result; the wrapper
;; `gptel-yatools-define-tool' writes around every tool renders it.
;;
;; - A signalled error never reaches the envelope: gptel stringifies it and
;;   stores that as the result, so the model would get bare text with no
;;   context tag and without passing through
;;   `gptel-yatools--escape-raw-bytes'.  Catching it here closes that hole
;;   for every tool at once.
;; - `vfs_diff' pages within the same size budget the envelope enforces, or
;;   the truncation would cut a page the tool had reported as complete
;;   (`gptel-yatools-page').
;;-------------------------------------------------------------------------
;;-------------------------------------------------------------------------
;; The Result, and where its content came from
;;-------------------------------------------------------------------------
(defconst gptel-yatools--provenances '(:disk :vfs :mixed :derived)
  "The provenance values a `gptel-yatools-result' may carry.

:disk    every byte of the body is what is on disk.
:vfs     the body is pending virtual-filesystem state, not on disk yet.
:mixed   the body blends the two, such as a directory listing that merges
         disk with VFS-only entries.
:derived the body is another model's conclusion, not a description of
         anything this process read: a subagent's answer.")

(defconst gptel-yatools--provenance-comments
  '((:disk . "This reply reflects the state of disk.")
    (:vfs . "\
This reply reflects pending changes in the virtual filesystem that are not on disk yet. Run the file_sync tool to persist them.")
    (:mixed . "\
This reply mixes pending virtual-filesystem changes with disk content: entries marked (pending) exist only in the VFS. Run the file_sync tool to persist them.")
    (:derived . "\
This reply was produced by a subagent, from the tools it ran and the files it read. Treat it as another model's conclusion, not as a description of disk: verify anything you intend to act on."))
  "Default envelope comments, keyed by a result's provenance.

Tools with something more specific to say pass :comment to
`gptel-yatools-ok' instead.")

(defun gptel-yatools--provenance-attr (provenance)
  "Return PROVENANCE as the envelope's vfs attribute value.

False only for `:disk', the one provenance that is wholly on disk.  The
attribute answers \"may this text disagree with disk?\" -- yes for
`:mixed'."
  (if (eq provenance :disk) "false" "true"))

(cl-defstruct (gptel-yatools-result (:constructor gptel-yatools--make-result)
                                    (:copier nil))
  "What a tool function returns.

BODY is the text the model reads.  PROVENANCE says where it came from, one
of `gptel-yatools--provenances'.  COMMENT is the envelope's one-line
context comment; nil derives it from PROVENANCE.

Build one with `gptel-yatools-ok'.  Formatting, truncation and escaping
happen once, at the boundary."
  (body "" :documentation "The text the model reads.")
  (provenance :disk :documentation "One of `gptel-yatools--provenances'.")
  (comment nil :documentation "Context comment, or nil to derive it from PROVENANCE."))

(defun gptel-yatools-ok (body &rest args)
  "Return a `gptel-yatools-result' carrying BODY.

BODY is what the model reads; it is size-limited and escaped at the
boundary, so a tool returns all of it.

ARGS is a plist of two optional keys:

  :provenance  one of `gptel-yatools--provenances', defaulting to `:disk'.
               `:vfs' for a pending entry, `:mixed' for a reply blending
               disk and pending state.
  :comment     the envelope's one-line context comment, defaulting to a
               sentence derived from :provenance."
  (let ((provenance (or (plist-get args :provenance) :disk)))
    (unless (memq provenance gptel-yatools--provenances)
      (error "gptel-yatools-ok: %S is not a provenance; expected one of %S"
             provenance gptel-yatools--provenances))
    (gptel-yatools--make-result
     :body (if (stringp body) body (format "%s" body))
     :provenance provenance
     :comment (or (plist-get args :comment)
                  (cdr (assq provenance gptel-yatools--provenance-comments))))))

(defun gptel-yatools--respond (result)
  "Render RESULT, a `gptel-yatools-result', as the envelope the model sees.

Anything else is a bug in this package, reported to the model as a failed
call rather than signalled -- a signal would bypass the envelope's
escaping."
  (if (gptel-yatools-result-p result)
      (gptel-yatools--envelope (gptel-yatools-result-provenance result)
                               (gptel-yatools-result-comment result)
                               (gptel-yatools-result-body result))
    (gptel-yatools--envelope
     :disk
     "The tool returned no result."
     (format "Error: internal error: the tool returned %S where a result was expected. This is a bug in gptel-yatools; nothing was changed."
             result))))

(defun gptel-yatools--error-text (err)
  "Return ERR's message without a leading \"Error:\".

Tool functions write \"Error: ...\", and the boundary would prefix the same
word again."
  (let ((text (error-message-string err)))
    (if (string-match "\\`Error: +\\(.+\\)\\'" text)
        (match-string 1 text)
      text)))

;;-------------------------------------------------------------------------
;; Tool call timeouts
;;
;; A tool that blocks blocks Emacs, so every tool gets a deadline
;; (`gptel-yatools-timeout', or `gptel-yatools-async-timeout' for one that
;; delivers asynchronously) plus an optional TIMEOUT argument for the call
;; that genuinely needs longer.
;;-------------------------------------------------------------------------
(defvar gptel-yatools--timeout-defaults (make-hash-table :test #'equal)
  "Per-tool default timeouts, by tool name.

A tool whose work is of a different kind states its own with `:timeout' in
its definition.  The value is a function, read when used, so a `defcustom'
changed during a session changes what the model is told.")

(defun gptel-yatools--timeout-default-for (name)
  "Return the budget NAME's tool declares for itself, or nil for the shared one.

Read through the thunk the definition stored, so a `defcustom' changed
during a session is what comes back."
  (when-let* ((thunk (gethash name gptel-yatools--timeout-defaults)))
    (and (functionp thunk) (funcall thunk))))

(defun gptel-yatools--tool-timeout-default (tool)
  "Return TOOL's own default timeout in seconds, or nil for the shared one."
  (gptel-yatools--timeout-default-for (gptel-tool-name tool)))

(defun gptel-yatools--timeout-default (&optional async)
  "Return the default number of seconds a call may run, ASYNC or not.

`gptel-yatools-async-timeout' for an asynchronous call, which does not hold
Emacs; `gptel-yatools-timeout' otherwise.  Falls back on 120 when the
variable holds something that is not a number."
  (gptel-yatools--coerce-integer
   (if async
       (bound-and-true-p gptel-yatools-async-timeout)
     (bound-and-true-p gptel-yatools-timeout))
   120 1))

(defun gptel-yatools--resolve-timeout (value &optional async default)
  "Return the timeout in seconds to use for one tool call.

VALUE is the model's TIMEOUT argument: a number, a numeric string, or nil
for the default.  An unusable value falls back on DEFAULT when given, and
otherwise on `gptel-yatools--timeout-default' for ASYNC.  The result is at
least one second."
  (gptel-yatools--coerce-integer
   value
   (or default (gptel-yatools--timeout-default async))
   1))

(defun gptel-yatools--timeout-arg (&optional async default)
  "Return the optional TIMEOUT argument plist added to every tool.

ASYNC selects which shared default is stated, DEFAULT overrides it with the
tool's own budget -- the model must never be told a number the boundary
will not enforce."
  (list :name "timeout"
        :type "integer"
        :description
        (format "Optional maximum number of seconds this call may run. Omit it to use the default (%s seconds). Do not raise it unless the task genuinely needs more time than the default allows.%s"
                (or default (gptel-yatools--timeout-default async))
                (if async
                    " This tool runs in the background: the call returns before the work finishes, and the result arrives when it does."
                  ""))
        :optional t))

(defun gptel-yatools--timeout-envelope (&optional seconds name)
  "Return the envelope for a call that outlived its deadline.

SECONDS and NAME are what the model is told: how long the call had, and
which tool ran out of time.  Both optional, since a conclusion built from a
sentinel does not always know the tool's name."
  (gptel-yatools--envelope
   :disk "Tool call timed out."
   (gptel-yatools--timeout-message seconds name)))

(defun gptel-yatools--failure-envelope (err)
  "Return the envelope for a call that reported ERR.

ERR is the `condition-case' value, `(SYMBOL . DATA)'.  `quit' arrives here
too, being no `error', and from a sentinel or a timer nothing above
catches it."
  (gptel-yatools--envelope
   :disk "The tool reported an error."
   (format "Error: %s" (gptel-yatools--error-text err))))

(define-error 'gptel-yatools-timeout-error
  "Tool call did not finish within its timeout")

(defun gptel-yatools--timeout-message (seconds &optional name)
  "Return the text reported when a call exceeds SECONDS.

NAME, when given, is the tool that ran out of time."
  (format "Error: the %stool call did not finish within its %s second timeout and was aborted. Whatever it had done up to that point may or may not have happened; do not assume it completed. Retry with a larger TIMEOUT argument only if the work genuinely needs more time; otherwise split the request into smaller calls."
          (if (and name (not (string-empty-p name)))
              (concat name " ")
            "")
          seconds))

(defun gptel-yatools--refresh-timeout-arg ()
  "Rewrite the TIMEOUT argument, and the docstring, in every tool.

Called after registration and whenever a timeout option changes, so the
number the model is told is the one in force.  Reads this package's own
tool list, not `gptel-tools', since a tool not yet enabled still needs a
correct argument."
  (dolist (tool gptel-yatools--tools)
    (let* ((default (gptel-yatools--tool-timeout-default tool))
           (args (gptel-tool-args tool)))
      (when (equal (plist-get (car (last args)) :name) "timeout")
        (setf (gptel-tool-args tool)
              (append (butlast args)
                      (list (gptel-yatools--timeout-arg
                             (gptel-tool-async tool) default)))))
      (gptel-yatools--refresh-tool-docstring tool))))

(defun gptel-yatools--set-timeout (symbol value)
  "Set `gptel-yatools-timeout' to VALUE, updating the tool arguments.

SYMBOL is the variable being set, as a `:set' function receives it."
  (set-default symbol value)
  (gptel-yatools--refresh-timeout-arg))

(defun gptel-yatools--set-async-timeout (symbol value)
  "Set `gptel-yatools-async-timeout' to VALUE, updating the tool arguments.

SYMBOL is the variable being set, as a `:set' function receives it."
  (set-default symbol value)
  (gptel-yatools--refresh-timeout-arg))

(defcustom gptel-yatools-async-timeout 600
  "Maximum number of seconds an asynchronous tool call may run.

An asynchronous tool does not hold Emacs, so this bounds a runaway command
rather than the user's patience -- which is why it is larger than
`gptel-yatools-timeout'.  Every asynchronous tool's TIMEOUT argument
states this default."
  :type 'number
  :group 'gptel-yatools
  :set #'gptel-yatools--set-async-timeout)

(defcustom gptel-yatools-timeout 120
  "Maximum number of seconds a gptel tool call may run before it is aborted.

Tool calls are synchronous, so this is also the longest one can keep Emacs
busy.  Time spent waiting for the user, reviewing a `file_sync' diff for
instance, does not count.

Every tool takes an optional TIMEOUT argument that overrides this for one
call.  Setting this with `customize-set-variable' updates the description
the model is given; a plain `setq' only affects tools defined afterwards."
  :type 'number
  :group 'gptel-yatools
  :set #'gptel-yatools--set-timeout)

(defun gptel-yatools--new-call (&optional timeout)
  "Return the `gptel-yatools-call' for a tool call starting now.

The root is inherited from an enclosing call, so a call never moves its
workspace half way through, and detected from the current buffer
otherwise.  TIMEOUT is the already-resolved deadline."
  (let ((outer gptel-yatools--call))
    (gptel-yatools--make-call
     :root (if outer
               (gptel-yatools-call-root outer)
             (gptel-yatools--detect-workspace-root))
     :deadline (or timeout (gptel-yatools--resolve-timeout nil)))))

(defcustom gptel-yatools-tool-trace nil
  "Whether to record what happens to each deferred tool call.

Every step is appended to `gptel-yatools-tool-trace-file': the call
arriving, each timer firing, and every reason a call was dropped.  A
request that stops in TOOL leaves nothing else behind.  A diagnostic:
leave it off."
  :type 'boolean
  :group 'gptel-yatools)

(defcustom gptel-yatools-tool-trace-file
  (expand-file-name "gptel-yatools-trace.log" temporary-file-directory)
  "Where `gptel-yatools-tool-trace' writes."
  :type 'file
  :group 'gptel-yatools)

(defun gptel-yatools--trace (format-string &rest arguments)
  "Append FORMAT-STRING and ARGUMENTS to the trace file, if tracing is on."
  (when gptel-yatools-tool-trace
    (ignore-errors
      (with-temp-buffer
        (insert (format-time-string "%H:%M:%S.%3N ")
                (apply #'format format-string arguments)
                "\n")
        (append-to-file (point-min) (point-max)
                        gptel-yatools-tool-trace-file)))))

(defvar gptel-yatools--pending-quit nil
  "Non-nil when a `C-g' arrived during a tool call and is owed to its caller.

The call completes, since it cannot do its work in halves, and the quit is
re-signalled by the outermost layer once the answer has been delivered.")

(defcustom gptel-yatools-ignore-quit t
  "Whether a running tool call lets a `C-g' pass through it.

With this on, a `C-g' that arrives during a call -- aimed at a minibuffer,
say -- does not abandon the call: the body finishes, and the quit is
re-signalled one layer out.

A quit already pending when the call started is left alone.  The deadline
still applies; it is enforced by a timer that throws."
  :type 'boolean
  :group 'gptel-yatools)

(defun gptel-yatools--replay-pending-quit ()
  "Re-signal a `C-g' that arrived during a tool call, if there was one.

Called at the outermost boundary of a call, after its result has been
delivered.  Clears the flag first, so it propagates once."
  (when gptel-yatools--pending-quit
    (setq gptel-yatools--pending-quit nil
          quit-flag nil)
    (signal 'quit nil)))

(defmacro gptel-yatools--without-quit (&rest body)
  "Run BODY to completion, and owe any `C-g' that arrives during it.

With `inhibit-quit' bound, a `C-g' is deferred and raised at the next safe
point after the binding ends -- which would fall inside this package's own
caller, aborting delivery of the result.  So the deferred quit is taken
here and re-signalled by `gptel-yatools--replay-pending-quit'.

A quit already pending before BODY propagates as usual, and `throw' is
unaffected, so a deadline timer can still end the call."
  (declare (indent 0) (debug t))
  `(let ((already-pending quit-flag)
         (value nil)
         (completed nil))
     (condition-case nil
         (let ((inhibit-quit t))
           (setq value (progn ,@body))
           (setq completed t)
           ;; Taken inside the inhibition: outside it, the very next safe
           ;; point would raise it in the caller, before the result has
           ;; been handed over.
           (when quit-flag
             (setq quit-flag nil
                   gptel-yatools--pending-quit t)))
       (quit nil))
     (cond
      ;; Somebody else's quit, still pending: not ours to hold.
      (already-pending (signal 'quit nil))
      ;; The body was cut short despite the inhibition.
      ((not completed) (signal 'quit nil))
      (t value))))

(defun gptel-yatools--call-with-timeout (function args &optional timeout name)
  "Call FUNCTION with positional ARGS, aborting after TIMEOUT seconds.

TIMEOUT defaults to `gptel-yatools-timeout'.  NAME labels the tool in the
error.  Returns FUNCTION's value, or signals
`gptel-yatools-timeout-error' carrying the seconds and the tool name.

Binds the `gptel-yatools-call' this call reads: its deadline, the workspace
root captured here, and the pause flag.  An enclosing call's root is
inherited, so it never moves half way through.

A timer rather than `with-timeout', so that time spent waiting for the user
is excluded.  Timers run while Emacs waits for input, so this bounds calls
that block on I/O and cannot interrupt a purely CPU-bound form.  The timer
`throw's a marker, which is re-signalled here as the timeout condition:
a `signal' from a timer callback is consumed by Emacs's timer loop."
  (let* ((timeout (gptel-yatools--resolve-timeout timeout))
         (call (gptel-yatools--new-call timeout))
         (tag (make-symbol "gptel-yatools-timeout"))
         (expired (list 'expired timeout name))
         (start (float-time))
         (paused 0.0)
         (pause-start nil)
         (timer (run-with-timer
                 0.2 0.2
                 (lambda ()
                   (if (gptel-yatools-call-suspended call)
                       (unless pause-start
                         (setq pause-start (float-time)))
                     (when pause-start
                       (setq paused (+ paused (- (float-time) pause-start)))
                       (setq pause-start nil))
                     (when (> (- (float-time) start paused) timeout)
                       (throw tag expired))
                     nil)))))
    (unwind-protect
        ;; `let*', not `let': the call's context must be in effect before
        ;; FUNCTION runs, so that everything inside it -- including a
        ;; helper asking for the deadline -- sees the same call.
        (let* ((gptel-yatools--call call)
               (value (catch tag
                        (if gptel-yatools-ignore-quit
                            (gptel-yatools--without-quit
                              (apply function args))
                          (apply function args)))))
          (if (eq value expired)
              (signal 'gptel-yatools-timeout-error
                      (list :seconds timeout :tool name))
            value))
      (cancel-timer timer))))

(defun gptel-yatools--checked-args (args arg-specs)
  "Return ARGS with each value brought into line with its ARG-SPECS.

ARGS is the positional list the tool function is called with, in the order
ARG-SPECS declares.  Each value goes through
`gptel-yatools--checked-arg', so a wrong-typed argument is refused here
rather than signalling from inside the body.

A tool declaring no arguments keeps the ones it was given, and nothing here
overrides the body's own defaulting."
  (if (null arg-specs)
      args
    ;; `cl-mapcar' stops at the shorter list, so anything past the
    ;; declaration is carried through rather than silently dropped.
    (append (cl-mapcar (lambda (value spec)
                         (gptel-yatools--checked-arg value (plist-get spec :type)
                                                     (plist-get spec :name)
                                                     (plist-get spec :optional)))
                       args arg-specs)
            (nthcdr (length arg-specs) args))))

(defun gptel-yatools--job-timed-out-p (job outcome)
  "Return non-nil when OUTCOME is a deadline kill JOB cannot describe itself.

A body that declared a result function describes its own timeout, and
better than the boundary can."
  (and (plist-get outcome :timed-out)
       (not (functionp (gptel-yatools-job-result job)))))

(defun gptel-yatools--job-tool-result (job name seconds)
  "Wait for JOB and return the Result its body declared.

NAME labels the tool and SECONDS is the budget that ran out.  A job that
outlived its deadline without a result function signals
`gptel-yatools-timeout-error'."
  (let ((outcome (gptel-yatools--await-job job)))
    (if (gptel-yatools--job-timed-out-p job outcome)
        (signal 'gptel-yatools-timeout-error
                (list :seconds seconds :tool name))
      (gptel-yatools--job-report job outcome))))

(defun gptel-yatools--call-tool (name function args &optional timeout arg-specs async default)
  "Call FUNCTION with positional ARGS and render the outcome for the model.

The tool boundary: enforces the deadline, renders the Result into the
envelope, and turns a signalled error, an expired deadline and a body that
returned the wrong shape into that same envelope -- sized, truncated and
escaped.

ARG-SPECS, when given, is the tool's `:args' declaration, checked here so
that a wrong-typed argument is refused inside the `condition-case' and
reaches the model as an enveloped sentence.

NAME labels the tool in a timeout message.  TIMEOUT is the call's own
deadline or nil for the default; ASYNC says which default that is, and
DEFAULT is the tool's own budget, overriding the shared one.

A body that handed its work to a process returns a job, waited for here.
ASYNC delivers through gptel's callback instead; the job and the rules are
the same.

`quit' passes through untouched, and `condition-case-unless-debug' leaves
signals alone while `debug-on-error' is set."
  (let ((seconds (gptel-yatools--resolve-timeout timeout async default)))
    (condition-case-unless-debug err
        (let ((value (gptel-yatools--call-with-timeout
                      function (gptel-yatools--checked-args args arg-specs)
                      seconds name)))
          (gptel-yatools--respond
           (cond
            ((not (gptel-yatools-job-p value)) value)
            (async (gptel-yatools--job-tool-result value name seconds))
            (t
             ;; A synchronous tool cannot hand gptel a job: gptel would
             ;; stringify it and send the printed struct to the model.
             ;; That is a definition bug, and it is said so.
             (error "Error: internal error: the %s tool returned a job but is not declared :async.  Nothing was changed" name)))))
      (gptel-yatools-timeout-error
       (gptel-yatools--timeout-envelope (plist-get (cdr err) :seconds)
                                        (or (plist-get (cdr err) :tool) name)))
      (error
       (gptel-yatools--failure-envelope err)))))

(defun gptel-yatools--start-async (name function callback args arg-specs &optional default)
  "Run FUNCTION for an asynchronous tool call and deliver its envelope.

NAME labels the tool in what the model is told when the call goes wrong.
ARGS is what gptel passed positionally: the tool's arguments, then its
timeout.

The body runs here and returns either a Result, delivered at once, or a
job, whose conclusion delivers.  Delivery re-enters the owner buffer and
rebinds the call context, since `default-directory' and the VFS are
buffer-local.  The callback runs exactly once."
  (let* ((split (gptel-yatools--split-args args arg-specs))
         (checked (gptel-yatools--checked-args (car split) arg-specs))
         (timeout (gptel-yatools--resolve-timeout (cdr split) t default))
         (call (gptel-yatools--new-call timeout))
         (owner (current-buffer))
         (gptel-yatools--call call)
         (value (if gptel-yatools-ignore-quit
                    (gptel-yatools--without-quit
                      (apply function checked))
                  (apply function checked))))
    (if (gptel-yatools-job-p value)
        (progn
          (gptel-yatools--job-conclude-with
           value
           (lambda (outcome)
             (when (buffer-live-p owner)
               (with-current-buffer owner
                 (let ((gptel-yatools--call call))
                   ;; `--job-conclusion' is what keeps a failure to render
                   ;; from becoming a callback that is never called.
                   (funcall callback
                            (gptel-yatools--job-conclusion
                             value outcome timeout name)))))))
          ;; The answer is coming: there is nothing to return.
          nil)
      (funcall callback (gptel-yatools--respond value))
      nil)))

(defun gptel-yatools--job-conclusion (job outcome &optional timeout name)
  "Return the envelope that reports JOB's OUTCOME, or one saying it failed.

Rendering runs the body's own RESULT function over the outcome, and either
can fail.  This is the last point at which the answer can be delivered --
the job is already marked delivered -- and it often runs from a sentinel,
where a signal is only logged, leaving gptel waiting for a callback that
never comes.  So a failure to render is reported as the tool failing.

TIMEOUT and NAME are the call's budget and tool name, used when the
deadline is what ended the work."
  (condition-case err
      (if (gptel-yatools--job-timed-out-p job outcome)
          (gptel-yatools--timeout-envelope timeout name)
        (gptel-yatools--respond (gptel-yatools--job-report job outcome)))
    (quit (gptel-yatools--failure-envelope '(quit)))
    (error (gptel-yatools--failure-envelope err))))

(defun gptel-yatools--job-report (job outcome)
  "Return JOB's Result, read from OUTCOME by the function its body gave."
  (let ((result (gptel-yatools-job-result job)))
    (if (functionp result)
        (funcall result outcome)
      (gptel-yatools-ok
       (format "The %s tool started work but declared no way to read its outcome. This is a bug in gptel-yatools; nothing was changed."
               (or (gptel-yatools-job-description job) "tool"))))))

(defun gptel-yatools--split-args (args arg-specs)
  "Return (TOOL-ARGS . TIMEOUT) from the positional ARGS gptel passes.

ARG-SPECS is the tool's `:args' declaration, whose length says how many of
the leading ARGS are the tool's own."
  (let ((n (length arg-specs)))
    (cons (cl-subseq args 0 (min n (length args)))
          (nth n args))))

(defun gptel-yatools--call-tool-async (name function first args arg-specs &optional default)
  "Tool boundary for a tool registered with `:async t'.

NAME labels the tool in what the model is told when the call goes wrong.
FUNCTION is the tool's body and ARGS is the rest of what gptel passed.

FIRST is gptel's callback on a real call, and the answer is delivered to
it.  A direct call -- from `eval', a hook or a test -- passes the tool's
own first argument, and is answered synchronously.

An error raised before a job exists is delivered to the callback here;
returning it would leave gptel waiting."
  (if (not (functionp first))
      (let ((split (gptel-yatools--split-args (cons first args) arg-specs)))
        (gptel-yatools--call-tool name function (car split) (cdr split)
                                  arg-specs t default))
    (condition-case-unless-debug err
        (gptel-yatools--start-async name function first args arg-specs default)
      (gptel-yatools-timeout-error
       (funcall first
                (gptel-yatools--timeout-envelope
                 (plist-get (cdr err) :seconds)
                 (or (plist-get (cdr err) :tool) name)))
       nil)
      (error
       (funcall first (gptel-yatools--failure-envelope err))
       nil))))

(defun gptel-yatools-page (text offset lines &optional reserve)
  "Return a page of TEXT as a plist.

The response budget, offered as a helper so that a tool paging its own
output can report what it showed without the boundary's truncation cutting
the page afterwards.

OFFSET is the 1-based first line wanted, LINES how many.  The page never
exceeds `gptel-yatools--output-char-limit' minus RESERVE, which is room
for text the caller adds around the page.  A single line longer than the
remaining budget is still returned whole.

The plist holds `:text', `:start' and `:end' (1-based, inclusive, of the
lines shown), `:total' (lines in TEXT), `:past-end' (OFFSET was beyond
the last line) and `:partial' (the page is not the whole of TEXT)."
  (let* ((all (split-string text "\n"))
         (total (gptel-yatools--line-count text))
         (start (max 1 offset))
         (want (max 1 lines))
         (budget (max 1 (- gptel-yatools--output-char-limit (or reserve 0))))
         (past-end (> start total))
         (end (if past-end
                  start
                (let ((shown 0) (used 0) (i (1- start)) (stop nil))
                  (while (and (not stop) (< i total) (< shown want))
                    (let ((size (1+ (length (nth i all)))))
                      (if (and (> shown 0)
                               (> (+ used size) budget))
                          (setq stop t)   ; the next line would overflow
                        (setq used (+ used size)
                              shown (1+ shown)
                              i (1+ i)))))
                  (+ start -1 (max 1 shown)))))
         ;; `all' holds one field more than there are lines when TEXT
         ;; ends in a newline.  A page that reaches the last line keeps
         ;; that field, so the page rejoins into the text it reports;
         ;; any earlier page stops at the line boundary as usual.
         (up-to (if (= end total) (length all) end)))
    (list :text (if past-end
                    ""
                  (mapconcat #'identity (cl-subseq all (1- start) up-to) "\n"))
          :start start
          :end end
          :total total
          :past-end past-end
          :partial (and (not past-end)
                        (or (> start 1) (< end total))))))

;;-------------------------------------------------------------------------
;; Defining a tool
;;-------------------------------------------------------------------------
;; What the user is asked to approve
;;
;; gptel renders a pending call with `gptel--format-tool-call', which
;; truncates every string argument at 256 characters, so a call could be
;; approved on a harmless prefix.  `gptel--tool-preview-alist' replaces that
;; per tool.
;;
;; Two facts are easy to get wrong: the setup function is called with
;; `(gptel--map-tool-args TOOL-SPEC ARGS)', a positional list, not the plist
;; its docstring mentions; and that list is `gptel-tool-args'' order, the
;; declared order plus TIMEOUT.  Hence `:preview': a tool names the
;; arguments worth showing, and the definition builds the renderer.
;;-------------------------------------------------------------------------
(defun gptel-yatools--preview-value (value)
  "Return VALUE as it is written into a confirmation.

A string is quoted after `gptel-yatools--printable-block', so a quote or a
backslash in the value cannot end it and invisible characters are spelled
out.  Newlines survive: a here-document or a subagent's brief is text a
person reads line by line, and a multi-line value starts a line of its
own."
  (if (stringp value)
      (let ((printed (prin1-to-string (gptel-yatools--printable-block value))))
        (if (string-match-p "\n" printed)
            (concat "\n" printed)
          printed))
    (format "%s" value)))

(defun gptel-yatools--preview-join (parts)
  "Join PARTS with a space, except where a part starts a new line.

A multi-line value already begins with a newline; adding a space before
it would leave one trailing at the end of the line above."
  (let ((result ""))
    (dolist (part parts result)
      (setq result (concat result
                           (if (or (string-empty-p result)
                                   (string-prefix-p "\n" part))
                               ""
                             " ")
                           part)))))

(defun gptel-yatools--preview-shows-p (value)
  "Return non-nil when VALUE is worth naming on a confirmation line.

An argument the model left out is not part of what will happen, and
naming it would suggest it is."
  (not (or (null value)
           (eq value :json-false)
           (and (stringp value) (string-empty-p value)))))

(defun gptel-yatools--preview-line (name display arg-specs values
                                         &optional async)
  "Return the confirmation text for a call to NAME.

DISPLAY is the tool's `:preview' list, the arguments to show in order.
ARG-SPECS is the tool's `:args', giving each name its position and whether
it may be omitted.  VALUES is the positional list gptel hands the tool,
including the trailing TIMEOUT.  ASYNC adds that the call returns before
the work finishes.

A required argument is printed positionally, an optional one as
NAME=VALUE.  `timeout' is shown as the number it will be used as.  A
multi-line value is shown as the block it is."
  (let* ((names (append (mapcar (lambda (arg) (plist-get arg :name)) arg-specs)
                        (list "timeout")))
         (required (mapcar (lambda (arg) (plist-get arg :name))
                           (cl-remove-if (lambda (arg) (plist-get arg :optional))
                                         arg-specs)))
         (parts nil))
    (dolist (shown display)
      (let* ((position (cl-position shown names :test #'equal))
             (value (and position (nth position values))))
        (when (equal shown "timeout")
          ;; Resolved with the tool's own budget: the prompt must name the
          ;; number the boundary will allow.
          (setq value (and (gptel-yatools--preview-shows-p value)
                           (gptel-yatools--resolve-timeout
                            value async
                            (gptel-yatools--timeout-default-for name)))))
        (cond
         ((null position) nil)
         ((member shown required)
          (push (if (null value)
                    ;; Named rather than printed as `nil', which reads as
                    ;; a value the user could approve.
                    "<missing>"
                  (gptel-yatools--preview-value value))
                parts))
         ((gptel-yatools--preview-shows-p value)
          (push (format "%s=%s" shown (gptel-yatools--preview-value value))
                parts)))))
    (concat "(" name
            (if parts
                (let ((body (gptel-yatools--preview-join (nreverse parts))))
                  (concat (if (string-prefix-p "\n" body) "" " ") body))
              "")
            (if async " [runs in the background]" "")
            ")\n")))

(defun gptel-yatools--register-preview (name display arg-specs &optional async)
  "Point gptel's preview alist at a renderer for NAME, showing DISPLAY.

ARG-SPECS is the tool's `:args', whose positions the renderer reads.
ASYNC makes the line say the call returns before the work does.  Nothing is
registered when DISPLAY is nil.

Guarded, since the alist is gptel's: a gptel without it falls back to the
default rendering."
  (when (and display (boundp 'gptel--tool-preview-alist))
    (setf (alist-get name gptel--tool-preview-alist nil nil #'equal)
          (list (lambda (values _info)
                  (insert (gptel-yatools--preview-line name display
                                                       arg-specs values async))
                  nil)))))

(defun gptel-yatools--literal (form)
  "Return FORM as the literal list it names, quoted or not."
  (if (and (consp form) (eq (car form) 'quote))
      (cadr form)
    form))

(defun gptel-yatools--plist-without (plist key)
  "Return PLIST, a keyword/value list, with KEY and its value removed.

For the keys this package reads itself and must not pass on to
`gptel-make-tool'."
  (let ((clean nil)
        (rest plist))
    (while rest
      (unless (eq (car rest) key)
        (push (car rest) clean)
        (push (cadr rest) clean))
      (setq rest (cddr rest)))
    (nreverse clean)))

(defun gptel-yatools--register-tool (&rest slots)
  "Create a tool from SLOTS and register it, returning the tool.

SLOTS are the arguments of `gptel-make-tool' plus `:timeout-default'.  The
TIMEOUT argument is appended here rather than repeated in every
definition.

Added to gptel's registry, which `gptel-menu' lists, and to
`gptel-yatools--tools', replacing an earlier tool of the same name in
place so a module can be reloaded without reordering the list.

An asynchronous tool is accepted and `:async' travels to gptel unchanged.
A synchronous tool whose body returns a job is refused by the boundary."
  (let* ((async (plist-get slots :async))
         (timeout-default (plist-get slots :timeout-default))
         ;; `gptel-make-tool' would reject our own key, so it is taken out
         ;; of the plist before the tool is built.
         (slots (gptel-yatools--plist-without slots :timeout-default))
         (slots (plist-put slots :args
                           (gptel-yatools--tool-args
                            (plist-get slots :args)
                            async
                            (and (functionp timeout-default)
                                 (funcall timeout-default)))))
         (tool (apply #'gptel-make-tool slots))
         (name (gptel-tool-name tool)))
    (if (functionp timeout-default)
        (puthash name timeout-default gptel-yatools--timeout-defaults)
      (remhash name gptel-yatools--timeout-defaults))
    (let ((existing (cl-position name gptel-yatools--tools
                                 :key #'gptel-tool-name :test #'equal)))
      (if existing
          (setf (nth existing gptel-yatools--tools) tool)
        (setq gptel-yatools--tools
              (append gptel-yatools--tools (list tool)))))
    tool))

(defun gptel-yatools--tool-args (arg-specs async &optional default)
  "Return the argument list the model is given for a tool.

ARG-SPECS is the tool's `:args'.  ASYNC says whether the tool delivers
through gptel's callback.  DEFAULT, when given, is the tool's own budget in
seconds.

Every tool takes one TIMEOUT argument after its declared ones, so the model
sees `(1+ (length ARG-SPECS))' arguments."
  (append arg-specs (list (gptel-yatools--timeout-arg async default))))

(defun gptel-yatools--docstring-escape (text)
  "Return TEXT with the quoting a docstring needs, and none it does not.

A docstring is read by `substitute-command-keys', which renders `word'
as a quoted word and turns \\=\\= into a literal backslash.  The tool
descriptions are written for the model, in plain text with `word' quoting
where it helps, so an apostrophe that is not part of such a pair has to
be escaped to survive both the byte compiler -- which warns about
\"unescaped single quotes\" -- and the renderer."
  (let ((text (replace-regexp-in-string "\\\\" "\\\\\\\\" text)))
    (replace-regexp-in-string "\\([^[:alnum:]]\\|\\`\\)'"
                              "\\1\\\\='"
                              text)))

(defun gptel-yatools--fill-text (text &optional indent)
  "Return TEXT quoted for a docstring and wrapped to 80 columns.

INDENT, when given, shifts every line right by that many columns.

Escaping happens before filling, so a line is measured in the characters
the byte compiler will actually see: an apostrophe becomes \\=' and would
otherwise push an otherwise-fitting line over the limit.  A word too long
to break is left alone, which the compiler accepts.

Empty or nil TEXT yields nil rather than the empty string, so a caller can
join the parts of a docstring with `delq nil' without an empty part
collapsing into a doubled separator."
  (with-temp-buffer
    (insert (gptel-yatools--docstring-escape (or text "")))
    (when indent
      (indent-rigidly (point-min) (point-max) indent))
    (let ((fill-column 80)
          (adaptive-fill-mode t))
      (goto-char (point-min))
      (while (not (eobp))
        (let ((start (point)))
          (forward-paragraph)
          (fill-region start (point) nil nil t)
          (unless (eobp) (forward-char 1)))))
    (let ((filled (string-trim-right (buffer-string))))
      (unless (string-empty-p filled) filled))))

(defun gptel-yatools--arg-lines (arg-specs)
  "Return a docstring's \"Arguments:\" section for ARG-SPECS.

ARG-SPECS is the tool's `:args' list, as written in its definition.  Each
entry is a line naming the argument, its type and whether it is required,
then its description wrapped underneath it."
  (when arg-specs
    (concat
     "Arguments:\n"
     (mapconcat
      (lambda (arg)
        (format "  %s (%s, %s)\n%s"
                (plist-get arg :name)
                (format "%s" (plist-get arg :type))
                (if (plist-get arg :optional) "optional" "required")
                (or (gptel-yatools--fill-text (plist-get arg :description) 6)
                    "")))      arg-specs "\n"))))

(defun gptel-yatools--tool-docstring (name category description arg-specs impl
                                           &optional async default)
  "Return the docstring for a tool's boundary function.

NAME, CATEGORY and DESCRIPTION are the tool's.  ARG-SPECS are the declared
arguments, IMPL is the symbol holding the body, and ASYNC and DEFAULT are
what the TIMEOUT argument states.

The description is reproduced in full -- it is what the model reads -- and
its first sentence is promoted to a summary line for `apropos'."
  (let* ((description (string-trim (or description "")))
         (split (and (string-match "\\`\\([^.]\\{1,70\\}\\.\\)\\s-+\\(.+\\)\\'"
                                   description)
                     (list (match-string 1 description)
                           (match-string 2 description))))
         (summary (or (car-safe split) description))
         (rest (cadr split))
         (args (gptel-yatools--tool-args arg-specs async default)))
    (mapconcat
     #'identity
     (delq nil
           (list
            (gptel-yatools--fill-text
             (format "Tool `%s' (category: %s). This function is the call the model makes: it adds the deadline, renders the Result and reports errors, and hands the work to `%s'. Defined by `gptel-yatools-define-tool', which see. Below is the description the model is given."
                     name category impl))
            (gptel-yatools--fill-text summary)
            (gptel-yatools--fill-text rest)
            (gptel-yatools--arg-lines args)))
     "\n\n")))

(defun gptel-yatools--refresh-tool-docstring (tool)
  "Re-render TOOL's docstring from its definition, and store it.

A docstring is a string literal in the `defun', so a compiled package would
keep stating budget numbers from compile time.  This sets
`function-documentation', which `documentation' consults first.

The declared arguments are the tool's own minus the trailing TIMEOUT.  A
tool whose function is not a symbol is left alone."
  (let ((symbol (gptel-tool-function tool)))
    (when (symbolp symbol)
      (put symbol 'function-documentation
           (gptel-yatools--tool-docstring
            (gptel-tool-name tool)
            (gptel-tool-category tool)
            (gptel-tool-description tool)
            (butlast (gptel-tool-args tool))
            (intern (format "%s-tool" symbol))
            (gptel-tool-async tool)
            (gptel-yatools--tool-timeout-default tool))))))

(defun gptel-yatools--tool-impl-docstring (symbol name)
  "Return the docstring for SYMBOL, the implementation of tool NAME.

Points at the boundary function, where the full text lives."
  (gptel-yatools--fill-text
   (format "Implementation of the `%s' tool, returning a Result.\n\nSee `%s' for the arguments, the deadline and the envelope the model reads."
           name (symbol-name symbol))))

(defmacro gptel-yatools-define-tool (symbol &rest spec)
  "Define and register a gptel tool called SYMBOL.

SPEC is a sequence of keyword/value pairs followed by the body:

  :name        The tool's name as the model sees it, a string like
               \"read_path\".  It must be SYMBOL's name without the
               `gptel-yatools-' prefix, with `_' for each `-'.
  :category    The category gptel groups it under, a string.  Defaults to
               \"misc\".
  :description The text the model reads, and the text `C-h f' shows.
  :args        The argument list, as `gptel-make-tool' takes it, or nil
               for a tool that takes none.  Order matters: gptel passes
               the values positionally.
  :confirm     Non-nil to make gptel ask the user to confirm each call.
  :preview     The argument names to show when gptel asks the user to
               approve a call, in order.  A required argument is printed
               positionally and an optional one as NAME=VALUE.  Leave it
               out for gptel's formatter, which truncates every string at
               256 characters -- so a tool whose arguments are what the
               user is approving should name them here.
  :async       Non-nil to hand the answer to gptel's callback instead of
               returning it.  The body is unchanged: it returns a Result
               or a job, and this key only says whether the boundary waits
               for it.
  :timeout     The default budget in seconds, as a form evaluated when it
               is used -- usually the symbol of a `defcustom'.  Omit it
               for the shared default (see
               `gptel-yatools--timeout-default').

The body is the implementation.  The arguments named in :args are bound to
the values the model sent, and the body returns a `gptel-yatools-result'
built with `gptel-yatools-ok'.  It formats nothing: sizes, escaping and
errors are the boundary's work.

Two functions are defined:

  SYMBOL-tool  The implementation.  Takes the tool's own arguments and
               returns a Result.  Advise it to change what a tool computes
               or reports.

  SYMBOL       The boundary, and the function gptel calls.  Takes the same
               arguments plus a final optional TIMEOUT, enforces the
               deadline, renders the Result into the envelope, and turns a
               signalled error or an expired deadline into that same
               envelope.  Advice here runs outside the deadline.

Both are named, so both can be advised, traced and found with `C-h f', and
advice survives reloading.

An asynchronous tool's boundary takes gptel's callback first, since that is
how gptel calls it.  A direct call -- from `eval', a hook or a test --
passes the tool's own first argument instead and is answered
synchronously.

The tool is registered in gptel's registry, which is what `gptel-menu'
lists, and in `gptel-yatools--tools'.  Nothing is sent to the model until
`gptel-yatools-enable' adds it to `gptel-tools'."
  (declare (indent 1))
  (let* ((rest spec)
         (plist nil))
    ;; Keywords first, body last: a value can itself be a list or a
    ;; keyword, so the split is made on the top level only.
    (while (keywordp (car rest))
      (unless (cdr rest)
        (error "gptel-yatools-define-tool: %s has no value" (car rest)))
      (setq plist (append plist (list (car rest) (cadr rest))))
      (setq rest (cddr rest)))
    (let* ((name (plist-get plist :name))
           (category (or (plist-get plist :category) "misc"))
           (description (plist-get plist :description))
           (args-form (plist-get plist :args))
           (arg-specs (gptel-yatools--literal args-form))
           (display (gptel-yatools--literal (plist-get plist :preview)))
           (async (plist-get plist :async))
           (body rest)
           (impl (intern (format "%s-tool" symbol)))
           ;; The budget is a `defcustom' that is unbound when the macro
           ;; expands, so the literal docstring states the shared default
           ;; and `--refresh-tool-docstring' replaces it with the live one.
           (doc (gptel-yatools--tool-docstring
                 name category description arg-specs impl async))
           (param-names (mapcar (lambda (arg) (intern (plist-get arg :name)))
                                arg-specs))
           ;; An argument the model may omit has to be optional in Lisp
           ;; too, and required parameters must come before `&optional' for
           ;; the positional mapping to hold.
           (required (mapcar (lambda (arg) (intern (plist-get arg :name)))
                             (cl-remove-if (lambda (arg)
                                             (plist-get arg :optional))
                                           arg-specs)))
           (optional (mapcar (lambda (arg) (intern (plist-get arg :name)))
                             (cl-remove-if-not (lambda (arg)
                                                 (plist-get arg :optional))
                                               arg-specs)))
           (impl-params (append required
                                (when optional (cons '&optional optional))))
           ;; The boundary takes the TIMEOUT argument in the same
           ;; `&optional' section, after the tool's own optional ones.
           (boundary-params (append required
                                    (cons '&optional
                                          (append optional (list 'timeout)))))
           (expected (string-replace "-" "_"
                                     (string-remove-prefix "gptel-yatools-"
                                                           (symbol-name symbol)))))
      (unless (stringp name)
        (error "gptel-yatools-define-tool: %s needs a :name string" symbol))
      (unless (equal name expected)
        (error "gptel-yatools-define-tool: %s would define the tool %S, but :name says %S; they must agree so the Lisp name and the tool name cannot drift"
               symbol expected name))
      (unless body
        (error "gptel-yatools-define-tool: %s has no body" symbol))
      (dolist (shown display)
        (unless (member shown (mapcar (lambda (arg) (plist-get arg :name))
                                      (append arg-specs (list '(:name "timeout")))))
          (error "gptel-yatools-define-tool: %s asks to preview %S, but it has no such argument"
                 symbol shown)))
      (unless (equal arg-specs
                     (append (cl-remove-if (lambda (arg) (plist-get arg :optional))
                                           arg-specs)
                             (cl-remove-if-not (lambda (arg) (plist-get arg :optional))
                                               arg-specs)))
        (error "gptel-yatools-define-tool: %s declares a required argument after an optional one; gptel passes the values positionally, so the required ones must come first"
               symbol))
      `(progn
         (defun ,impl ,impl-params
           ,(gptel-yatools--tool-impl-docstring symbol name)
           ,@body)
         (defun ,symbol ,(if async '(&rest args) boundary-params)
           ,doc
           ,(if async
                ;; gptel passes the callback first, so the argument list
                ;; cannot be the declared one; the two callers are told
                ;; apart by type, safe because no tool declares a function
                ;; argument.
                `(gptel-yatools--call-tool-async ,name #',impl
                                                 (car args) (cdr args)
                                                 (copy-tree ',arg-specs)
                                                 ,(plist-get plist :timeout))
              `(gptel-yatools--call-tool ,name #',impl
                                         (list ,@param-names)
                                         timeout
                                         (copy-tree ',arg-specs)
                                         nil
                                         ,(plist-get plist :timeout))))
         (gptel-yatools--register-tool
          :name ,name
          :category ,category
          :description ,description
          ;; Copied because `gptel-make-tool' rewrites the :type symbols in
          ;; place, and a quoted literal in compiled code is not ours to
          ;; modify.
          :args (copy-tree ',arg-specs)
          :function #',symbol
          ,@(when async (list :async t))
          ,@(when (plist-get plist :timeout)
              ;; A thunk, so a `defcustom' changed later is read when used.
              (list :timeout-default `(lambda () ,(plist-get plist :timeout))))
          ,@(when (plist-get plist :confirm)
              (list :confirm (plist-get plist :confirm))))
         (gptel-yatools--register-preview ,name ',display ',arg-specs ,async)
         ;; The docstring above was built during macro expansion, before any
         ;; budget was bound; this renders it from the registered tool and
         ;; again whenever a budget changes.
         (gptel-yatools--refresh-tool-docstring
          (cl-find ,name gptel-yatools--tools
                   :key #'gptel-tool-name :test #'equal))
         ',symbol))))

;;-------------------------------------------------------------------------
;; Enabling
;;-------------------------------------------------------------------------
(defun gptel-yatools-enable-all ()
  "Add every tool this package defines to the variable `gptel-tools'."
  (interactive)
  (gptel-yatools-enable))

(defun gptel-yatools-enable (&rest categories-or-names)
  "Add some of this package's tools to the variable `gptel-tools'.

CATEGORIES-OR-NAMES are categories such as \"filesystem\", tool names such
as \"write_file\", or nil for every tool.

Enabled tools are prepended and replace any earlier entry of the same name,
so calling this twice does not send a tool twice."
  (interactive
   (list (completing-read-multiple
          "Enable tool category or name (comma separated, empty for all): "
          (delete-dups
           (append (delq nil (mapcar #'gptel-tool-category
                                     gptel-yatools--tools))
                   (mapcar #'gptel-tool-name gptel-yatools--tools))))))
  (let* ((categories-or-names (delq nil (mapcar
                                         (lambda (key)
                                           (unless (string-empty-p key) key))
                                         categories-or-names)))
         (wanted (if categories-or-names
                     (cl-remove-if-not
                      (lambda (tool)
                        (let ((category (gptel-tool-category tool))
                              (name (gptel-tool-name tool)))
                          (cl-some (lambda (key)
                                     (or (equal key name)
                                         (equal key category)))
                                   categories-or-names)))
                      gptel-yatools--tools)
                   gptel-yatools--tools)))
    (when (and categories-or-names (null wanted))
      (user-error "No tool matches %s"
                  (mapconcat #'identity categories-or-names ", ")))
    (customize-set-variable
     'gptel-tools
     (append wanted
             (cl-remove-if
              (lambda (tool)
                (cl-some (lambda (new)
                           (equal (gptel-tool-name new)
                                  (gptel-tool-name tool)))
                         wanted))
              gptel-tools)))
    wanted))

(provide 'gptel-yatools-common)
;;; gptel-yatools-common.el ends here
