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

A provider rejects an image it considers too large by failing the whole
request, so the size is refused here instead.

Zero or nil removes the limit."
  :type '(choice (const :tag "No limit" 0) integer)
  :group 'gptel-yatools)

(defconst gptel-yatools-media--head-bytes 16
  "How many bytes of a file are examined to decide whether it is an image.")

(defun gptel-yatools-media--head (path)
  "Return the first `gptel-yatools-media--head-bytes' bytes of PATH.

A unibyte string, exactly as stored.  An unreadable file yields \"\", which
matches no signature."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path nil 0 gptel-yatools-media--head-bytes)
        (buffer-string))
    (file-error "")))

(defun gptel-yatools-media--signature-type (head)
  "Return the MIME type the bytes in HEAD begin, or nil for none of them.

PNG, JPEG, GIF and WebP, recognized by their first bytes.  The file name
is not consulted."
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
  "Return the first bytes of TEXT as a unibyte string, or nil.

For a caller that has already read a file and should not read it again.
Nil means the characters cannot be bytes, so TEXT cannot begin with an
image signature."
  (let ((head (substring text 0 (min gptel-yatools-media--head-bytes
                                     (length text)))))
    (if (multibyte-string-p head)
        (ignore-errors (string-to-unibyte head))
      head)))

(defun gptel-yatools-media-type (path &optional head)
  "Return the MIME type of the image at PATH, or nil when it is not one.

HEAD, when given, is PATH's first bytes from
`gptel-yatools-media--head-from-text'; otherwise they are read from disk."
  (gptel-yatools-media--signature-type
   (or head (gptel-yatools-media--head path))))

(defun gptel-yatools-media-supported-p (mime &optional model)
  "Return non-nil when MODEL can be shown media of MIME type MIME.

MODEL defaults to the current `gptel-model'.  Asks gptel's model metadata
whether the model takes media at all and whether it lists MIME."
  (and (fboundp 'gptel--model-capable-p)
       (gptel--model-capable-p 'media model)
       (gptel--model-mime-capable-p mime model)))

(defun gptel-yatools-media--size (path)
  "Return the size of PATH in bytes, or nil when it cannot be asked."
  (file-attribute-size (file-attributes path)))

;;;; The attached images of a buffer

(defvar-local gptel-yatools-media--pending nil
  "Images attached to this buffer's conversation, not yet delivered.

Each entry is a `gptel-context' media spec, (PATH :mime MIME ...).  Drained
by `gptel-yatools-media-deliver' into the request being answered, and
cleared when a new request is built from this buffer.")

(defconst gptel-yatools-media--tag :gptel-yatools-media
  "Key marking a `gptel-context' entry as one this package attached.")

(defun gptel-yatools-media--tagged-entries ()
  "Return the buffer's `gptel-context' entries that this package attached.

The entries themselves, since they are what has to be removed."
  (seq-filter (lambda (source)
                (plist-get (cdr-safe (ensure-list source))
                           gptel-yatools-media--tag))
              gptel-context))

(defun gptel-yatools-media-attached (&optional buffer)
  "Return the paths of the images this package attached in BUFFER.

BUFFER defaults to the current buffer.  Read from the buffer's effective
`gptel-context', so entries removed through gptel's own commands are not
listed."
  (with-current-buffer (or buffer (current-buffer))
    (mapcar (lambda (entry) (car (ensure-list entry)))
            (gptel-yatools-media--tagged-entries))))

(defun gptel-yatools-media--remember (path mime)
  "Attach PATH, of MIME type MIME, to this buffer's conversation.

Records the image twice: in `gptel-yatools-media--pending' for the request
being answered, and in a tagged buffer-local `gptel-context' entry for the
turns after it.  An existing entry for PATH is replaced, not duplicated."
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

BUFFER defaults to the current buffer.  Leaves entries the user added
themselves alone.  gptel's `[N files]' label lists the same entries and
removes them one at a time; this command takes all of this package's and
nothing else."
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
  "Return the :refused outcome for an image larger than the limit.

PATH, SIZE (in bytes) and MIME describe the file.  The message names the
file, its size and the limit."
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
  "Return the :refused outcome for an image this model cannot be shown.

PATH and MIME describe the file, which is a valid image; the model is what
does not accept it."
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
  "Return the :attached outcome for the image at PATH.

PATH, SIZE (in bytes) and MIME describe the file.  The message says the
image is visible from now on, and that it stays attached until removed."
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

PATH must be absolute.  HEAD and SIZE, when given, are its first bytes
\(`gptel-yatools-media--head-from-text') and its length, which spares a
caller that has just read the file a second disk read.

Returns nil when PATH is not an image this model can be shown, and
otherwise a plist:

  :kind     `:attached', or `:refused' (size limit or model limits).
  :mime     the type the bytes were recognized as.
  :size     the file's size in bytes.
  :message  what to tell the model.
  :comment  the envelope's one-line comment."
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

`:messages' for the chat-completions shape, `:input' for the Responses API,
`:contents' for Gemini.")

(defun gptel-yatools-media--conversation (data)
  "Return the array of turns in DATA, a gptel request payload, or nil."
  (seq-some (lambda (key) (plist-get data key)) gptel-yatools-media--message-keys))

(defun gptel-yatools-media--tool-results-p (message)
  "Return non-nil when MESSAGE carries tool results rather than a prompt.

The Anthropic API requires a tool-result message to start with them, so
media must not be prepended to one."
  (let ((content (or (plist-get message :content) (plist-get message :parts))))
    (and (vectorp content)
         (seq-some (lambda (part)
                     (member (plist-get part :type)
                             '("tool_result" "functionResponse")))
                   content))))

(defun gptel-yatools-media--first-message (data)
  "Return the first user message in DATA that is a prompt, or nil.

Tool-result messages are skipped."
  (let ((messages (gptel-yatools-media--conversation data)))
    (seq-find (lambda (message)
                (and (listp message)
                     (equal (plist-get message :role) "user")
                     (not (gptel-yatools-media--tool-results-p message))))
              (append messages nil))))

(defun gptel-yatools-media-deliver (backend data entries)
  "Add the media ENTRIES to DATA, the payload built for BACKEND.

ENTRIES is a list of `gptel-context' media specs, (PATH :mime MIME).  The
media goes into the first user prompt in DATA, through BACKEND's own
`gptel--inject-media', so the content block is the shape the backend
expects.

Returns non-nil when something was delivered."
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

;; gptel's own `[N files]' label already counts these entries and opens the
;; context buffer where they can be removed, and its `[Media: ...]' label is
;; a different feature.  See ADR 0008.

(provide 'gptel-yatools-media)
;;; gptel-yatools-media.el ends here
