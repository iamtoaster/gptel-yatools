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

A call settles these once, at the boundary, so that everything the call
does reads one answer instead of recomputing a slightly different
ambient one:

  ROOT      the workspace root, so resolving the path the model wrote,
            displaying a path back to it and finding the skill roots all
            agree -- even when a tool rebinds `default-directory'
            mid-call (the shell runner does, to run in a subdirectory).
  DEADLINE  seconds the call may run for, enforced by
            `gptel-yatools--call-with-timeout' and respected by helpers
            that block on their own.
  SUSPENDED non-nil while the call is waiting for the user, whose time
            does not count against DEADLINE.

ROOT and DEADLINE are read-only once the call is bound.  SUSPENDED is
the one field that moves during a call, and it moves only through
`gptel-yatools--with-deadline-suspended'."
  (root nil)
  (deadline nil)
  (suspended nil))

(defvar gptel-yatools--call nil
  "The `gptel-yatools-call' in progress, or nil outside a tool call.

Bound by `gptel-yatools--call-with-timeout'.  nil is an ordinary state,
not an error: tests, `eval' and hooks call tool functions directly, and
every accessor below answers for that case by falling back on what it
would have computed anyway.")

(defun gptel-yatools--call-root ()
  "Return the workspace root of the call in progress, or detect one.

Outside a call -- a tool function invoked from `eval', a test or a hook --
this is `gptel-yatools--detect-workspace-root', exactly as it was before
a call context existed.  Inside one it is the root settled at the
boundary, so a tool that rebinds `default-directory' half way through
still resolves and renders paths against the root the call started in."
  (or (and gptel-yatools--call (gptel-yatools-call-root gptel-yatools--call))
      (gptel-yatools--detect-workspace-root)))

(defun gptel-yatools--call-deadline ()
  "Return the deadline in seconds of the call in progress.

Falls back on `gptel-yatools-timeout' outside a call, for a helper called
directly."
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

The first is what a POSIX system has.  The other two are what a stripped
busybox environment -- a busybox image with nothing added -- may be left
with, where `/bin/sh' is not there at all, `/bin/ash' might not be
either, and the login shell's `PATH' is the only thing that knows where
`ash' went.

The host's own answer (`tramp-remote-shell', \"/bin/sh\" for every method
that ships with Emacs) is tried first of all; it is a default rather than
a promise, so it is asked whether it is executable just like these are.")

(defvar gptel-yatools--remote-shell-cache (make-hash-table :test #'equal)
  "The shell found on each remote host, so a host is probed only once.

Deciding costs one `file-executable-p' per candidate, and on a remote
host each of those is a round trip: worth paying once per host, not once
per tool call.")

(defun gptel-yatools--remote-shell-declared (directory)
  "Return the shell DIRECTORY's TRAMP method declares, or nil.

That is TRAMP's own answer, kept in the connection and needing no round
trip.  It is only consulted when TRAMP is loaded, which it is by the time
a remote file name can reach a tool."
  (when (fboundp 'tramp-dissect-file-name)
    (ignore-errors
      (let ((shell (tramp-get-method-parameter
                    (tramp-dissect-file-name directory) 'tramp-remote-shell)))
        (and (stringp shell) shell)))))

(defun gptel-yatools--connection (path)
  "Return a value identifying the machine PATH lives on, or nil for this one.

Two paths whose connections are `equal' run on the same host -- which is
the question `execute_command' has to answer before running a command,
because a command is approved for a workspace and must run where that
workspace is.

`file-remote-p' alone cannot answer it.  For a multi-hop name it returns
only the last hop, so \"/ssh:a|sudo:root@b:/etc/\" and
\"/ssh:c|sudo:root@b:/etc/\" both answer \"/sudo:root@b:\" although they
leave from different machines.  TRAMP's dissection keeps the hop, so the
identity is method, user, host, port and the hop chain.

A name handled by something other than TRAMP falls back on the prefix
`file-remote-p' gives, which is all such a handler offers."
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

The label is what a message can name: \"ssh:a|sudo:root@b\" rather than
the last hop alone.  It is built from `gptel-yatools--connection', so the
two cannot describe different hosts."
  (pcase (gptel-yatools--connection path)
    (`(,hop ,method ,user ,host ,port)
     (concat hop method ":"
             (and user (concat user "@"))
             host
             (and port (concat "#" port))))
    (`(,prefix) (string-remove-suffix ":" prefix))))

(defun gptel-yatools--remote-shell (directory)
  "Return the shell to run a remote command with on DIRECTORY's host.

DIRECTORY is a remote file name; the answer is an absolute path *on that
host*, fit to be the program of a process that `:file-handler' sends
there.

Every candidate is asked whether it is executable *on the host*, including
the shell the TRAMP method declares: a method's declared shell is a
default (\"\\/bin/sh\" for every backend that ships with Emacs), not a
promise.  When nothing answers -- a backend that does not implement
`file-executable-p' cannot be asked -- the first candidate is returned
anyway, so the command that fails names the shell it tried."
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
;; A tool that hands its work to a process returns a JOB instead of a
;; Result.  The body says only *what to run* and *how to read the outcome*;
;; the boundary decides whether to wait for it and render it, or to let
;; gptel's callback render it whenever it arrives.  That single decision is
;; the whole difference between a synchronous and an asynchronous tool.
;;
;; A job is concluded exactly once.  A deadline timer and a process
;; sentinel can both fire, and gptel counts a tool result every time its
;; callback runs, so a second delivery would inject the result twice and
;; could advance the request twice.
;;
;; A job becomes live in exactly one place, `gptel-yatools--make-job-live':
;; that is what puts it in the owning buffer's registry, installs the kill
;; hook, arms the deadline and starts the status line counting.  The
;; registrar starts nothing -- the work is already running when it is
;; called -- and a job is registered at the moment it can be stopped, and
;; not before.  So a new long-running tool gets the deadline, cancellation,
;; the status line and the kill-buffer hook by returning a job, and nothing
;; outside this section knows what a live job is (ADR 0005).
;;-------------------------------------------------------------------------

(defconst gptel-yatools--job-output-limit 1000000
  "Characters of output a running job will hold before it stops reading.

A tool reply is capped at `gptel-yatools--output-char-limit' (64000), so
everything past the first chunk would be discarded anyway.  Without a
ceiling, a command that loops for its whole budget -- which for an
asynchronous tool can be ten minutes -- would hold every byte it printed
in a buffer.  The ceiling sits far above the envelope limit so ordinary
truncation is unaffected.")

(cl-defstruct (gptel-yatools-job (:constructor gptel-yatools--make-job))
  "Work a tool has started and not yet finished.

Not every job is a process.  `execute_command' runs one, and a subagent
is a whole request in another buffer; what they share is everything the
boundary does with them -- the deadline, the status line, cancellation,
and the rule that the answer is delivered exactly once.  The function
slots are where the difference lives: a job that leaves them nil is a
process job.

KIND       a symbol naming the work in the status line: `command' for a
           process, `subagent' for a child request.  Anything else is
           named as it prints itself.
PROCESS    the process, or nil when it could not be started, or when the
           work is not a process at all.
BUFFER     the buffer that owns the call: its VFS, its status line and
           its cancellation are what the outcome belongs to.
OUTPUT     the buffer the process writes into.
RESULT     a function of the outcome plist returning the Result to report.
           The body owns the wording; the boundary owns delivery.
REMOTE     non-nil when the process runs on a TRAMP host.
STARTED    `float-time' at which the job was spawned.
DEADLINE   `float-time' after which the job is killed, or nil for none.
CONCLUDE   a function of the outcome plist, run exactly once.
TIMER      the deadline timer, cancelled when the job concludes.
TIMED-OUT  non-nil once the deadline has fired.
START-ERROR the message when the process could not be started.
DELIVERED  non-nil once CONCLUDE has run: the one-shot flag.
SETTLED    non-nil once the work has finished, whether or not the answer
           has been delivered yet.  The two are separate because a job
           can finish before the boundary attaches its CONCLUDE -- a
           child request that answered while the tool body was still
           returning -- and the answer must still be delivered then.
OUTCOME    the outcome plist recorded when JOB settled.
DATA       whatever the job's own functions need: for a subagent, the
           record whose state is what the outcome describes.
OUTCOME-FUNCTION a function of JOB returning the outcome plist, for work
           that is not a process.  Nil means read a process's.
CANCEL     a function of JOB and a reason, stopping the work without
           concluding it, for work that is not a process.  Nil means kill
           the process.  The reason says why the work is being stopped --
           `cancelled' when the chat is going away or the user asked,
           `timed-out' when the deadline passed -- so work that has to
           explain itself can, instead of the kit inventing a second
           vocabulary beside this one."
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

Buffer-local because a job belongs to the chat that started it: its
result is rendered against that buffer's VFS and its status is shown in
that buffer's header line.  `gptel-yatools-cancel-tool-calls' empties
it.")

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
;; gptel already shows that a tool call is in progress -- it sets
;; " Calling tool (execute_command)" before the function is called and
;; leaves it there until the result arrives -- so the only thing left to
;; add is how long it has been running, which gptel does not track.
;;
;; One timer per buffer, not per job: it runs while any job in that buffer
;; is live and stops when the last one concludes, so two parallel commands
;; share one clock.  It only runs when the header line is in use, because
;; with `gptel-use-header-line' nil `gptel--update-status' falls through to
;; `message', and a message every second is not a status, it is a nuisance.
;;-------------------------------------------------------------------------

(defvar-local gptel-yatools--jobs-timer nil
  "The timer that ticks this buffer's running-tool status, or nil.")

(defconst gptel-yatools--jobs-tick-interval 1.0
  "Seconds between refreshes of the running-tool status.")

(declare-function gptel--update-status "gptel" (msg &optional face))
(declare-function gptel--fsm-transition "gptel-request" (machine &optional new-state))

(defun gptel-yatools--job-kind-name (kind count)
  "Return the word describing COUNT jobs of KIND.

A process job is a command, because that is what `execute_command'
starts."
  (let ((word (pcase kind
                ('command "command")
                ('subagent "subagent")
                (_ (format "%s" kind)))))
    (if (= count 1) word (concat word "s"))))

(defun gptel-yatools--job-counts-by-kind (jobs)
  "Return (KIND . COUNT) for each kind in JOBS.

Ordered the way the status line reads it -- commands first, then
subagents -- and anything else after those, alphabetically, so the line
does not reshuffle itself as jobs come and go."
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
    ;; the status on to "Waiting..." or "Ready" as the request continues,
    ;; and a second opinion from here would only race them.
    nil))

;;-------------------------------------------------------------------------
;; Cancelling
;;
;; An asynchronous tool call is the one thing a user can start and then
;; have no way to stop: `C-g' has nothing to interrupt, and `gptel-abort'
;; looks the request up in `gptel--request-alist', whose entry is the
;; network process -- removed once curl finished, so during a tool call it
;; finds nothing.
;;
;; It kills the jobs first and stops the request second.  Delivering a
;; "cancelled" result instead would let the model retry the command, which
;; turns one cancel into a loop of them.
;;-------------------------------------------------------------------------

(defun gptel-yatools--abort-request (&optional buffer)
  "Move BUFFER's gptel request to its abort state, when it has one.

The state machine is recorded in the chat buffer in the variable
`gptel--fsm-last' by `gptel--update-tool-call', before the tool runs,
which is where it can be found while a tool call is what is holding the
request."
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

A subagent's buffer runs a request that belongs to its parent's tool
call, so nothing in the child's own job list describes it.  The module
that owns such a buffer sets this, and \\[gptel-yatools-cancel-tool-calls]
reaches it: the key means \"stop what this buffer is doing\", whatever
started it.")

(defun gptel-yatools-cancel-tool-calls (&optional buffer)
  "Kill the running tool calls of BUFFER and stop its request.

With no job running there is nothing to stop, and that is a `user-error'
rather than a silent success: the command is offered as a key, and a key
that does nothing cannot be told apart from one that is not bound.  The
exception is a buffer that set `gptel-yatools--cancel-function' -- a
subagent's own buffer -- where the work to stop is the request the
buffer is running rather than a job it started."
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

A filter is used rather than `:buffer' so that a command which prints
without end cannot grow a buffer without end."
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
deadline is what ended it.  A process that never started has no output of
its own, so the reason it did not travels the same way output does."
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
and the buffer is what held its status line and its cancellation, so a
process left running would be one nothing could reach.  The deadline would
eventually reap it; this makes it immediate."
  (dolist (job (gptel-yatools--jobs-live))
    (gptel-yatools--job-abandon job)))

(defun gptel-yatools--make-job-live (job)
  "Make JOB live in the buffer that owns it, and return JOB.

Every job comes through here, whatever its work is.  Registering it in
its buffer's job list is what makes it cancellable and countable;
installing the buffer's kill hook is what stops it when the chat goes
away; arming the deadline timer is what bounds it; and noting the change
starts the status line ticking (ADR 0005).

The registrar starts nothing: the caller's work is already running.  That
is why `gptel-yatools--spawn-process' calls it after `make-process'
returns rather than before -- `make-process' can block for seconds while
TRAMP opens a connection, and TRAMP runs timers while it waits, so a job
registered earlier could be cancelled while it had no process to kill.

JOB must already carry its BUFFER, STARTED and DEADLINE.  A nil deadline
arms no timer.  A job that could not be started at all is not registered
here: nothing could stop it."
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

A process job is killed, with the rules `gptel-yatools--kill-process'
states, and REASON means nothing to it: a signal has no words.  Anything
else is stopped by the function its body supplied, which is told the
reason -- `cancelled' or `timed-out' -- because a child request has to say
in its answer what stopped it."
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

Nothing happens if JOB has already settled: that is what keeps a late
sentinel, a second answer and a deadline kill from delivering a second
result.  A job can settle before the boundary has attached its
conclusion -- a child that answered while its job was still being
returned -- so recording the outcome and delivering it are separate
steps, and `gptel-yatools--job-conclude-with' delivers what was already
recorded."
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
child request can answer before this is called, so the conclusion has to
be made now in either case -- the outcome is already recorded and would
otherwise never be delivered."
  (setf (gptel-yatools-job-conclude job) function)
  (when (or (gptel-yatools-job-start-error job)
            (gptel-yatools-job-settled job))
    ;; `--job-settle' records the outcome if it is not recorded yet -- the
    ;; start error is one that has to be read -- and `--job-deliver' then
    ;; delivers whatever is recorded, which `--job-settle' alone would not
    ;; do for a job that had already settled before this call.
    (gptel-yatools--job-settle job)
    (gptel-yatools--job-deliver job))
  job)

(defun gptel-yatools--job-abandon (job)
  "Stop JOB without delivering anything, and mark it concluded.

A cancelled job reports no result: the request it belonged to is being
aborted, so there is no conversation left for the result to join.  An
answer that had already been recorded but not yet delivered is dropped
for the same reason."
  (unless (or (null job) (gptel-yatools-job-delivered job))
    (setf (gptel-yatools-job-settled job) t
          (gptel-yatools-job-delivered job) t)
    (gptel-yatools--job-stop job 'cancelled)
    (gptel-yatools--job-release job)))

(defun gptel-yatools--job-expire (job)
  "Stop JOB because its deadline has passed, and conclude it as timed out.

This runs on a timer, where a signal is logged and nothing else, so the
stop is attempted and its failure ignored: concluding the job is what has
to happen, and an outcome that says it timed out is the truth either way."
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
  "Kill PROCESS, locally or on the host, and give it a moment to be reaped.

REMOTE says PROCESS was started through a file-name handler's shell, so
it has to be killed on the host rather than here.

A local process is killed with its whole process group, because Emacs puts
each subprocess in one and the shell may ignore SIGINT while its children
carry on.  A remote process cannot be killed that way: `(process-id
PROCESS)' is the pid of the *local* ssh/docker client, so signalling that
group signals a group here and leaves the command running on the host.
`signal-process' on the process object is what TRAMP turns into a remote
`kill'."
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
                                            result description)
  "Start ARGV in the background and return a `gptel-yatools-job'.

ARGV is a list of strings: the program and its arguments, not a shell
command.  The process is the one `gptel-yatools--run-process' would
start, under the same rules: stderr merged into stdout, stdin closed at
once, the host's own shell when the directory is remote, and a
handler-built process there so the command runs on the host rather than
on this machine.

Runs where DIRECTORY says, or in `default-directory' when it is nil: a
subprocess runs where its artifacts live, so a caller that works on a
remote tree passes that tree's directory rather than letting the command
run here (ADR 0006).

RESULT is a function of the outcome plist returning the Result to
report; DESCRIPTION names the work in the header line.  TIMEOUT is the
budget in seconds, or nil for the call's own deadline, less a margin so
that the kill still lands inside it -- larger on a remote host, where
killing is a round trip before it is even a signal.

Nothing waits.  The process reports to its sentinel when it exits and the
deadline timer kills it if it does not."
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
                ;; Only a handler-built process runs on the host.
                ;; Without this flag `make-process' starts the command
                ;; here, in "~", and the reply then describes a workspace
                ;; it never touched.
                :file-handler (and remote t)
                ;; TRAMP's `pipe' path rewrites the command into a heredoc
                ;; fed to /dev/tty, and the tty echoes that wrapper into
                ;; the very buffer read as output; only the tty path
                ;; returns the command's own bytes.
                :connection-type (unless remote 'pipe)
                :filter #'gptel-yatools--job-filter
                :noquery t
                :sentinel #'gptel-yatools--job-sentinel)))
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

This is the synchronous delivery path: the same job, the same rules,
waited for on the stack instead of handed to gptel's callback.  A
process job is waited on through its process; any other kind has no
process to poll, so the wait is for whatever concludes it -- a child
request's answer, or the deadline timer, which runs while
`accept-process-output' waits.  `quit' and a signalled error leave
through the `unwind-protect', which abandons the job so that nothing
outlives the call that started it."
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

(cl-defun gptel-yatools--run-process (argv &key directory timeout)
  "Run ARGV under a deadline and return a plist describing what happened.

ARGV is a list of strings: the program and its arguments, not a shell
command.  The keyword arguments are:

  :directory  DIRECTORY to run in, or nil for `default-directory'.
  :timeout    TIMEOUT in seconds to allow, or nil for the call's deadline.

The answer is always a plist, never a signal, so a caller writes one
`pcase' instead of a `condition-case' around each failure:

  (:status exited     :exit CODE :output STRING)
  (:status timed-out  :exit nil  :output STRING)
  (:status start-error :exit nil  :output STRING)

STDERR IS MERGED into STDOUT, STDIN IS CLOSED, and the output of a
process that timed out is kept: a caller that reports why a command
failed needs the bytes it managed to write.  The kill signals the whole
process group, so a shell's children go with it -- on a remote host the
group is the remote one, killed through TRAMP.

The process is started by `gptel-yatools--spawn-process', the same
spawner a tool uses when it hands the work to the boundary, and waited
for here -- so there is one process implementation, and a tool that needs
the outcome rather than a Result asks for it with this function."
  (gptel-yatools--await-job
   (gptel-yatools--spawn-process argv :directory directory :timeout timeout)))

(defmacro gptel-yatools--with-deadline-suspended (&rest body)
  "Run BODY without counting its time against the call's deadline.

This is the only way SUSPENDED moves: a review that sits in
`recursive-edit' for a few minutes must not trip the timeout, and the
flag must be cleared however BODY exits, including a `quit'."
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

Each element is a `gptel-tool' struct.  The tools are also in gptel's
registry, which is what `gptel-menu' lists; this list is what
`gptel-yatools-enable' copies from, so that enabling does not depend on
the registry's shape.

`gptel-yatools--register-tool' appends to it, and replaces an existing
entry with the same name in place, so reloading one tool module neither
duplicates its tools nor moves them to the end of the list.")

(defvar gptel-yatools-header-line-extra-functions nil
  "Functions that contribute a label to gptel's header line.

Each is called with no arguments while the header line is being rendered
and should return a propertized string, or nil to contribute nothing.
This is how a tool module reports its own state without the module that
draws the header line having to know about it: the drawer iterates this
list and renders what it finds, so no module is a special case.

Modules append rather than prepend, so the labels appear in the order
their modules load -- the VFS count before the attached-skill count.

The functions are called on every redisplay, so they must be cheap: the
VFS count, for example, is what the header-line cache exists for.")

;;-------------------------------------------------------------------------
;; Paths
;;
;; Two kinds of argument reach a tool as text and mean a path: one the
;; model wrote (relative to the workspace root) and one this package
;; already resolved.  The helpers here are the only place that difference
;; is spelled out, so a message never mixes the two.
;;
;; Turning the first into the second happens in exactly one function,
;; `gptel-yatools--resolve-path', at the tool's edge.  The VFS interface
;; takes absolute paths only and says so loudly (see
;; `gptel-yatools-vfs--key').
;;-------------------------------------------------------------------------
(defun gptel-yatools--workspace-root ()
  "Return the root every relative path of this package is resolved against.

Outside a tool call that is `project-current's root, or
`default-directory' when there is no project.  Inside one it is the root
settled at the call's boundary (see `gptel-yatools--call-root'), so a
tool that rebinds `default-directory' half way through still resolves
and renders paths against the root the call started in."
  (gptel-yatools--call-root))

(defun gptel-yatools--detect-workspace-root ()
  "Return the workspace root implied by the current buffer, ignoring any pin.

Separate from `gptel-yatools--workspace-root' so that reading the pin and
computing a fresh answer are two different calls: the boundary needs the
fresh one."
  (let ((proj (project-current)))
    (if proj
        (file-name-as-directory (expand-file-name (project-root proj)))
      (file-name-as-directory (expand-file-name default-directory)))))

(defun gptel-yatools--remote-prefix (path)
  "Return the part of PATH that names the machine it is on, or nil if local.

`file-remote-p' is not enough to rebase a path with, because for a
multi-hop name it returns only the last hop: \"/ssh:a|sudo:root@b:/etc/\"
answers \"/sudo:root@b:\", and prepending that to a path would produce a
name that reaches b without going through a.  So the prefix is taken as
\"PATH minus its local name\", which keeps the whole hop chain.

A name handled by something other than TRAMP falls back on what
`file-remote-p' gives, which is all such a handler offers."
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

This is where a path the model wrote becomes a path this package acts
on, and it is the only such place.  Everything past it takes absolute
paths, so what a relative path means is decided once, by the tool that
received it.

A remote workspace is one machine, and a path never leaves it:

- A relative path is resolved against the root, which carries the root's
  connection with it.
- An absolute path -- \"/etc/hostname\", or \"~/notes\" -- is resolved
  against the root's *machine*.  `expand-file-name' would have treated it
  as a local absolute name and read this computer instead: in a
  container-based workspace, `read_path \"/etc/hostname\"' answered with
  the user's own desktop, and the reply looked perfectly ordinary.
- A path that already names a machine is kept, unless it names a
  different one, in which case it is refused.

A local workspace is unaffected: there, an absolute path is already a
path on the one machine in play."
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

Bidi controls (U+061C, U+200E, U+200F, U+202A-U+202E, U+2066-U+2069)
change the order in which a line is displayed, and the zero-width
characters (U+200B-U+200D, U+2060, U+FEFF) can hide inside an
identifier.  The model reading a program, and the user reading a diff,
both need to see that one is there; a character drawn as a hairline is
as good as absent.  Newlines and tabs are deliberately not here: they
are legitimate in text and mean what they look like.")

(defconst gptel-yatools--control-char-regexp
  "[\x00-\x1f\x7f\u061c\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]"
  "Regexp matching every character that may not be displayed verbatim.

That is `gptel-yatools--invisible-char-regexp' plus the C0 controls and
DEL, newline included.  A path is inserted into a buffer as one line of
output; a newline in it would add lines of its own, which is how a file
name can forge a review heading the user will read as another file's.

Text a model wrote for a human to read -- a shell command, a subagent's
brief -- is shown through `gptel-yatools--block-char-regexp' instead,
because a line break in a here-document is content, not an attack.")

(defconst gptel-yatools--block-char-regexp
  "[\x00-\x08\x0b-\x1f\x7f\u061c\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]"
  "Like `gptel-yatools--control-char-regexp', but newline and tab are allowed.

Escaping either was the mistake this exists to undo: they are the two C0
characters that are legitimate in text meant to be read, and spelling them
out turned a script into one unreadable wall of <U+000A> and <U+0009>.
Everything else invisible is still spelled out, and a carriage return
still is: it says nothing a reader can see, and would move the cursor if
it ever reached a terminal.")

(defun gptel-yatools--escape-chars (string regexp)
  "Return STRING with every match of REGEXP written as <U+XXXX>.

Text that holds none of them is returned unchanged, which is every reply
that matters for speed."
  (if (null (string-match-p regexp string))
      string
    (replace-regexp-in-string
     regexp
     (lambda (m) (format "<U+%04X>" (string-to-char m)))
     string t t)))

(defun gptel-yatools--printable-string (string)
  "Return STRING with every invisible character written as <U+XXXX>.

Newline is included, so the result is always one line:
`gptel-yatools--display-path' uses this for paths, where a line break
would let a name compose the review it appears in.  Text that a human is
meant to read line by line goes through
`gptel-yatools--printable-block' instead."
  (gptel-yatools--escape-chars string gptel-yatools--control-char-regexp))

(defun gptel-yatools--printable-block (string)
  "Return STRING with its invisible characters spelled out, newlines kept.

For the text a model wrote to be read rather than to be compared: a
multi-line shell command, the brief handed to a subagent.  Keeping the
line breaks and the tabs is the whole point -- the shape of a
here-document, or the indentation of an inline script, is what the user is
being asked to approve."
  (gptel-yatools--escape-chars string gptel-yatools--block-char-regexp))

(defun gptel-yatools--display-path (path)
  "Return PATH relative to the workspace root, escaped for display.

Falls back to the absolute path when PATH is outside the workspace.
The workspace root itself is shown as \".\", the way a relative path
would name it: stripping the root from the root leaves an empty
string, which would read as \"the directory called nothing\".

Control characters are written as <U+XXXX>, so that everything this
package shows -- review headings, the skipped list, sync reports, tool
replies -- can only ever be one line per string.  Without that, a file
whose name holds a newline could add lines of its own to the review
heading, and the user would approve a change set that is not the one
being described: the review is the control, so a path must not be able
to compose it.  Git stores arbitrary bytes in file names, so such a
name can arrive from a cloned repository and need not be exotic."
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
string is read as the number it begins with -- \"2\", \"2.0\" and
\"7 items\" all name 7, 2 and 7.  A string holding no digit at all is
nil, so the caller can tell \"two\" from \"2\" instead of being handed a
silent 0.

Reading the number a string begins with, rather than requiring bare
digits, is deliberate: a model that quotes an argument sends \"2.0\"
about as often as \"2\", and refusing the first would make it fall back
to a default -- a wrong answer that looks like a right one.  This is the
primitive `gptel-yatools--coerce-integer' and `gptel-yatools--checked-arg'
are both built from."
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

Integers pass through, other numbers are truncated toward zero, and
numeric strings are parsed first.  The result is never below MINIMUM
\(default 0).  Tool arguments come from JSON, where a model may send
1.0, \"2\" or nil even for a declared integer; without this coercion
they reach `forward-line' or `nth' as a non-integer and signal a raw
Lisp error instead of a readable tool response."
  (let* ((minimum (or minimum 0))
         (n (gptel-yatools--integer-value value)))
    (if (and (integerp n) (>= n minimum))
        n
      (max minimum (or default minimum)))))

(defun gptel-yatools--require-string (value what)
  "Signal a readable error unless VALUE is a string.

WHAT names the argument in the message.  Tools are called with JSON
arguments; a missing or wrong-typed required argument used to reach
`expand-file-name' or `string-trim' and signal a raw Lisp error."
  (unless (stringp value)
    (error "Error: %s must be a string" what))
  value)

(defun gptel-yatools--flag-p (value)
  "Interpret VALUE as a JSON-ish boolean flag.

Only clearly-false values are false: nil, `:json-false', the number
0 and the strings \"false\", \"no\" and \"0\".  This matters for
`overwrite': a model that sends the string \"false\", or the number
0, must not silently discard a pending conflict."
  (not (or (null value)
           (eq value :json-false)
           (and (numberp value) (zerop value))
           (and (stringp value)
                (member (downcase (string-trim value))
                        '("false" "no" "0" ""))))))

(defun gptel-yatools--checked-arg (value type name optional)
  "Return VALUE as the TYPE that argument NAME is declared with.

OPTIONAL says the model may leave the argument out, and then nil passes
through untouched: only an argument that is present is checked, so a
tool's own defaulting stays in charge of what an omitted one means.

A string is checked rather than converted, because the tool body will
hand it to `expand-file-name' or `string-trim' and a number there
signals a raw Lisp error instead of a readable reply.  Integers and
booleans are converted instead: JSON gives a model three ways to spell
two and two to spell false, and \"that is not an integer\" is a worse
answer than doing what it plainly meant.  A value that names no integer
is left alone for the body to refuse in its own words.

The declarations this reads are the `:args' list of
`gptel-yatools-define-tool', which already states every argument's type,
so the check is written once, in the definition."
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
;; Two things can make a tool's answer unfit to send back to the model: it
;; can be too large for the context window, and it can contain bytes that do
;; not decode, which `json-serialize' refuses outright.  Both are handled
;; here, once, rather than in each tool.
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

A byte 0x80-0xFF read by `string-to-multibyte' becomes the character
#x3FFF00+BYTE, whose charset is `eight-bit'.  Detecting them with a
regexp costs one C-level pass over the text, where a per-character loop
costs roughly a microsecond per character -- 60 ms for a 60 kB tool
response, paid on every single call.")

(defun gptel-yatools--escape-raw-bytes (string)
  "Return STRING with undecodable raw bytes and invisible characters escaped.

Tool responses are serialised to JSON when they are sent back to
the model, and Emacs cannot encode a string containing raw (eight
bit) characters: `json-serialize' signals
\"Wrong type argument: json-value-p\" and the whole request dies.
Raw bytes appear whenever a command prints binary or non-UTF-8
data (`cat' of an ISO-8859-1 file, `od', a PDF, ...), so every
tool response is passed through this before it is returned.

A bidi control or a zero-width character is ordinary, encodable
Unicode, so serialisation is happy with it and the model would read a
file whose displayed order is not its logical order without ever
learning that.  Those are escaped too, as <U+XXXX>, which is a true
statement about the text where an invisible character is no statement
at all.

Almost every response is ordinary text, which needs no escaping at
all, so that case is detected first and returned as it is: the
character loop below is only for the string that really does carry raw
bytes."
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

`gptel-yatools--escape-raw-bytes' turns one raw byte into four characters,
so a cut can land inside an escape.  Dropping the partial escape keeps the
text unambiguous for the reader.

That includes a bare trailing backslash and the prefixes \"\\x\" and
\"\\xa\": an escape cut to one or two of its four characters reads as an
escape with no byte behind it."
  (let ((cut (substring string 0 (min limit (length string)))))
    (if (string-match "\\\\\\(x[0-9a-f]?\\)?\\'" cut)
        (substring cut 0 (match-beginning 0))
      cut)))

(defun gptel-yatools--within-limits-p (string)
  "Return non-nil if STRING needs no truncation.

That is: it is within `gptel-yatools--output-char-limit' characters and
holds at most `gptel-yatools--output-line-limit' lines.

Counting the lines is itself bounded: the scan stops as soon as the
line limit is passed, so a large response costs one C-level
`string-search' per line up to the limit rather than a
`split-string' over the whole text."
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

The text is capped to the line and character limits and has raw,
non-UTF-8 bytes escaped.  The size limit is enforced twice: once on
the original text, so the reported counts mean something to the
reader, and again after escaping, because one raw byte becomes four
characters and would otherwise blow past the limit by up to 4x.

A note is appended whenever anything was cut, so a truncated reply is
never mistaken for the whole file.

A response that is already within both limits and carries no raw bytes
is returned as it is.  That is the case for nearly every tool call, and
skipping the `split-string'/`mapconcat' round trip keeps it cheap: a
60 kB read costs a few hundred microseconds instead of tens of
milliseconds, which is time the user spends waiting between tool
calls."
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
lines and \"\" holds none.  That is the answer `count-lines' gives for
the same text in a buffer, and so the answer `read_file_from_offset'
reports.  Truncation and paging count lines through this function too,
so no two replies can disagree about how many lines a text has.

The temptation is `(length (split-string string \"\\n\"))', which is one
too high for any text ending in a newline -- that is, for every diff."
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
  "Return BODY with anything that could forge an envelope tag neutralised.

The envelope is assembled as a string, so the only thing that tells
tool output apart from harness chrome is that the output cannot spell
the chrome.  Escaping every \"<\" would also achieve that, but it
expands Lisp and HTML diffs about fourfold, and `gptel-yatools-page'
promises a page that the envelope's own truncation will not then cut in
half -- a promise worth more than the readability of the tag names this
touches.  So only the starts of the two envelope tags are escaped;
every other \"<\" is left as the file had it."
  (replace-regexp-in-string
   "<\\(/?tool_\\(?:context\\|response\\)\\)"
   "&lt;\\1"
   body))

(defun gptel-yatools--envelope (provenance comment body)
  "Return BODY wrapped in the tool context/response XML envelope.

PROVENANCE says where BODY came from: `:disk', `:vfs', `:mixed' or
`:derived' (see `gptel-yatools--provenances').  It becomes the context
tag's `vfs' attribute, which is false only for a wholly-on-disk reply.
COMMENT is a short note shown to the LLM in the context tag.

COMMENT is escaped with `gptel-yatools--xml-escape' because it sits in
an attribute.  BODY cannot be escaped wholesale without breaking the
page size that `vfs_diff' reports, so it is passed through
`gptel-yatools--escape-envelope-body' instead, which neutralises the
two tags a reply could use to forge the provenance line the package
asks the model to trust.  Both are then run through
`gptel-yatools--truncate', so that no response carries bytes that
cannot be serialised for the model."
  (format "<tool_context vfs=\"%s\" comment=\"%s\"/>\n<tool_response>\n%s\n</tool_response>"
          (gptel-yatools--provenance-attr provenance)
          (gptel-yatools--xml-escape (gptel-yatools--escape-raw-bytes comment))
          (gptel-yatools--truncate
           (gptel-yatools--escape-envelope-body body))))

;;-------------------------------------------------------------------------
;; The tool boundary
;;
;; A tool function says what it found and returns a Result; rendering that
;; as the envelope above is this section's job, and it happens in exactly
;; one place -- the wrapper `gptel-yatools-define-tool' writes around every
;; tool.  Two reasons this is not left to each tool:
;;
;; - An error that is signalled rather than returned never reaches the
;;   envelope.  gptel catches it, stringifies it and stores THAT as the
;;   result, so the model would get "error <message>" with no
;;   <tool_context>, and -- worse -- without passing through
;;   `gptel-yatools--escape-raw-bytes'.  A raw byte in an error message
;;   (a file name that does not decode, say) then makes `json-serialize'
;;   refuse the whole request.  Catching here closes that hole for every
;;   tool at once.
;; - `vfs_diff' pages its own output, and the page has to fit the same
;;   size budget the envelope enforces, or the truncation below would cut
;;   it in half after the tool had already reported what it showed.
;;   `gptel-yatools-page' is that budget, offered as a helper instead of a
;;   constant each tool reads directly.
;;-------------------------------------------------------------------------
;;-------------------------------------------------------------------------
;; The Result, and where its content came from
;;
;; A reply's provenance is one of three things, and the tool functions
;; were spelling it out in prose -- each one writing its own
;; `:vfs'/comment pair, and a listing that merged both saying "disk".
;; It is a fact about the reply, so it travels as data and the boundary
;; renders it once.
;;-------------------------------------------------------------------------
(defconst gptel-yatools--provenances '(:disk :vfs :mixed :derived)
  "The provenance values a `gptel-yatools-result' may carry.

:disk    every byte of the body is what is on disk.
:vfs     the body is pending virtual-filesystem state, not on disk yet.
:mixed   the body blends the two -- a directory listing that merges disk
         with VFS-only entries, for instance -- so the reply is neither
         a description of disk nor a description of pending changes.
:derived the body is a conclusion drawn by another model, not a
         description of anything this process read.  A subagent's
         answer is the case this exists for: it may be right, and it is
         not evidence, so it must not arrive claiming to describe disk.")

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

`:disk' is the only provenance that is wholly on disk, so it is the only
one that answers false.  A model that checks the attribute is asking
\"may this text disagree with disk?\", and for :mixed the answer is yes."
  (if (eq provenance :disk) "false" "true"))

(cl-defstruct (gptel-yatools-result (:constructor gptel-yatools--make-result)
                                    (:copier nil))
  "What a tool function returns.

BODY is the text the model reads.  PROVENANCE says where it came from:
`:disk', `:vfs' or `:mixed' (see `gptel-yatools--provenances').
COMMENT is the envelope's one-line context comment; nil means derive it
from PROVENANCE.

Build one with `gptel-yatools-ok'.  A tool never formats, truncates or
escapes its own response: all of that happens once, at the boundary
\(see `gptel-yatools--call-tool')."
  (body "" :documentation "The text the model reads.")
  (provenance :disk :documentation "One of `gptel-yatools--provenances'.")
  (comment nil :documentation "Context comment, or nil to derive it from PROVENANCE."))

(defun gptel-yatools-ok (body &rest args)
  "Return a `gptel-yatools-result' carrying BODY.

BODY is what the model reads.  It is size-limited and raw-byte-escaped
at the boundary, so a tool can return all of it and let the boundary
decide what fits.

ARGS is a plist with two optional keys:

  :provenance  one of `gptel-yatools--provenances'.  Defaults to `:disk'.
               A tool that read a pending VFS entry says `:vfs'; one
               whose reply blends disk and pending state -- a merged
               directory listing -- says `:mixed'.
  :comment     the envelope's one-line context comment.  Defaults to a
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

A tool returning anything else is a bug in this package.  It is reported
to the model as a failed call rather than signalled, because a signalled
error would bypass the envelope -- and with it the escaping that keeps
the request serialisable."
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
  "Return ERR's message without a redundant leading \"Error:\".

Tool functions write \"Error: ...\" because that is the text the model
reads; the boundary prefixes the same word, so stripping it here keeps a
failure from arriving as \"Error: Error: ...\"."
  (let ((text (error-message-string err)))
    (if (string-match "\\`Error: +\\(.+\\)\\'" text)
        (match-string 1 text)
      text)))

;;-------------------------------------------------------------------------
;; Tool call timeouts
;;
;; A tool that blocks -- a hung shell command, a read from a FIFO -- blocks
;; Emacs itself, so every tool gets a deadline (120 seconds by default, or
;; `gptel-yatools-async-timeout' for one that delivers asynchronously) plus
;; an optional TIMEOUT argument for the rare call that genuinely needs
;; longer.  That argument's description tells the model not to raise it
;; unless it truly has to.
;;-------------------------------------------------------------------------
(defvar gptel-yatools--timeout-defaults (make-hash-table :test #'equal)
  "Per-tool default timeouts, by tool name.

Most tools share one default, chosen by whether they deliver
synchronously or not.  A tool whose work is of a different kind states its
own with `:timeout' in its definition, so that raising one tool's budget
does not raise every other tool's: a subagent may legitimately run for
half an hour while a shell command that does is already suspicious.

The value is a function, not a number, because the answer has to be read
when it is used -- a `defcustom' the user changes during a session must
change the description the model is given.")

(defun gptel-yatools--timeout-default-for (name)
  "Return the budget NAME's tool declares for itself, or nil for the shared one.

Looked up by name, and read through the thunk the definition stored, so a
`defcustom' changed during a session is the number returned rather than the
one that was in force when the tool was defined."
  (when-let* ((thunk (gethash name gptel-yatools--timeout-defaults)))
    (and (functionp thunk) (funcall thunk))))

(defun gptel-yatools--tool-timeout-default (tool)
  "Return TOOL's own default timeout in seconds, or nil for the shared one."
  (gptel-yatools--timeout-default-for (gptel-tool-name tool)))

(defun gptel-yatools--timeout-default (&optional async)
  "Return the default number of seconds a call may run, ASYNC or not.

A synchronous call blocks Emacs for its whole duration, so its default is
`gptel-yatools-timeout' (two minutes).  An asynchronous one does not hold
Emacs at all, so its budget is about the host's resources rather than the
user's keyboard -- `gptel-yatools-async-timeout' (ten minutes).

Both fall back on a number when the variable holds something that is not
one, so a bad `setq' in a config file cannot make a tool unbounded."
  (gptel-yatools--coerce-integer
   (if async
       (bound-and-true-p gptel-yatools-async-timeout)
     (bound-and-true-p gptel-yatools-timeout))
   120 1))

(defun gptel-yatools--resolve-timeout (value &optional async default)
  "Return the timeout in seconds to use for one tool call.

VALUE is the TIMEOUT argument supplied by the model: a number, a
numeric string, or nil for the default.  Unusable values fall back on
DEFAULT when given -- a tool's own stated budget -- and otherwise on the
default for this kind of call where ASYNC says which kind this is: see
`gptel-yatools--timeout-default',
which is `gptel-yatools-timeout' for a synchronous tool and
`gptel-yatools-async-timeout' for an asynchronous one.  The result is
always at least one second."
  (gptel-yatools--coerce-integer
   value
   (or default (gptel-yatools--timeout-default async))
   1))

(defun gptel-yatools--timeout-arg (&optional async default)
  "Return the optional TIMEOUT argument plist added to every tool.

ASYNC says which shared default to state, because the two kinds of tool
quote a different one: see `gptel-yatools--timeout-default'.  DEFAULT,
when given, is the tool's own budget and is stated instead -- the model
must never be told a number the boundary will not enforce.

This is the only place the model is told about timeouts: one argument
description, stated once, naming the default and telling the model not
to raise it unless the work genuinely needs longer."
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
which tool ran out of time.  Both are optional because a conclusion built
from a sentinel knows the call's budget but not always its name, and a
sentence with a gap is worse than one without the clause.

This and `gptel-yatools--failure-envelope' are the only two places a
failure is turned into something a model reads."
  (gptel-yatools--envelope
   :disk "Tool call timed out."
   (gptel-yatools--timeout-message seconds name)))

(defun gptel-yatools--failure-envelope (err)
  "Return the envelope for a call that reported ERR.

ERR is the `condition-case' value, `(SYMBOL . DATA)'.  `quit' arrives
here too: it is not an `error', so a handler written for errors alone
lets it through, and from a sentinel or a timer nothing above catches it
-- which is the same silence as a crash, with the request still waiting."
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

Kept separate from registration so that changing
`gptel-yatools-timeout' or `gptel-yatools-async-timeout' during a session
updates what the model is told instead of leaving a stale number behind.
The tools are taken from this package's own list, not from the variable
`gptel-tools': a tool that the user has not enabled is not there, but its
argument must still be correct when it is enabled later.

Each tool states the default that applies to it, which is why the async
flag is read from the tool rather than assumed, and its own stated
default takes precedence over the shared one.

The docstring is re-rendered here too, through `function-documentation',
which see.  A docstring is a string baked into the `defun', so a compiled
package would otherwise keep stating whatever the budget was when it was
compiled -- and `C-h f' is exactly where a user goes to check the number
they are about to rely on."
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

An asynchronous tool does not hold Emacs: the call returns, the user keeps
working, and the result is delivered when the work finishes.  So this
budget is about the host's resources and about not leaving a runaway
command behind -- not about how long the editor is unavailable, which is
what `gptel-yatools-timeout' bounds.  That is why it is ten minutes rather
than two.

Every asynchronous tool takes the same optional TIMEOUT argument, whose
description states this default, so the model is not left guessing what a
raised value would mean."
  :type 'number
  :group 'gptel-yatools
  :set #'gptel-yatools--set-async-timeout)

(defcustom gptel-yatools-timeout 120
  "Maximum number of seconds a gptel tool call may run before it is aborted.

Every tool takes an optional TIMEOUT argument that overrides this for a
single call; the argument's description tells the model not to raise it
unless the task truly needs more time.

Tool calls are synchronous, so this is also the longest a single call can
keep Emacs busy.  Time spent waiting for the user (for example reviewing
a `file_sync' diff) does not count.

Changing this with `customize-set-variable' updates the description the
model is given, so a stale number is not left behind.  A plain `setq'
does not: it takes effect for the tools defined afterwards, which is the
case that matters when the value is set in a config file."
  :type 'number
  :group 'gptel-yatools
  :set #'gptel-yatools--set-timeout)

(defun gptel-yatools--new-call (&optional timeout)
  "Return the `gptel-yatools-call' for a tool call starting now.

The root is inherited from an enclosing call when there is one, so a call
never moves its workspace half way through; otherwise it is detected from
the current buffer.  The deadline is TIMEOUT, already resolved.

Both halves of the boundary build their call here: the synchronous one
that waits under a timer, and the asynchronous one that binds the same
context again when the answer arrives, long after the buffer that started
the call has stopped being current."
  (let ((outer gptel-yatools--call))
    (gptel-yatools--make-call
     :root (if outer
               (gptel-yatools-call-root outer)
             (gptel-yatools--detect-workspace-root))
     :deadline (or timeout (gptel-yatools--resolve-timeout nil)))))

(defcustom gptel-yatools-tool-trace nil
  "Whether to record what happens to each deferred tool call.

When non-nil every step is appended to `gptel-yatools-tool-trace-file':
the call arriving, whether it ran inline or was deferred, each timer
firing with the state it found, and every reason a call was dropped.

It exists because a request that stops in TOOL leaves nothing behind --
no error, no timer, no result -- so the only way to find out where the
chain broke is to record the chain.  Leave it off: it is a diagnostic,
and it writes a line per step."
  :type 'boolean
  :group 'gptel-yatools)

(defcustom gptel-yatools-tool-trace-file
  (expand-file-name "gptel-yatools-trace.log" temporary-file-directory)
  "Where `gptel-yatools-tool-trace' writes.

The name is built from the variable `temporary-file-directory' rather
than a literal \"/tmp\", so that the file lands in the machine's own temp
directory, and a trace needs no place of its own."
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

The call runs to completion -- it cannot do its work in halves -- but the
quit is not the call's to swallow.  It is recorded here and re-signalled by
the outermost layer once the answer has been delivered, so it reaches
whatever the user actually meant to interrupt: a minibuffer, another
command, anything above the tool call on the stack.")

(defcustom gptel-yatools-ignore-quit t
  "Whether a running tool call lets a `C-g' pass through it.

A tool call can be running when `C-g' is pressed for something else --
closing the minibuffer, dismissing a prompt, cancelling an unrelated
command.  The quit signal travels to whatever is on the stack, so the call
was abandoned mid-way and its chat reported an error the user never asked
for: \"DeepSeek error: (HTTP/2 200) Quit\".

With this on, the call behaves as though it were not there: its body runs
to completion, and the `C-g' is then re-signalled one layer out, so the
minibuffer still closes and the command the user stopped still stops.  The
call is not cancelled, and the keypress is not swallowed.

A quit that was already pending when the call started is left alone, so a
deliberate `C-g' outside a call is untouched.

This does not make a call unkillable: the deadline in
`gptel-yatools-timeout' is enforced by a timer that throws, which is
unaffected."
  :type 'boolean
  :group 'gptel-yatools)

(defun gptel-yatools--replay-pending-quit ()
  "Re-signal a `C-g' that arrived during a tool call, if there was one.

Called at the outermost boundary of a call, after its result has been
delivered: by then the work is done and the quit belongs to whoever was
waiting above.  The flag is cleared first, so the signal propagates once
rather than being raised again at every later safe point."
  (when gptel-yatools--pending-quit
    (setq gptel-yatools--pending-quit nil
          quit-flag nil)
    (signal 'quit nil)))

(defmacro gptel-yatools--without-quit (&rest body)
  "Run BODY to completion, and owe any `C-g' that arrives during it.

Measured in this Emacs: with `inhibit-quit' bound, a `C-g' is deferred
rather than signalled, and it is raised at the next safe point after the
binding ends.  That is the shape wanted here -- the body finishes and the
quit is not lost -- but that safe point falls inside this package's own
caller, where a quit would abort the delivery of the result and strand the
request.  So the deferred quit is taken here, and re-signalled only by
`gptel-yatools--replay-pending-quit' at the boundary that has finished
delivering.

A quit already pending before BODY propagates as usual.  `throw' is
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

TIMEOUT defaults to `gptel-yatools-timeout'; NAME labels the tool in the
error.  Returns FUNCTION's value, or signals `gptel-yatools-timeout-error'
with the seconds and tool name in its data when the deadline is hit.  A
timer is used rather than `with-timeout' so that time spent waiting for
the user (see `gptel-yatools--with-deadline-suspended') can be excluded,
and because `with-timeout' cannot interrupt `call-process' anyway.

This is also where the call's context is settled: the `gptel-yatools-call'
it binds carries the deadline, the workspace root captured at this point,
and the pause flag, so everything the call does reads one answer.  It is
inherited from an enclosing call when there is one -- the root never moves
half way through.

Timers only run while Emacs waits for input, so this bounds calls that
block on I/O -- the case that matters -- but cannot interrupt a purely
CPU-bound form.

The timer can only `throw': a `signal' raised inside a timer callback is
consumed by Emacs's timer loop and the call would carry on running.  So
the timer throws a fresh marker, and the catch site re-signals it as the
condition the boundary renders."
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

ARGS is the positional list the tool function is called with, in the
order `:args' declares, and ARG-SPECS is that declaration.  Each value
is passed through `gptel-yatools--checked-arg', so a string argument
that arrived as a number is refused here -- with an envelope and a
sentence -- instead of signalling from inside `string-trim'.

A tool that declares no arguments keeps the ones it was given: having
nothing to check against is not the same as having nothing to pass, and
dropping them made the tool run with none of its arguments and report
`wrong-number-of-arguments' for a call the model had made correctly.

Nothing here is a second opinion about the tool's own defaults: an
omitted optional argument stays nil, and an integer that names no
number is left for the body to refuse in its own words."
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
  "Return non-nil when OUTCOME is a deadline kill and JOB cannot describe it.

A body that declared a result function gets to describe its own timeout,
and it does so better than the boundary can: `execute_command' knows the
command, the directory and the output it managed to produce, and says
\"Command killed ... Partial output: ...\" rather than a generic sentence.
So the boundary's timeout envelope is for a job that has no such function
-- one that spawned a process without saying how to read its outcome."
  (and (plist-get outcome :timed-out)
       (not (functionp (gptel-yatools-job-result job)))))

(defun gptel-yatools--job-tool-result (job name seconds)
  "Wait for JOB and return the Result its body declared.

NAME labels the tool and SECONDS is the budget that ran out, both used to
describe a deadline the job did not meet.

A job that outlived its deadline and has no result function of its own
signals `gptel-yatools-timeout-error', so the model is told the call was
abandoned rather than handed the output of a process killed mid-sentence."
  (let ((outcome (gptel-yatools--await-job job)))
    (if (gptel-yatools--job-timed-out-p job outcome)
        (signal 'gptel-yatools-timeout-error
                (list :seconds seconds :tool name))
      (gptel-yatools--job-report job outcome))))

(defun gptel-yatools--call-tool (name function args &optional timeout arg-specs async default)
  "Call FUNCTION with positional ARGS and render the outcome for the model.

This is the tool boundary in one function: the deadline is enforced, the
Result is rendered into the envelope, and a signalled error, an expired
deadline and a tool that returned the wrong shape all become that same
envelope -- sized, truncated and escaped -- so the model never receives
bare text and never receives text that cannot be serialised back to JSON.

ARG-SPECS, when given, is the tool's `:args' declaration.  It is checked
here rather than at the top of each tool body for two reasons: the check
is generated from the declaration that already states the types, and a
refusal raised here is inside the `condition-case' below, so it reaches
the model as an enveloped sentence rather than as bare text.

NAME labels the tool in a timeout message.  TIMEOUT is the call's own
deadline, or nil for the default; ASYNC says which default that is (see
`gptel-yatools--timeout-default'), and DEFAULT, when given, is the tool's
own budget, which overrides the shared one.

A body that handed its work to a process returns a job rather than a
Result, and is waited for here.  That is the synchronous half of the
delivery decision: `gptel-yatools--call-tool-async' is the other half, and
the job, the process and the rules are the same for both.

The call's context -- the workspace root, settled once -- is bound by
`gptel-yatools--call-with-timeout', so a tool that rebinds
`default-directory' (the shell runner, to run in a subdirectory) cannot
change what a later relative path or message means.

`quit' passes through untouched, and so does anything the user asked to
debug: `condition-case-unless-debug' leaves the signal alone while
`debug-on-error' is set."
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

NAME labels the tool in what the model is told when the call goes wrong,
and ARGS is what gptel passed positionally: the tool's own arguments,
then its timeout, split by `gptel-yatools--split-args'.

gptel calls an asynchronous tool with its callback as the first argument.
The body runs here, in the buffer that owns the call, and returns either a
Result -- it had nothing to wait for -- or a job, whose conclusion
delivers.

Delivery re-enters the owner buffer and rebinds the call context, because
the answer arrives long after the call returned and both
`default-directory' and the VFS are buffer-local: rendering outside that
buffer would resolve paths against the wrong root and read the wrong VFS.
The callback is called exactly once, because gptel counts a tool result
every time it runs."
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

Rendering a conclusion runs the body's own RESULT function over the
outcome plist, and either can be wrong in a way nobody planned for: a
record read off a nil slot, a formatter tripping over output it did not
expect.  This is the last point at which the answer can still be
delivered -- by the time it runs the job is marked delivered and has left
its buffer's registry, so there is nothing left to retry -- and it often
runs from a process sentinel, where a signal is logged and nothing else.
Silence there is a tool call that never reports, and gptel waits for ever
for a callback that is never going to come.

So a failure to render is reported as the tool failing.  That is true,
and it is an answer.

TIMEOUT and NAME are the call's budget and tool name, for the sentence
used when the deadline is what ended the work; a job whose body said how
to read its own timeout is rendered by that body instead."
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

ARG-SPECS is the tool's `:args' declaration, whose length says how many
of the leading ARGS are the tool's own.

ARGS holds the tool's declared arguments in order, then the TIMEOUT every
tool takes; the declaration says how many of the first are the tool's own.
gptel passes them positionally, so this is the only place the boundary has
to know where the tool's arguments end."
  (let ((n (length arg-specs)))
    (cons (cl-subseq args 0 (min n (length args)))
          (nth n args))))

(defun gptel-yatools--call-tool-async (name function first args arg-specs &optional default)
  "Tool boundary for a tool registered with `:async t'.

NAME labels the tool in what the model is told when the call goes wrong.

FIRST is what gptel passed first.  On a real tool call that is gptel's
callback, and the answer is delivered to it.  A direct call -- from
`eval', a hook, or a test -- passes the tool's own first argument instead,
and is answered synchronously, so both ways of calling a tool keep
working and both end at the same envelope.  FUNCTION is the tool's body,
and ARGS is the rest of what gptel passed.

An error raised before a job exists has to be delivered here: returning it
would leave gptel waiting for a callback that is never going to come."
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
  "Return a page of TEXT, described by a plist.

This is the response budget, offered as a helper rather than a constant
each tool reads directly: a tool that pages its own output -- `vfs_diff'
-- has to say what it showed, and a page that could be cut in half by the
boundary's truncation would make its report a lie.

OFFSET is the 1-based number of the first line wanted, LINES how many.
The page never exceeds `gptel-yatools--output-char-limit' minus RESERVE,
so the boundary's truncation cannot cut it in half after the caller has
said what it showed.  RESERVE is for text the caller adds around the
page -- a banner, say -- and which the size limit counts too; without it
a page that filled the budget exactly left no room for its own heading,
and the truncation this function exists to prevent happened anyway, to
the last line the page had claimed to show.  A single line longer than
the remaining budget is still returned whole; the boundary handles that
case.

Lines are counted by `gptel-yatools--line-count', so a text that ends in
a newline has no phantom last line to page onto, and the page text is
exactly the text of the lines it reports.

The plist holds :text, :start and :end (1-based, inclusive, of the lines
shown), :total (lines in TEXT), :past-end (OFFSET was beyond the last
line) and :partial (the page is not the whole of TEXT)."
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
;; gptel renders a pending tool call with `gptel--format-tool-call', which
;; truncates every string argument at 256 characters, so a call could be
;; approved on a harmless prefix.  `gptel--tool-preview-alist' is gptel's
;; answer: a tool-specific renderer in place of the default, asked for by
;; name.
;;
;; Two facts about that alist are easy to get wrong:
;;
;; - Its docstring says the setup function is called with \"a plist of the
;;   corresponding tool call arguments\", but gptel actually passes
;;   `(gptel--map-tool-args TOOL-SPEC ARGS)' -- a positional list.  A
;;   renderer that reads it as a plist finds nothing and draws nil.
;; - The list it is handed is `gptel-tool-args'' order, which is the
;;   declared order plus the TIMEOUT every tool gets.
;;
;; Hence `:preview': a tool names the arguments worth showing, and the
;; definition builds the renderer that reads them by name.
;;-------------------------------------------------------------------------
(defun gptel-yatools--preview-value (value)
  "Return VALUE as it is written into a confirmation.

A string is quoted with `prin1-to-string' after
`gptel-yatools--printable-block': quoting is what keeps a `\"' or a `\\'
in the value from being read as the end of it, and the printable pass is
what spells out the invisible characters.  Newlines survive both: a shell
command holding a here-document, or a subagent's brief, is text a person
is meant to read line by line.  A value that spans lines is put on a line
of its own so the block does not begin mid-line.  Anything that is not a
string is printed as it prints itself."
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

DISPLAY is the tool's `:preview' list: the arguments to show, in the
order to show them.  ARG-SPECS is the tool's `:args' declaration, which
gives each shown name its position and says whether it may be omitted.
VALUES is the positional argument list gptel hands the tool function,
with the trailing TIMEOUT every tool takes.  ASYNC says the call returns
before the work finishes, which is stated on the line: whether the
command keeps running after you accept is part of what is being approved.

A required argument is printed where it belongs -- positionally, the
way the call reads -- and an optional one as NAME=VALUE, so the two
kinds stay tellable apart.  `timeout' is named explicitly because it is
not part of the command but does bound how long the call runs; it is
also the one value printed as the number it will be used as, rather
than as the model wrote it, since \"5\" and 5 mean the same seconds.

The result is one line only when every value is one line.  A command
holding a here-document is shown as the block it is, because a
confirmation the user cannot read is not a confirmation."
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
          ;; Resolved with the tool's own budget, not the shared one: the
          ;; prompt is the user's only chance to notice a call that runs
          ;; far longer than they expected, so it must name the number the
          ;; boundary will actually allow -- the same number the tool's
          ;; TIMEOUT argument states to the model.
          (setq value (and (gptel-yatools--preview-shows-p value)
                           (gptel-yatools--resolve-timeout
                            value async
                            (gptel-yatools--timeout-default-for name)))))
        (cond
         ((null position) nil)
         ((member shown required)
          (push (if (null value)
                    ;; A required argument gptel did not pass at all.  It
                    ;; is named rather than printed as `nil', which reads
                    ;; as a value the user could approve instead of as an
                    ;; argument that is missing.
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

ARG-SPECS is the tool's `:args', which the renderer reads positions
from; ASYNC is passed through so the line can say the call returns
before the work does.  Nothing is registered for a tool that asks for no
preview.

The registration is guarded: the alist is gptel's, so a gptel that stops
defining it simply falls back to the default rendering, which is
truncated but not wrong in the way a missing prompt would be."
  (when (and display (boundp 'gptel--tool-preview-alist))
    (setf (alist-get name gptel--tool-preview-alist nil nil #'equal)
          (list (lambda (values _info)
                  (insert (gptel-yatools--preview-line name display
                                                       arg-specs values async))
                  nil)))))

(defun gptel-yatools--literal (form)
  "Return FORM as the literal list it names, quoted or not.

A definition writes `:args \\='(...)' because that is how a list of
plists survives the byte compiler.  The macro needs the list itself, so
the quote -- present or absent -- is stripped here rather than in each
of the places that reads a literal."
  (if (and (consp form) (eq (car form) 'quote))
      (cadr form)
    form))

(defun gptel-yatools--plist-without (plist key)
  "Return PLIST with KEY and its value removed.

PLIST is a keyword/value list, as a `&rest' argument builds it.  Used for
the keys this package reads itself and must not pass on to
`gptel-make-tool', which rejects what it does not know."
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

SLOTS are the arguments of `gptel-make-tool', with the TIMEOUT argument
appended: every tool this package defines takes one, so it is added here
rather than repeated in each definition.

The tool is added to gptel's registry, which is what `gptel-menu' lists,
and to `gptel-yatools--tools', replacing an earlier tool of the same name
in place, so one tool module can be reloaded without reordering the list
the rest of the package reads.

An asynchronous tool is accepted, and `:async' travels to gptel unchanged.
gptel calls such a tool with a callback as its first argument and does not
use the return value; the boundary delivers the envelope to that callback
instead.  A *synchronous* tool whose body returns a job is refused: gptel
would stringify it and send the printed struct to the model, so the
boundary reports it as the definition bug it is."
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

ARG-SPECS is the tool's `:args' as written in its definition; ASYNC says
whether the tool delivers through gptel's callback; DEFAULT, when given,
is the tool's own budget in seconds.

Every tool takes exactly one TIMEOUT argument after its declared ones, and
five readers needed that list: registration, the live refresh when a
budget is customized, the docstring, the confirmation preview, and the
split that separates the model's arguments from the trailing TIMEOUT.  Each
built it itself, from the same two facts, so a change to either fact had to
be made five times.

The one consequence worth knowing is that the count of the model's own
arguments is `(1- (length (gptel-yatools--tool-args ...)))' -- which is why
`gptel-yatools--split-args' asks this function rather than counting the
declaration for itself.

Not folded in here: the per-argument integer coercion some bodies do.
Those carry a default and a minimum per argument (`gptel-yatools-vfs.el`
has one minimum of `(- gptel-yatools--output-line-limit 10)'), while the
`:args' declaration states only whether an argument is optional.  Teaching
the declaration two more keys to serve two call sites would move the
knowledge rather than remove it."
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

NAME is the tool's name as the model sees it, CATEGORY is its category,
DESCRIPTION is the description the model is given, ARG-SPECS are the
declared arguments, IMPL is the symbol the body lives in, and ASYNC and
DEFAULT are what the TIMEOUT argument states.

The opening paragraph is about the function the reader asked about: which
tool it is, which implementation holds the body, and that the text below is
the model's, not a description of this function.  It goes first because
`C-h f' is a question about a Lisp function, and opening with a paragraph
about the model's view of it answered a question nobody had asked yet.

The description follows in full -- the same text the model reads, so it
cannot drift from it -- and its first sentence is still promoted to a
summary line so `apropos' has something to show.

A tool whose budget is a `defcustom' gets its docstring re-rendered by
`gptel-yatools--refresh-timeout-arg', through `function-documentation';
the string this returns is the one a loaded package starts with."
  (let* ((description (string-trim (or description "")))
         ;; Promote the first sentence to a summary line, when it fits, so
         ;; `apropos' has something to show.  The rest of the description
         ;; follows it, so nothing is said twice.
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

A docstring is a string literal in the `defun', so the one a compiled
package carries is the one its definition produced, with whatever the
budget was at that moment.  `function-documentation' is the standing
override `documentation' consults first, and this is how the live answer
replaces the frozen one -- at load time, from the macro, and again whenever
a budget is customized.

The arguments are taken from the tool rather than the definition because
that is the copy that has been kept current: the declared ones are
everything but the trailing TIMEOUT that `gptel-yatools--tool-args' adds.

A tool whose function is not a symbol -- a probe built by hand in a test
or a config, with no `-tool' half to name -- is left alone."
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

The full text lives on the boundary function, which is the name that
matches the tool, so there is one place to read rather than two copies
to keep in step."
  (gptel-yatools--fill-text
   (format "Implementation of the `%s' tool, returning a Result.\n\nSee `%s' for the arguments, the deadline and the envelope the model reads."
           name (symbol-name symbol))))

(defmacro gptel-yatools-define-tool (symbol &rest spec)
  "Define and register a gptel tool called SYMBOL.

SPEC is a sequence of keyword/value pairs followed by the body:

  :name        The tool's name as the model sees it, a string like
               \"read_path\".  It must be SYMBOL's name without the
               `gptel-yatools-' prefix and with `_' for each `-'; the
               mismatch is an error at load time rather than a tool the
               model calls by one name and Lisp knows by another.
  :category    The category gptel groups it under, a string.  Defaults to
               \"misc\".
  :description The text the model reads, and the text `C-h f' shows.
  :args        The argument list, as `gptel-make-tool' takes it, or nil
               for a tool that takes none.  Argument order matters: gptel
               passes the values positionally.
  :confirm     Non-nil to make gptel ask the user to confirm each call,
               as it does before running a shell command.
  :preview     A list of the argument names to show when gptel asks the
               user to approve a call, in the order to show them.  A
               required argument is printed positionally, the way the
               call reads, and an optional one as NAME=VALUE.  Leave it
               out for gptel's own formatter, which truncates every
               string at 256 characters -- so a tool whose arguments are
               what the user is approving should name them here, or a
               long one can be approved on a harmless prefix.
  :async       Non-nil to hand the answer to gptel's callback instead of
               returning it.  The body is unchanged: it returns either a
               Result or a job (`gptel-yatools--spawn-process'), and this
               key only says whether the boundary waits for it.  A tool
               that runs a command should set it, so that the command
               does not hold Emacs for as long as it runs.
  :timeout     The default budget in seconds for this tool, as a form
               evaluated when it is used -- usually the symbol of a
               `defcustom'.  Stated in the TIMEOUT argument's description
               and enforced by the deadline, so the model cannot be told a
               number that is not the one in force.  Omit it for the
               shared default (see `gptel-yatools--timeout-default'), which
               is what a tool whose work is like every other tool's wants.

The body is the tool's implementation.  The arguments named in :args are
bound to the values the model sent, and the body returns a
`gptel-yatools-result' built with `gptel-yatools-ok'.  It is not expected
to format anything: sizes, escaping and errors are the boundary's work.

Two functions are defined:

  SYMBOL-tool  The implementation.  It takes the tool's own arguments and
               returns a Result.  Advise this to change what a tool
               computes, or what it says it found -- for example to add a
               path to a Result's body, or to refuse a call without
               touching the tool's own code.  It sees no TIMEOUT argument
               and never sees the envelope.

  SYMBOL       The boundary, and the function gptel calls.  It takes the
               same arguments plus a final optional TIMEOUT, enforces the
               deadline for the call, renders the Result into the envelope
               the model reads, and turns a signalled error or an expired
               deadline into that same envelope.  Advise this to observe
               or replace a whole call, including its timing and its
               wire format; advice here runs outside the deadline, so it
               can take as long as it likes.

Both are named, so both can be advised, traced with `trace-function' and
found with `C-h f'.  Advice survives reloading the tool: it attaches to
the symbol, not to a closure built at load time.

An asynchronous tool (`:async t') has the same two functions, but its
boundary takes gptel's callback first, because that is how gptel calls it.
A direct call -- from `eval', a hook or a test -- passes the tool's own
first argument instead and is answered synchronously, so both ways of
calling a tool produce the same envelope.

The tool itself is registered in gptel's registry -- which is what
`gptel-menu' lists -- and in `gptel-yatools--tools'.  Nothing is sent to
the model until `gptel-yatools-enable' adds it to the variable
`gptel-tools'.

Here is a whole tool:

  (gptel-yatools-define-tool gptel-yatools-count-lines
    :name \"count_lines\"
    :category \"filesystem\"
    :description \"Count the lines in a file.\"
    :args \\='((:name \"path\"
                   :type string
                   :description \"File to count.\"))
    (let ((file (gptel-yatools--resolve-path path)))
      (gptel-yatools-ok
       (format \"%d lines\" (line-number-at-pos (point-max)))
       :comment \"Counted from disk.\")))"
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
           ;; The budget is a `defcustom', and the macro is expanded before
           ;; any of them is bound -- the compiler sees `nil'.  So the
           ;; literal docstring states the shared default, and
           ;; `--refresh-tool-docstring', called once the tool exists,
           ;; immediately replaces it with the live one.
           (doc (gptel-yatools--tool-docstring
                 name category description arg-specs impl async))
           (param-names (mapcar (lambda (arg) (intern (plist-get arg :name)))
                                arg-specs))
           ;; An argument the model may omit has to be optional in Lisp
           ;; too, or a call that legitimately leaves it out signals
           ;; `wrong-number-of-arguments'.  Lisp wants every required
           ;; parameter before `&optional', so the declared order has to
           ;; be required-then-optional for the positional mapping to hold.
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
                ;; cannot be the declared one; the boundary tells the two
                ;; callers apart by type, which is safe because no tool
                ;; declares a function argument.
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
              ;; A thunk, so that a `defcustom' changed later is read when
              ;; it is used instead of frozen at definition time.
              (list :timeout-default `(lambda () ,(plist-get plist :timeout))))
          ,@(when (plist-get plist :confirm)
              (list :confirm (plist-get plist :confirm))))
         (gptel-yatools--register-preview ,name ',display ',arg-specs ,async)
         ;; The docstring above was built while the macro was expanded,
         ;; before any budget was bound; this replaces it with one rendered
         ;; from the tool just registered, and re-rendered whenever a
         ;; budget changes.
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

CATEGORIES-OR-NAMES are tool categories, like \"filesystem\", tool
names, like \"write_file\", or nil for every tool.

Enabled tools are prepended to the variable `gptel-tools' and replace any
earlier
entry with the same name, so calling this twice does not send a tool
to the model twice.  The value is set with `customize-set-variable',
so it is the buffer-local value that changes when there is one."
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
