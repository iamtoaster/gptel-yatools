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

(provide 'gptel-yatools)
;;; gptel-yatools.el ends here
