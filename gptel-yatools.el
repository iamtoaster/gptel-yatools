;;; gptel-yatools.el --- Extra tools for gptel  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9.5") (yaml "1.2.4"))
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
;; `gptel-yatools-shell.el' for the shell and workspace tools, and
;; `gptel-yatools-skills.el' for Agent Skills.
;;
;; What is left here is the one thing that belongs to gptel rather than to
;; any tool: a tool call must run in the buffer that owns the request, so
;; that a chat's buffer-local VFS and `default-directory' apply.  gptel
;; only anchors some of the paths that reach its dispatcher, so this file
;; anchors the rest, and drops the stale VFS state that a reused
;; inspection buffer would otherwise keep.
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
;; Both `gptel-yatools-vfs' and `default-directory' are buffer-local, so
;; a tool that runs in the wrong buffer reads and writes a fresh, empty
;; VFS and resolves every relative path against a directory nobody asked
;; about.  gptel only anchors some of the paths that reach
;; `gptel--accept-tool-calls': the
;; automatic path (`gptel--handle-tool-use') and the minibuffer confirmation
;; path already re-enter the request buffer, but the dispatcher itself has
;; no such wrapper, and `gptel--inspect-accept-tool-calls' calls it from the
;; `*gptel-tool-calls*' inspection buffer.  A `write_file' accepted from
;; there is stored in the inspection buffer's VFS -- which the chat buffer
;; never sees -- and a `file_sync' accepted from there reports that the VFS
;; has no pending changes even though the chat has plenty.
;;
;; One limit is recorded rather than fixed: a request whose chat buffer was
;; killed dies inside gptel itself ("Selecting deleted buffer"); we only
;; make the failure readable when we are the ones to notice it.
;;-------------------------------------------------------------------------
(defun gptel-yatools--tool-owner-buffer (&optional overlay)
  "Return the buffer the tool call in OVERLAY belongs to.

OVERLAY, when it is the dispatch overlay, is the most precise answer: it
lives in the buffer the model's request came from.  Otherwise the
buffer recorded in `gptel--fsm-last''s request info is used, which is
what the `*gptel-tool-calls*' inspection buffer carries.  Falling back
on the current buffer keeps direct calls (tests, `eval', a tool invoked
from a hook) working as before.

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

FUNCTION is `gptel--accept-tool-calls'.  Re-entering the owner buffer is
what keeps that buffer's VFS and `default-directory' in effect for the
whole batch of calls, whichever buffer the user is looking at when the
call is confirmed.

The batch is anchored once, not once per call: no registered tool leaves
another buffer current.  A tool that did switch buffers would still leak
into the later calls of its batch."
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

Tools that may run for a while call this just before they start, so
the header line says what is happening instead of continuing to show
\"Calling tool\".  MESSAGE should start with a space, matching gptel's
own status strings.

The frame is redrawn here, and that is the point of this function rather
than a nicety.  `gptel--update-status' ends with
`force-mode-line-update', which only *flags* the mode line: Emacs
redraws when it next becomes idle.  A tool call does not become idle --
a subprocess is polled until it exits, in `gptel-yatools--run-process' --
so without an explicit redisplay the new status is set, is correct, and
is never seen.  The screen keeps whatever was drawn before the call
began, which is why a long command appeared to leave \"Typing...\" up.

Measured on a terminal frame, in the polling loop `gptel-yatools--run-process'
uses: `gptel--update-status' alone gives 0 redisplays over a two-second
command; adding the `redisplay' below gives one, immediately.

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

`gptel--inspect-tool-calls' reuses `*gptel-tool-calls*' and only
switches it to `lisp-data-mode' the first time -- the mode switch, and
with it `kill-all-local-variables', is skipped on every later use.  A
`gptel-yatools-vfs' table left there by an earlier session therefore survives,
and its entries would make the kill guard ask about files nobody
touched from that buffer when the inspection window is closed.  Tools
no longer run there (see
`gptel-yatools--accept-tool-calls-in-owner'), so the table is pure debris.

`default-directory' is deliberately left alone: it is inherited only
when the buffer is created, but nothing resolves paths against it any
more."
  (when (get-buffer "*gptel-tool-calls*")
    (with-current-buffer (get-buffer "*gptel-tool-calls*")
      (gptel-yatools-vfs-reset-buffer-state))))

(defcustom gptel-yatools-remote-tool-delay 0.2
  "Seconds between checks for a free TRAMP connection.

A tool call in a remote workspace waits for the connection to be free
rather than assuming it is, so this is a poll interval and not a guess at
how long the work takes.  A tool that runs while the connection is busy
is refused by TRAMP (\"Forbidden reentrant call\"), which is what a
subagent fan-out produced: several calls arriving within one another's
file operations."
  :type 'number
  :group 'gptel-yatools)

(defcustom gptel-yatools-remote-tool-tries 100
  "Most times to check for a free TRAMP connection before giving up.

At the default poll interval this is twenty seconds.  A tool that has
waited that long is reported as an error rather than started anyway: a
refused remote call is not a file that is missing, and pretending
otherwise is what made a subagent describe the wrong machine in the first
place."
  :type 'integer
  :group 'gptel-yatools)

(defun gptel-yatools--remote-buffer-p (buffer)
  "Return non-nil when BUFFER works in a remote workspace."
  (and (buffer-live-p buffer)
       (file-remote-p (buffer-local-value 'default-directory buffer))))

(defun gptel-yatools--tramp-locked-p (buffer)
  "Return non-nil when BUFFER's TRAMP connection is in use.

The lock is a property of the connection *process*, which is why it is
read there and not from the file name: `with-tramp-locked-connection'
sets it on the process for the whole of a file operation, and TRAMP
refuses any second call into that connection until it is cleared.

Nothing here opens a connection: dissecting a name is parsing, and
looking up the process is a name lookup in `process-list'."
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

TRAMP waits for its command's reply by pumping output, which runs
timers.  A deferred tool call whose timer fires then would start inside
another call's TRAMP operation and re-enter the connection -- corrupting
its buffer (\"End of file during parsing\"), or having its own reply read
by the wrong waiter.  Measured: three calls, three concurrent.

Emacs is single-threaded, so this flag is enough: nothing else can begin
while a call is on the stack, and a call that finds it set waits its
turn.")

(defcustom gptel-yatools-remote-tool-wait-limit 120
  "Most seconds a tool call may wait for another call to finish.

A call that is waiting behind another one is only bounded by that other
call finishing.  If it never does -- a connection that has silently died,
a host that stopped answering -- the waiting calls would sit in gptel's
TOOL state for ever, with no result and no error, which is exactly the
state a stuck subagent was found in.  At this limit the wait is reported
as an error instead."
  :type 'number
  :group 'gptel-yatools)

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

(defcustom gptel-yatools-tool-trace-file "/tmp/gptel-yatools-trace.log"
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

(defun gptel-yatools--run-tool-call-later (function fsm args tries &optional deadline)
  "Run FUNCTION on FSM and ARGS once the TRAMP connection is free.

TRIES counts down; at zero the call is made anyway, so a connection that
never reports itself free produces TRAMP's own error rather than a
request that waits for ever.

DEADLINE, in `float-time' units, bounds the whole wait: it is set on the
first call and carried through every re-arm.  A call queued behind
another one would otherwise be bounded only by that call finishing, and a
connection that has died would leave it in TOOL for ever -- no result, no
error, and a subagent the user cannot even see is stuck.

Two things are waited for, and both were measured to matter.  The
connection's own lock covers another operation's command; the flag above
covers this package's own calls, which can otherwise start inside one
another because TRAMP runs timers while it waits for output.

The state is checked first: an abort between the sentinel and this timer
leaves nothing to run, and a state machine that has already moved on must
not be handed another tool call.

`quit' is caught as well as `error', and that is not pedantry:
`condition-case' does not treat a quit as an error, so a `C-g' during a
deferred call escaped every handler and left the request in TOOL for ever
-- no result, no error, and a chat that could never continue.  A quit is
reported as `Quit' so the request ends somewhere the user can see."
  (let* ((buffer (plist-get (gptel-fsm-info fsm) :buffer))
         (deadline (or deadline
                       (+ (float-time) gptel-yatools-remote-tool-wait-limit))))
    (run-at-time
     gptel-yatools-remote-tool-delay nil
     (lambda ()
       ;; The whole body is guarded, not just the tool call.  Deciding
       ;; whether to wait -- asking TRAMP for a connection property,
       ;; asking the state machine for its state -- can signal too, and a
       ;; signal from a timer is only logged: the call would neither run
       ;; nor be re-armed, leaving the request in TOOL for ever with no
       ;; result and no error.  That is the shape of a subagent that
       ;; silently never finishes.
       (condition-case err
           (if (not (and (buffer-live-p buffer)
                         (eq (gptel-fsm-state fsm) 'TOOL)))
               ;; Two legitimate reasons to stop, and both used to be silent:
               ;; the request moved on, or its buffer died.  Recorded so that
               ;; "the call never ran" has a cause on file.
               (gptel-yatools--trace "drop: buffer=%S state=%S"
                                     (and (buffer-live-p buffer) t)
                                     (and (buffer-live-p buffer)
                                          (gptel-fsm-state fsm)))
             (cond
              ;; Another of this package's calls is on the stack.  Wait for
              ;; it without spending a try: it is bounded by that call
              ;; finishing, and running now would re-enter the connection
              ;; the flag exists to protect.
              (gptel-yatools--tool-call-running
               (gptel-yatools--trace "wait: another call is running")
               (if (> (float-time) deadline)
                   (gptel-yatools--fail-request
                    fsm
                    (list 'error (format "waited %gs for another tool call to finish"
                                         gptel-yatools-remote-tool-wait-limit)))
                 (gptel-yatools--run-tool-call-later
                  function fsm args tries deadline)))
              ((and (> tries 0) (gptel-yatools--tramp-locked-p buffer))
               (gptel-yatools--trace "wait: connection locked")
               (if (> (float-time) deadline)
                   (gptel-yatools--fail-request
                    fsm
                    (list 'error (format "waited %gs for the connection to be free"
                                         gptel-yatools-remote-tool-wait-limit)))
                 (gptel-yatools--run-tool-call-later
                  function fsm args (1- tries) deadline)))
              (t
               (gptel-yatools--trace "run: %s" buffer)
               (with-current-buffer buffer
                 (let ((gptel-yatools--tool-call-running t))
                   (prog1 (apply function fsm args)
                     (gptel-yatools--trace "ran: %s" buffer)))))))
         (quit (gptel-yatools--trace "quit: %S" err)
               (gptel-yatools--fail-request fsm err))
         (error (gptel-yatools--trace "error: %S" err)
                (gptel-yatools--fail-request fsm err)))))
    nil))

(defun gptel-yatools--tool-calls-outside-the-sentinel (function fsm &rest args)
  "Run gptel's tool-use handler, but not from inside a process sentinel.

gptel runs a tool call from the response process's sentinel: when curl
finishes, the sentinel moves the state machine through TYPE and into TOOL,
whose handler applies the tools.  In a remote workspace that is a TRAMP
call nested inside whatever else Emacs was doing, and TRAMP refuses a
second call into a connection it is already using -- \"Forbidden reentrant
call of Tramp\".  Measured both ways: a tool called from a process
sentinel while a remote file's attributes are being read fails exactly
that way, and the same call succeeds from a timer.

So for a remote workspace the handler is deferred, then waits until the
connection is free.  Waiting is a condition, not a sleep: the poll above
re-arms while another call holds the connection, so any number of
subagents can arrive at once and each takes its turn.  Emacs runs one
timer at a time, which is what makes that safe.

A local workspace is untouched: there is no connection to re-enter, and a
tool call keeps running inline.

Both paths are guarded, and that matters as much as the waiting.  This
runs from gptel's state-machine handler, which itself runs inside
`with-demoted-errors' in the process sentinel: an error escaping here is
turned into a message and the request is left in TOOL with no result and
no error, for ever.  A failure is reported to the request instead, so the
chat says what happened."
  (let ((buffer (plist-get (gptel-fsm-info fsm) :buffer)))
    (gptel-yatools--trace "arrive: buffer=%S remote=%S state=%S"
                          buffer
                          (and (buffer-live-p buffer)
                               (gptel-yatools--remote-buffer-p buffer))
                          (gptel-fsm-state fsm))
    (if (not (gptel-yatools--remote-buffer-p buffer))
        (condition-case err
            (apply function fsm args)
          (quit (gptel-yatools--fail-request fsm err))
          (error (gptel-yatools--fail-request fsm err)))
      (gptel-yatools--trace "defer: buffer=%S" buffer)
      (gptel-yatools--run-tool-call-later function fsm args
                                         gptel-yatools-remote-tool-tries))))

(unless (advice-member-p #'gptel-yatools--tool-calls-outside-the-sentinel
                         'gptel--handle-tool-use)
  (advice-add 'gptel--handle-tool-use :around
              #'gptel-yatools--tool-calls-outside-the-sentinel))

;; `advice-add' is idempotent for an identical advice function, but the
;; guard makes the intent explicit and keeps the load path obviously safe
;; to re-run (the test suite reloads this file on purpose).
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
;; during a tool call it finds nothing and does nothing.
;;
;; So cancellation is provided here, where the gptel adaptation lives: a
;; command, a key in `gptel-mode-map', and advice so that gptel's own abort
;; does what its name promises when the thing running is a tool.
;;-------------------------------------------------------------------------
(defun gptel-yatools--abort-cancels-tools (&optional buffer)
  "Kill this package's running tool jobs when gptel aborts BUFFER.

BUFFER defaults to the current buffer, and is optional because this is
advice on `gptel-abort': an advice narrower than the function it guards
turns a working abort into \"Wrong number of arguments\".

Aborting a request should stop the command it started, not leave it
running on the host with its output going nowhere."
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (gptel-yatools--cancel-jobs buffer))))

(defun gptel-yatools--abort-accepts-no-argument (function &rest args)
  "Call FUNCTION, supplying the current buffer when it is given no argument.

`gptel-abort' declares BUF as a required argument, but its docstring says
it \"defaults to the current buffer\" and a key bound to it usually passes
nothing.  Following the docstring produced \"Wrong number of arguments\"
from `gptel-abort' itself, so the promise is kept here rather than left to
be discovered."
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
;; wherever they apply.  A user who wants a different key rebinds this one
;; in their config, as with any package key.
(when (boundp 'gptel-mode-map)
  (define-key gptel-mode-map (kbd "C-c C-k")
              #'gptel-yatools--cancel-tool-calls))

;;-------------------------------------------------------------------------
;; Drawing the header line
;;
;; gptel builds `header-line-format' as (BACKEND STATUS INFO), and INFO
;; right-aligns itself with a `:align-to' space.  Labels from this package
;; have to join that group rather than sit beside it: appended after INFO
;; they are drawn past the right edge, inserted before it they are stranded
;; next to the backend name.  So the INFO element is replaced wholesale by a
;; segment that renders every label and gptel's own indicators as one
;; right-aligned string.
;;
;; This lives here, with the other gptel adaptation, and not in a tool
;; module: it touches gptel private state (`gptel--header-line-info') and
;; nothing about the filesystem.  Modules contribute labels through
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

`gptel-use-header-line' builds `header-line-format' as
\(BACKEND STATUS INFO).  The INFO element is replaced by
`gptel-yatools--header-line-segment', which renders the labels together
with gptel's indicators as a single aligned group.

Element 1 is the status indicator, which gptel rewrites in place with
`(setf (nth 1 header-line-format) ...)'.  Element 2 is the one replaced
here.

Replacing in place, rather than dropping the segment and appending it,
is what makes a second run harmless: removing it first shortens the list
below the length the replacement is guarded on, so the segment would be
dropped for good.  gptel rebuilds the list on every request, but this
also has to survive being run twice."
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
;; `gptel-yatools-common.el', and they are what this file is glue for.
;;-------------------------------------------------------------------------
(require 'gptel-yatools-vfs)
(require 'gptel-yatools-shell)
(require 'gptel-yatools-skills)
(require 'gptel-yatools-diagram)
(require 'gptel-yatools-agents)

(provide 'gptel-yatools)
;;; gptel-yatools.el ends here
