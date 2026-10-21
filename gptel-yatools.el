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
;; paths, line-addressed reads, regexp search, shell commands, Elisp
;; evaluation, and Agent Skills -- directories of instructions and scripts
;; that the model loads on demand.
;;
;; This file holds what every tool shares, and nothing else:
;;
;; - the glue that makes a tool call run in the buffer that owns the
;;   request, so a chat's buffer-local VFS and `default-directory' apply;
;; - the helpers every tool builds on: workspace-relative paths, argument
;;   coercion, binary detection;
;;
;; - the tool boundary: the one adapter that renders what a tool returns
;;   (`gptel-yatools-result') as the envelope the model sees.  It sizes,
;;   truncates and escapes the text, and turns a signalled error or an
;;   expired deadline into the same envelope, so no tool formats its own
;;   response and every response reaches the model by the same route;
;;
;; - the timeout machinery every tool is wrapped in;
;; - the registry: `gptel-yatools--tools', `gptel-yatools-enable' and
;;   friends.
;;
;; The tools themselves live in the file that owns their subject:
;; `gptel-yatools-vfs.el' for the filesystem, `gptel-yatools-tools.el' for
;; the shell, Elisp and workspace tools, and `gptel-yatools-skills.el' for
;; Agent Skills.  Those files are loaded from here at the bottom of this
;; file, once the helpers they build on exist; they cannot be loaded
;; before this one.
;;
;; Loading this file registers every tool in gptel's tool registry, so they
;; appear in the `gptel-menu' tool picker immediately.  Nothing is sent to
;; the model until the tools are enabled: per category or by name with
;; `gptel-yatools-enable', or all of them with `gptel-yatools-enable-all'.
;;
;; See the README for the tool list and for installation instructions.

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'project)

(defgroup gptel-yatools nil
  "Extra tools for gptel."
  :group 'gptel
  :prefix "gptel-yatools-")

(defvar gptel-yatools--current-timeout nil
  "Deadline in seconds of the tool call in progress, or nil.

Bound by `gptel-yatools--call-with-timeout' so that helpers which can
block on their own (`gptel-yatools-tools--run-command') enforce the same
deadline instead of outliving it.")

(defvar gptel-yatools--tools nil
  "The tools defined by this package, in declaration order.

Each element is a `gptel-tool' struct that already carries the shared
TIMEOUT argument and the guard enforcing it.  The tools are also in
gptel's registry, which is what `gptel-menu' lists; this list is what
`gptel-yatools-enable' copies from, so that enabling does not depend on
the registry's shape.

The list is flattened from the tool modules at the bottom of this file,
so it covers every tool the package defines and nothing else.")

(defvar gptel-yatools--timeout-suspended nil
  "Non-nil while the current tool call is waiting for the user.

Time spent in that state is not counted against the timeout, so a
human reading a `file_sync' diff for a few minutes cannot trip it.")

(defvar gptel-yatools-header-line-extra-functions nil
  "Functions that contribute a label to gptel's header line.

Each is called with no arguments while the header line is being
rendered and should return a propertized string, or nil to contribute
nothing.  This is how a tool module reports its own state next to the
VFS pending count without the module that draws the header line having
to know about it.

The functions are called on every redisplay, so they must be cheap: the
VFS count, for example, is what the header-line cache exists for.")

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
;; Two limits are recorded rather than fixed:
;;
;; - A request whose chat buffer was killed dies inside gptel itself
;;   ("Selecting deleted buffer"); we only make the failure readable when
;;   we are the ones to notice it.
;; - `execute_elisp' evaluates inside `with-temp-buffer', so the chat
;;   buffer's `gptel-yatools-vfs' is invisible to the form being evaluated even
;;   when the tool runs in the chat buffer.  That is a property of the
;;   tool, not of buffer switching, and is left as it is.
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
another buffer current, and `execute_elisp' structurally cannot, because
the form it evaluates runs inside `with-temp-buffer'.  A tool that did
switch buffers would still leak into the later calls of its batch."
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

Nothing happens outside a live `gptel-mode' buffer, so calling a tool
directly (tests, `eval', a hook) is unaffected."
  (let ((owner (gptel-yatools--tool-owner-buffer)))
    (when (buffer-live-p owner)
      (with-current-buffer owner
        (when (and (bound-and-true-p gptel-mode)
                   (fboundp 'gptel--update-status))
          (gptel--update-status message face))))))

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
      (when (local-variable-p 'gptel-yatools-vfs)
        (kill-local-variable 'gptel-yatools-vfs))
      (when (local-variable-p 'gptel-yatools-vfs--header-line-cache)
        (kill-local-variable 'gptel-yatools-vfs--header-line-cache)))))

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
;; Path helpers
;;-------------------------------------------------------------------------
(defun gptel-yatools--workspace-root ()
  "Return the current project root, or `default-directory'."
  (let ((proj (project-current)))
    (if proj
        (file-name-as-directory (expand-file-name (project-root proj)))
      (file-name-as-directory (expand-file-name default-directory)))))

(defun gptel-yatools--resolve-path (path)
  "Resolve PATH relative to the workspace root."
  (expand-file-name path (gptel-yatools--workspace-root)))

(defun gptel-yatools--display-path (path)
  "Return PATH relative to the workspace root, for display.

Falls back to the absolute path when PATH is outside the workspace.
The workspace root itself is shown as \".\", the way a relative path
would name it: stripping the root from the root leaves an empty
string, which would read as \"the directory called nothing\"."
  (let ((root (gptel-yatools--workspace-root)))
    (cond
     ((equal path root) ".")
     ((string-prefix-p root path)
      (substring path (length root)))
     (t path))))

(defun gptel-yatools--coerce-integer (value default &optional minimum)
  "Return VALUE coerced to an integer, or DEFAULT if that is impossible.

Integers pass through, other numbers are truncated toward zero, and
numeric strings are parsed first.  The result is never below MINIMUM
\(default 0).  Tool arguments come from JSON, where a model may send
1.0, \"2\" or nil even for a declared integer; without this coercion
they reach `forward-line' or `nth' as a non-integer and signal a raw
Lisp error instead of a readable tool response."
  (let* ((minimum (or minimum 0))
         (n (cond
             ((integerp value) value)
             ((numberp value)
              (condition-case nil (truncate value) (error nil)))
             ((stringp value)
              (condition-case nil
                  (let ((v (string-to-number value)))
                    (and (numberp v) (truncate v)))
                (error nil)))
             (t nil))))
    (if (and (integerp n) (>= n minimum))
        n
      (max minimum (or default minimum)))))

(defun gptel-yatools--require-string (value what)
  "Signal a readable error unless VALUE is a string.

WHAT names the argument in the message.  Tools are called with JSON
arguments; a missing or wrong-typed required argument used to reach
`expand-file-name' or `string-trim' and signal a raw Lisp error."
  (unless (stringp value)
    (error "Error: %s must be a string." what))
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

;;-------------------------------------------------------------------------
;; XML wrapping helpers
;;-------------------------------------------------------------------------
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
regexp costs one C-level pass over the text, where the character loop
in `gptel-yatools--escape-raw-bytes' costs roughly a microsecond per
character -- 60 ms for a 60 kB tool response, paid on every single
call.")

(defun gptel-yatools--escape-raw-bytes (string)
  "Return STRING with undecodable raw bytes escaped as \\xNN.

Tool responses are serialised to JSON when they are sent back to
the model, and Emacs cannot encode a string containing raw (eight
bit) characters: `json-serialize' signals
\"Wrong type argument: json-value-p\" and the whole request dies.
Raw bytes appear whenever a command prints binary or non-UTF-8
data (`cat' of an ISO-8859-1 file, `od', a PDF, ...), so every
tool response is passed through this before it is returned.

Almost every response is ordinary text, which needs no escaping at
all, so that case is detected first and returned as it is: the
character loop below is only for the rare string that really does
carry raw bytes."
  (let ((s (if (multibyte-string-p string)
               string
             (string-to-multibyte string))))
    (if (null (string-match-p gptel-yatools--raw-byte-regexp s))
        s
      (let (parts)
        (dotimes (i (length s))
          (let ((c (aref s i)))
            (push (if (eq (char-charset c) 'eight-bit)
                      (format "\\x%02x" (logand c #xFF))
                    (char-to-string c))
                  parts)))
        (apply #'concat (nreverse parts))))))

(defun gptel-yatools--binary-p (string)
  "Return non-nil if STRING looks like binary content.

The test is the conventional one: presence of a NUL byte.  Text files
essentially never contain one, while images, PDFs, archives and
compiled artifacts almost always do."
  (and (stringp string) (string-match-p "\0" string)))

(defun gptel-yatools--binary-notice (path content from-vfs)
  "Return a tool response reporting that PATH is binary and withheld.

CONTENT is the file's text as decoded by the read tool, used only to
fall back on a size when the file does not exist on disk (a pending
VFS file).  FROM-VFS says where the content came from."
  (let* ((size (or (file-attribute-size (file-attributes path))
                   (condition-case nil
                       (gptel-yatools-vfs--encodable-bytes content 'no-conversion)
                     (error nil))))
         (body (format "\
%s is a binary file (%s), so its contents are not returned.

Binary files cannot be meaningfully read or edited as text: the
bytes do not form lines, and round-tripping them through text
editing would corrupt the file.  If you need information about it,
use the execute_command tool instead, for example:

  file %s
  ls -l %s
  sha256sum %s

If the goal is to replace the file, write it with write_file
without reading it first."
                       (gptel-yatools--display-path path)
                       (if size (format "%d bytes" size) "size unknown")
                       (gptel-yatools--display-path path)
                       (gptel-yatools--display-path path)
                       (gptel-yatools--display-path path))))
    (gptel-yatools-ok body :vfs from-vfs
                      :comment "Binary file; contents withheld.")))

(defconst gptel-yatools--output-char-limit 64000
  "Maximum number of characters a single tool response may contain.

Tool output is pasted into the model's context, so an unbounded read
of a large file costs a whole context window in one call.")

(defconst gptel-yatools--output-line-limit 2000
  "Maximum number of lines a single tool response may contain.")

(defun gptel-yatools--hard-cut (string limit)
  "Return STRING cut to LIMIT characters, without splitting a \\xNN escape.

`gptel-yatools--escape-raw-bytes' turns one raw byte into four characters,
so a cut can land in the middle of an escape.  Dropping the partial
escape keeps the text unambiguous for the reader."
  (let ((cut (substring string 0 (min limit (length string)))))
    (if (string-match "\\\\x[0-9a-f]?\\'" cut)
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

The text is capped to the line and character limits and has raw
(non-UTF-8) bytes escaped.  The size limit is enforced twice: once on
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

(defun gptel-yatools--truncate-slow (string)
  "Return STRING cut to the response limits, with a note saying what was cut.

This is the general path behind `gptel-yatools--truncate'; it assumes
nothing about STRING and walks all of it."
  (let* ((total-chars (length string))
         ;; `split-string' keeps a trailing empty field when the text
         ;; ends with a newline, so that the pieces rejoin into the
         ;; original text.  That field is not a line: counting it made a
         ;; file of exactly the line limit look over it (and get cut
         ;; mid-file), and made every count one too high.
         (lines (split-string string "\n"))
         (total-lines (if (string-suffix-p "\n" string)
                          (1- (length lines))
                        (length lines)))
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

(defun gptel-yatools--envelope (from-vfs comment body)
  "Return BODY wrapped in the tool context/response XML envelope.

FROM-VFS is non-nil if the content came from the virtual filesystem.
COMMENT is a short note shown to the LLM in the context tag.

Both COMMENT and BODY are sanitised with
`gptel-yatools--escape-raw-bytes' so that a response never carries
bytes that cannot be serialised for the model."
  (format "<tool_context vfs=\"%s\" comment=\"%s\"/>\n<tool_response>\n%s\n</tool_response>"
          (if from-vfs "true" "false")
          (gptel-yatools--xml-escape (gptel-yatools--escape-raw-bytes comment))
          (gptel-yatools--truncate body)))

;;-------------------------------------------------------------------------
;; The tool boundary
;;
;; A tool function says what it found and returns a Result; rendering that
;; as the envelope above is this section's job, and it happens in exactly
;; one place -- the wrapper `gptel-yatools--make-tool' installs around every
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
;;   `gptel-yatools--page-text' is that budget, offered as a helper
;;   instead of a constant each tool reads directly.
;;-------------------------------------------------------------------------
(cl-defstruct (gptel-yatools-result (:constructor gptel-yatools--make-result)
                                    (:copier nil))
  "What a tool function returns.

BODY is the text the model reads.  VFS is non-nil when the reply
describes pending virtual-filesystem state that is not on disk yet.
COMMENT is the envelope's one-line context comment; nil means derive it
from VFS.

Build one with `gptel-yatools-ok'.  A tool never formats, truncates or
escapes its own response: all of that happens once, at the boundary
\(see `gptel-yatools--call-tool')."
  (body "" :documentation "The text the model reads.")
  (vfs nil :documentation "Non-nil if this reply reflects pending VFS state.")
  (comment nil :documentation "Context comment, or nil to derive it from VFS."))

(defconst gptel-yatools--result-comments
  '((t . "\
This reply reflects pending changes in the virtual filesystem that are not on disk yet. Run the file_sync tool to persist them.")
    (nil . "This reply reflects the state of disk."))
  "Default envelope comments, keyed by a result's VFS flag.

Tools with something more specific to say pass :comment to
`gptel-yatools-ok' instead.")

(defun gptel-yatools-ok (body &rest args)
  "Return a `gptel-yatools-result' carrying BODY.

BODY is what the model reads.  It is size-limited and raw-byte-escaped
at the boundary, so a tool can return all of it and let the boundary
decide what fits.

ARGS is a plist with two optional keys:

  :vfs      non-nil when the reply describes pending virtual-filesystem
            state that is not on disk yet, which is what the model needs
            to know before it trusts the text as a description of disk.
  :comment  the envelope's one-line context comment.  Defaults to a
            sentence derived from :vfs."
  (let ((vfs (plist-get args :vfs)))
    (gptel-yatools--make-result
     :body (if (stringp body) body (format "%s" body))
     :vfs (and vfs t)
     :comment (or (plist-get args :comment)
                  (cdr (assq (and vfs t) gptel-yatools--result-comments))))))

(defun gptel-yatools--respond (result)
  "Render RESULT, a `gptel-yatools-result', as the envelope the model sees.

A tool returning anything else is a bug in this package.  It is reported
to the model as a failed call rather than signalled, because a signalled
error would bypass the envelope -- and with it the escaping that keeps
the request serialisable."
  (if (gptel-yatools-result-p result)
      (gptel-yatools--envelope (gptel-yatools-result-vfs result)
                               (gptel-yatools-result-comment result)
                               (gptel-yatools-result-body result))
    (gptel-yatools--envelope
     nil
     "The tool returned no result."
     (format "Error: internal error: the tool returned %S where a result was expected. This is a bug in gptel-yatools; nothing was changed."
             result))))

(defun gptel-yatools--call-tool (name function args)
  "Call FUNCTION with positional ARGS and render the outcome for the model.

NAME labels the tool in the envelope.  This is the tool boundary: a
signalled error, an expired deadline and a tool that returned the wrong
shape all become the same envelope here, sized, truncated and escaped,
so the model never receives bare text and never receives text that
cannot be serialised back to JSON.

`quit' passes through untouched, and so does anything the user asked to
debug: `condition-case-unless-debug' leaves the signal alone while
`debug-on-error' is set."
  (condition-case-unless-debug err
      (gptel-yatools--respond (apply function args))
    (gptel-yatools-timeout-error
     (gptel-yatools--envelope
      nil "Tool call timed out."
      (gptel-yatools--timeout-message (plist-get (cdr err) :seconds)
                                      (plist-get (cdr err) :tool))))
    (error
     (gptel-yatools--envelope
      nil (format "The %s tool reported an error." name)
      (format "Error: %s" (error-message-string err))))))

(defun gptel-yatools--page-text (text offset lines)
  "Return a page of TEXT, described by a plist.

OFFSET is the 1-based number of the first line wanted, LINES how many.
The page never exceeds `gptel-yatools--output-char-limit', so the
boundary's truncation cannot cut it in half after the caller has said
what it showed.  A single line longer than the limit is still returned
whole; the boundary handles that case.

The plist holds :text, :start and :end (1-based, inclusive, of the lines
shown), :total (lines in TEXT), :past-end (OFFSET was beyond the last
line) and :partial (the page is not the whole of TEXT)."
  (let* ((all (split-string text "\n"))
         (total (length all))
         (start (max 1 offset))
         (want (max 1 lines))
         (past-end (> start total))
         (end (if past-end
                  start
                (let ((shown 0) (used 0) (i (1- start)) (stop nil))
                  (while (and (not stop) (< i total) (< shown want))
                    (let ((size (1+ (length (nth i all)))))
                      (if (and (> shown 0)
                               (> (+ used size)
                                  gptel-yatools--output-char-limit))
                          (setq stop t)   ; the next line would overflow
                        (setq used (+ used size)
                              shown (1+ shown)
                              i (1+ i)))))
                  (+ start -1 (max 1 shown))))))
    (list :text (if past-end
                    ""
                  (mapconcat #'identity (cl-subseq all (1- start) end) "\n"))
          :start start
          :end end
          :total total
          :past-end past-end
          :partial (and (not past-end)
                        (or (> start 1) (< end total))))))
;;-------------------------------------------------------------------------
;; Tool call timeouts
;;
;; Tool calls run synchronously inside gptel's request handler, so a tool
;; that blocks -- a hung shell command, a read from a FIFO, an Elisp form
;; that sleeps -- blocks Emacs itself.  Every tool below therefore gets a
;; deadline (120 seconds by default) plus an optional TIMEOUT argument for
;; the rare call that genuinely needs longer, and its description tells
;; the model not to raise that timeout unless it truly has to.
;;
;; `gptel-yatools--current-timeout' and `gptel-yatools--timeout-suspended' are
;; declared at the top of this file, see the comment there.
;;-------------------------------------------------------------------------
(defun gptel-yatools--resolve-timeout (value)
  "Return the timeout in seconds to use for one tool call.

VALUE is the TIMEOUT argument supplied by the model: a number, a
numeric string, or nil for the default.  Unusable values fall back on
`gptel-yatools-timeout', which itself falls back on 120 seconds when it
holds something that is not a number.  The result is always at least
one second."
  (gptel-yatools--coerce-integer
   value
   (gptel-yatools--coerce-integer (bound-and-true-p gptel-yatools-timeout) 120 1)
   1))

(defun gptel-yatools--timeout-note ()
  "Return the timeout paragraph appended to every tool description.

The model is the only one who can raise a timeout, so the note is
worded for it: the default is already generous, and a longer one
keeps Emacs busy for that long, which the user pays for."
  (format "\n\nTimeouts: this tool call is aborted if it runs longer than %s seconds. Passing a larger TIMEOUT argument is possible, but do not raise the timeout unless the task truly cannot be completed within the default -- a longer timeout means the user waits longer."
          (gptel-yatools--resolve-timeout nil)))

(defun gptel-yatools--timeout-arg ()
  "Return the optional TIMEOUT argument plist added to every tool."
  (list :name "timeout"
        :type "integer"
        :description
        (format "Optional maximum number of seconds this call may run. Omit it to use the default (%s seconds). Do not raise it unless the task genuinely needs more time than the default allows."
                (gptel-yatools--resolve-timeout nil))
        :optional t))

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

(defun gptel-yatools--description-base (description)
  "Return DESCRIPTION without the timeout note, or nil if it is not a string.

Stripping the note before it is re-added is what keeps repeated installs
from piling up copies of the same paragraph."
  (when (stringp description)
    (let ((pos (string-match "\n\nTimeouts: " description)))
      (if pos (substring description 0 pos) description))))

(defun gptel-yatools--refresh-timeout-notes ()
  "Rewrite the timeout text in every tool's description and TIMEOUT argument.

Kept separate from `gptel-yatools--install-timeout' so that changing
`gptel-yatools-timeout' during a session updates what the model is told
instead of leaving a stale number behind.  The tools are taken from this
package's own list, not from `gptel-tools': a tool that the user has not
enabled is not in `gptel-tools', but its description must still be
correct when it is enabled later."
  (dolist (tool gptel-yatools--tools)
    (let* ((desc (gptel-tool-description tool))
           (args (gptel-tool-args tool))
           (base (gptel-yatools--description-base desc))
           (last-arg (car (last args))))
      (when base
        (setf (gptel-tool-description tool)
              (concat base (gptel-yatools--timeout-note))))
      (when (equal (plist-get last-arg :name) "timeout")
        (setf (gptel-tool-args tool)
              (append (butlast args) (list (gptel-yatools--timeout-arg))))))))

(defun gptel-yatools--set-timeout (symbol value)
  "Set `gptel-yatools-timeout' to VALUE, updating the tool descriptions."
  (set-default symbol value)
  (gptel-yatools--refresh-timeout-notes))

(defcustom gptel-yatools-timeout 120
  "Maximum number of seconds a gptel tool call may run before it is aborted.

Every tool defined in this file takes an optional TIMEOUT argument
that overrides this for a single call; the tool descriptions tell the
model not to raise it unless the task truly needs more time.

Tool calls are synchronous, so this is also the longest a single
call can keep Emacs busy.  Time spent waiting for the user (for
example reviewing a `file_sync' diff) does not count."
  :type 'number
  :group 'gptel
  :set #'gptel-yatools--set-timeout)

(defun gptel-yatools--call-with-timeout (function args &optional timeout name)
  "Call FUNCTION with positional ARGS, aborting after TIMEOUT seconds.

TIMEOUT defaults to `gptel-yatools-timeout'; NAME labels the tool in the
error.  Returns FUNCTION's value, or signals `gptel-yatools-timeout-error'
with the seconds and tool name in its data when the deadline is hit.  A
timer is used rather than `with-timeout' so that time spent waiting for
the user (see `gptel-yatools--timeout-suspended') can be excluded, and
because `with-timeout' cannot interrupt `call-process' anyway.

Timers only run while Emacs waits for input, so this bounds calls that
block on I/O -- the case that matters -- but cannot interrupt a purely
CPU-bound Elisp form.

The timer can only `throw': a `signal' raised inside a timer callback is
consumed by Emacs's timer loop and the call would carry on running.  So
the timer throws a fresh marker, and the catch site re-signals it as the
condition the boundary renders."
  (let* ((timeout (gptel-yatools--resolve-timeout timeout))
         (gptel-yatools--current-timeout timeout)
         (tag (make-symbol "gptel-yatools-timeout"))
         (expired (list 'expired timeout name))
         (start (float-time))
         (paused 0.0)
         (pause-start nil)
         (timer (run-with-timer
                 0.2 0.2
                 (lambda ()
                   (if gptel-yatools--timeout-suspended
                       (unless pause-start
                         (setq pause-start (float-time)))
                     (when pause-start
                       (setq paused (+ paused (- (float-time) pause-start)))
                       (setq pause-start nil))
                     (when (> (- (float-time) start paused) timeout)
                       (throw tag expired)))))))
    (unwind-protect
        (let ((value (catch tag (apply function args))))
          (if (eq value expired)
              (signal 'gptel-yatools-timeout-error
                      (list :seconds timeout :tool name))
            value))
      (cancel-timer timer))))

(defun gptel-yatools--install-timeout (tool)
  "Give TOOL a TIMEOUT argument and a guard that aborts it when it expires.

The guard wraps the tool's function, so the tool definitions below
stay written in terms of their own arguments.  Installing twice on the
same tool changes nothing, and asynchronous tools are left untouched:
such a tool returns before its work is done, so a deadline around the
call could only report a timeout for work that is still running.
Returns TOOL."
  (if (gptel-tool-async tool)
      tool
    (let* ((args (gptel-tool-args tool))
           (installed (equal (plist-get (car (last args)) :name) "timeout")))
      (unless installed
        (let ((function (gptel-tool-function tool))
              (declared (length args))
              (tool-name (gptel-tool-name tool)))
          (setf (gptel-tool-args tool)
                (append args (list (gptel-yatools--timeout-arg))))
          (setf (gptel-tool-function tool)
                (lambda (&rest call-args)
                  ;; gptel passes one positional value per declared
                  ;; argument, and TIMEOUT is the last of them.
                  (let* ((has-timeout (= (length call-args)
                                         (1+ declared)))
                         (timeout (and has-timeout
                                       (car (last call-args)))))
                    (gptel-yatools--call-with-timeout
                     function
                     (if has-timeout (butlast call-args) call-args)
                     timeout tool-name))))))
      (setf (gptel-tool-description tool)
            (concat (string-trim-right
                     (or (gptel-yatools--description-base
                          (gptel-tool-description tool))
                         ""))
                    (gptel-yatools--timeout-note)))
      tool)))

(defun gptel-yatools--install-response (tool)
  "Make TOOL's function cross the tool boundary, and return TOOL.

The tool's own function keeps returning a `gptel-yatools-result'; the
wrapper installed here is what renders it, and what catches the errors
the function signals on the way out."
  (let ((function (gptel-tool-function tool))
        (name (gptel-tool-name tool)))
    (setf (gptel-tool-function tool)
          (lambda (&rest args)
            (gptel-yatools--call-tool name function args)))
    tool))

(defun gptel-yatools--make-tool (&rest slots)
  "Create a tool from SLOTS, register it, and put it behind the boundary.

SLOTS are the arguments of `gptel-make-tool'.  The tool is added to
gptel's registry, which is what `gptel-menu' lists, and comes back with
its TIMEOUT argument, its deadline guard and the response boundary
already installed: enabling a tool later needs no further work on it, and
creating one any other way is what would leave it without them.

An asynchronous tool is refused here rather than accepted and quietly
left outside the boundary: gptel calls such a tool with a callback and
the tool returns before its work is done, so there is no value for this
function to render.  This package defines none, and a tool that needs to
be asynchronous needs a different interface, not an exception."
  (let ((tool (apply #'gptel-make-tool slots)))
    (when (gptel-tool-async tool)
      (error "gptel-yatools: %s cannot be asynchronous: an asynchronous tool returns before its work is done, so its response cannot be rendered at the tool boundary"
             (gptel-tool-name tool)))
    (gptel-yatools--install-response
     (gptel-yatools--install-timeout tool))))

(defun gptel-yatools-enable-all ()
  "Add every tool defined by this package to `gptel-tools'."
  (interactive)
  (gptel-yatools-enable))

(defun gptel-yatools-enable (&rest categories-or-names)
  "Add some of this package's tools to `gptel-tools'.

CATEGORIES-OR-NAMES are tool categories, like \"filesystem\", tool
names, like \"write_file\", or nil for every tool.

Enabled tools are prepended to `gptel-tools' and replace any earlier
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


;;-------------------------------------------------------------------------
;; Tools
;;
;; The tools live in the module that owns their subject matter.  Each module
;; returns its own list already carrying the shared TIMEOUT argument and the
;; deadline guard, so this file only flattens them; `gptel-yatools-enable'
;; copies from the result, which is why it must exist before a chat is
;; started.
;;
;; The modules are required here, at the point where their tools are needed
;; and not before: they call `gptel-yatools--make-tool' and the helpers above,
;; so loading them earlier is not possible, and requiring them anywhere else
;; would only hide that.
;;-------------------------------------------------------------------------
(require 'gptel-yatools-vfs)
(require 'gptel-yatools-tools)
(require 'gptel-yatools-skills)

(setq gptel-yatools--tools
      (append (gptel-yatools-vfs--tools)
              (gptel-yatools-tools--tools)
              (list (gptel-yatools-skills--tool))))

(provide 'gptel-yatools)
;;; gptel-yatools.el ends here
