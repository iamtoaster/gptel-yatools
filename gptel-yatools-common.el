;;; gptel-yatools-common.el --- What every gptel-yatools tool is  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

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
;; A tool is three things, and `gptel-yatools-define-tool' writes all three
;; from one definition:
;;
;; 1. An implementation function, `NAME-tool', which takes the tool's
;;    arguments and returns a `gptel-yatools-result'.  It says what it
;;    found; it never formats, truncates or escapes anything.
;; 2. A boundary function, `NAME', which gptel calls.  It adds the optional
;;    TIMEOUT argument, enforces the deadline, renders the Result into the
;;    envelope the model sees, and turns a signalled error into that same
;;    envelope.
;; 3. The `gptel-tool' struct, registered in gptel's registry and in this
;;    package's own list.
;;
;; Both functions are named, so both can be advised, traced and found with
;; `C-h f'.  Advice on `NAME-tool' sees the tool's own arguments and can
;; rewrite its Result; advice on `NAME' sees everything, including the
;; deadline, and can stand in for the whole call.
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

;; Declared here so the functions below can refer to it; the `defcustom'
;; that gives it a value and a setter is further down, once the setter
;; exists -- `defcustom' calls its `:set' as it defines the variable.
(defvar gptel-yatools-timeout)

(defvar gptel-yatools--current-timeout nil
  "Deadline in seconds of the tool call in progress, or nil.

Bound by `gptel-yatools--call-with-timeout' so that helpers which can
block on their own (`gptel-yatools-shell--run-command') enforce the same
deadline instead of outliving it.")

(defvar gptel-yatools--timeout-suspended nil
  "Non-nil while the current tool call is waiting for the user.

Time spent in that state is not counted against the timeout, so a human
reading a `file_sync' diff for a few minutes cannot trip it.")

(defvar gptel-yatools--current-root nil
  "Workspace root of the tool call in progress, or nil.

Bound by `gptel-yatools--call-tool' so that everything a single call
does -- resolving the path the model wrote, displaying a path back to
it, finding the skill roots -- reads one root, settled once at the
boundary.  Otherwise a tool that rebinds `default-directory' mid-call
\(the shell runner does, to run in a subdirectory) changes what a
relative path means half way through, and a message printed afterwards
describes a different directory from the one the tool acted on.

This is the same shape as `gptel-yatools--current-timeout': a value the
boundary settles, so a helper cannot recompute a slightly different
ambient answer.")

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
This is how a tool module reports its own state next to the VFS pending
count without the module that draws the header line having to know about
it.

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
;; `gptel-yatools-vfs--key'), which is what stops a second tool from
;; quietly inventing a second base.
;;-------------------------------------------------------------------------
(defun gptel-yatools--workspace-root ()
  "Return the root every relative path of this package is resolved against.

Outside a tool call that is `project-current's root, or
`default-directory' when there is no project.  Inside one it is the root
captured at the boundary (see `gptel-yatools--current-root'), so a tool
that rebinds `default-directory' half way through still resolves and
renders paths against the root the call started in."
  (or gptel-yatools--current-root
      (gptel-yatools--detect-workspace-root)))

(defun gptel-yatools--detect-workspace-root ()
  "Return the workspace root implied by the current buffer, ignoring any pin.

Separate from `gptel-yatools--workspace-root' so that reading the pin
and computing a fresh answer are two different calls: the boundary needs
the fresh one, and a function that called the pinned one to get it would
never see the pin change."
  (let ((proj (project-current)))
    (if proj
        (file-name-as-directory (expand-file-name (project-root proj)))
      (file-name-as-directory (expand-file-name default-directory)))))

(defun gptel-yatools--resolve-path (path)
  "Return PATH as an absolute path, resolved against the workspace root.

This is where a path the model wrote becomes a path this package acts
on, and it is the only such place.  Everything past it takes absolute
paths, so what a relative path means is decided once, by the tool that
received it, rather than re-guessed by the VFS from whichever buffer
happens to be current."
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
                   ;; A pending file has no disk size yet; its bytes under
                   ;; `no-conversion' are the size it will be written at.
                   (condition-case nil
                       (string-bytes (encode-coding-string content 'no-conversion))
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
    (gptel-yatools-ok body :provenance (if from-vfs :vfs :disk)
                      :comment "Binary file; contents withheld.")))

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

(defun gptel-yatools--envelope (provenance comment body)
  "Return BODY wrapped in the tool context/response XML envelope.

PROVENANCE says where BODY came from: `:disk', `:vfs' or `:mixed' (see
`gptel-yatools--provenances').  It becomes the context tag's `vfs'
attribute, which is false only for a wholly-on-disk reply.
COMMENT is a short note shown to the LLM in the context tag.

Both COMMENT and BODY are sanitised with
`gptel-yatools--escape-raw-bytes' so that a response never carries
bytes that cannot be serialised for the model."
  (format "<tool_context vfs=\"%s\" comment=\"%s\"/>\n<tool_response>\n%s\n</tool_response>"
          (gptel-yatools--provenance-attr provenance)
          (gptel-yatools--xml-escape (gptel-yatools--escape-raw-bytes comment))
          (gptel-yatools--truncate body)))

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
;;   `gptel-yatools--page-text' is that budget, offered as a helper
;;   instead of a constant each tool reads directly.
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
(defconst gptel-yatools--provenances '(:disk :vfs :mixed)
  "The provenance values a `gptel-yatools-result' may carry.

:disk   every byte of the body is what is on disk.
:vfs    the body is pending virtual-filesystem state, not on disk yet.
:mixed  the body blends the two -- a directory listing that merges disk
        with VFS-only entries, for instance -- so the reply is neither
        a description of disk nor a description of pending changes.")

(defconst gptel-yatools--provenance-comments
  '((:disk . "This reply reflects the state of disk.")
    (:vfs . "\
This reply reflects pending changes in the virtual filesystem that are not on disk yet. Run the file_sync tool to persist them.")
    (:mixed . "\
This reply mixes pending virtual-filesystem changes with disk content: entries marked (pending) exist only in the VFS. Run the file_sync tool to persist them."))
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
;; Tool calls run synchronously inside gptel's request handler, so a tool
;; that blocks -- a hung shell command, a read from a FIFO -- blocks Emacs
;; itself.  Every tool therefore gets a deadline (120 seconds by default)
;; plus an optional TIMEOUT argument for the rare call that genuinely needs
;; longer, and that argument's description tells the model not to raise it
;; unless it truly has to.
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

(defun gptel-yatools--timeout-arg ()
  "Return the optional TIMEOUT argument plist added to every tool.

This is the only place the model is told about timeouts: one argument
description, stated once, naming the default and telling the model not
to raise it unless the work genuinely needs longer.  Saying the same
thing again at the end of every tool description was tried and dropped
-- it tripled the size of the whole tool interface and had to be
re-appended on every reload to stay in step with this one."
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

(defun gptel-yatools--refresh-timeout-arg ()
  "Rewrite the TIMEOUT argument's description in every tool.

Kept separate from registration so that changing
`gptel-yatools-timeout' during a session updates what the model is told
instead of leaving a stale number behind.  The tools are taken from this
package's own list, not from `gptel-tools': a tool that the user has not
enabled is not in `gptel-tools', but its argument must still be correct
when it is enabled later."
  (dolist (tool gptel-yatools--tools)
    (let ((args (gptel-tool-args tool)))
      (when (equal (plist-get (car (last args)) :name) "timeout")
        (setf (gptel-tool-args tool)
              (append (butlast args) (list (gptel-yatools--timeout-arg))))))))

(defun gptel-yatools--set-timeout (symbol value)
  "Set `gptel-yatools-timeout' to VALUE, updating the tool arguments."
  (set-default symbol value)
  (gptel-yatools--refresh-timeout-arg))

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
CPU-bound form.

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
                       (throw tag expired))
                     nil)))))
    (unwind-protect
        (let ((value (catch tag (apply function args))))
          (if (eq value expired)
              (signal 'gptel-yatools-timeout-error
                      (list :seconds timeout :tool name))
            value))
      (cancel-timer timer))))

(defun gptel-yatools--call-tool (name function args &optional timeout)
  "Call FUNCTION with positional ARGS and render the outcome for the model.

This is the tool boundary in one function: the deadline is enforced, the
Result is rendered into the envelope, and a signalled error, an expired
deadline and a tool that returned the wrong shape all become that same
envelope -- sized, truncated and escaped -- so the model never receives
bare text and never receives text that cannot be serialised back to JSON.

NAME labels the tool in a timeout message.  TIMEOUT is the call's own
deadline, or nil for `gptel-yatools-timeout'.

The workspace root is settled here, once, and pinned for the whole call
\(see `gptel-yatools--current-root'), so a tool that rebinds
`default-directory' -- the shell runner, to run in a subdirectory --
cannot change what a later relative path or message means.

`quit' passes through untouched, and so does anything the user asked to
debug: `condition-case-unless-debug' leaves the signal alone while
`debug-on-error' is set."
  (let ((gptel-yatools--current-root (gptel-yatools--detect-workspace-root)))
    (condition-case-unless-debug err
        (gptel-yatools--respond
         (gptel-yatools--call-with-timeout function args timeout name))
      (gptel-yatools-timeout-error
       (gptel-yatools--envelope
        :disk "Tool call timed out."
        (gptel-yatools--timeout-message (plist-get (cdr err) :seconds)
                                        (or (plist-get (cdr err) :tool) name))))
      (error
       (gptel-yatools--envelope
        :disk "The tool reported an error."
        (format "Error: %s" (gptel-yatools--error-text err)))))))

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
;; Defining a tool
;;-------------------------------------------------------------------------
(defun gptel-yatools--register-tool (&rest slots)
  "Create a tool from SLOTS and register it, returning the tool.

SLOTS are the arguments of `gptel-make-tool', with the TIMEOUT argument
appended: every tool this package defines takes one, so it is added here
rather than repeated in each definition.

The tool is added to gptel's registry, which is what `gptel-menu' lists,
and to `gptel-yatools--tools', replacing an earlier tool of the same name
in place.  Replacing in place is what lets one tool module be reloaded
without reordering the list the rest of the package reads.

An asynchronous tool is refused rather than accepted and quietly left
outside the boundary: gptel calls such a tool with a callback and the
tool returns before its work is done, so there is no Result for the
boundary to render.  This package defines none, and a tool that needs to
be asynchronous needs a different interface, not an exception."
  (let* ((slots (plist-put slots :args
                           (append (plist-get slots :args)
                                   (list (gptel-yatools--timeout-arg)))))
         (tool (apply #'gptel-make-tool slots))
         (name (gptel-tool-name tool)))
    (when (gptel-tool-async tool)
      (error "gptel-yatools: %s cannot be asynchronous: an asynchronous tool returns before its work is done, so its response cannot be rendered at the tool boundary"
             name))
    (let ((existing (cl-position name gptel-yatools--tools
                                 :key #'gptel-tool-name :test #'equal)))
      (if existing
          (setf (nth existing gptel-yatools--tools) tool)
        (setq gptel-yatools--tools
              (append gptel-yatools--tools (list tool)))))
    tool))

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

(defun gptel-yatools--tool-docstring (name category description arg-specs)
  "Return the docstring for a tool's boundary function.

NAME is the tool's name as the model sees it, CATEGORY is its category,
DESCRIPTION is the description the model is given, and ARG-SPECS are the
declared arguments; the TIMEOUT argument every tool takes is added.

The description is the same text the model reads, so `C-h f' answers what
this function is for with the words the tool was written in, and cannot
drift from them: both come from one definition."
  (let* ((description (string-trim (or description "")))
         ;; Promote the first sentence to a summary line, when it fits, so
         ;; `C-h f' and `apropos' have something to show.  The rest of the
         ;; description follows it, so nothing is said twice.
         (split (and (string-match "\\`\\([^.]\\{1,70\\}\\.\\)\\s-+\\(.+\\)\\'"
                                   description)
                     (list (match-string 1 description)
                           (match-string 2 description))))
         (summary (or (car-safe split) description))
         (rest (cadr split))
         (args (append arg-specs (list (gptel-yatools--timeout-arg)))))
    (mapconcat
     #'identity
     (delq nil
           (list
            (gptel-yatools--fill-text summary)
            (gptel-yatools--fill-text rest)
            (gptel-yatools--arg-lines args)
            (gptel-yatools--fill-text
             (format "Tool `%s' (category: %s). This is the description the model is given, and the call the model makes: this function adds the deadline, renders the Result and reports errors. Defined by `gptel-yatools-define-tool', which see."
                     name category))))
     "\n\n")))

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

The tool itself is registered in gptel's registry -- which is what
`gptel-menu' lists -- and in `gptel-yatools--tools'.  Nothing is sent to
the model until `gptel-yatools-enable' adds it to `gptel-tools'.

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
           (arg-specs (if (and (consp args-form) (eq (car args-form) 'quote))
                          (cadr args-form)
                        args-form))
           (body rest)
           (doc (gptel-yatools--tool-docstring
                 name category description arg-specs))
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
           (impl (intern (format "%s-tool" symbol)))
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
         (defun ,symbol ,boundary-params
           ,doc
           (gptel-yatools--call-tool ,name #',impl
                                     (list ,@param-names)
                                     timeout))
         (gptel-yatools--register-tool
          :name ,name
          :category ,category
          :description ,description
          ;; Copied because `gptel-make-tool' rewrites the :type symbols in
          ;; place, and a quoted literal in compiled code is not ours to
          ;; modify.
          :args (copy-tree ',arg-specs)
          :function #',symbol
          ,@(when (plist-get plist :confirm)
              (list :confirm (plist-get plist :confirm))))
         ',symbol))))

;;-------------------------------------------------------------------------
;; Enabling
;;-------------------------------------------------------------------------
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

(provide 'gptel-yatools-common)
;;; gptel-yatools-common.el ends here
