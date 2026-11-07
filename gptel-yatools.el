;;; gptel-yatools.el --- Extra tools for gptel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; URL: https://github.com/iamtoaster/gptel-yatools
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9.6") (yaml "1.2.4"))
;; Keywords: convenience, tools, llm
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A set of gptel tools built around a small, buffer-local virtual
;; filesystem layered over the real one: reads come from disk unless a
;; buffered copy exists, writes are buffered until the user reviews and
;; syncs them, and every pending change is shown as a unified diff before
;; it lands.  Around it sit the tools a coding assistant needs: workspace
;; paths, line-addressed reads, regexp search, shell commands, and Agent
;; Skills -- directories of instructions and scripts that the model loads
;; on demand.
;;
;; This file is the glue between gptel and the tool modules, and nothing
;; else.  What a tool is -- its Result, its boundary, its deadline, the
;; macro that defines it -- lives in `gptel-yatools-common.el', which the
;; tool modules require.  The tools themselves live in the file that owns
;; their subject: `gptel-yatools-vfs.el' for the filesystem,
;; `gptel-yatools-shell.el' for the shell and workspace tools,
;; `gptel-yatools-skills.el' for Agent Skills, `gptel-yatools-diagram.el'
;; for diagrams and `gptel-yatools-agents.el' for child agents.
;;
;; What is left here belongs to gptel rather than to any tool: a tool call
;; must run in the buffer that owns the request, so that a chat's
;; buffer-local VFS and `default-directory' apply.
;;
;; Loading this file registers every tool in gptel's registry, so they
;; appear in the `gptel-menu' tool picker immediately.  Nothing is sent to
;; the model until the tools are enabled: per category or by name with
;; `gptel-yatools-enable', or all of them with `gptel-yatools-enable-all'.
;;
;; See the README for the tool list and for installation instructions.

;;; Code:

(require 'gptel-yatools-common)
(require 'gptel)

(declare-function tramp-dissect-file-name "tramp" (file &optional nested))
(declare-function tramp-get-connection-process "tramp" (vec))
(declare-function tramp-get-connection-property "tramp" (vec-or-proc key &optional default))

;;-------------------------------------------------------------------------
;; A tool call must run in the buffer that owns the request
;;
;; Both `gptel-yatools-vfs' and `default-directory' are buffer-local, so a
;; tool that runs in the wrong buffer reads a fresh, empty VFS and
;; resolves every relative path against a directory nobody asked about.
;; gptel re-enters the request buffer on the automatic and the
;; confirmation path, but `gptel--inspect-accept-tool-calls' calls the
;; dispatcher from the `*gptel-tool-calls*' inspection buffer, so a
;; `write_file' accepted from there lands in that buffer's VFS and a
;; `file_sync' accepted there finds nothing pending.
;;-------------------------------------------------------------------------
(defun gptel-yatools--tool-owner-buffer (&optional overlay)
  "Return the buffer the tool call in OVERLAY belongs to.

OVERLAY, when it is the dispatch overlay, lives in the buffer the model's
request came from and is the most precise answer.  Otherwise the buffer
recorded in the request info of the variable `gptel--fsm-last' is used,
which
is what the `*gptel-tool-calls*' inspection buffer carries.  Falling back
on the current buffer keeps direct calls (tests, `eval', a tool invoked
from a hook) working.

The result can be a killed buffer; callers must check `buffer-live-p'
so that a dead owner is reported instead of silently running the tool
somewhere else."
  (let ((fsm (bound-and-true-p gptel--fsm-last)))
    (or (and (overlayp overlay) (overlay-buffer overlay))
        (and (gptel-fsm-p fsm)
             (let ((buffer (plist-get (gptel-fsm-info fsm) :buffer)))
               (and (bufferp buffer) buffer)))
        (current-buffer))))

(defun gptel-yatools--accept-tool-calls-in-owner (function tool-calls &optional overlay)
  "Call FUNCTION on TOOL-CALLS and OVERLAY in the request's own buffer.

FUNCTION is `gptel--accept-tool-calls'.  Re-entering the owner buffer
keeps that buffer's VFS and `default-directory' in effect for the whole
batch of calls, whichever buffer the user is looking at when the call is
confirmed.  The batch is anchored once, not once per call."
  (let ((owner (gptel-yatools--tool-owner-buffer overlay)))
    (cond
     ((not (buffer-live-p owner))
      (user-error "The chat buffer for this tool call no longer exists; nothing was run"))
     ((eq owner (current-buffer))
      (funcall function tool-calls overlay))
     (t
      (with-current-buffer owner
        (funcall function tool-calls overlay))))))

(defun gptel-yatools--update-tool-status (message &optional face)
  "Show MESSAGE in the owning gptel chat buffer's status indicator.

FACE is passed to `gptel--update-status' to pick the indicator's face;
nil keeps whatever gptel uses for a status.

Tools that may run for a while call this just before they start, so the
header line says what is happening instead of continuing to show
\"Calling tool\".  MESSAGE should start with a space, matching gptel's
own status strings.

The explicit `redisplay' is required, not a nicety:
`gptel--update-status' ends with `force-mode-line-update', which only
*flags* the mode line, and Emacs redraws when it next becomes idle -- a
tool call polling a subprocess never does.  Measured on a terminal frame:
`gptel--update-status' alone gives 0 redisplays over a two-second
command; adding the `redisplay' gives one, immediately.

Nothing happens outside a live `gptel-mode' buffer, so calling a tool
directly (tests, `eval', a hook) is unaffected."
  (let ((owner (gptel-yatools--tool-owner-buffer)))
    (when (buffer-live-p owner)
      (with-current-buffer owner
        (when (and (bound-and-true-p gptel-mode)
                   (fboundp 'gptel--update-status))
          (gptel--update-status message face)
          (redisplay))))))

(defun gptel-yatools--forget-inspection-vfs (&rest _)
  "Drop stale buffer-local VFS state from the tool-call inspection buffer.

`gptel--inspect-tool-calls' reuses `*gptel-tool-calls*' and switches it to
`lisp-data-mode' only the first time, so `kill-all-local-variables' is
skipped on later uses and a `gptel-yatools-vfs' table left there survives.
Tools no longer run in that buffer, so the table is debris -- and it would
make the kill guard ask about files nobody touched.

`default-directory' is deliberately left alone: nothing resolves paths
against it any more."
  (when (get-buffer "*gptel-tool-calls*")
    (with-current-buffer (get-buffer "*gptel-tool-calls*")
      (gptel-yatools-vfs-reset-buffer-state))))

(defcustom gptel-yatools-remote-tool-delay 0.2
  "Seconds between checks for a free TRAMP connection.

A tool call in a remote workspace waits for the connection to be free
rather than assuming it is, so this is a poll interval and not a guess at
how long the work takes.  A tool that runs while the connection is busy
is refused by TRAMP (\"Forbidden reentrant call\")."
  :type 'number
  :group 'gptel-yatools)

(defcustom gptel-yatools-remote-tool-tries 100
  "Most times to check for a free TRAMP connection before giving up.

At the default poll interval this is twenty seconds.  A tool that has
waited that long is reported as an error rather than started anyway: a
refused remote call is not a file that is missing."
  :type 'integer
  :group 'gptel-yatools)

(defun gptel-yatools--remote-buffer-p (buffer)
  "Return non-nil when BUFFER works in a remote workspace."
  (and (buffer-live-p buffer)
       (file-remote-p (buffer-local-value 'default-directory buffer))))

(defun gptel-yatools--tramp-locked-p (buffer)
  "Return non-nil when BUFFER's TRAMP connection is in use.

The lock is a property of the connection *process*, not of the file name:
`with-tramp-locked-connection' sets it on the process for the whole of a
file operation.  Nothing here opens a connection: dissecting a name is
parsing, and looking up the process is a lookup in `process-list'."
  (when (and (buffer-live-p buffer)
             (fboundp 'tramp-dissect-file-name))
    (when-let* ((vec (ignore-errors
                       (tramp-dissect-file-name
                        (buffer-local-value 'default-directory buffer))))
                (proc (ignore-errors (tramp-get-connection-process vec))))
      (tramp-get-connection-property proc "locked"))))

(defun gptel-yatools--fail-request (fsm err)
  "Record ERR on FSM and move it to gptel's error state.

Used from callbacks and timers, where an escaping condition is not
reported to anyone: a signal from a timer is only logged, and one from a
process sentinel breaks the request's state machine.  The request is told
instead, which is the only outcome a waiting chat can act on."
  (ignore-errors
    (plist-put (gptel-fsm-info fsm) :error
               (if (eq (car-safe err) 'quit)
                   "Quit"
                 (error-message-string err))))
  (ignore-errors (gptel--fsm-transition fsm 'ERRS)))

(defvar gptel-yatools--tool-call-running nil
  "Non-nil while a tool call is inside the remote filesystem.

TRAMP waits for its command's reply by pumping output, which runs timers,
so a deferred call whose timer fires then would start inside another
call's TRAMP operation and re-enter the connection -- corrupting its
buffer (\"End of file during parsing\") or having its own reply read by
the wrong waiter.  Measured: three calls, three concurrent.

Emacs is single-threaded, so this flag is enough: a call that finds it set
waits its turn.")

(defcustom gptel-yatools-remote-tool-wait-limit 120
  "Most seconds a tool call may wait for another call to finish.

A call waiting behind another is otherwise bounded only by that other call
finishing.  At this limit the wait is reported as an error instead of
leaving the request in gptel's TOOL state with no result and no error."
  :type 'number
  :group 'gptel-yatools)

(defvar gptel-yatools--deferred-tool-calls nil
  "Tool calls waiting their turn at the remote filesystem.

Each entry is a list (FUNCTION FSM ARGS TRIES DEADLINE).  The oldest is
first, and only the oldest is ever considered, so calls run in the order
they arrived.

A queue rather than one timer per call, because `with-tramp-suspended-timers'
-- which wraps every operation TRAMP performs -- binds `timer-list' to nil
for the duration and discards whatever was pushed onto it.  A
`run-at-time' made inside that section is silently lost: never cancelled,
never fired, never reported.  Measured: a timer created inside such a
section never fires, while one created outside survives one.

The tool-use handler runs from gptel's process sentinel, which can be
inside exactly such a section.  One timer, created when this package
loads, works through the queue instead.")

(defvar gptel-yatools--tool-drain-timer nil
  "The timer that works through `gptel-yatools--deferred-tool-calls'.

Created once at load time and re-armed from its own body, which is safe
because by then the TRAMP section is over.")

(defun gptel-yatools--drain-deferred-calls ()
  "Run the oldest deferred tool call, if it can run now.

Called on a timer.  Leaves the queue alone while another of this package's
calls is on the stack, and drops entries whose request has moved on --
with a trace line, because a call that vanished without a word is
indistinguishable from a hang.

The deadline is checked before the reasons for waiting: a call queued
behind something that never finishes must still give up, and that is the
case where nothing else would reconsider it."
  (when gptel-yatools--deferred-tool-calls
    (let* ((entry (car gptel-yatools--deferred-tool-calls))
           (function (nth 0 entry))
           (fsm (nth 1 entry))
           (args (nth 2 entry))
           (tries (nth 3 entry))
           (deadline (nth 4 entry))
           (buffer (ignore-errors (plist-get (gptel-fsm-info fsm) :buffer))))
      (condition-case err
          (cond
           ;; The request moved on, or its buffer died.  A legitimate
           ;; reason to stop, but it is recorded: a call that simply
           ;; disappears is indistinguishable from a hang.
           ((not (and (buffer-live-p buffer)
                      (eq (gptel-fsm-state fsm) 'TOOL)))
            (setq gptel-yatools--deferred-tool-calls
                  (cdr gptel-yatools--deferred-tool-calls))
            (gptel-yatools--trace "drop: buffer=%S state=%S"
                                  (and (buffer-live-p buffer) t)
                                  (and (buffer-live-p buffer)
                                       (gptel-fsm-state fsm))))
           ;; Waited too long, whatever it was waiting for.
           ((> (float-time) deadline)
            (gptel-yatools--trace "expired after %gs" gptel-yatools-remote-tool-wait-limit)
            (setq gptel-yatools--deferred-tool-calls
                  (cdr gptel-yatools--deferred-tool-calls))
            (gptel-yatools--fail-request
             fsm
             (list 'error
                   (format "waited %gs for the remote filesystem to be free"
                           gptel-yatools-remote-tool-wait-limit))))
           ;; Another of this package's calls is on the stack.  Emacs runs
           ;; one timer at a time, so this is the only guard that keeps
           ;; two calls from starting inside one another.
           (gptel-yatools--tool-call-running
            (gptel-yatools--trace "wait: another call is running"))
           ;; Another operation holds the connection.  Leave it queued.
           ((and (> tries 0) (gptel-yatools--tramp-locked-p buffer))
            (gptel-yatools--trace "wait: connection locked, tries left %d" (1- tries))
            (setcar (nthcdr 3 entry) (1- tries)))
           (t
            ;; Free: take it off the queue and run it.
            (setq gptel-yatools--deferred-tool-calls
                  (cdr gptel-yatools--deferred-tool-calls))
            (gptel-yatools--trace "run: %s" buffer)
            (with-current-buffer buffer
              (let ((gptel-yatools--tool-call-running t))
                (apply function fsm args)))
            (gptel-yatools--trace "ran: %s" buffer)))
        (quit
         ;; A `C-g' that arrived while deciding.  It belongs to whatever the
         ;; user was actually looking at, so it is passed on rather than
         ;; swallowed; the call stays queued and the next tick picks it up.
         (setq quit-flag nil)
         (gptel-yatools--trace "quit while deciding; passing it on")
         (signal 'quit nil))
        (error (gptel-yatools--fail-request fsm err)))
      ;; The call has run and its results are with gptel: a `C-g' that
      ;; arrived during it is owed to the caller, and travels out of the
      ;; timer from here -- up to the minibuffer it was aimed at.
      (gptel-yatools--replay-pending-quit))))

(defun gptel-yatools--ensure-drain-timer ()
  "Start the queue's timer, if it is not already running.

Called at load time, and from anywhere the queue grows.  Creating it only
works from outside a TRAMP section, but it is a repeating timer that
re-arms from its own body, so it is not missing at those moments."
  (unless (timerp gptel-yatools--tool-drain-timer)
    (setq gptel-yatools--tool-drain-timer
          (run-with-timer
           0.01 gptel-yatools-remote-tool-delay
           (lambda ()
             (condition-case err
                 (gptel-yatools--drain-deferred-calls)
               ;; A signal here would be logged and the queue would stop
               ;; being worked.  The timer repeats, so it recovers.
               (error (gptel-yatools--trace "drain error: %S" err))))))))

(defun gptel-yatools--run-tool-call-later (function fsm args tries &optional deadline)
  "Queue FUNCTION on FSM and ARGS to run when the connection is free.

TRIES counts down; at zero the call is made anyway, so a connection that
never reports itself free produces TRAMP's own error rather than a
request that waits for ever.

DEADLINE, in `float-time' units, bounds the whole wait: it is set on the
first call and carried through every pass of the queue.

Nothing is scheduled here: this can run inside TRAMP's suspended-timer
section, where a timer created for the purpose is discarded.  The entry
is queued, and the one timer made at load time picks it up."
  (let ((deadline (or deadline
                      (+ (float-time) gptel-yatools-remote-tool-wait-limit))))
    (unless (gptel-yatools--deferred-call-p fsm)
      (setq gptel-yatools--deferred-tool-calls
            (append gptel-yatools--deferred-tool-calls
                    (list (list function fsm args tries deadline))))
      (gptel-yatools--trace "queued: %S entries=%d"
                            (plist-get (gptel-fsm-info fsm) :buffer)
                            (length gptel-yatools--deferred-tool-calls)))
    (gptel-yatools--ensure-drain-timer)))

(defun gptel-yatools--deferred-call-p (fsm)
  "Return non-nil when FSM already has a call waiting in the queue."
  (seq-some (lambda (entry) (eq (nth 1 entry) fsm))
            gptel-yatools--deferred-tool-calls))
(defun gptel-yatools--tool-calls-outside-the-sentinel (function fsm &rest args)
  "Run gptel's tool-use handler, but not from inside a process sentinel.

FUNCTION is called with FSM and ARGS, the way gptel calls it: FSM is the
tool-call state and ARGS the arguments of the call.

gptel runs a tool call from the response process's sentinel.  In a remote
workspace that is a TRAMP call nested inside whatever else Emacs was
doing, and TRAMP refuses a second call into a connection it is already
using: \"Forbidden reentrant call of Tramp\".  Measured both ways: a tool
called from a process sentinel while a remote file's attributes are being
read fails that way, and the same call succeeds from a timer.

So for a remote workspace the handler is deferred until the connection is
free.  The connection's lock says when another operation is running; a
flag says when another of this package's own calls is.

Nothing here schedules a timer -- see `gptel-yatools--deferred-tool-calls'.

A local workspace is untouched: there is no connection to re-enter.

Both paths are guarded: this runs from gptel's state-machine handler,
which runs inside `with-demoted-errors' in the process sentinel, so an
error escaping here leaves the request in TOOL with no result and no
error, for ever.  A failure is reported to the request instead."
  (let ((buffer (plist-get (gptel-fsm-info fsm) :buffer)))
    (gptel-yatools--trace "arrive: buffer=%S remote=%S state=%S"
                          buffer
                          (and (buffer-live-p buffer)
                               (gptel-yatools--remote-buffer-p buffer))
                          (gptel-fsm-state fsm))
    (if (not (gptel-yatools--remote-buffer-p buffer))
        (condition-case err
            (prog1 (apply function fsm args)
              (gptel-yatools--replay-pending-quit))
          (quit
           ;; Not aimed at this call: the body runs with quits inhibited,
           ;; so this is somebody else's pending quit.  Pass it on.
           (setq quit-flag nil)
           (gptel-yatools--trace "quit in local call; passing it on")
           (signal 'quit nil))
          (error (gptel-yatools--fail-request fsm err)))
      (gptel-yatools--trace "defer: buffer=%S" buffer)
      (condition-case err
          (gptel-yatools--run-tool-call-later function fsm args
                                             gptel-yatools-remote-tool-tries)
        (quit (gptel-yatools--trace "quit while queueing; retrying next tick"))
        (error (gptel-yatools--fail-request fsm err))))))

(unless (advice-member-p #'gptel-yatools--tool-calls-outside-the-sentinel
                         'gptel--handle-tool-use)
  (advice-add 'gptel--handle-tool-use :around
              #'gptel-yatools--tool-calls-outside-the-sentinel))

;; Created here, at load time, and not from any request: a timer made
;; inside TRAMP's suspended-timer section is silently discarded.  See
;; `gptel-yatools--deferred-tool-calls'.
(gptel-yatools--ensure-drain-timer)

;; `advice-add' is idempotent for an identical advice function, but the
;; guard keeps the load path obviously safe to re-run (the test suite
;; reloads this file on purpose).
(unless (advice-member-p #'gptel-yatools--accept-tool-calls-in-owner
                         'gptel--accept-tool-calls)
  (advice-add 'gptel--accept-tool-calls :around
              #'gptel-yatools--accept-tool-calls-in-owner))
(unless (advice-member-p #'gptel-yatools--forget-inspection-vfs
                         'gptel--inspect-tool-calls)
  (advice-add 'gptel--inspect-tool-calls :after
              #'gptel-yatools--forget-inspection-vfs))

;;-------------------------------------------------------------------------
;; Stopping a tool call that is still running
;;
;; An asynchronous tool call is the one piece of work a user can start and
;; then have no way to stop: `C-g' has nothing on the stack to interrupt,
;; and `gptel-abort' looks the request up in `gptel--request-alist', whose
;; entry is the *network* process -- removed once the response arrived, so
;; during a tool call it finds nothing.
;;
;; So cancellation is provided here: a command, a key in `gptel-mode-map',
;; and advice so that gptel's own abort does what its name promises when
;; the thing running is a tool.
;;-------------------------------------------------------------------------
(defun gptel-yatools--abort-cancels-tools (&optional buffer)
  "Kill this package's running tool jobs when gptel aborts BUFFER.

BUFFER defaults to the current buffer, and is optional because this is
advice on `gptel-abort': an advice narrower than the function it guards
turns a working abort into \"Wrong number of arguments\"."
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (gptel-yatools--cancel-jobs buffer))))

(defun gptel-yatools--abort-accepts-no-argument (function &rest args)
  "Call FUNCTION with ARGS, or with the current buffer when ARGS is empty.

`gptel-abort' declares BUF as a required argument, but its docstring says
it \"defaults to the current buffer\" and a key bound to it usually passes
nothing.  Following the docstring produced \"Wrong number of arguments\"
from `gptel-abort' itself."
  (apply function (or args (list (current-buffer)))))

(unless (advice-member-p #'gptel-yatools--abort-accepts-no-argument
                         'gptel-abort)
  (advice-add 'gptel-abort :around
              #'gptel-yatools--abort-accepts-no-argument))

(unless (advice-member-p #'gptel-yatools--abort-cancels-tools 'gptel-abort)
  (advice-add 'gptel-abort :before #'gptel-yatools--abort-cancels-tools))

;; `C-c RET' is the only binding `gptel-mode-map' ships with, and gptel's
;; own `C-c C-k' bindings live in other maps (the tool-call actions map,
;; the inspection map, the request-preview buffer), which take precedence
;; wherever they apply.
(when (boundp 'gptel-mode-map)
  (define-key gptel-mode-map (kbd "C-c C-k")
              #'gptel-yatools-cancel-tool-calls))

;;-------------------------------------------------------------------------
;; Drawing the header line
;;
;; gptel builds `header-line-format' as (BACKEND STATUS INFO), and INFO
;; right-aligns itself with a `:align-to' space.  A label from this package
;; has to join that group rather than sit beside it: appended after INFO it
;; is drawn past the right edge, inserted before it it is stranded next to
;; the backend name.  So the INFO element is replaced wholesale by a
;; segment that renders every label and gptel's own indicators as one
;; right-aligned string.
;;
;; This touches gptel private state (`gptel--header-line-info') and nothing
;; about the filesystem, so it belongs here and not in a tool module.
;; Modules contribute labels through
;; `gptel-yatools-header-line-extra-functions' and never draw.
;;-------------------------------------------------------------------------
(defun gptel-yatools--header-line-extras ()
  "Return the labels the tool modules want in the header line.

Each function in `gptel-yatools-header-line-extra-functions' is called
with no arguments; nil results are dropped and the rest are joined with
a single space.  A failing function is ignored rather than breaking
redisplay, which is what a header line that signals would do."
  (let (labels)
    (dolist (function gptel-yatools-header-line-extra-functions)
      (let ((label (ignore-errors (funcall function))))
        (when (and (stringp label) (not (string-empty-p label)))
          (push label labels))))
    (when labels (mapconcat #'identity (nreverse labels) " "))))

(defvar gptel-yatools--header-line-segment
  '(:eval (gptel-yatools--header-line-rendered))
  "Header-line segment: gptel's right-hand indicators plus our labels.")

(defun gptel-yatools--header-line-rhs ()
  "Return gptel's right-hand indicator group, without its alignment pad."
  (let ((info (ignore-errors (eval (cadr gptel--header-line-info)))))
    (when (stringp info)
      (if (> (length info) 0) (substring info 1) info))))

(defun gptel-yatools--header-line-rendered ()
  "Render gptel's indicator group, prefixed by this package's labels.

The offset must be parenthesised: `incorrect (space :align-to (- right N))'
is silently ignored and the whole group collapses to the left, next
to the backend name.  gptel's own template writes `(,(width))' for
this reason, so do the same."
  (let* ((rhs   (or (gptel-yatools--header-line-rhs) ""))
         (label (gptel-yatools--header-line-extras))
         (text  (if label (concat label " " rhs) rhs))
         (align (if (and (fboundp 'string-pixel-width)
                         (display-graphic-p))
                    `(space :align-to
                            (- right (,(string-pixel-width text))))
                  `(space :align-to
                          (- right (,(+ 5 (string-width text))))))))
    (concat (propertize " " 'display align) text)))

(defun gptel-yatools--extend-header-line (&rest _)
  "Put this package's labels in gptel's right-hand indicator group.

The option `gptel-use-header-line' makes `header-line-format' hold
\(BACKEND STATUS INFO).  The INFO element is replaced by
`gptel-yatools--header-line-segment', which renders the labels together
with gptel's indicators as a single aligned group.
Element 1 is the status indicator, which gptel rewrites in place with
`(setf (nth 1 header-line-format) ...)'.  Element 2 is the one replaced
here.

Replacing in place rather than dropping the segment and appending it is
what makes a second run harmless: removing it first shortens the list
below the length the replacement is guarded on."
  (when (and gptel-use-header-line (consp header-line-format))
    (let* ((fmt (copy-sequence header-line-format))
           (existing (cl-position gptel-yatools--header-line-segment fmt
                                  :test #'equal)))
      (cond
       (existing
        (setf (nth existing fmt) gptel-yatools--header-line-segment))
       ((>= (length fmt) 3)
        (setf (nth 2 fmt) gptel-yatools--header-line-segment))
       (t
        (setq fmt (append fmt (list gptel-yatools--header-line-segment)))))
      (setq header-line-format fmt)))
  (force-mode-line-update))

(advice-add 'gptel-use-header-line :after #'gptel-yatools--extend-header-line)

;;-------------------------------------------------------------------------
;; The tools
;;
;; Each module defines its own tools with `gptel-yatools-define-tool', which
;; registers them as it defines them, so there is no list to assemble here.
;; The modules are required at this point and not earlier: they build on
;; `gptel-yatools-common.el'.
;;-------------------------------------------------------------------------
(require 'gptel-yatools-vfs)
(require 'gptel-yatools-shell)
(require 'gptel-yatools-skills)
(require 'gptel-yatools-diagram)
(require 'gptel-yatools-agents)

(provide 'gptel-yatools)
;;; gptel-yatools.el ends here
