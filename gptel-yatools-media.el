;;; gptel-yatools-media.el --- Showing a model an image it asked for  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; An image cannot be read as text, but a model that can see one does not
;; need it described.  This module is the path between the two: a read tool
;; hands it the path of a file it would otherwise refuse as binary, and if
;; the bytes are a supported image the file is attached to the conversation
;; instead of being refused.
;;
;; An attached image has two lifetimes, and they are different problems:
;;
;; The turn it was asked for.  gptel builds a request's payload once, before
;; the request is sent, and a tool call happens after that -- so an image
;; attached during a tool call is in no request at all until the next one is
;; built from the buffer.  The model would be told "attached" and see
;; nothing.  `gptel-yatools-media--pending' is the answer: the images
;; attached during a request, drained into that request's payload just
;; before it is sent again (`gptel-yatools-media-deliver', called from the
;; advice in `gptel-yatools.el').
;;
;; The rest of the chat.  A `gptel-context' entry of the form
;; \(PATH :mime MIME) is what gptel itself uses to send a file as media, and
;; an entry travels with every later request until it is removed.  So the
;; image stays visible to a model reasoning about it across several turns,
;; and the price of that is re-sending it: `gptel-yatools-media-forget' is
;; how the user stops paying.
;;
;; What the bytes are is decided by the bytes, not by the file name: a
;; screenshot saved without an extension is an image, and a text file
;; renamed to `.png' is not one.  Whether the model can be shown it is
;; gptel's question, asked of gptel's own model metadata so that no model
;; is ever sent a MIME type it does not claim to accept.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'gptel)
(require 'gptel-yatools-common)

(declare-function gptel-context--collect-media "gptel-context" (&optional contexts))
(declare-function gptel-context--buffer-setup "gptel-context")

(defcustom gptel-yatools-media-size-limit (* 5 1024 1024)
  "Largest image, in bytes, that a read tool will attach to the conversation.

A provider rejects an image it considers too large, and it rejects it as a
failed request: the whole turn is lost, and the tool call that read the
file looks like it succeeded.  Refusing here instead costs the model one
sentence and keeps the conversation alive.

Zero, or nil, removes the limit.  That is the setting to choose on a
backend whose image limits are enforced on its own side, or when the
model accepts a format whose size cannot be predicted."
  :type '(choice (const :tag "No limit" 0) integer)
  :group 'gptel-yatools)

(defconst gptel-yatools-media--head-bytes 16
  "How many bytes of a file are examined to decide whether it is an image.

Sixteen covers the longest signature below -- \"RIFF\", a four-byte size
and \"WEBP\" -- with room to spare, and it is small enough that asking for
it over a remote connection is one short command.")

(defun gptel-yatools-media--head (path)
  "Return the first `gptel-yatools-media--head-bytes' bytes of PATH.

The bytes are returned as a unibyte string, exactly as stored: a
signature is a sequence of bytes, and decoding it as text would turn a
JPEG header into `raw-text' soup that no `string-prefix-p' can match.
An unreadable file yields the empty string, which matches no signature."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path nil 0 gptel-yatools-media--head-bytes)
        (buffer-string))
    (file-error "")))

(defun gptel-yatools-media--signature-type (head)
  "Return the MIME type the bytes in HEAD begin, or nil for none of them.

This is the whole of the format policy, in one place: the four formats
every multimodal provider accepts, recognized by their own first bytes.
The name of the file is not consulted -- a screenshot has none worth
trusting, and a renamed text file has one that lies."
  (when head
    (cond
     ((string-prefix-p "\211PNG\r\n\032\n" head) "image/png")
     ((string-prefix-p "\377\330\377" head) "image/jpeg")
     ((string-prefix-p "GIF87a" head) "image/gif")
     ((string-prefix-p "GIF89a" head) "image/gif")
     ((and (>= (length head) 12)
           (string-prefix-p "RIFF" head)
           (equal (substring head 8 12) "WEBP"))
      "image/webp"))))

(defun gptel-yatools-media--head-from-text (text)
  "Return the first bytes of TEXT, or nil when they cannot be bytes.

TEXT is what a read returned, and the point of this function is that a
caller which has just read a file should not read it again to find out
what it is -- over TRAMP that is a second command and a second wait.
Note that \"nil\" here means \"not an image\" and not \"unknown\": an
image's first bytes are a byte sequence, so a string whose first
characters are not representable as bytes cannot begin with one."
  (let ((head (substring text 0 (min gptel-yatools-media--head-bytes
                                     (length text)))))
    (if (multibyte-string-p head)
        (ignore-errors (string-to-unibyte head))
      head)))

(defun gptel-yatools-media-type (path &optional head)
  "Return the MIME type of the image at PATH, or nil when it is not one.

HEAD, when given, is PATH's first bytes as the caller already has them;
without it they are read from disk.  See
`gptel-yatools-media--head-from-text'."
  (gptel-yatools-media--signature-type
   (or head (gptel-yatools-media--head path))))

(defun gptel-yatools-media-supported-p (mime &optional model)
  "Return non-nil when MODEL can be shown media of MIME type MIME.

MODEL defaults to the backend in use.  Both questions are gptel's own and
are asked of gptel's model metadata: can the model take media at all, and
does it list this MIME type.  A model that would have to be told about an
image it cannot see is better answered with the text a binary file gets."
  (and (fboundp 'gptel--model-capable-p)
       (gptel--model-capable-p 'media model)
       (gptel--model-mime-capable-p mime model)))

(defun gptel-yatools-media--size (path)
  "Return the size of PATH in bytes, or nil when it cannot be asked."
  (file-attribute-size (file-attributes path)))

;;;; The attached images of a buffer

(defvar-local gptel-yatools-media--pending nil
  "Images attached to this buffer's conversation, not yet delivered.

Each entry is a `gptel-context' media spec, (PATH :mime MIME ...).  The
list belongs to one request: it is drained when that request is sent
again (`gptel-yatools-media-deliver') and cleared when a new request is
built from this buffer, so an image can be delivered in at most one
place.

Buffer-local for the same reason the VFS is: a chat's images are the
chat's, and a subagent is a different conversation that happens to run in
the same Emacs.")

(defconst gptel-yatools-media--tag :gptel-yatools-media
  "Key marking a `gptel-context' entry as one this package attached.

A user's own media entries are theirs: `gptel-yatools-media-forget'
removes only the tagged ones, and the header-line label counts only
them.")

(defun gptel-yatools-media--tagged-entries ()
  "Return the buffer's `gptel-context' entries that this package attached.

The entries themselves are returned, not their paths: they are what has to
be removed, and rebuilding one from a path would be a guess at the MIME
type it was attached with."
  (seq-filter (lambda (source)
                (plist-get (cdr-safe (ensure-list source))
                           gptel-yatools-media--tag))
              gptel-context))

(defun gptel-yatools-media-attached (&optional buffer)
  "Return the paths of the images this package attached in BUFFER.

BUFFER defaults to the current buffer.  The entries are read out of the
buffer's effective `gptel-context', so what is reported is what gptel will
actually send -- removing an entry through gptel's own commands removes it
from this list too."
  (with-current-buffer (or buffer (current-buffer))
    (mapcar (lambda (entry) (car (ensure-list entry)))
            (gptel-yatools-media--tagged-entries))))

(defun gptel-yatools-media--remember (path mime)
  "Attach PATH, of MIME type MIME, to this buffer's conversation.

Two things are recorded, for the two lifetimes in the Commentary: the
pending queue, which delivers the image to the request being answered,
and the `gptel-context' entry, which keeps it visible to the turns after
that.

The context is made buffer-local on the way, so an image read in one chat
does not appear in every other one.  gptel's own commands mutate whichever
binding is in effect, so a later `gptel-add' in this buffer still lands
where the user can see it.  An existing entry for the same path is
replaced rather than duplicated: two entries for one file would send it
twice and be counted twice."
  (let ((entry (list path :mime mime gptel-yatools-media--tag t)))
    (setq-local gptel-context
                (cons entry
                      (seq-remove (lambda (source)
                                    (equal (car-safe (ensure-list source)) path))
                                  gptel-context)))
    (setq gptel-yatools-media--pending
          (cons entry (seq-remove (lambda (old)
                                    (equal (car-safe old) path))
                                  gptel-yatools-media--pending)))
    entry))

(defun gptel-yatools-media-forget (&optional buffer)
  "Remove the images this package attached from BUFFER's conversation.

BUFFER defaults to the current buffer.  Only this package's own entries
are removed: a file the user added to the context themselves, even the
same file, is left alone.  The images stay on disk -- what stops is
paying for them again on every request.

This is gptel's context list being edited, so gptel shows and removes the
same entries its own way: the `[N files]' label in the header line opens
the context buffer, where each attached image is listed and can be removed
one at a time.  This command is the same thing for \"all of the images this
package attached, and nothing else\"."
  (interactive)
  (let ((paths (gptel-yatools-media-attached buffer)))
    (cond
     ((null paths)
      (when (called-interactively-p 'interactive)
        (message "gptel: no attached images to forget")))
     (t
      (with-current-buffer (or buffer (current-buffer))
        (setq-local gptel-context
                    (seq-difference gptel-context
                                    (gptel-yatools-media--tagged-entries)))
        (setq gptel-yatools-media--pending nil))
      (when (called-interactively-p 'interactive)
        (message "gptel: forgot %d attached image(s): %s"
                 (length paths)
                 (mapconcat #'gptel-yatools--display-path paths ", ")))))))

;;;; Attaching

(defun gptel-yatools-media--too-large (path size mime)
  "Return the outcome plist for an image too large to attach.

PATH, SIZE and MIME describe the file; SIZE is in bytes.  The message
names the file, its size and the limit, so the model can report the
decision rather than guess at it, and points at the tools that can still
say something useful about the file."
  (let ((name (gptel-yatools--display-path path)))
    (list :kind :refused
          :mime mime
          :size size
          :comment "Image not attached: it is larger than the limit."
          :message
          (format "\
%s is an image (%s, %d bytes), which is larger than the %d-byte limit \
on images that can be attached to this conversation, so it was not \
attached and nothing was read.

The limit is the variable `gptel-yatools-media-size-limit'; set it to 0 \
to remove it.  Do not try to read the file as text.  To learn something \
about it without the image itself, use execute_command, for example:

  file %s
  identify %s"
                  name mime size gptel-yatools-media-size-limit name name))))

(defun gptel-yatools-media--unsupported (path mime)
  "Return the outcome plist for an image this model cannot be shown.

PATH and MIME describe the file.  The refusal is honest about which side
said no -- the model, not the file -- because the remedy is different: the
file is fine, and a model that accepts MIME can see it."
  (let ((name (gptel-yatools--display-path path)))
    (list :kind :refused
          :mime mime
          :comment "Image not attached: this model does not accept it."
          :message
          (format "\
%s is an image (%s) but the model in use does not accept that media \
type, so it was not attached and nothing was read.  Selecting a model \
that can see images would let this work; until then the file's contents \
cannot be shown.  Use execute_command if its metadata would help:

  file %s"
                  name mime name))))

(defun gptel-yatools-media--attached-outcome (path size mime)
  "Return the outcome plist for the image at PATH now attached.

PATH, SIZE and MIME describe the file; SIZE is in bytes.  The message
says what happened in terms the model can act on: the image is visible
from now on, it is not text, and it will keep being visible until it is
removed -- which is also a warning that its cost recurs."
  (let ((name (gptel-yatools--display-path path)))
    (list :kind :attached
          :mime mime
          :size size
          :comment "Image attached to the conversation; nothing was read as text."
          :message
          (format "\
%s is an image (%s, %d bytes).  It has been attached to this \
conversation and you can see it now, in this reply and in the turns that \
follow; its bytes are not text and are not returned.

It stays attached -- and is sent again on every request -- until the user \
removes it with M-x gptel-yatools-media-forget.  Say so if the image turns \
out not to be what was needed, so that it is not paid for twice."
                  name mime size))))

(defun gptel-yatools-media-attach (path &optional head size)
  "Attach the image at PATH to this buffer's conversation, if it is one.

PATH must be absolute; resolution belongs at the tool's edge.

HEAD and SIZE, when given, are what the caller already knows about PATH --
its first bytes and its length in bytes.  A read tool has both, having
just read the file, and they are worth passing: in a remote workspace
every question is a command and a wait, and asking what the file starts
with once more would be a second one for an answer already in hand.

The value is nil when PATH is not an image this model can be shown -- not
an image at all, or one whose MIME type the model does not accept -- and
a plist saying what happened otherwise:

  :kind     `:attached', or `:refused' when the image was found but not
            attached (its size, or the model's limits).
  :mime     the type the bytes were recognized as.
  :size     the file's size in bytes, when it could be asked.
  :message  what to tell the model, in the envelope's terms.
  :comment  the envelope's one-line comment.

A nil value is not an error: \"this is not an image\" is the caller's
answer to give, and `read_path' gives it by falling back to the text and
binary paths it already has."
  (let* ((head (or head
                   (and (file-regular-p path) (gptel-yatools-media--head path))))
         (mime (gptel-yatools-media--signature-type head))
         (size (and mime
                    (or size
                        (and (file-regular-p path)
                             (gptel-yatools-media--size path))))))
    (when (and mime size)
      (cond
       ((not (gptel-yatools-media-supported-p mime))
        (gptel-yatools-media--unsupported path mime))
       ((and gptel-yatools-media-size-limit
             (> gptel-yatools-media-size-limit 0)
             (> size gptel-yatools-media-size-limit))
        (gptel-yatools-media--too-large path size mime))
       (t
        (require 'gptel-context)
        (gptel-yatools-media--remember path mime)
        (gptel-yatools-media--attached-outcome path size mime))))))

;;;; Delivery

(defconst gptel-yatools-media--message-keys '(:messages :input :contents)
  "Keys a backend keeps its array of turns under, in the order tried.

Each is one gptel backend's name for the same thing: `:messages' for the
chat-completions shape (OpenAI, Anthropic, Ollama), `:input' for the
Responses API, `:contents' for Gemini.  Nothing here writes a content
block itself -- the backend's own `gptel--inject-media' method is asked to,
so the shape of the block and where the media goes inside the message
remain gptel's business.")

(defun gptel-yatools-media--conversation (data)
  "Return the array of turns in DATA, a gptel request payload, or nil."
  (seq-some (lambda (key) (plist-get data key)) gptel-yatools-media--message-keys))

(defun gptel-yatools-media--tool-results-p (message)
  "Return non-nil when MESSAGE carries tool results rather than a prompt.

The Anthropic API requires a message holding tool results to start with
them, so media prepended to one would be a malformed request.  A message
like that is not the user's prompt anyway; the prompt it answers is."
  (let ((content (or (plist-get message :content) (plist-get message :parts))))
    (and (vectorp content)
         (seq-some (lambda (part)
                     (member (plist-get part :type)
                             '("tool_result" "functionResponse")))
                   content))))

(defun gptel-yatools-media--first-message (data)
  "Return the first message from the user in DATA that is a prompt, or nil.

Skipping the tool-result messages is what keeps the image out of a place
the provider would reject; when every user message in DATA is one, the
image waits for the next request, where `gptel-context' delivers it."
  (let ((messages (gptel-yatools-media--conversation data)))
    (seq-find (lambda (message)
                (and (listp message)
                     (equal (plist-get message :role) "user")
                     (not (gptel-yatools-media--tool-results-p message))))
              (append messages nil))))

(defun gptel-yatools-media-deliver (backend data entries)
  "Add ENTRIES to DATA, the payload of a request built for BACKEND.

ENTRIES is a list of `gptel-context' media specs, (PATH :mime MIME).
DATA is what `gptel--request-data' built; it is the one thing a tool call
can still reach, since gptel builds it before the request is sent and
sends the same payload again after tool results come back.

The media is prepended to the first message the user wrote, which is
where gptel itself puts the media it carries in `gptel-context'.  Appending
it as a message of its own would be easier and would put the image after
a tool result, separated from the call it answers.

Return non-nil when something was delivered."
  (when-let* ((entries)
              (message (gptel-yatools-media--first-message data)))
    (require 'gptel-context)
    ;; The method reads the context; binding it to these entries and
    ;; nothing else is what keeps a request's earlier images out of this
    ;; delivery -- they are already in the payload.
    (let ((gptel-context entries))
      (gptel--inject-media backend (list message)))
    t))

;;;; No header-line label

;; gptel already counts what is in `gptel-context', in a label of its own:
;; `[1 file]', clickable, opening the context buffer where each entry can be
;; inspected and removed.  Attaching an image puts an ordinary context entry
;; there, so that label already says the image is attached, and adding a
;; second counter for a subset of the same list would claim a concept gptel
;; owns -- right next to gptel's own `[Media: No]', which is a different
;; feature again (`gptel-track-media': whether links in the buffer text are
;; followed).  Two neighbouring labels about "media", disagreeing, is worse
;; than no label.

(provide 'gptel-yatools-media)
;;; gptel-yatools-media.el ends here
