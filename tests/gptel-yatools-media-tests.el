;;; gptel-yatools-media-tests.el --- Tests for the media module  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2026  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The media module answers three questions and the tests are grouped by
;; them: is this file an image (and one this model accepts), does the read
;; tool attach it instead of refusing it, and does the image get into the
;; payload of the request that asked for it.
;;
;; Nothing here talks to a provider.  The payload is built the way gptel
;; builds it -- a plist under `:messages' -- and handed to
;; `gptel-yatools-media-deliver', which is where the media has to land.

;;; Code:

(require 'ert)
(require 'gptel-yatools-test-lib)

;;;; Fixtures

(defconst gptel-yatools-media-test--png
  (concat (unibyte-string 137 80 78 71 13 10 26 10)
          (unibyte-string 0 0 0 13 73 72 68 82)
          (make-string 4 0))
  "Bytes that begin like a PNG and are not valid one further in.

The module decides what a file is from its first bytes, so a header is
all a fixture needs.")

(defconst gptel-yatools-media-test--jpeg
  (concat (unibyte-string 255 216 255 224) (make-string 8 0))
  "Bytes that begin like a JPEG.")

(defconst gptel-yatools-media-test--gif
  (concat (unibyte-string 71 73 70 56 57 97) (make-string 8 0))
  "Bytes that begin like a GIF.")

(defconst gptel-yatools-media-test--webp
  (concat (unibyte-string 82 73 70 70) ;RIFF
          (unibyte-string 36 0 0 0)    ;a size
          (unibyte-string 87 69 66 80) ;WEBP
          (make-string 4 0))
  "Bytes that begin like a WebP.")

(defun gptel-yatools-media-test--model (&optional capabilities mime-types)
  "Return a model symbol that has CAPABILITIES and accepts MIME-TYPES.

gptel keeps a model's capabilities and MIME types as symbol properties,
which is all `gptel--model-capable-p' and its MIME sibling consult -- so a
fresh symbol is a model, without a backend or a network."
  (let ((model (make-symbol "test-media-model")))
    (put model :capabilities (or capabilities '(media tool-use)))
    (put model :mime-types (or mime-types
                               '("image/png" "image/jpeg" "image/gif" "image/webp")))
    model))

(defmacro gptel-yatools-media-test--with-buffer (&rest body)
  "Run BODY in a buffer whose model can see images.

The buffer is a `gptel-context' away from being a chat, which is what the
module reads: a buffer-local context list, a model with media
capabilities, and the buffer-local queue."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq-local gptel-context nil)
     (setq-local gptel-model (gptel-yatools-media-test--model))
     (setq gptel-yatools-media--pending nil)
     ,@body))

(defun gptel-yatools-media-test--context-props (path)
  "Return the properties of the buffer's `gptel-context' entry for PATH.

A context entry is PATH followed by its properties, so the properties are
its cdr -- which is how gptel itself reads them."
  (let ((source (seq-find (lambda (entry)
                            (equal (car-safe (ensure-list entry)) path))
                          gptel-context)))
    (cdr-safe (ensure-list source))))

;;;; 1. What the bytes are

(ert-deftest gptel-yatools-test-media-type-is-decided-by-the-bytes ()
  "Each supported format must be recognized from its own first bytes."
  (gptel-yatools-test--in-dir
    (let ((png (gptel-yatools-test--root-file "a.png"))
          (jpeg (gptel-yatools-test--root-file "b.bin"))
          (gif (gptel-yatools-test--root-file "c.dat"))
          (webp (gptel-yatools-test--root-file "d.thing")))
      (gptel-yatools-test--write png gptel-yatools-media-test--png)
      (gptel-yatools-test--write jpeg gptel-yatools-media-test--jpeg)
      (gptel-yatools-test--write gif gptel-yatools-media-test--gif)
      (gptel-yatools-test--write webp gptel-yatools-media-test--webp)
      (should (equal (gptel-yatools-media-type png) "image/png"))
      (should (equal (gptel-yatools-media-type jpeg) "image/jpeg"))
      (should (equal (gptel-yatools-media-type gif) "image/gif"))
      (should (equal (gptel-yatools-media-type webp) "image/webp")))))

(ert-deftest gptel-yatools-test-media-type-ignores-the-name ()
  "A name proves nothing in either direction.

A screenshot is often saved without an extension, and a text file is
sometimes renamed to `.png'.  Both are decided by the bytes."
  (gptel-yatools-test--in-dir
    (let ((named-png (gptel-yatools-test--root-file "lie.png"))
          (unnamed (gptel-yatools-test--root-file "screenshot"))
          (text (gptel-yatools-test--root-file "plain.txt")))
      (gptel-yatools-test--write named-png "just some text\n")
      (gptel-yatools-test--write unnamed gptel-yatools-media-test--png)
      (gptel-yatools-test--write text "hello\n")
      (should-not (gptel-yatools-media-type named-png))
      (should (equal (gptel-yatools-media-type unnamed) "image/png"))
      (should-not (gptel-yatools-media-type text))
      ;; A path that does not exist is not an image, and does not signal.
      (should-not (gptel-yatools-media-type
                   (gptel-yatools-test--root-file "absent.png"))))))

;;;; 2. What the model accepts

(ert-deftest gptel-yatools-test-media-attach-needs-a-capable-model ()
  "An image must not be attached for a model that does not claim it.

The refusal is the module's, not the file's: the file is a perfectly good
image, and the message says so, because the remedy is to use a model that
can see it."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (with-temp-buffer
        (setq-local gptel-context nil)
        ;; A model with no media capability at all: not an image it can see.
        (setq-local gptel-model
                    (gptel-yatools-media-test--model '(tool-use)))
        (should (eq (plist-get (gptel-yatools-media-attach file) :kind)
                    :refused))
        ;; Media, but not this type.
        (setq-local gptel-model
                    (gptel-yatools-media-test--model '(media) '("image/jpeg")))
        (let ((outcome (gptel-yatools-media-attach file)))
          (should (eq (plist-get outcome :kind) :refused))
          (should (string-match-p "image/png" (plist-get outcome :message))))
        ;; Nothing was remembered for a model that cannot see it.
        (should-not gptel-context)
        (should-not gptel-yatools-media--pending)))))

(ert-deftest gptel-yatools-test-media-attach-records-both-lifetimes ()
  "Attaching must queue the image for this request and keep it for the next.

The queue is what gets the image into the request being answered, and the
context entry is what keeps it visible afterwards.  One without the other
is the bug this module exists to avoid."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (let ((outcome (gptel-yatools-media-attach file)))
          (should (eq (plist-get outcome :kind) :attached))
          (should (equal (plist-get outcome :mime) "image/png"))
          (should (= (plist-get outcome :size)
                     (length gptel-yatools-media-test--png)))
          ;; The request being answered.
          (should (= 1 (length gptel-yatools-media--pending)))
          (should (equal (car (car gptel-yatools-media--pending)) file))
          ;; The turns after it.
          (should (equal (plist-get (gptel-yatools-media-test--context-props file)
                                    :mime)
                         "image/png"))
          (should (equal (gptel-yatools-media-attached) (list file))))))))

(ert-deftest gptel-yatools-test-media-attach-does-not-duplicate ()
  "Reading the same image twice must not send it twice.

A model that asks for the same file again -- after an edit, say -- is
common, and a second entry would cost the image's tokens twice in every
request and show up twice in the header line."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (gptel-yatools-media-attach file)
        (gptel-yatools-media-attach file)
        (should (= 1 (length gptel-context)))
        (should (= 1 (length gptel-yatools-media--pending)))))))

;;;; 3. The size limit

(ert-deftest gptel-yatools-test-media-size-limit-refuses-and-says-why ()
  "An image over the limit must be refused, with the numbers to report.

The provider rejects an oversized image by failing the whole request, so
the refusal has to happen here and has to name the limit, or the model
cannot tell the user what to change."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "big.png"))
          (gptel-yatools-media-size-limit 8))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (let ((outcome (gptel-yatools-media-attach file)))
          (should (eq (plist-get outcome :kind) :refused))
          (should (string-match-p
                   (format "larger than the 8-byte limit")
                   (plist-get outcome :message)))
          ;; The remedy is named, because the variable is the user's.
          (should (string-match-p "gptel-yatools-media-size-limit"
                                  (plist-get outcome :message)))
          ;; Nothing was attached, so nothing will be sent.
          (should-not gptel-context)
          (should-not gptel-yatools-media--pending))))))

(ert-deftest gptel-yatools-test-media-size-limit-zero-means-no-limit ()
  "A zero (or nil) limit must disable the check, not refuse everything."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "big.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (dolist (limit '(0 nil))
        (let ((gptel-yatools-media-size-limit limit))
          (gptel-yatools-media-test--with-buffer
            (should (eq (plist-get (gptel-yatools-media-attach file) :kind)
                        :attached))
            (should (= 1 (length gptel-yatools-media--pending)))))))))

;;;; 4. The read tool

(ert-deftest gptel-yatools-test-read-path-attaches-an-image ()
  "`read_path' must attach an image instead of refusing it as binary."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (gptel-yatools-test--vfs
          (let ((out (funcall (gptel-yatools-test--tool "read_path") "shot.png")))
            (gptel-yatools-test--should-be-enveloped out)
            (should (string-match-p "attached to this" out))
            (should (string-match-p "image/png" out))
            ;; It is not the binary refusal, which is what the same call
            ;; answered with before the module existed.
            (should-not (string-match-p "binary file" out))
            (should (equal (gptel-yatools-media-attached) (list file)))))))))

(ert-deftest gptel-yatools-test-read-path-names-a-model-that-cannot-see ()
  "Without a model that can see it, the image is refused, not attached.

The answer says which side said no: the file is an image, and the model is
what cannot be shown it.  That is more useful than the binary notice,
which would send the model looking for a way to read the bytes."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (with-temp-buffer
        (setq-local gptel-context nil)
        (setq-local gptel-model
                    (gptel-yatools-media-test--model '(tool-use)))
        (gptel-yatools-test--vfs
          (let ((out (funcall (gptel-yatools-test--tool "read_path") "shot.png")))
            (gptel-yatools-test--should-be-enveloped out)
            (should (string-match-p "does not accept that media" out))
            (should-not (string-match-p "binary file" out))
            (should-not gptel-context)))))))

(ert-deftest gptel-yatools-test-read-path-does-not-attach-a-pending-copy ()
  "A pending VFS entry is text, so it can never be the image that is sent.

The bytes on disk are not what such a read describes, so attaching the
file would show the model something the VFS says has been replaced."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (gptel-yatools-test--vfs
          (gptel-yatools-vfs-put file "a text stand-in\n")
          (let ((out (funcall (gptel-yatools-test--tool "read_path") "shot.png")))
            (should (string-match-p "a text stand-in" out))
            (should-not gptel-context)
            (should-not gptel-yatools-media--pending)))))))

(ert-deftest gptel-yatools-test-read-file-tools-still-refuse-an-image ()
  "Only `read_path' attaches: the line tools are about text.

`read_file_from_offset' asks for lines, and an image has none.  Attaching
the file from there would answer a question that was not asked."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (gptel-yatools-test--vfs
          (should (string-match-p
                   "binary file"
                   (funcall (gptel-yatools-test--tool "read_file_from_offset")
                            "shot.png" 1 2)))
          (should-not gptel-context))))))

(ert-deftest gptel-yatools-test-read-path-decides-from-the-bytes-it-read ()
  "Deciding whether a file is an image must not read the file again.

The type is recognized from the bytes the read already returned.  Asking
the disk a second time would be a second round trip in a remote workspace
-- for an answer already in hand -- on every `read_path' call there is.
The disk's own head reader is made to fail, so a second read would show up
as a broken reply rather than as a slower one."
  (gptel-yatools-test--in-dir
    (let ((text (gptel-yatools-test--root-file "notes.txt"))
          (png (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write text "hello\n")
      (gptel-yatools-test--write png gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (gptel-yatools-test--vfs
          (cl-letf (((symbol-function 'gptel-yatools-media--head)
                     (lambda (&rest _)
                       (error "The file was read a second time"))))
            ;; A text file: not an image, and no disk question asked.
            (should (string-match-p
                     "hello"
                     (funcall (gptel-yatools-test--tool "read_path") "notes.txt")))
            ;; An image: still recognized, from the bytes already read.
            (should (string-match-p
                     "image/png"
                     (funcall (gptel-yatools-test--tool "read_path") "shot.png")))
            (should (equal (gptel-yatools-media-attached) (list png)))))))))

(ert-deftest gptel-yatools-test-media-type-can-be-told-the-bytes ()
  "The type must be answerable from bytes the caller already has.

This is the seam `read_path' crosses, so it is checked directly as well as
through the tool."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (should (equal (gptel-yatools-media-type
                      (gptel-yatools-test--root-file "absent.png")
                      gptel-yatools-media-test--png)
                     "image/png"))
      ;; Bytes that begin with none of the signatures are not an image.
      (should-not (gptel-yatools-media-type file "hello, world")))))

;;;; 5. Delivery into the request that asked

(defun gptel-yatools-media-test--payload (&optional first-message)
  "Return an OpenAI-shaped request payload, as gptel builds one.

FIRST-MESSAGE, when given, replaces the user's message, which is how the
tool-result case is set up."
  (list :model "test"
        :messages (vector (or first-message
                              (list :role "user" :content "look at this")))))

(ert-deftest gptel-yatools-test-media-delivers-into-the-first-user-message ()
  "An attached image must be in the payload of the request being answered.

The image goes where gptel itself puts media: into the message the user
wrote, as a content part, not as a message of its own.  The backend here
is the default OpenAI one, which speaks the Responses API -- the shape is
gptel's, which is the point: this module adds no content block of its own."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (gptel-yatools-media-attach file)
        (let* ((backend (gptel-make-openai "gptel-yatools-test-media"))
               (data (gptel-yatools-media-test--payload))
               (entries gptel-yatools-media--pending))
          (should (gptel-yatools-media-deliver backend data entries))
          (let* ((message (aref (plist-get data :messages) 0))
                 (content (plist-get message :content))
                 (image (aref content 0)))
            (should (vectorp content))
            ;; The media part, then the text, as gptel orders them.
            (should (equal (plist-get image :type) "input_image"))
            (should (string-prefix-p
                     "data:image/png;base64,"
                     (plist-get image :image_url)))
            (should (equal (plist-get (aref content 1) :text) "look at this"))))))))

(ert-deftest gptel-yatools-test-media-delivers-an-anthropic-block ()
  "The image must arrive in the shape the backend asked for.

Anthropic takes a `source' object with the base64 data inside it, where
the OpenAI backends take a data URL.  Asking the backend rather than
writing the block here is what makes both work, so both are checked."
  (require 'gptel-anthropic)
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (gptel-yatools-media-attach file)
        (let* ((backend (gptel-make-anthropic "gptel-yatools-test-media"))
               (data (gptel-yatools-media-test--payload))
               (entries gptel-yatools-media--pending))
          (should (gptel-yatools-media-deliver backend data entries))
          (let* ((content (plist-get (aref (plist-get data :messages) 0) :content))
                 (image (aref content 0))
                 (source (plist-get image :source)))
            (should (equal (plist-get image :type) "image"))
            (should (equal (plist-get source :type) "base64"))
            (should (equal (plist-get source :media_type) "image/png"))
            (should (stringp (plist-get source :data)))))))))

(ert-deftest gptel-yatools-test-media-delivery-skips-a-tool-result-message ()
  "Media must not be prepended to a message that answers a tool call.

The Anthropic API requires such a message to start with its tool results,
so an image in front of them is a malformed request.  When there is no
prompt to attach to, the next request delivers the image from the context
instead -- which is why refusing here loses nothing."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (gptel-yatools-media-attach file)
        (let* ((backend (gptel-make-openai "gptel-yatools-test-media"))
               (tool-result (list :role "user"
                                  :content (vector (list :type "tool_result"
                                                         :tool_use_id "x"
                                                         :content "done"))))
               (data (gptel-yatools-media-test--payload tool-result))
               (before (copy-tree data))
               (entries gptel-yatools-media--pending))
          (should-not (gptel-yatools-media-deliver backend data entries))
          (should (equal data before)))))))

(ert-deftest gptel-yatools-test-media-delivery-does-nothing-without-entries ()
  "An empty queue must leave the payload untouched, and say so."
  (let* ((backend (gptel-make-openai "gptel-yatools-test-media"))
         (data (gptel-yatools-media-test--payload))
         (before (copy-tree data)))
    (should-not (gptel-yatools-media-deliver backend data nil))
    (should (equal data before))))

;;;; 6. Forgetting, and the header line

(ert-deftest gptel-yatools-test-media-forget-leaves-the-users-own-alone ()
  "Forgetting must remove this package's entries and nobody else's.

A user who added the same image to the context by hand has said they want
it sent; a command named after this module must not take it away."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png"))
          (plain (gptel-yatools-test--root-file "notes.txt")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-test--write plain "hello\n")
      (gptel-yatools-media-test--with-buffer
        (gptel-yatools-media-attach file)
        ;; The user's own two entries: a file, and the same image again.
        (setq-local gptel-context
                    (append gptel-context (list (list plain) (list file :mime "image/png"))))
        (gptel-yatools-media-forget)
        (should (= 2 (length gptel-context)))
        (should-not (gptel-yatools-media-attached))
        (should-not gptel-yatools-media--pending)
        (should (gptel-yatools-media-test--context-props file))))))

(ert-deftest gptel-yatools-test-media-header-line-counts-attached-images ()
  "The label must appear with the images and go when they are forgotten."
  (gptel-yatools-test--in-dir
    (let ((file (gptel-yatools-test--root-file "shot.png")))
      (gptel-yatools-test--write file gptel-yatools-media-test--png)
      (gptel-yatools-media-test--with-buffer
        (should-not (gptel-yatools-media--header-line-label))
        (gptel-yatools-media-attach file)
        (should (string-match-p "\\[Media: 1\\]"
                                (gptel-yatools-media--header-line-label)))
        (gptel-yatools-media-forget)
        (should-not (gptel-yatools-media--header-line-label))))))

(ert-deftest gptel-yatools-test-media-header-line-label-is-registered ()
  "The label must be contributed through the registry, not drawn directly."
  (should (memq #'gptel-yatools-media--header-line-label
                gptel-yatools-header-line-extra-functions)))

;;;; 7. The queue belongs to one request

(ert-deftest gptel-yatools-test-media-queue-is-cleared-when-a-request-starts ()
  "An image left queued by a dead request must not reach the next one twice.

It is already in `gptel-context', which the next request's build reads, so
keeping it queued would put the same image in the payload twice."
  (gptel-yatools-media-test--with-buffer
    (setq gptel-yatools-media--pending '(("/tmp/x.png" :mime "image/png")))
    (gptel-yatools--media-queue-cleared)
    (should-not gptel-yatools-media--pending)))

(provide 'gptel-yatools-media-tests)
;;; gptel-yatools-media-tests.el ends here
