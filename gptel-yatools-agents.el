;;; gptel-yatools-agents.el --- Child agents the model can delegate to  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The `subagent' tool: the model hands a task to another model, waits for
;; its answer, and gets it back as one tool result.
;;
;; What a child is, exactly: a second gptel request in a second buffer, with
;; its own conversation, its own read-only tool list and no access to the
;; parent's.  It is a *reader*.  That single restriction is what makes every
;; other decision here simple:
;;
;; - Nothing a child does can be lost, so an aborted, timed-out or killed
;;   child costs tokens and nothing else.  No merge, no review, no VFS
;;   policy; the child's VFS is empty because it never writes.
;; - No child tool asks the user anything, so a hidden buffer is honest.
;;   The one gptel prompt that could appear -- `gptel-confirm-tool-calls'
;;   -- is bound to nil for the child's request and re-enabled afterwards.
;; - A child cannot call `subagent' either, because its tool list is built
;;   from `gptel-yatools-subagent-tools' and that list does not contain it.
;;   There is no recursion, so there is no depth field anywhere.
;;
;; The parent's tool call is a job, the same object `execute_command' hands
;; the boundary: the deadline, the header-line count, `C-c C-k' and the
;; exactly-once rule all come from the kit rather than from here.  That is
;; what `gptel-yatools-common.el' was generalized for -- see
;; `gptel-yatools--job-stop' and friends.
;;
;; Three things are worth knowing before changing this file.
;;
;; First, the child's answer is only ever its *last message*.  A tool-using
;; turn calls gptel's callback with `(tool-result . RESULTS)` and no text,
;; so "the string I last received" is already the final answer when the
;; request ends; but "the string I last received" is a prefix, not a whole
;; message, if streaming is ever turned on.  Streaming is therefore off, and
;; `gptel-yatools-subagent--start` says what that buys.
;;
;; Second, the child buffer is `buffer-read-only' while it runs and writable
;; once it settles.  Editing a transcript mid-run would change what gptel
;; re-parses on the child's next turn, and there is no way to notice that
;; from the outside; a read-only buffer makes the mistake impossible instead
;; of making it detectable.  `C-x k' still works, because killing a buffer
;; is not insertion -- and it aborts the child, which is why the kill hook
;; exists.
;;
;; Third, the name of the child buffer is decoration.  Every lookup goes
;; through the record; `gptel-yatools-subagent--name` only builds something
;; a human can read in `C-x b`.  A detached child is renamed anyway, so
;; nothing may parse meaning back out of a name.

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'gptel-yatools-common)

(declare-function gptel--insert-response "gptel" (response info &optional raw))
(declare-function gptel--fsm-transition "gptel-request" (machine &optional new-state))
(declare-function gptel-abort "gptel-request" (buf))

(defgroup gptel-yatools-agents nil
  "Child agents the model can delegate to."
  :group 'gptel-yatools)

;;-------------------------------------------------------------------------
;; How much a child may do
;;-------------------------------------------------------------------------
(defcustom gptel-yatools-subagent-tools
  '("read_path"
    "read_file_from_offset"
    "fetch_lines_from_file_using_regex"
    "read_workspace_root"
    "skill")
  "The tools a child agent may use, by name.

Read-only by design: a child reads and reports, and nothing it does has to
be reviewed, merged or undone.  Adding a writing or a shell tool here is
the one change that would invalidate the rest of this module's reasoning --
a child that can write needs a VFS policy, a visible buffer and a merge
step, none of which exist.

Names are resolved against `gptel-yatools--tools' when a child starts, so a
typo is reported to the model as an error rather than silently leaving the
child with fewer tools than it was promised.  The list is deliberately not
filtered through the parent's `gptel-tools': a parent that never enabled
`read_path' must not hand the model a child that cannot read."
  :type '(repeat string)
  :group 'gptel-yatools-agents)

(defcustom gptel-yatools-subagent-max-turns 50
  "Most model responses one child may produce before it is stopped.

Each response re-sends the child's whole conversation, so this is the
budget that bounds what a child costs.  It is not the same number as
`gptel-yatools-subagent-max-tool-calls': one response can carry several
tool calls, and a final answer is a response that carries none."
  :type 'integer
  :group 'gptel-yatools-agents)

(defcustom gptel-yatools-subagent-max-tool-calls 150
  "Most tool calls one child may make before it is stopped.

One turn can carry many calls, and a model that is short of tools tends to
spend turns rather than batch them, so this is the bound on how much the
child may read.  It is the only budget the child itself is told about,
because it is the only one it can count."
  :type 'integer
  :group 'gptel-yatools-agents)

(defun gptel-yatools-subagent--set-timeout (symbol value)
  "Set SYMBOL to VALUE, and restate the subagent's default to the model.

The TIMEOUT argument's description is the only place the model is told
what a call may spend, so a changed `defcustom' has to reach it; otherwise
the tool would enforce one number and advertise another."
  (set-default symbol value)
  (gptel-yatools--refresh-timeout-arg))

(defcustom gptel-yatools-subagent-timeout 1800
  "Seconds one child may run before it is stopped.

Its own variable rather than `gptel-yatools-async-timeout', because the
defaults are chosen for different work: a command that takes ten minutes is
already suspicious, while a child may legitimately spend half an hour
across fifty turns.  The model may still pass the tool's own TIMEOUT
argument, which overrides this for one call."
  :type 'number
  :group 'gptel-yatools-agents
  :set #'gptel-yatools-subagent--set-timeout)

(defcustom gptel-yatools-subagent-model nil
  "Model for child agents, or nil to inherit the parent's.

A single override rather than a model argument on the tool: the model
choosing its own child's model is a way to spend money by typo, and a
`defcustom' covers the one thing a user actually wants -- run children
cheap."
  :type '(choice (const :tag "Inherit the parent's model" nil) string)
  :group 'gptel-yatools-agents)

(defcustom gptel-yatools-subagent-task-width 30
  "Characters of a child's task shown in the subagent picker.

The annotation is a line in a minibuffer, so it has to fit: a task long
enough to fill the frame would push the state, which is what the row is
scanned for, off the right edge."
  :type 'integer
  :group 'gptel-yatools-agents)

;;-------------------------------------------------------------------------
;; The record
;;
;; One of these per child, and the only thing anything looks a child up by.
;; The buffer name is derived from it, never the other way round.
;;-------------------------------------------------------------------------
(cl-defstruct (gptel-yatools-subagent--record
               (:constructor gptel-yatools--make-subagent))
  "One child agent, from the call that started it to its last answer.

ID         the number in the child's buffer name, and nothing else.
PARENT     the chat buffer whose tool call is waiting for the answer.
BUFFER     the child's own buffer, or nil once it has been killed.
TASK       the parent model's instruction, verbatim.
STATE      `running', `done', `failed', `aborted', `timed out',
           `turn cap' or `call cap'.
STARTED    `float-time' at which the child started.
FINISHED   `float-time' at which it settled, or nil.
TURNS      model responses received so far.
CALLS      tool calls made so far.
PATHS      workspace-relative paths the child read, deduplicated, in the
           order it first read them.
ANSWER     the child's last message, when it settled with one.
LAST-TEXT  the most recent message the child sent, whatever state it is in;
           what a cap message quotes.
ERROR      the sentence explaining a failure, when it failed.
FSM        the child's request state machine.
INFO       the plist gptel hands the callback, reused so that successive
           replies are inserted as one conversation.
JOB        the job the parent's tool call is waiting on.
READ-ONLY  non-nil while the child is running: its buffer is read-only.
DETACHED   non-nil once the user has taken the child over."
  id parent buffer task state started finished turns calls paths
  answer error fsm info job read-only detached last-text)

(defvar gptel-yatools-subagent--records nil
  "Every live child agent, newest first.

One list rather than one per parent: the picker shows every child, a chat
buffer's label filters this list by `parent', and there is no second
structure to fall out of step with it.  A record leaves the list when its
buffer dies or when the user takes it over.")

(defvar-local gptel-yatools-subagent--record nil
  "The record of the child this buffer runs, or nil for any other buffer.

Set on a child buffer, and the thing `--child-label' reads: a child is a
`gptel-mode' chat too, so the label function needs to know which chat it
is looking at without searching the record list by buffer.")

(defun gptel-yatools-subagent--records-for (parent)
  "Return the live records whose parent is PARENT, newest first."
  (cl-remove-if-not (lambda (record)
                      (and (buffer-live-p (gptel-yatools-subagent--record-parent record))
                           (eq (gptel-yatools-subagent--record-parent record) parent)))
                    gptel-yatools-subagent--records))

(defun gptel-yatools-subagent--forget (record)
  "Drop RECORD from the list of live children."
  (setq gptel-yatools-subagent--records
        (delq record gptel-yatools-subagent--records)))

(defun gptel-yatools-subagent--running-p (record)
  "Return non-nil while RECORD's child is still working."
  (eq (gptel-yatools-subagent--record-state record) 'running))

;;-------------------------------------------------------------------------
;; Naming
;;-------------------------------------------------------------------------
(defun gptel-yatools-subagent--parent-label (buffer)
  "Return BUFFER's name, which is how the user knows it.

`*DeepSeek*' stays `*DeepSeek*': a child's name then reads
` *gptel-yatools-subagent-*DeepSeek*-1', so the parent is recognisable
without a decoding step."
  (if (buffer-live-p buffer) (buffer-name buffer) "unknown"))

(defun gptel-yatools-subagent--next-id (parent)
  "Return the next free child number for PARENT.

Counted from the records that still exist, so the number in a buffer name
is never reused while its child is alive.  It is a label, not an identity:
a name that collides anyway gets a suffix from `generate-new-buffer'."
  (let ((used nil))
    (dolist (record gptel-yatools-subagent--records)
      (when (eq (gptel-yatools-subagent--record-parent record) parent)
        (push (gptel-yatools-subagent--record-id record) used)))
    (let ((n 1))
      (while (member n used) (setq n (1+ n)))
      n)))

(defun gptel-yatools-subagent--name (parent id)
  "Return the buffer name for PARENT's child number ID.

The leading space is what keeps it out of an empty `C-x b' list and out of
the buffer menu, while `C-x b' followed by a space still finds it."
  (format " *gptel-yatools-subagent-%s-%d"
          (gptel-yatools-subagent--parent-label parent)
          id))

;;-------------------------------------------------------------------------
;; The fixed boilerplate
;;
;; The parent model writes the task; this paragraph is the only other thing
;; the child is told.  It says the four things a child cannot discover for
;; itself: that it is a child, that it has no conversation to look at, that
;; its tools are read-only, and that only its last message is read.
;;
;; The tool list is *not* repeated -- gptel sends it with the request, and a
;; second copy is one more thing that can disagree with the first.  Neither
;; are the turn and time budgets: a model cannot count either.  The tool-call
;; budget is the one it can count, so it is the one it is told.
;;-------------------------------------------------------------------------
(defun gptel-yatools-subagent--system-prompt (parent)
  "Return the fixed instructions given to a child started from PARENT."
  (format "You are a subagent. Another agent, working in the buffer `%s', started you for one task and is waiting for your answer.

- The task below is all the context you have. You cannot see that conversation.
- Your tools are read-only. You cannot modify files, run commands, or start another subagent.
- Nobody will answer a question, so do not ask one. If something cannot be determined, say so and say why.
- Only your final message reaches the parent agent. Everything you want reported must be in it.
- Give file paths and line numbers as evidence. Do not paste file contents back; the parent can read what it needs.
- You may make at most %d tool calls; reaching that limit stops you, so report before then."
          (gptel-yatools-subagent--parent-label parent)
          gptel-yatools-subagent-max-tool-calls))

;;-------------------------------------------------------------------------
;; What a child may use
;;-------------------------------------------------------------------------
(defun gptel-yatools-subagent--tool-specs ()
  "Return the `gptel-tool' structs named by `gptel-yatools-subagent-tools'.

An unknown name is an error rather than an omission: a user who mistyped a
tool name wants to hear about it, not to watch a child fail at a task it
never had the tools for."
  (let ((specs nil))
    (dolist (name gptel-yatools-subagent-tools)
      (let ((spec (cl-find name gptel-yatools--tools
                           :key #'gptel-tool-name :test #'equal)))
        (unless spec
          (error "Error: the subagent tool list names %S, which this package does not define. Nothing was started; fix `gptel-yatools-subagent-tools'"
                 name))
        (push spec specs)))
    (nreverse specs)))

;;-------------------------------------------------------------------------
;; The child buffer
;;-------------------------------------------------------------------------
(defvar-local gptel-yatools-subagent--inserting nil
  "Non-nil while this module is inserting into a child buffer.

`inhibit-read-only' suppresses the read-only check, and nothing else -- so
jit-lock and gptel's own change functions keep working.  This flag is what
tells the module's edit detector that a change was ours rather than the
user taking the child over.")

(defun gptel-yatools-subagent--insert (buffer string)
  "Insert STRING at the end of BUFFER without the user's edit hook firing.

Binding `inhibit-read-only' suppresses the read-only check and nothing
else, so jit-lock and gptel's own `after-change-functions' keep working;
the module's edit detector has to be silenced separately, because it would
otherwise see our insert as the user taking the child over."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (gptel-yatools-subagent--inserting t))
      (goto-char (point-max))
      (insert string))))

(defun gptel-yatools-subagent--make-buffer (record)
  "Create and return RECORD's child buffer, configured but not started.

The buffer is a real `gptel-mode' chat, so the user can open it, read it,
and -- once it has finished -- carry on talking to it, with the same
read-only tool list and the same system prompt."
  (let* ((parent (gptel-yatools-subagent--record-parent record))
         (buffer (generate-new-buffer
                  (gptel-yatools-subagent--name
                   parent (gptel-yatools-subagent--record-id record)))))
    (with-current-buffer buffer
      ;; The child's paths resolve against the parent's workspace, not
      ;; against whatever `default-directory' happened to be.
      (setq default-directory
            (with-current-buffer parent default-directory))
      (unless (derived-mode-p 'text-mode) (text-mode))
      (visual-line-mode 1)
      ;; Capabilities first: `gptel-mode' itself reads some of them, and
      ;; `gptel-request' copies this buffer's values into the prompt buffer.
      (setq-local gptel-backend
                  (with-current-buffer parent gptel-backend))
      (setq-local gptel-model
                  (or gptel-yatools-subagent-model
                      (with-current-buffer parent gptel-model)))
      (setq-local gptel-use-tools t)
      (setq-local gptel-tools (gptel-yatools-subagent--tool-specs))
      (setq-local gptel-system-prompt
                  (gptel-yatools-subagent--system-prompt parent))
      ;; Nothing from the parent's context: the task is the context.
      (setq-local gptel-context nil)
      (setq-local gptel-use-context nil)
      (setq-local gptel-stream nil)
      (setq-local gptel-include-reasoning nil)
      ;; A read-only tool set cannot need confirming, and a confirmation in
      ;; a hidden buffer would hang the child with nothing on screen to
      ;; answer.  The child's own buffer-local value is restored when it is
      ;; taken over.
      (setq-local gptel-confirm-tool-calls nil)
      (gptel-mode 1)
      (setq-local gptel-yatools-subagent--record record)
      (setq-local gptel-yatools--cancel-function
                  (lambda () (gptel-yatools-subagent--abort record 'by-hand)))
      ;; Take the task as the prompt, so the transcript reads as a
      ;; conversation and a later `gptel-send' from here makes sense.
      (insert (gptel-yatools-subagent--record-task record))
      (insert "\n\n")
      (setq buffer-read-only t)
      (setf (gptel-yatools-subagent--record-buffer record) buffer)
      (setf (gptel-yatools-subagent--record-read-only record) t)
      (add-hook 'kill-buffer-hook
                (lambda () (gptel-yatools-subagent--buffer-killed record))
                nil t)
      (add-hook 'after-change-functions
                (lambda (beg end before)
                  (gptel-yatools-subagent--buffer-changed record beg end before))
                nil t))
    buffer))

(defun gptel-yatools-subagent--buffer-killed (record)
  "Abort RECORD's child when its buffer is killed.

`C-x k' on a running child is the user saying stop: the child's answer has
nowhere to go, and the parent's tool call would otherwise wait for a result
that can never arrive.  A child that has settled is simply forgotten -- its
answer was delivered already, so killing the transcript is not a cancel."
  (when (gptel-yatools-subagent--running-p record)
    (gptel-yatools-subagent--abort record 'buffer-killed))
  (gptel-yatools-subagent--forget record))

;;-------------------------------------------------------------------------
;; Detaching
;;
;; A child is a transcript of what happened, not a place to type.  Once it
;; has settled, a user edit is read as "I want this buffer": the kill hook
;; goes, the record leaves the parent's list, and the rename is offered.
;;
;; Both hang off the edit rather than off a command, because there is no
;; command a user would think to run.  The detaching is silent and the
;; rename is a question, so the common case -- fixing a typo in the task --
;; costs nothing when the answer is no.
;;-------------------------------------------------------------------------
;;-------------------------------------------------------------------------
;; The child buffer
;;-------------------------------------------------------------------------
(defvar-local gptel-yatools-subagent--inserting nil
  "Non-nil while this module is inserting into a child buffer.

`inhibit-read-only' would suppress the read-only check *and* jit-lock and
gptel's own change functions, so our inserts bind both it and this.  The
flag is what tells the edit detector that a change was ours.")
(defun gptel-yatools-subagent--buffer-changed (record beg end _before)
  "Detach RECORD's child if the user has just edited its buffer.

Our own inserts bind `gptel-yatools-subagent--inserting', so anything that
reaches here is the user's.  A child still running has a read-only buffer,
so this only fires once it has settled -- which is also the only time the
question makes sense."
  (when (and (not gptel-yatools-subagent--inserting)
             (/= beg end)
             (not (gptel-yatools-subagent--record-detached record))
             (not (gptel-yatools-subagent--running-p record)))
    (gptel-yatools-subagent--detach record)))

(defun gptel-yatools-subagent--detach (record)
  "Take RECORD's child out of its parent's hands, and offer to rename it.

Removing the kill hook is the point: the buffer stops being part of the
parent's transcript, so killing the parent must not destroy it."
  (setf (gptel-yatools-subagent--record-detached record) t)
  (gptel-yatools-subagent--forget record)
  (let ((buffer (gptel-yatools-subagent--record-buffer record)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'kill-buffer-hook
                     (lambda () (gptel-yatools-subagent--buffer-killed record))
                     t)
        (remove-hook 'after-change-functions
                     (lambda (beg end before)
                       (gptel-yatools-subagent--buffer-changed record beg end before))
                     t)
        ;; The child's own cancel function names work that is over.
        (setq-local gptel-yatools--cancel-function nil)
        ;; The minibuffer must not be entered from inside
        ;; `after-change-functions': the edit is still in flight, and the
        ;; prompt would recurse through the same hook.
        (run-at-time
         0 nil
         (lambda ()
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (gptel-yatools-subagent--offer-rename)))))))))

(defun gptel-yatools-subagent--offer-rename ()
  "Ask whether this child buffer should be renamed into a normal session.

Empty input keeps the hidden name; the buffer has already been detached
either way, which is what stops it dying with its parent."
  (let ((suggested (format "%s"
                           (string-trim
                            (buffer-name)
                            "\\` \\*gptel-yatools-subagent-" "\\'"))))
    (let ((name (read-string
                 (format "Rename this subagent buffer, or empty to keep %s: "
                         (buffer-name))
                 suggested)))
      (when (and (stringp name) (not (string-empty-p name)))
        (condition-case nil
            (rename-buffer name t)
          (error (message "Could not rename to %s" name)))))))

;;-------------------------------------------------------------------------
;; Running
;;-------------------------------------------------------------------------
(defun gptel-yatools-subagent--path-recorded-p (path)
  "Return non-nil when PATH is worth listing as read by the child.

A path is recorded so the parent can tell whether an answer was grounded.
Directories are not: listing a directory reads its entries, but reporting
it as a file the child \"read\" would mislead more than inform."
  (and (stringp path)
       (not (string-empty-p path))
       (not (file-directory-p
             (gptel-yatools--resolve-path path)))))

(defun gptel-yatools-subagent--note-call (record results)
  "Record the tool calls in RESULTS as work RECORD's child did.

RESULTS is the `(tool-result . RESULTS)' payload: a list of
\(TOOL ARGS RESULT) triples for the calls that just finished.  gptel clears
`:tool-result' when it starts the next request, so this list holds one
turn's calls and its length is the count to add."
  (setf (gptel-yatools-subagent--record-calls record)
        (+ (gptel-yatools-subagent--record-calls record) (length results)))
  (dolist (triple results)
    (let* ((tool (car-safe triple))
           (args (car-safe (cdr-safe triple)))
           (name (and (gptel-tool-p tool) (gptel-tool-name tool)))
           (path (and args (plist-get args :path))))
      ;; Only the file-reading tools name a path in a way this can report.
      (when (and (member name '("read_path"
                                "read_file_from_offset"
                                "fetch_lines_from_file_using_regex"))
                 (gptel-yatools-subagent--path-recorded-p path))
        (let ((resolved (gptel-yatools--resolve-path path)))
          (unless (member resolved (gptel-yatools-subagent--record-paths record))
            (setf (gptel-yatools-subagent--record-paths record)
                  (append (gptel-yatools-subagent--record-paths record)
                          (list resolved)))))))))

(defun gptel-yatools-subagent--tool-call-refusal (calls)
  "Refuse the confirmations in CALLS, releasing the child to continue.

A child tool set is read-only and has nothing to confirm, so this should
never run.  If it does -- a user added a `:confirm' tool to
`gptel-yatools-subagent-tools' -- the child must still be told, because a
dropped callback is a request that hangs with nothing on screen."
  (dolist (call calls)
    (let ((callback (nth 2 call)))
      (when (functionp callback)
        (funcall callback
                 "Error: a subagent cannot ask the user to confirm a tool call. Use the tools you have; if you cannot finish without this one, say so in your final message.")))))

(defun gptel-yatools-subagent--settle (record state &optional message)
  "Settle RECORD with STATE and MESSAGE, and free its buffer for reading.

The job is settled rather than delivered here: delivery belongs to the
boundary, which may not have attached its conclusion yet."
  (unless (gptel-yatools-subagent--record-finished record)
    (setf (gptel-yatools-subagent--record-finished record) (float-time))
    (setf (gptel-yatools-subagent--record-state record) state)
    (when message
      (if (eq state 'done)
          (setf (gptel-yatools-subagent--record-answer record) message)
        (setf (gptel-yatools-subagent--record-error record) message)))
    (let ((buffer (gptel-yatools-subagent--record-buffer record)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (read-only-mode -1)
          (setf (gptel-yatools-subagent--record-read-only record) nil)
          ;; Nothing is running any more, so `C-c C-k' has nothing to reach.
          (setq-local gptel-yatools--cancel-function nil))))
    (when-let* ((job (gptel-yatools-subagent--record-job record)))
      (gptel-yatools--job-settle job))))

(defun gptel-yatools-subagent--abort (record cause)
  "Stop RECORD's child because of CAUSE, and settle it as aborted.

CAUSE is `by-hand', `buffer-killed' or `parent-cancelled', and it is named
in the sentence the parent reads, because \"aborted\" alone leaves the
parent model guessing whether it did something wrong."
  (when (gptel-yatools-subagent--running-p record)
    (let ((fsm (gptel-yatools-subagent--record-fsm record))
          (buffer (gptel-yatools-subagent--record-buffer record)))
      ;; Transition the child's own request first: gptel's abort looks the
      ;; request up by network process, which has finished by the time a
      ;; tool call is running, so it cannot find this one.
      (when (and (buffer-live-p buffer) (gptel-fsm-p fsm))
        (with-current-buffer buffer
          (ignore-errors (gptel--fsm-transition fsm 'ABRT))))
      (gptel-yatools-subagent--settle
       record 'aborted
       (format "Error: the subagent was %s before it finished, after %d tool call%s. Its partial output is not an answer."
               (pcase cause
                 ('buffer-killed "killed")
                 ('parent-cancelled "cancelled with its parent request")
                 (_ "aborted"))
               (gptel-yatools-subagent--record-calls record)
               (if (= (gptel-yatools-subagent--record-calls record) 1) "" "s"))))))

(defun gptel-yatools-subagent--callback (record response info)
  "Handle RESPONSE, one event of RECORD's child request.

The shapes gptel uses are the whole contract.  A string is the model's
message for this turn -- but a turn that also made tool calls sends its
text first and then `(tool-result ...)', so a string only *ends* the child
when the turn made no calls (`:tool-use' is empty).  A nil response is a
failure, and gptel only sends one for a failed request: a successful 200
with no body is a pure tool-call turn and is not reported at all.  `abort'
is the user stopping it, and `(tool-call . CALLS)' is a confirmation
nobody here can answer."
  (setf (gptel-yatools-subagent--record-info record) info)
  (pcase response
    ((pred stringp)
     (unless (gptel-yatools-subagent--record-finished record)
       (setf (gptel-yatools-subagent--record-last-text record) response)
       (let ((buffer (gptel-yatools-subagent--record-buffer record)))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (let ((inhibit-read-only t)
                   (gptel-yatools-subagent--inserting t))
               (gptel--insert-response response info)))))
       (setf (gptel-yatools-subagent--record-turns record)
             (1+ (gptel-yatools-subagent--record-turns record)))
       ;; gptel is about to run tools for this turn, so this text is a
       ;; preamble, not the answer: the child carries on.
       (unless (plist-get info :tool-use)
         (gptel-yatools-subagent--settle record 'done response))))
    ('nil
     (unless (gptel-yatools-subagent--record-finished record)
       (gptel-yatools-subagent--settle
        record 'failed
        (gptel-yatools-subagent--failure-sentence info))))
    ('abort
     (gptel-yatools-subagent--abort record 'by-hand))
    (`(tool-call . ,calls)
     (gptel-yatools-subagent--tool-call-refusal calls))
    (`(tool-result . ,results)
     (unless (gptel-yatools-subagent--record-finished record)
       (gptel-yatools-subagent--note-call record results)
       (setf (gptel-yatools-subagent--record-turns record)
             (1+ (gptel-yatools-subagent--record-turns record)))
       (when (> (gptel-yatools-subagent--record-calls record)
                gptel-yatools-subagent-max-tool-calls)
         (gptel-yatools-subagent--abort-for-cap
          record 'call-cap
          (format "Error: the subagent stopped after %d tool calls without finishing. Its last message was: %s"
                  (gptel-yatools-subagent--record-calls record)
                  (gptel-yatools-subagent--last-words record))))
       (when (and (gptel-yatools-subagent--running-p record)
                  (> (gptel-yatools-subagent--record-turns record)
                     gptel-yatools-subagent-max-turns))
         (gptel-yatools-subagent--abort-for-cap
          record 'turn-cap
          (format "Error: the subagent stopped after %d model turns without finishing, after %d tool calls. Its last message was: %s"
                  (gptel-yatools-subagent--record-turns record)
                  (gptel-yatools-subagent--record-calls record)
                  (gptel-yatools-subagent--last-words record))))))
    ;; `(reasoning . TEXT)' and anything gptel adds later: nothing a child
    ;; reports is worth failing over.
    (_ nil)))

(defun gptel-yatools-subagent--last-words (record)
  "Return what RECORD's child last said, for a message about a cap.

A capped child's most recent message is the most useful thing it produced,
and quoting it is what lets the parent tell \"ran out of budget halfway\"
from \"nearly finished\".  It is quoted whole: sizing the reply is the
boundary's work, and this module must not reach into that machinery."
  (or (gptel-yatools-subagent--record-last-text record) "(nothing)"))

(defun gptel-yatools-subagent--abort-for-cap (record cap sentence)
  "Stop RECORD's child because of CAP, settling it with SENTENCE."
  (let ((fsm (gptel-yatools-subagent--record-fsm record))
        (buffer (gptel-yatools-subagent--record-buffer record)))
    (when (and (buffer-live-p buffer) (gptel-fsm-p fsm))
      (with-current-buffer buffer
        (ignore-errors (gptel--fsm-transition fsm 'ABRT))))
    (gptel-yatools-subagent--settle record cap sentence)))

(defun gptel-yatools-subagent--failure-sentence (info)
  "Return the sentence describing why gptel's request produced no answer.

Three different failures arrive as nil, and they need different reactions:
a connection that never opened is worth retrying, a rate limit is worth
waiting out, and a rejected request is worth rephrasing.  `:error' is gptel's
own message and is usually the most specific thing available, so it is
quoted rather than replaced."
  (let ((error (plist-get info :error))
        (status (plist-get info :status))
        (http (plist-get info :http-status)))
    (cond
     ((and http (not (member http '("200" "100"))))
      (format "Error: the subagent's request was rejected by the provider (%s%s): %s"
              http
              (if (and status (not (string-empty-p status)))
                  (concat " " status)
                "")
              (or error "no message")))
     (error
      (format "Error: the subagent's request failed: %s" error))
     (status
      (format "Error: the subagent's request failed: %s" status))
     (t
      "Error: the subagent's request failed, and the provider gave no reason."))))

(defun gptel-yatools-subagent--outcome (job)
  "Return JOB's outcome plist, read from the record it carries."
  (let* ((record (gptel-yatools-job-data job))
         (state (gptel-yatools-subagent--record-state record)))
    (list :status (pcase state
                    ('done 'exited)
                    ('failed 'failed)
                    ('aborted 'aborted)
                    ('timed-out 'timed-out)
                    (_ 'capped))
          :timed-out (and (eq state 'timed-out) t)
          :output (or (gptel-yatools-subagent--record-answer record)
                      (gptel-yatools-subagent--record-error record)
                      "")
          :state state
          :turns (gptel-yatools-subagent--record-turns record)
          :calls (gptel-yatools-subagent--record-calls record)
          :paths (gptel-yatools-subagent--record-paths record)
          :elapsed (and (gptel-yatools-subagent--record-finished record)
                        (- (gptel-yatools-subagent--record-finished record)
                           (gptel-yatools-subagent--record-started record))))))

(defun gptel-yatools-subagent--result (record outcome)
  "Return the Result RECORD's job reports, given OUTCOME.

A finished child's answer is `:derived': it is another model's conclusion.
Everything else is an error envelope, so the parent cannot mistake a
half-finished investigation for a negative result."
  (let ((state (plist-get outcome :state)))
    (if (eq state 'done)
        (gptel-yatools-ok
         (gptel-yatools-subagent--report record outcome)
         :provenance :derived)
      (gptel-yatools-ok
       (or (gptel-yatools-subagent--record-error record)
           (format "Error: the subagent stopped (%s)." state))
       :provenance :derived
       :comment "The subagent did not finish. Nothing it read is summarised here."))))

(defun gptel-yatools-subagent--report (record outcome)
  "Return the body the parent model reads for RECORD's finished answer.

The metadata is not decoration: without the paths, \"no problems found\"
cannot be told apart from \"did not look\", and the parent has no way to
decide whether to trust the answer."
  (let ((paths (plist-get outcome :paths))
        (elapsed (plist-get outcome :elapsed)))
    (concat
     (format "Subagent result (status: %s%s, %d turn%s, %d tool call%s)\n"
             (gptel-yatools-subagent--record-state record)
             (if elapsed (format ", %.1fs" elapsed) "")
             (plist-get outcome :turns)
             (if (= (plist-get outcome :turns) 1) "" "s")
             (plist-get outcome :calls)
             (if (= (plist-get outcome :calls) 1) "" "s"))
     (if paths
         (format "Files read: %s\n"
                 (mapconcat (lambda (path)
                              (gptel-yatools--display-path path))
                            paths ", "))
       "Files read: none\n")
     "\n"
     (or (plist-get outcome :output) ""))))

;;-------------------------------------------------------------------------
;; The deadline
;;-------------------------------------------------------------------------
(defun gptel-yatools-subagent--expire (job)
  "Stop JOB's child because its deadline has passed."
  (let ((record (gptel-yatools-job-data job)))
    (when (gptel-yatools-subagent--running-p record)
      (let ((fsm (gptel-yatools-subagent--record-fsm record))
            (buffer (gptel-yatools-subagent--record-buffer record)))
        (when (and (buffer-live-p buffer) (gptel-fsm-p fsm))
          (with-current-buffer buffer
            (ignore-errors (gptel--fsm-transition fsm 'ABRT)))))
      (gptel-yatools-subagent--settle
       record 'timed-out
       (format "Error: the subagent timed out after %d seconds and was stopped, after %d tool call%s."
               (round (- (gptel-yatools-job-deadline job)
                         (gptel-yatools-job-started job)))
               (gptel-yatools-subagent--record-calls record)
               (if (= (gptel-yatools-subagent--record-calls record) 1) "" "s"))))
    (gptel-yatools--job-settle job)))

;;-------------------------------------------------------------------------
;; Starting one
;;-------------------------------------------------------------------------
(defun gptel-yatools-subagent--start (task timeout)
  "Start a child on TASK and return the job that will report its answer.

TIMEOUT is the call's own budget in seconds.  The child runs in a hidden
buffer with a read-only tool list, and its answer arrives through the job
the boundary waits for -- or does not, when the tool is asynchronous.
"
  (let* ((parent (current-buffer))
         (record (gptel-yatools--make-subagent
                  :id (gptel-yatools-subagent--next-id parent)
                  :parent parent
                  :task task
                  :state 'running
                  :started (float-time)
                  :turns 0
                  :calls 0
                  :paths nil))
         (buffer (gptel-yatools-subagent--make-buffer record))
         (deadline (+ (float-time) timeout))
         (job (gptel-yatools--make-job
               :kind 'subagent
               :buffer parent
               :started (gptel-yatools-subagent--record-started record)
               :deadline deadline
               :description (format "subagent %d" (gptel-yatools-subagent--record-id record))
               :data record
               :outcome-function #'gptel-yatools-subagent--outcome
               :cancel (lambda (j)
                         (gptel-yatools-subagent--abort
                          (gptel-yatools-job-data j) 'parent-cancelled))
               :result (lambda (outcome)
                         (gptel-yatools-subagent--result record outcome)))))
    (setf (gptel-yatools-subagent--record-job record) job)
    (push record gptel-yatools-subagent--records)
    (setf (gptel-yatools-job-timer job)
          (run-at-time (max 0.01 (- deadline (float-time)))
                       nil #'gptel-yatools-subagent--expire job))
    (condition-case err
        (with-current-buffer buffer
          (let* ((fsm (gptel-make-fsm))
                 (gptel-backend gptel-backend)
                 (gptel-model gptel-model)
                 (gptel-use-tools t)
                 ;; `gptel-request' works on a copy of this buffer, so the
                 ;; buffer-local values set in `--make-buffer' are what the
                 ;; prompt is built from; the let-bindings are here for the
                 ;; parts gptel reads from the current buffer instead.
                 (gptel-confirm-tool-calls nil)
                 (gptel-stream nil))
            (setf (gptel-yatools-subagent--record-fsm record) fsm)
            (setf (gptel-yatools-subagent--record-info record) nil)
            (gptel-request
             (gptel-yatools-subagent--record-task record)
             :buffer buffer
             :fsm fsm
             :stream nil
             :transforms nil
             :system (gptel-yatools-subagent--system-prompt parent)
             :callback (lambda (response info)
                         (gptel-yatools-subagent--callback record response info)))))
      (error
       (gptel-yatools-subagent--settle
        record 'failed
        (format "Error: the subagent could not be started: %s"
                (error-message-string err)))))
    job))

;;-------------------------------------------------------------------------
;; Aborting the children of an aborted request
;;-------------------------------------------------------------------------
(defun gptel-yatools--cancel-subagents-in (buffer)
  "Abort every child BUFFER started, because BUFFER's request is stopping.

A child whose answer has nowhere to go must not keep spending tokens, and
`gptel-yatools--cancel-jobs' reaches them through the job registry already
-- this exists so that `gptel-abort' does too, whatever order the two run
in."
  (when (buffer-live-p buffer)
    (dolist (record (gptel-yatools-subagent--records-for buffer))
      (gptel-yatools-subagent--abort record 'parent-cancelled))))

(unless (advice-member-p #'gptel-yatools--cancel-subagents-in 'gptel-abort)
  (advice-add 'gptel-abort :before #'gptel-yatools--cancel-subagents-in))

;;-------------------------------------------------------------------------
;; The indicator
;;
;; Our own label rather than gptel's status text, because clicking the
;; status text is already taken: `gptel--update-status' buttonizes it with
;; `gptel--inspect-fsm', so a click there can only ever show the request
;; state.  A label from `gptel-yatools-header-line-extra-functions' is ours
;; to make do something else.
;;-------------------------------------------------------------------------
(defun gptel-yatools-subagent--header-line-label ()
  "Return this buffer's subagent label, or nil when it has none.

A chat buffer counts the children it started -- three shapes: a count while
any run, a bare `[Subagents]' when only finished ones remain (so the way
back to them does not vanish the moment the last one answers), and nothing
when there are none.  A child's own buffer says whose it is instead."
  (or (gptel-yatools-subagent--child-label)
      (let ((records (gptel-yatools-subagent--records-for (current-buffer))))
        (when records
          (let* ((running (cl-count-if #'gptel-yatools-subagent--running-p records))
                 (text (if (> running 0)
                           (format "[Subagents: %d]" running)
                         "[Subagents]"))
                 (names (mapconcat
                         (lambda (record)
                           (format "%s %s"
                                   (gptel-yatools-subagent--record-state record)
                                   (gptel-yatools-subagent--short-task record)))
                         records "; ")))
            (propertize
             (buttonize text
                        (lambda (&rest _) (gptel-yatools-subagent-select)))
             'mouse-face 'highlight
             'help-echo (format "%s. Click to list them."
                                (if (> running 0)
                                    (format "%d subagent%s running: %s"
                                            running (if (= running 1) "" "s") names)
                                  (format "Finished subagents: %s" names)))))))))

(unless (memq #'gptel-yatools-subagent--header-line-label
              gptel-yatools-header-line-extra-functions)
  (add-to-list 'gptel-yatools-header-line-extra-functions
               #'gptel-yatools-subagent--header-line-label t))

;;-------------------------------------------------------------------------
;; The picker
;;
;; A `completing-read' rather than a table buffer, so it inherits whatever
;; completion UI is in use -- vertico, ivy, fido -- as the user asked.
;;
;; Marginalia cannot annotate these candidates, and must not be asked to:
;; it dispatches on the completion *category*, and it has no annotator for
;; ours, so its advice on `completion-metadata-get' returns nil and our own
;; `:annotation-function' is used untouched.  Declaring the category is what
;; makes that true; leaving it out would let marginalia classify these as
;; buffers and annotate them with the modified flag and the major mode.
;;-------------------------------------------------------------------------
(defconst gptel-yatools-subagent-category 'gptel-yatools-subagent
  "Completion category for subagent candidates.

Ours alone: a category marginalia knows nothing about is a category it
leaves alone.")

(defun gptel-yatools-subagent--short-task (record)
  "Return RECORD's task, cut to `gptel-yatools-subagent-task-width'."
  (let ((task (string-trim
               (replace-regexp-in-string
                "[ \t\n]+" " " (or (gptel-yatools-subagent--record-task record) "")))))
    (if (> (length task) gptel-yatools-subagent-task-width)
        (concat (substring task 0 (max 1 (1- gptel-yatools-subagent-task-width)))
                "…")
      task)))

(defun gptel-yatools-subagent--annotation (record)
  "Return the picker's annotation for RECORD.

State first and the task last: the state is what a row is scanned for, and
truncating the task at a fixed width is what keeps the line inside a frame
however long the parent's instruction was."
  (format "  %s -- %s"
          (pcase (gptel-yatools-subagent--record-state record)
            ('running (format "running %ds"
                              (round (- (float-time)
                                        (gptel-yatools-subagent--record-started record)))))
            (state (format "%s" state)))
          (gptel-yatools-subagent--short-task record)))

(defun gptel-yatools-subagent--prompt (records)
  "Return the picker's prompt for RECORDS, explaining the state column."
  (let ((running (cl-count-if #'gptel-yatools-subagent--running-p records)))
    (format "Subagent (%d running, %d finished): "
            running (- (length records) running))))

(defun gptel-yatools-subagent-select ()
  "List the live child agents and switch to the one chosen.

The candidates are buffer names, but the annotation comes from the record,
not from the buffer: a child that has finished and been renamed is still
the same child, and the state and task are what a row is for."
  (interactive)
  (let* ((live (cl-remove-if-not
                (lambda (record)
                  (buffer-live-p (gptel-yatools-subagent--record-buffer record)))
                (gptel-yatools-subagent--active-records))))
    (unless live
      (user-error "No subagent buffers are open"))
    (let* ((by-name (mapcar (lambda (record)
                              (cons (buffer-name
                                     (gptel-yatools-subagent--record-buffer record))
                                    record))
                            live))
           (completion-extra-properties
            (list :annotation-function
                  (lambda (candidate)
                    (when-let* ((record (cdr (assoc candidate by-name))))
                      (gptel-yatools-subagent--annotation record)))))
           (chosen (completing-read
                    (gptel-yatools-subagent--prompt live)
                    by-name nil t nil nil
                    (caar by-name))))
      (when-let* ((record (cdr (assoc chosen by-name)))
                  (buffer (gptel-yatools-subagent--record-buffer record)))
        (when (buffer-live-p buffer)
          (pop-to-buffer buffer))))))

(defun gptel-yatools-subagent--active-records ()
  "Return the live records, running ones first, then most recent first."
  (cl-sort (copy-sequence gptel-yatools-subagent--records)
           (lambda (a b)
             (let ((ra (gptel-yatools-subagent--running-p a))
                   (rb (gptel-yatools-subagent--running-p b)))
               (cond ((and ra (not rb)) t)
                     ((and rb (not ra)) nil)
                     (t (> (or (gptel-yatools-subagent--record-started a) 0)
                           (or (gptel-yatools-subagent--record-started b) 0))))))))

;;-------------------------------------------------------------------------
;; In a child's own buffer
;;-------------------------------------------------------------------------
(defun gptel-yatools-subagent--child-label ()
  "Return the label a child buffer shows instead of a subagent count.

A child is a `gptel-mode' buffer too, so the same label function runs
there; saying `[Subagent of *DeepSeek*]' answers the one question someone
landing in a hidden buffer has, and clicking it goes back to the parent."
  (when-let* ((record gptel-yatools-subagent--record)
              (parent (gptel-yatools-subagent--record-parent record)))
    (when (buffer-live-p parent)
      (propertize
       (buttonize (format "[Subagent of %s]" (buffer-name parent))
                  (lambda (&rest _)
                    (when (buffer-live-p parent) (pop-to-buffer parent))))
       'mouse-face 'highlight
       'help-echo "Click to go back to the chat that started this subagent"))))

;;-------------------------------------------------------------------------
;; The tool
;;
;; `:async t' because a child may run for half an hour, and `:confirm t'
;; because starting one spends tokens with nobody watching.  The two go
;; together: the confirmation is the cost control, and a fan-out of three
;; children is three approvals rather than one.
;;
;; The preview names the task, the model and the tools, because those are
;; what is being approved -- and because gptel's default renderer truncates
;; every string argument at 256 characters, which would let a long task be
;; approved on its first harmless sentence.
;;-------------------------------------------------------------------------
(gptel-yatools-define-tool gptel-yatools-subagent
  :name "subagent"
  :category "agents"
  :description "Hand one self-contained task to a child agent, which reads files and reports back.

The child sees only the task you write, not this conversation. It can read files and load skills, and it cannot write, run commands, or start another subagent. Its whole answer arrives as this tool's result, marked as another model's conclusion rather than as a description of disk.

Write the task as a complete brief: what to investigate, what to look for, and what the answer should contain. Say what you already know, so it does not read the same files you did. Ask for file paths and line numbers as evidence. Use it when the reading is wide and the answer is narrow -- reviewing a subsystem, finding where something is handled, checking several files against one rule. Do not use it for work you can finish with one read, and do not use it to have an opinion confirmed: a child cannot see your reasoning and will answer from what it reads."
  :args '((:name "task"
           :type "string"
           :description "The complete instruction for the child. It sees nothing else: no conversation, no attached files, no context. State the goal, the constraints, and exactly what the answer must contain."))
  :preview ("task" "timeout")
  :timeout gptel-yatools-subagent-timeout
  :async t
  :confirm t
  (gptel-yatools-subagent--start task (gptel-yatools--call-deadline)))

;;-------------------------------------------------------------------------
;; The key
;;
;; gptel ships only `C-c RET' in `gptel-mode-map'; this package already
;; took `C-c C-k', and `C-c C-s' is free.  A user who wants another binding
;; rebinds this one, as with any package key.
;;-------------------------------------------------------------------------
(defun gptel-yatools-subagents ()
  "List the live subagent buffers and switch to one.

The same command the `[Subagents]' label clicks through to."
  (interactive)
  (gptel-yatools-subagent-select))

(when (boundp 'gptel-mode-map)
  (define-key gptel-mode-map (kbd "C-c C-s") #'gptel-yatools-subagents))

(provide 'gptel-yatools-agents)
;;; gptel-yatools-agents.el ends here
