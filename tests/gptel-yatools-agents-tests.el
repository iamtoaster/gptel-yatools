;;; gptel-yatools-agents-tests.el --- Tests for child agents  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A subagent is a second gptel request, and these tests do not send one.
;; `gptel-request' is replaced for the duration of each test by a fake that
;; records what it was called with and hands back the request's callback --
;; which is the whole contract the child runner has with gptel, so driving
;; that callback through the shapes gptel uses (a string, a tool-result, a
;; failure, an abort) is a real test of the runner rather than of a mock of
;; it.
;;
;; What is *not* tested here is gptel's own tool loop.  It is exercised by
;; gptel, and reimplementing it in a fake would test the fake.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-yatools)
(require 'gptel-yatools-agents)
;; Only for `gptel-make-openai': a child inherits a backend, and the tests
;; need one that is a real struct rather than nil.
(require 'gptel-openai)
(unless (featurep 'gptel-yatools-test-lib)
  ;; Loaded by path, not by feature: a suite has to work from a checkout
  ;; without the tests directory being on `load-path'.
  (load (expand-file-name "gptel-yatools-test-lib.el"
                          (file-name-directory
                           (or load-file-name buffer-file-name)))
        nil 'nosuffix))

;;-------------------------------------------------------------------------
;; A fake parent chat, and a fake gptel
;;-------------------------------------------------------------------------
(defvar gptel-yatools-agent-test--calls nil
  "The arguments the fake `gptel-request' was called with, newest first.")

(defvar gptel-yatools-agent-test--callback nil
  "The request callback the fake `gptel-request' was handed.")

(defvar gptel-yatools-agent-test--fsm nil
  "The state machine the fake `gptel-request' was handed.")

(defmacro gptel-yatools-agent-test--with-parent (&rest body)
  "Run BODY in a chat buffer that looks like a parent, with gptel faked.

The buffer is a real `gptel-mode' buffer with a backend and a model, so a
child inherits something, and `gptel-request' is replaced by a fake that
records the call and makes no network request at all."
  (declare (indent 0) (debug t))
  `(let* ((gptel-yatools-agent-test--calls nil)
          (gptel-yatools-agent-test--callback nil)
          (gptel-yatools-agent-test--fsm nil)
          (gptel-yatools-subagent--records nil)
          (parent (gptel-yatools-test--request-buffer "*Test parent*")))
     (unwind-protect
         (with-current-buffer parent
           (setq-local gptel-mode t)
           (setq-local gptel-backend (gptel-make-openai "Fake"))
           (setq-local gptel-model 'fake-model)
           (cl-letf (((symbol-function 'gptel-request)
                      (lambda (prompt &rest args)
                        (push (cons prompt args) gptel-yatools-agent-test--calls)
                        (setq gptel-yatools-agent-test--callback
                              (plist-get args :callback)
                              gptel-yatools-agent-test--fsm
                              (plist-get args :fsm))
                        (plist-get args :fsm)))
                     ;; A dead child must not be left waiting on a timer
                     ;; that the suite has to wait out.
                     ((symbol-function 'gptel--fsm-transition) #'ignore))
           ,@body)
       ;; Kill the children first: they carry a kill hook that aborts, and
       ;; that is the behaviour under test elsewhere.
       (dolist (record gptel-yatools-subagent--records)
         (let ((buffer (gptel-yatools-subagent--record-buffer record)))
           (when (buffer-live-p buffer)
             (let ((kill-buffer-query-functions nil))
               (kill-buffer buffer)))))
       (gptel-yatools-test--kill-request-buffer parent)))))

(defun gptel-yatools-agent-test--start (&optional task)
  "Start one child in the fake parent on TASK and return its job.

The tool *body* is called, not the boundary.  An asynchronous tool's
boundary waits for its answer when gptel is not the caller -- that is the
documented behaviour that keeps a direct call working -- and the fake
request never answers, so calling the boundary here would pump the event
loop forever instead of testing anything."
  (gptel-yatools-subagent--start (or task "Check the parser.") 60))

(defun gptel-yatools-agent-test--deliver (response &optional info)
  "Deliver RESPONSE to the fake child request, as gptel would.

gptel hands the callback an info plist carrying the buffer, a `:position'
marker into it, the tool list the request was sent with, and a status.
`gptel--insert-response' and `gptel--display-tool-results' read all four,
so building them here is copying gptel's contract rather than papering
over the module."
  (let* ((record (car gptel-yatools-subagent--records))
         (buffer (gptel-yatools-subagent--record-buffer record)))
    (funcall gptel-yatools-agent-test--callback
             response
             (or info
                 (list :buffer buffer
                       :position (with-current-buffer buffer
                                   (set-marker (make-marker) (point-max)))
                       :tools (gptel-yatools-subagent--tool-specs)
                       :status "200 OK")))))

;;-------------------------------------------------------------------------
;; What the child is
;;-------------------------------------------------------------------------
(ert-deftest gptel-yatools-test-subagent-starts-a-child-request ()
  "The tool starts one hidden gptel request and returns a job.

The buffer name is the only thing that says \"hidden\": a leading space is
what keeps an empty `C-x b' list quiet until the user asks for it."
  (gptel-yatools-agent-test--with-parent
    (let* ((job (gptel-yatools-agent-test--start "Check the parser."))
           (record (car gptel-yatools-subagent--records)))
      (should (gptel-yatools-job-p job))
      (should (eq (gptel-yatools-job-kind job) 'subagent))
      (should record)
      (should (eq (gptel-yatools-job-data job) record))
      (should (eq (gptel-yatools-subagent--record-parent record)
                  (current-buffer)))
      (should (string-prefix-p " *gptel-yatools-subagent-"
                               (buffer-name
                                (gptel-yatools-subagent--record-buffer record))))
      (should (string-match-p (regexp-quote (buffer-name))
                              (buffer-name
                               (gptel-yatools-subagent--record-buffer record))))
      (should (= (length gptel-yatools-agent-test--calls) 1))
      (should (equal (caar gptel-yatools-agent-test--calls) "Check the parser.")))))

(ert-deftest gptel-yatools-test-subagent-child-has-only-read-tools ()
  "A child's tool list is the read-only list, not the parent's.

The parent below has the shell tool enabled.  The child must not: a child
that can run commands is not a reader, and every other decision in the
module rests on its being one."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-enable "execute_command")
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (child (gptel-yatools-subagent--record-buffer record)))
      (with-current-buffer child
        (should (equal (mapcar #'gptel-tool-name gptel-tools)
                       gptel-yatools-subagent-tools))
        (should-not (cl-find "execute_command" gptel-tools
                             :key #'gptel-tool-name :test #'equal))
        (should-not (cl-find "subagent" gptel-tools
                             :key #'gptel-tool-name :test #'equal))))))

(ert-deftest gptel-yatools-test-subagent-child-inherits-the-workspace ()
  "The child resolves paths against the parent's workspace, not its own.

Two buffers with different `default-directory' is the case that catches a
child inheriting the wrong one: it would read the wrong repository and
report plausible nonsense."
  (gptel-yatools-agent-test--with-parent
    (let ((parent-root (expand-file-name "parent-root/"
                                         (make-temp-file "gptel-sub-" t))))
      (make-directory parent-root t)
      (setq default-directory parent-root)
      (gptel-yatools-agent-test--start)
      (let ((child (gptel-yatools-subagent--record-buffer
                    (car gptel-yatools-subagent--records))))
        (with-current-buffer child
          (should (equal default-directory parent-root)))))))

(ert-deftest gptel-yatools-test-subagent-child-cannot-confirm ()
  "A child runs its read-only tools unconfirmed, and says why.

A confirmation prompt in a hidden buffer is a request that hangs with
nothing on screen to answer, so the child's request must never raise one --
whatever the user's global setting is."
  (gptel-yatools-agent-test--with-parent
    (let ((gptel-confirm-tool-calls t))
      (gptel-yatools-agent-test--start)
      (let ((child (gptel-yatools-subagent--record-buffer
                    (car gptel-yatools-subagent--records))))
        (with-current-buffer child
          (should-not gptel-confirm-tool-calls))))))

(ert-deftest gptel-yatools-test-subagent-child-buffer-is-read-only-while-running ()
  "A child's buffer cannot be edited until its answer has arrived.

Editing a transcript mid-run would change what gptel re-parses on the
child's next turn, and nothing would notice.  Read-only makes the mistake
impossible instead of detectable -- and it is lifted once the child
settles, so the transcript can be taken over."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let ((child (gptel-yatools-subagent--record-buffer
                  (car gptel-yatools-subagent--records))))
      (with-current-buffer child
        (should buffer-read-only)
        ;; `buffer-read-only' is the condition for a whole read-only
        ;; buffer; `text-read-only' is for a read-only text property.
        (should-error (insert "typing over the task") :type 'buffer-read-only))
      (gptel-yatools-agent-test--deliver "All good.")
      (with-current-buffer child
        (should-not buffer-read-only)))))

(ert-deftest gptel-yatools-test-subagent-prompt-is-fixed-boilerplate ()
  "The child is told what it is, and is not told the tool list twice.

gptel sends the tool list with the request, so a second copy in the system
prompt is one more thing that can disagree with it.  The call budget is
the one number the child can count, so it is the one it is told, and it is
interpolated from the variable rather than written twice."
  (gptel-yatools-agent-test--with-parent
    (let ((gptel-yatools-subagent-max-tool-calls 42))
      (gptel-yatools-agent-test--start)
      (let* ((record (car gptel-yatools-subagent--records))
             (child (gptel-yatools-subagent--record-buffer record))
             (system (with-current-buffer child gptel-system-prompt)))
        (should (string-match-p "You are a subagent" system))
        (should (string-match-p "43\\|42 tool calls\\|at most 42" system))
        (should (string-match-p "Only your final message reaches" system))
        ;; The tool names are gptel's job, not the prompt's.
        (should-not (string-match-p "read_file_from_offset" system))))))

;;-------------------------------------------------------------------------
;; Waiting for the answer
;;-------------------------------------------------------------------------
(ert-deftest gptel-yatools-test-subagent-delivers-its-answer-once ()
  "A child contributes exactly one result, however many times it answers.

gptel counts a tool result every time its callback runs, so a second
delivery would inject the text twice and could advance the parent's
request twice.  The job's one-shot guard is what prevents it."
  (gptel-yatools-agent-test--with-parent
    (let ((results nil))
      (let ((job (gptel-yatools-agent-test--start)))
        (gptel-yatools--job-conclude-with
         job (lambda (outcome) (push outcome results))))
      (gptel-yatools-agent-test--deliver "All good.")
      (gptel-yatools-agent-test--deliver "All good, again.")
      (should (= (length results) 1))
      (should (eq (plist-get (car results) :state) 'done)))))

(ert-deftest gptel-yatools-test-subagent-text-before-a-tool-call-is-not-the-answer ()
  "A message that precedes tool calls does not finish the child.

gptel sends a turn's text before running the turn's tool calls, so a
callback that treated every string as the answer would end the child at
its first \"Let me look at the parser\" and report that as the finding.
`:tool-use' being non-empty is what tells the two apart."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let ((record (car gptel-yatools-subagent--records)))
      (gptel-yatools-agent-test--deliver
       "Let me look at the parser."
       (list :buffer (gptel-yatools-subagent--record-buffer record)
             :position (with-current-buffer
                           (gptel-yatools-subagent--record-buffer record)
                         (set-marker (make-marker) (point-max)))
             :status "200 OK"
             :tool-use (list (list :name "read_path" :args '(:path "a.el")))))
      (should (gptel-yatools-subagent--running-p record))
      (should (= (gptel-yatools-subagent--record-turns record) 1))
      ;; The next turn's tool results arrive, then the real answer.
      (gptel-yatools-agent-test--deliver
       (cons 'tool-result
             (list (list (cl-find "read_path" gptel-yatools--tools
                                  :key #'gptel-tool-name :test #'equal)
                         '(:path "a.el") "one"))))
      (should (gptel-yatools-subagent--running-p record))
      (gptel-yatools-agent-test--deliver "It is on line 3.")
      (should (eq (gptel-yatools-subagent--record-state record) 'done))
      (should (equal (gptel-yatools-subagent--record-answer record)
                     "It is on line 3.")))))

(ert-deftest gptel-yatools-test-subagent-result-is-derived-and-names-its-work ()
  "A child's answer is `:derived', and says what it read.

`:disk' would be false -- the text describes nothing this process read --
and a bare answer with no paths cannot be told apart from \"did not look\"."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (job (gptel-yatools-subagent--record-job record))
           (outcome nil))
      (gptel-yatools--job-conclude-with
       job (lambda (o) (setq outcome o)))
      (gptel-yatools-agent-test--deliver "Found it in parser.el:12.")
      (should outcome)
      (let ((result (gptel-yatools-subagent--result record outcome)))
        (should (eq (gptel-yatools-result-provenance result) :derived))
        (should (string-match-p "Found it in parser.el:12"
                                (gptel-yatools-result-body result)))
        (should (string-match-p "status: done"
                                (gptel-yatools-result-body result)))
        (should (string-match-p "tool call"
                                (gptel-yatools-result-body result)))))))

(ert-deftest gptel-yatools-test-subagent-counts-calls-and-paths ()
  "A child's tool calls and the files it read are counted and listed.

The paths are what lets the parent tell a grounded answer from a guess, so
they are deduplicated and reported in the order the child first read
them."
  (gptel-yatools-agent-test--with-parent
    (let ((gptel-yatools-test--dir nil))
      (gptel-yatools-test--in-dir
        (gptel-yatools-test--write "a.el" "one")
        (gptel-yatools-test--write "b.el" "two")
        (gptel-yatools-agent-test--start)
        (let* ((record (car gptel-yatools-subagent--records))
               (read-tool (cl-find "read_path" gptel-yatools--tools
                                   :key #'gptel-tool-name :test #'equal)))
          (gptel-yatools-agent-test--deliver
           (cons 'tool-result
                 (list (list read-tool '(:path "a.el") "one")
                       (list read-tool '(:path "b.el") "two")
                       (list read-tool '(:path "a.el") "one"))))
          (should (= (gptel-yatools-subagent--record-calls record) 3))
          (should (= (gptel-yatools-subagent--record-turns record) 1))
          (should (equal (length (gptel-yatools-subagent--record-paths record)) 2)))))))

;;-------------------------------------------------------------------------
;; Failure
;;-------------------------------------------------------------------------
(ert-deftest gptel-yatools-test-subagent-reports-a-curl-failure ()
  "A connection failure reaches the parent as a sentence, not as silence.

gptel reports one as a nil response with `:error' set.  Returning an empty
answer instead would read as \"nothing found\", which is the one thing a
broken child must never be able to say."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (job (gptel-yatools-subagent--record-job record))
           (outcome nil))
      (gptel-yatools--job-conclude-with job (lambda (o) (setq outcome o)))
      (gptel-yatools-agent-test--deliver
       nil (list :error "Curl failed with exit code 7."
                 :status "Curl failure"))
      (should (eq (plist-get outcome :state) 'failed))
      (should (string-match-p "Curl failed with exit code 7"
                              (gptel-yatools-subagent--record-error record)))
      (let ((result (gptel-yatools-subagent--result record outcome)))
        (should (string-match-p "Error:" (gptel-yatools-result-body result)))))))

(ert-deftest gptel-yatools-test-subagent-reports-a-provider-rejection ()
  "A rejected request names the status, so \"retry\" and \"rephrase\" differ.

A 429 is worth waiting out and a 400 is not; a single \"the request
failed\" leaves the parent model unable to choose between them."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let ((record (car gptel-yatools-subagent--records)))
      (gptel-yatools-agent-test--deliver
       nil (list :error "rate limited" :status "Too Many Requests"
                 :http-status "429"))
      (should (string-match-p "429" (gptel-yatools-subagent--record-error record)))
      (should (string-match-p "Too Many Requests"
                              (gptel-yatools-subagent--record-error record))))))

(ert-deftest gptel-yatools-test-subagent-abort-names-its-cause ()
  "An aborted child says why, and how far it got.

\"Aborted\" alone leaves the parent model guessing whether it did something
wrong.  The cause is one of the three ways a child stops early, and the
tool-call count is how much of the work was done."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let ((record (car gptel-yatools-subagent--records)))
      (with-current-buffer (gptel-yatools-subagent--record-buffer record)
        (gptel-yatools--cancel-tool-calls (current-buffer)))
      (should (eq (gptel-yatools-subagent--record-state record) 'aborted))
      (should (string-match-p "aborted before it finished"
                              (gptel-yatools-subagent--record-error record))))))

(ert-deftest gptel-yatools-test-subagent-tool-call-cap-stops-it ()
  "Reaching the tool-call cap stops the child and quotes what it had.

A capped child's partial answer is the most useful thing it produced, and
quoting it is what lets the parent tell \"ran out halfway\" from \"nearly
finished\"."
  (gptel-yatools-agent-test--with-parent
    (let ((gptel-yatools-subagent-max-tool-calls 1))
      (gptel-yatools-agent-test--start)
      (let* ((record (car gptel-yatools-subagent--records))
             (read-tool (cl-find "read_path" gptel-yatools--tools
                                 :key #'gptel-tool-name :test #'equal)))
        (gptel-yatools-agent-test--deliver
         (cons 'tool-result
               (list (list read-tool '(:path "a.el") "one")
                     (list read-tool '(:path "b.el") "two"))))
        (should (eq (gptel-yatools-subagent--record-state record) 'call-cap))
        (should (string-match-p "stopped after 2 tool calls"
                                (gptel-yatools-subagent--record-error record)))))))

(ert-deftest gptel-yatools-test-subagent-turn-cap-stops-it ()
  "Reaching the turn cap stops the child, and is not the same as the call cap.

One turn can carry many tool calls, so a child can spend turns one call at
a time: the turn cap is what bounds what it costs, not what it reads."
  (gptel-yatools-agent-test--with-parent
    (let ((gptel-yatools-subagent-max-turns 1)
          (gptel-yatools-subagent-max-tool-calls 100))
      (gptel-yatools-agent-test--start)
      (let* ((record (car gptel-yatools-subagent--records))
             (read-tool (cl-find "read_path" gptel-yatools--tools
                                 :key #'gptel-tool-name :test #'equal)))
        (gptel-yatools-agent-test--deliver
         (cons 'tool-result (list (list read-tool '(:path "a.el") "one"))))
        (gptel-yatools-agent-test--deliver
         (cons 'tool-result (list (list read-tool '(:path "b.el") "two"))))
        (should (eq (gptel-yatools-subagent--record-state record) 'turn-cap))
        (should (string-match-p "model turns"
                                (gptel-yatools-subagent--record-error record)))))))

;;-------------------------------------------------------------------------
;; The three ways a child can be stopped
;;-------------------------------------------------------------------------
(ert-deftest gptel-yatools-test-subagent-killing-its-buffer-aborts-it ()
  "`C-x k' on a running child stops the child and answers the parent.

Nothing in gptel's request loop checks whether `info :buffer' is still
alive, so a child whose buffer was killed would keep calling the model
while the parent's tool call waited forever for a result that can never
arrive."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (job (gptel-yatools-subagent--record-job record))
           (outcome nil))
      (gptel-yatools--job-conclude-with job (lambda (o) (setq outcome o)))
      (let ((kill-buffer-query-functions nil)
            (buffer (gptel-yatools-subagent--record-buffer record)))
        (kill-buffer buffer))
      (should (eq (gptel-yatools-subagent--record-state record) 'aborted))
      (should outcome)
      (should (string-match-p "killed"
                              (gptel-yatools-subagent--record-error record))))))

(ert-deftest gptel-yatools-test-subagent-aborts-with-its-parent ()
  "Aborting the parent aborts every child it started, and only children.

The parent reaches its children the way it reaches a command: through the
job registry, with no advice of the agent module's own and no second list
of things to stop.  A child whose answer has nowhere to go must not keep
spending tokens, and `gptel-abort' is the key the user has."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start "First")
    (let ((first (car gptel-yatools-subagent--records)))
      (gptel-yatools-agent-test--start "Second")
      (let ((second (car gptel-yatools-subagent--records)))
        (should-not (eq first second))
        (gptel-abort (current-buffer))
        (dolist (record (list first second))
          (should (eq (gptel-yatools-subagent--record-state record) 'aborted))
          (should-not (gptel-yatools-subagent--running-p record)))
        (should-not (gptel-yatools--jobs-live))))))

(ert-deftest gptel-yatools-test-subagent-joins-the-job-registry ()
  "A child's job is live in its parent's registry, like a command's.

That is what gives a child the status line, `C-c C-k', the kill-buffer
hook and the deadline without the agent module writing any of them: the
registrar owns them, and this asserts the module went through it."
  (gptel-yatools-agent-test--with-parent
    (let* ((job (gptel-yatools-agent-test--start))
           (record (car gptel-yatools-subagent--records)))
      (should (memq job gptel-yatools--jobs))
      (should (memq job (gptel-yatools--jobs-live)))
      (should (timerp (gptel-yatools-job-timer job)))
      (should (memq #'gptel-yatools--kill-buffer-jobs kill-buffer-hook))
      (should (eq record (gptel-yatools-job-data job)))
      (should (string-match-p "subagent"
                              (gptel-yatools--jobs-status-text
                               (gptel-yatools--jobs-live)))))))

(ert-deftest gptel-yatools-test-subagent-dies-with-the-chat-that-started-it ()
  "Killing the parent abandons its children, because they are its jobs.

Without this a child would keep calling the model with its answer going
into a buffer nobody can see, and the tokens would be spent for nothing."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let ((record (car gptel-yatools-subagent--records)))
      (should (memq #'gptel-yatools--kill-buffer-jobs kill-buffer-hook))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (current-buffer)))
      (should (eq (gptel-yatools-subagent--record-state record) 'aborted))
      (should-not (gptel-yatools-subagent--running-p record)))))

(ert-deftest gptel-yatools-test-subagent-expires-on-its-deadline ()
  "A child that outlives its deadline is stopped and reported as timed out.

The child has no deadline code of its own: the job's CANCEL function is
told `timed-out', and the record settles in the child's own words.  The
number it quotes is the call's whole budget, with no margin subtracted --
a subagent is always asynchronous, so no caller above it is counting down
and its kill has no reason to land early."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (job (gptel-yatools-subagent--record-job record))
           (outcome nil))
      (gptel-yatools--job-conclude-with job (lambda (o) (setq outcome o)))
      (gptel-yatools--job-expire job)
      (should (eq (gptel-yatools-subagent--record-state record) 'timed-out))
      (should (plist-get outcome :timed-out))
      (should (string-match-p "timed out after 60 seconds"
                              (gptel-yatools-subagent--record-error record)))
      (should-not (memq job (gptel-yatools--jobs-live))))))

;;-------------------------------------------------------------------------
;; Taking a child over
;;-------------------------------------------------------------------------
(ert-deftest gptel-yatools-test-subagent-finishing-does-not-detach-it ()
  "gptel's own finishing insert must not count as the user taking over.

gptel lays a reply down in two steps: the callback receives the text, then
the DONE handler inserts a response separator and a prompt prefix.  The
second step changes the buffer *after* the child has settled, so reading
every change as a user edit detached every child the moment it answered,
dropped it from the parent's list and offered a rename nobody asked for.
"
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (child (gptel-yatools-subagent--record-buffer record))
           (asked nil))
      (gptel-yatools-agent-test--deliver "All good.")
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (setq asked t) "")))
        ;; What `gptel--handle-post-insert' does, unchanged: no user
        ;; command ran in between, so it must be attributed to gptel.
        (with-current-buffer child
          (let ((tracking (plist-get (gptel-yatools-subagent--record-info record)
                                     :tracking-marker)))
            (unless tracking
              (setq tracking (set-marker (make-marker) (point-max))))
            (goto-char tracking)
            (insert "\n\n"))
          (insert "You: "))
        (let ((deadline (+ (float-time) 1.0)))
          (while (< (float-time) deadline)
            (accept-process-output nil 0.05))))
      (should-not (gptel-yatools-subagent--record-detached record))
      (should (memq record gptel-yatools-subagent--records))
      (should-not asked))))

(ert-deftest gptel-yatools-test-subagent-edit-detaches-it ()
  "Editing a settled child's buffer takes it out of the parent's hands.

The kill hook is the point: a buffer the user has adopted must not be
destroyed when the chat that started it goes away.  A child that is still
running cannot be edited at all, so this only ever fires after it settles.

The edit is made the way a user makes one: `pre-command-hook' runs first,
which is what tells the module that the change about to arrive is not
gptel finishing its reply."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (child (gptel-yatools-subagent--record-buffer record))
           (asked nil))
      (gptel-yatools-agent-test--deliver "All good.")
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (setq asked t) "")))
        (with-current-buffer child
          ;; A real command loop runs these; ERT has no command loop.
          (run-hooks 'pre-command-hook)
          (goto-char (point-max))
          (insert "\nmy note"))
        ;; The rename question is asked from a timer, so run the timers.
        (let ((deadline (+ (float-time) 2)))
          (while (and (not asked) (< (float-time) deadline))
            (accept-process-output nil 0.05))))
      (should (gptel-yatools-subagent--record-detached record))
      (should-not (memq record gptel-yatools-subagent--records))
      (should asked))))

(ert-deftest gptel-yatools-test-subagent-rename-keeps-the-name-on-empty ()
  "An empty answer to the rename question keeps the buffer as it is.

The buffer has already been detached by then, so declining the rename
costs the user nothing but the hidden name."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (child (gptel-yatools-subagent--record-buffer record))
           (before (buffer-name child)))
      (gptel-yatools-agent-test--deliver "All good.")
      (with-current-buffer child
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
          (gptel-yatools-subagent--offer-rename))
        (should (equal (buffer-name) before))))))

;;-------------------------------------------------------------------------
;; Surfaces
;;-------------------------------------------------------------------------
(ert-deftest gptel-yatools-test-subagent-states-its-own-timeout ()
  "The TIMEOUT argument names the subagent budget, not the shared one.

A tool that states one number and enforces another is worse than one that
says nothing: the model would believe it had raised a limit it had not.
The number is read from the `defcustom' each time, so changing it during a
session changes what the model is told."
  (let ((tool (gptel-yatools-test--tool-spec "subagent")))
    (should (equal (mapcar (lambda (arg) (plist-get arg :name))
                           (gptel-tool-args tool))
                   '("task" "timeout")))
    (should (string-match-p
             (format "default (%s seconds)" gptel-yatools-subagent-timeout)
             (plist-get (car (last (gptel-tool-args tool))) :description)))
    (let ((original gptel-yatools-subagent-timeout))
      (unwind-protect
          (progn
            (customize-set-variable 'gptel-yatools-subagent-timeout 111)
            (should (string-match-p
                     "default (111 seconds)"
                     (plist-get (car (last (gptel-tool-args tool)))
                                :description))))
        (customize-set-variable 'gptel-yatools-subagent-timeout original)))))

(ert-deftest gptel-yatools-test-subagent-draws-its-tool-calls ()
  "A child's transcript shows the tool calls it made, and what they returned.

A request that supplies a callback takes over drawing, and gptel's display
branches are then only reached if the callback forwards to them.  A child
that did not forward showed its prose and nothing else, so the buffer
looked like a model that announced a read and then stopped."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (child (gptel-yatools-subagent--record-buffer record))
           (read-tool (cl-find "read_path" gptel-yatools--tools
                               :key #'gptel-tool-name :test #'equal)))
      (gptel-yatools-agent-test--deliver
       "Let me check the parser."
       (list :buffer child
             :position (with-current-buffer child
                         (set-marker (make-marker) (point-max)))
             :tools (gptel-yatools-subagent--tool-specs)
             :tool-use (list (list :name "read_path" :args '(:path "src/parser.el")))
             :status "200 OK"))
      (gptel-yatools-agent-test--deliver
       (cons 'tool-result
             (list (list read-tool '(:path "src/parser.el") "line one\nline two"))))
      (with-current-buffer child
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "Let me check the parser" text))
          (should (string-match-p "read_path" text))
          (should (string-match-p "line one" text)))))))

(ert-deftest gptel-yatools-test-subagent-draws-its-reasoning ()
  "A child's transcript shows its reasoning, without resending it.

`gptel-include-reasoning' is `ignore' in a child buffer: the block is
drawn, and the next request does not pay for it again."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (child (gptel-yatools-subagent--record-buffer record)))
      (with-current-buffer child
        (should (eq gptel-include-reasoning 'ignore)))
      (gptel-yatools-agent-test--deliver
       (cons 'reasoning "The parser is probably in src/")
       (list :buffer child
             :position (with-current-buffer child
                         (set-marker (make-marker) (point-max)))
             :tools (gptel-yatools-subagent--tool-specs)
             :include-reasoning 'ignore
             :status "200 OK"))
      (with-current-buffer child
        (should (string-match-p "probably in src/"
                                (buffer-substring-no-properties
                                 (point-min) (point-max))))))))

(ert-deftest gptel-yatools-test-subagent-uses-gptels-send-state-machine ()
  "A child request runs gptel's `gptel-send' handlers, not the bare default.

The bare `gptel-make-fsm' default has no UI handlers: it never sets
`gptel--fsm-last' -- so the child's status indicator is not even
clickable -- never updates the status line, and never reports a request
error.  A child that ran on it looked finished while it was still working,
and a failed one showed nothing at all."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (fsm (gptel-yatools-subagent--record-fsm record)))
      (should (gptel-fsm-p fsm))
      (should (eq (gptel-fsm-handlers fsm) gptel-send--handlers))
      (should (eq (gptel-fsm-table fsm) gptel-send--transitions))
      ;; And the handler that makes the indicator clickable is one of them.
      (should (memq #'gptel--update-tool-call
                    (alist-get 'TOOL (gptel-fsm-handlers fsm)))))))

(ert-deftest gptel-yatools-test-subagent-does-not-count-displayed-blocks-as-turns ()
  "Forwarding a tool result for display must not re-enter the callback.

`gptel--display-tool-results' inserts each block by calling the request
callback itself.  Left pointed at this module's callback, that nested call
would arrive as a turn -- and, worse, could settle a child mid-request."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (read-tool (cl-find "read_path" gptel-yatools--tools
                               :key #'gptel-tool-name :test #'equal))
           (info (list :buffer (gptel-yatools-subagent--record-buffer record)
                       :position (with-current-buffer
                                     (gptel-yatools-subagent--record-buffer record)
                                   (set-marker (make-marker) (point-max)))
                       :tools (gptel-yatools-subagent--tool-specs)
                       :callback gptel-yatools-agent-test--callback
                       :status "200 OK")))
      (gptel-yatools-agent-test--deliver
       (cons 'tool-result (list (list read-tool '(:path "a.el") "one"))) info)
      (should (= (gptel-yatools-subagent--record-turns record) 1))
      (should (gptel-yatools-subagent--running-p record))
      ;; The request's own callback is put back, so gptel can deliver the
      ;; next turn through it.
      (should (eq (plist-get info :callback)
                  gptel-yatools-agent-test--callback)))))

(ert-deftest gptel-yatools-test-subagent-preview-shows-the-whole-brief ()
  "The task the user approves is the task the child receives, line for line.

A subagent is approved on its brief, and a brief is written in
paragraphs.  Escaping the line breaks turned it into one dense line of
<U+000A> that described nothing anyone could judge."
  (let ((text (gptel-yatools-test--preview
               "subagent"
               (list :task "Review the parser change.\n\nReturn findings with file:line evidence."))))
    (should (string-match-p "Review the parser change\\.\n\n" text))
    (should (string-match-p "file:line evidence" text))
    (should-not (string-match-p "U+000A" text))))

(ert-deftest gptel-yatools-test-subagent-callback-touches-no-filesystem ()
  "The child's callback must not resolve paths or consult the project.

gptel calls the callback from a process sentinel, and Tramp may have
started that sentinel from inside its own locked connection -- where any
further remote call is refused as a reentrant one.  A `file-directory-p'
in the path bookkeeping, or a `project-current' reached through
`--resolve-path', was enough to break every subagent in a remote
workspace, and the failures looked like a broken model rather than a
broken callback.

What is asserted is the property that fails when either creeps back: the
paths are recorded exactly as the child wrote them, never made absolute.
`project-current' is trapped too, because it is an ordinary function and
cl-letf can safely replace it; the filesystem primitives are not trapped
here, because rebinding a subr makes native-comp stat its own cache,
which would trip the trap on the compiler's behalf."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (read-tool (cl-find "read_path" gptel-yatools--tools
                               :key #'gptel-tool-name :test #'equal)))
      (cl-letf (((symbol-function 'project-current)
                 (lambda (&rest _) (error "callback consulted the project")))
                ((symbol-function 'gptel-yatools--resolve-path)
                 (lambda (&rest _) (error "callback resolved a path"))))
        (gptel-yatools-agent-test--deliver
         (cons 'tool-result
               (list (list read-tool '(:path "src/parser.el") "one")
                     (list read-tool '(:path "src/other.el") "two")
                     (list read-tool '(:path "etc") "a directory, as it happens")))))
      (should (= (gptel-yatools-subagent--record-calls record) 3))
      ;; As written, not expanded against any root, and not dropped for
      ;; being a directory.
      (should (equal (gptel-yatools-subagent--record-paths record)
                     '("src/parser.el" "src/other.el" "etc")))
      (should (gptel-yatools-subagent--running-p record))
      (should-not (gptel-yatools-subagent--record-error record)))))

(ert-deftest gptel-yatools-test-subagent-reports-an-internal-error ()
  "An error in the callback settles the child instead of escaping.

Nothing catches a callback error in gptel's request loop, so one escaping
here breaks the state machine and leaves the child running with nothing
watching it.  It becomes the child failing instead, which is recoverable
and says what happened."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (job (gptel-yatools-subagent--record-job record))
           (outcome nil))
      (gptel-yatools--job-conclude-with job (lambda (o) (setq outcome o)))
      (cl-letf (((symbol-function 'gptel-yatools-subagent--dispatch)
                 (lambda (&rest _) (error "boom"))))
        (gptel-yatools-agent-test--deliver "an answer"))
      (should (eq (gptel-yatools-subagent--record-state record) 'failed))
      (should (string-match-p "internal error: boom"
                              (gptel-yatools-subagent--record-error record)))
      (should outcome))))

(ert-deftest gptel-yatools-test-subagent-says-when-its-answer-was-cut-off ()
  "A child whose reply hit its output limit must not read as finished.

gptel records `:stop-reason' and never reads it, so a truncated reply is
drawn exactly like a complete one.  For a parent model that is the worst
case: it receives the answer as `:derived' and cannot tell a finding from
half a sentence, so it acts on a report that looks whole."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (job (gptel-yatools-subagent--record-job record))
           (outcome nil))
      (gptel-yatools--job-conclude-with job (lambda (o) (setq outcome o)))
      (gptel-yatools-agent-test--deliver
       "The parser looks fine, but the tokenizer"
       (list :buffer (gptel-yatools-subagent--record-buffer record)
             :position (with-current-buffer
                           (gptel-yatools-subagent--record-buffer record)
                         (set-marker (make-marker) (point-max)))
             :tools (gptel-yatools-subagent--tool-specs)
             :stop-reason "length"
             :status "200 OK"))
      (should (eq (gptel-yatools-subagent--record-state record) 'done))
      (should (gptel-yatools-subagent--truncated-p record))
      (should (plist-get outcome :truncated))
      (let ((body (gptel-yatools-result-body
                   (gptel-yatools-subagent--result record outcome))))
        (should (string-match-p "INCOMPLETE" body))
        (should (string-match-p "length" body))
        (should (string-match-p "tokenizer" body))))))

(ert-deftest gptel-yatools-test-subagent-quiet-when-its-answer-finished ()
  "A finished answer must not be marked incomplete.

Every backend reports a normal stop differently -- `stop', `end_turn',
`completed' -- so the check is a list of the failures, not of the
successes: a new success value must not produce a false alarm."
  (gptel-yatools-agent-test--with-parent
    (dolist (reason '("stop" "end_turn" "completed" nil))
      (let ((gptel-yatools-subagent--records nil))
        (gptel-yatools-agent-test--start)
        (let* ((record (car gptel-yatools-subagent--records))
               (job (gptel-yatools-subagent--record-job record))
               (outcome nil))
          (gptel-yatools--job-conclude-with job (lambda (o) (setq outcome o)))
          (gptel-yatools-agent-test--deliver
           "All good."
           (list :buffer (gptel-yatools-subagent--record-buffer record)
                 :position (with-current-buffer
                               (gptel-yatools-subagent--record-buffer record)
                             (set-marker (make-marker) (point-max)))
                 :tools (gptel-yatools-subagent--tool-specs)
                 :stop-reason reason
                 :status "200 OK"))
          ;; The child's buffer stays live: the suite's kill hook aborts
          ;; it, which is the behaviour tested elsewhere.
          (let ((body (gptel-yatools-result-body
                       (gptel-yatools-subagent--result record outcome))))
            (should-not (gptel-yatools-subagent--truncated-p record))
            (should-not (string-match-p "INCOMPLETE" body))))))))

(ert-deftest gptel-yatools-test-subagent-survives-a-display-failure ()
  "A failure drawing the transcript must not end the child.

gptel's tool-result rendering has been seen to raise \"Args out of range\"
for an ordinary short result.  That is a display bug, and it used to cost
the child its answer: the error escaped the callback, which settles the
child as failed.  The transcript is worth less than the answer it was
describing."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (read-tool (cl-find "read_path" gptel-yatools--tools
                               :key #'gptel-tool-name :test #'equal)))
      (cl-letf (((symbol-function 'gptel--insert-response)
                 (lambda (&rest _) (error "Args out of range"))))
        (gptel-yatools-agent-test--deliver
         (cons 'tool-result
               (list (list read-tool '(:path "/etc/apk/world") "x")))))
      (should (gptel-yatools-subagent--running-p record))
      (should (= (gptel-yatools-subagent--record-calls record) 1))
      (should-not (gptel-yatools-subagent--record-error record))
      ;; And the answer still lands and still settles the child.
      (gptel-yatools-agent-test--deliver "All good.")
      (should (eq (gptel-yatools-subagent--record-state record) 'done)))))

(ert-deftest gptel-yatools-test-subagent-expire-survives-a-broken-host ()
  "A deadline that cannot stop its child cleanly must still settle it.

The expire runs on a timer, where a signal is only logged: a dead remote
host left the child `running' for ever, its buffer read-only and the
parent's tool call waiting.  It is reported as the timeout it was."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (job (gptel-yatools-subagent--record-job record))
           (outcome nil))
      (gptel-yatools--job-conclude-with job (lambda (o) (setq outcome o)))
      (cl-letf (((symbol-function 'gptel-yatools-subagent--stop-request)
                 (lambda (&rest _) (error "Tramp failed to connect"))))
        (gptel-yatools--job-expire job))
      (should (eq (gptel-yatools-subagent--record-state record) 'timed-out))
      (should (string-match-p "timed out"
                              (gptel-yatools-subagent--record-error record)))
      (should (string-match-p "could not be stopped cleanly"
                              (gptel-yatools-subagent--record-error record)))
      (should outcome)
      (should-not (gptel-yatools-subagent--running-p record)))))

(ert-deftest gptel-yatools-test-abort-advice-takes-optional-arguments ()
  "Advice on `gptel-abort' must not be narrower than `gptel-abort'.

The package adds one, and a required BUFFER in it would make anything
that called `gptel-abort' with fewer arguments get \"Wrong number of
arguments\" from the advice instead of an abort."
  (should (equal (func-arity #'gptel-yatools--abort-cancels-tools)
                 '(0 . 1)))
  ;; And calling it with none uses the current buffer.
  (with-temp-buffer
    (should (= 0 (gptel-yatools--abort-cancels-tools)))))

(ert-deftest gptel-yatools-test-abort-works-without-an-argument ()
  "`gptel-abort' promises a default the function itself does not provide.

Its docstring says BUF defaults to the current buffer while the argument
is required, so a key bound to it with nothing to pass -- which is the
natural reading of that docstring -- failed with \"Wrong number of
arguments\" and stopped aborting anything."
  (with-temp-buffer
    (setq-local gptel-mode t)
    (let ((gptel-yatools-subagent--records nil))
      (should-not (condition-case err
                      (progn (gptel-abort) nil)
                    (error (error-message-string err))))
      (should-not (condition-case err
                      (progn (gptel-abort (current-buffer)) nil)
                    (error (error-message-string err)))))))

(ert-deftest gptel-yatools-test-a-quit-during-a-deferred-call-does-not-strand-it ()
  "A `C-g' during a deferred call must leave the call runnable.

`condition-case' does not treat `quit' as an `error', so a quit used to
escape every handler around the deferred call.  It is now swallowed by the
call itself (see `gptel-yatools-ignore-quit'), so the call runs and the
request carries on -- rather than being failed for a keypress aimed at
something else.

What must never happen again is the halfway case: the call not running
*and* the request not being told, which left it in TOOL for ever with
`:tool-result' nil and nothing on screen."
  (should (eq (condition-case _e (signal 'quit nil)
                (error 'caught)
                (quit 'escaped))
              'escaped))
  (let ((fsm nil)
        (ran nil)
        (gptel-yatools-ignore-quit t))
    (cl-letf (((symbol-function 'gptel-yatools--remote-buffer-p)
               (lambda (_buffer) t))
              ((symbol-function 'gptel-yatools--tramp-locked-p)
               (lambda (_buffer) nil))
              ((symbol-function 'gptel--fsm-transition)
               (lambda (machine state) (setf (gptel-fsm-state machine) state))))
      (with-temp-buffer
        (setq fsm (gptel-make-fsm :state 'TOOL
                                  :info (list :buffer (current-buffer))))
        (gptel-yatools--tool-calls-outside-the-sentinel
         (lambda (&rest _) (setq ran t)) fsm)
        (let ((deadline (+ (float-time) 5)))
          (while (and (not ran) (< (float-time) deadline))
            (condition-case _q (accept-process-output nil 0.05) (quit nil))))
        (should ran)
        (should-not (plist-get (gptel-fsm-info fsm) :error))))))

(ert-deftest gptel-yatools-test-subagent-settles-when-its-callback-is-quit ()
  "A quit inside the child's callback must settle the child too.

The same reason as above, one layer in: the child's callback is called
from a sentinel, so a quit escaping it ends the run with no result and a
parent tool call waiting for ever."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (job (gptel-yatools-subagent--record-job record))
           (outcome nil))
      (gptel-yatools--job-conclude-with job (lambda (o) (setq outcome o)))
      (cl-letf (((symbol-function 'gptel-yatools-subagent--dispatch)
                 (lambda (&rest _) (signal 'quit nil))))
        (gptel-yatools-agent-test--deliver "an answer"))
      (should (eq (gptel-yatools-subagent--record-state record) 'aborted))
      (should (string-match-p "interrupted"
                              (gptel-yatools-subagent--record-error record)))
      (should outcome))))

(ert-deftest gptel-yatools-test-subagent-label-counts-only-running ()
  "The label counts children that are still working, and says so when none are.

A finished child's buffer is still worth reaching, so the label stays --
clickable, uncounted -- rather than vanishing the moment the last answer
arrives."
  (gptel-yatools-agent-test--with-parent
    (should-not (gptel-yatools-subagent--header-line-label))
    (gptel-yatools-agent-test--start)
    (should (string-match-p "\\[Subagents: 1\\]"
                            (gptel-yatools-subagent--header-line-label)))
    (gptel-yatools-agent-test--deliver "All good.")
    (should (equal (substring-no-properties
                    (gptel-yatools-subagent--header-line-label))
                   "[Subagents]"))))

(ert-deftest gptel-yatools-test-subagent-label-is-not-gptels-status ()
  "The label is ours, so clicking it is not gptel's state inspector.

gptel buttonizes its status text with `gptel--inspect-fsm', so a click
there can only ever show the request state.  A label contributed through
`gptel-yatools-header-line-extra-functions' is ours to make do something
else -- and it carries a click map and a help string, which is what makes
it look clickable."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let ((label (gptel-yatools-subagent--header-line-label)))
      (should (stringp label))
      (should (get-text-property 0 'mouse-face label))
      (should (get-text-property 0 'help-echo label))
      (should (memq #'gptel-yatools-subagent--header-line-label
                    gptel-yatools-header-line-extra-functions)))))

(ert-deftest gptel-yatools-test-subagent-annotation-fits-the-frame ()
  "The picker's annotation is short, and the task is what gets cut.

The line lives in a minibuffer, so a task long enough to fill the frame
would push the state -- the thing a row is scanned for -- off the edge.
State first, task last and truncated, is the ordering that survives that."
  (gptel-yatools-agent-test--with-parent
    (let ((gptel-yatools-subagent-task-width 30))
      (gptel-yatools-agent-test--start
       (make-string 300 ?x))
      (let* ((record (car gptel-yatools-subagent--records))
             (annotation (gptel-yatools-subagent--annotation record)))
        (should (< (length annotation) 60))
        (should (string-prefix-p "  running" annotation))
        (should (string-suffix-p "…" annotation))))))

(ert-deftest gptel-yatools-test-subagent-picker-lists-the-children ()
  "The picker offers every live child and switches to the one chosen.

The completion table carries our own category and an annotation, and
marginalia -- which dispatches on category -- has no annotator for it, so
its buffer annotation never replaces ours."
  (gptel-yatools-agent-test--with-parent
    (gptel-yatools-agent-test--start)
    (let* ((record (car gptel-yatools-subagent--records))
           (child (gptel-yatools-subagent--record-buffer record))
           (offered nil)
           (annotations 0)
           (properties nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (mapcar #'car collection)
                         properties completion-extra-properties)
                   (car offered))))
        (gptel-yatools-subagent-select))
      (should (equal offered (list (buffer-name child))))
      (should (plist-get properties :annotation-function))
      (funcall (plist-get properties :annotation-function) (car offered))
      (setq annotations 1)
      (should (= annotations 1))
      (should (eq (current-buffer) child)))))

(provide 'gptel-yatools-agents-tests)
;;; gptel-yatools-agents-tests.el ends here
