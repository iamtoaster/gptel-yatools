;;; gptel-yatools-tests.el --- Regression tests for the gptel-yatools tools  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Loaded on demand only -- deliberately NOT part of the package, which is
;; evaluated whenever a chat starts.  `(require 'ert)' costs ~90ms and defines
;; dozens of symbols that startup does not need.
;;
;; Usage:
;;
;;   M-x ert RET RET                      ; run everything
;;   M-x ert RET gptel-yatools-test- RET  ; run this suite only
;;
;; Or from a shell, in a running Emacs or a batch instance:
;;
;;   emacs -Q --batch -L . -l gptel-yatools.el -l tests/gptel-yatools-tests.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; No test may prompt the user.  Each one runs synchronously in the
;; current Emacs, so a modal question (a coding system, "Save file?",
;; a sync confirmation) would block the user's session -- and in batch
;; would read from stdin and abort -- while also touching whatever
;; buffer the user was editing.  `gptel-yatools-test--noninteractive' turns
;; prompts into errors, and the helpers below keep file buffers private.
;;
;; Every test works in a throwaway temp directory and a private,
;; buffer-local VFS, so the real workspace and the real VFS are untouched.

;;; Code:

(require 'ert)
(require 'json)
(require 'cl-lib)
(require 'gptel-yatools)

(defgroup gptel-yatools-test nil
  "Regression tests for the gptel-yatools tools."
  :group 'gptel)

;;;; Helpers

(defconst gptel-yatools-test--file
  (expand-file-name "gptel-yatools.el"
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory (or load-file-name buffer-file-name)))))
  "The package file these tests exercise.")

(defun gptel-yatools-test--run-batch (form)
  "Evaluate FORM in a fresh `emacs --batch -Q' and return (STATUS . OUTPUT).

Used for tests that need a *fresh* Emacs: what loading the package
does to gptel's global state cannot be observed in an Emacs whose
registry already holds the tools.  FORM is printed with `prin1' so it
travels intact.

The script re-creates this Emacs's `load-path', and puts this package's
directory first, so that everything resolves exactly as it does here."
  (let* ((dir (make-temp-file "gptel-batch-" t))
         (script (expand-file-name "probe.el" dir))
         (package-dir (file-name-directory gptel-yatools-test--file))
         (emacs (or (and invocation-directory invocation-name
                         (expand-file-name invocation-name invocation-directory))
                    (executable-find "emacs")
                    "emacs")))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; -*- lexical-binding: t; -*-\n"
                    ;; Re-create this Emacs's load-path, so gptel is found.
                    (format "(setq load-path (cons %S (quote %S)))\n"
                            package-dir load-path)
                    (format "%S\n" form)))
          (with-temp-buffer
            (let ((status (call-process emacs nil t nil "-Q" "--batch"
                                        "-l" script)))
              (cons status (buffer-string)))))
      (ignore-errors (delete-directory dir t)))))

(defun gptel-yatools-test--tool (name)
  "Return the callable implementing the gptel tool NAME."
  (let ((tool (cl-find name gptel-yatools--tools
                       :key #'gptel-tool-name :test #'equal)))
    (unless tool (error "No such tool registered: %s" name))
    (gptel-tool-function tool)))

(defun gptel-yatools-test--tool-spec (name)
  "Return the `gptel-tool' struct registered as NAME.

`gptel-yatools-test--tool' returns the callable inside it, which is what a
direct call needs; gptel's dispatcher, by contrast, takes the struct."
  (let ((tool (cl-find name gptel-yatools--tools
                       :key #'gptel-tool-name :test #'equal)))
    (unless tool (error "No such tool registered: %s" name))
    tool))

(defun gptel-yatools-test--raw (file)
  "Return FILE's bytes as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun gptel-yatools-test--write (file content)
  "Write CONTENT to FILE, replacing it, without coding prompts.

CONTENT is often a unibyte string holding arbitrary bytes (Latin-1
text, a BOM, binary data).  Letting `write-region' pick a coding
system for it makes Emacs ask the user to choose one, which a test
must never do; and choosing UTF-8 would corrupt the bytes.  Write
multibyte text as UTF-8 and unibyte bytes verbatim instead."
  (let ((coding-system-for-write
         (if (multibyte-string-p content) 'utf-8-unix 'no-conversion)))
    (with-temp-file file (insert content))))

(defmacro gptel-yatools-test--in-dir (&rest body)
  "Run BODY with `default-directory' in a fresh temp dir, then delete it."
  (declare (indent 0) (debug t))
  `(let* ((gptel-yatools-test--dir (file-name-as-directory
                                (make-temp-file "gptel-yatools-test-" t)))
          (default-directory gptel-yatools-test--dir))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory gptel-yatools-test--dir t)))))

(defmacro gptel-yatools-test--vfs (&rest body)
  "Run BODY with a fresh private VFS in the current buffer."
  (declare (indent 0) (debug t))
  `(let ((gptel-yatools-vfs (make-hash-table :test #'equal)))
     (setq gptel-yatools-vfs--header-line-cache nil)
     ,@body))

(defmacro gptel-yatools-test--with-file (file content &rest body)
  "Write CONTENT to FILE, then run BODY in a buffer with a private VFS."
  (declare (indent 2) (debug t))
  `(progn
     (gptel-yatools-test--write ,file ,content)
     (with-temp-buffer
       (gptel-yatools-test--vfs ,@body))))

(defmacro gptel-yatools-test--with-open-buffer (file &rest body)
  "Visit FILE in a real buffer, run BODY in that buffer, then kill it.

BODY must run with the visited buffer current: tests use this macro
to make the file buffer dirty (`insert', `goto-char') and then check
what `file_sync' does with it.  Running BODY in whatever buffer ERT
happened to start in would edit that buffer instead -- including a
real gptel chat buffer -- and leave the file buffer untouched."
  (declare (indent 1) (debug t))
  `(let ((gptel-yatools-test--buf nil))
     (unwind-protect
         (progn
           (setq gptel-yatools-test--buf (find-file-noselect ,file))
           (with-current-buffer gptel-yatools-test--buf
             ,@body))
       (when (buffer-live-p gptel-yatools-test--buf)
         ;; Several tests deliberately leave the visiting buffer modified
         ;; (that is the condition they exercise).  Killing it without first
         ;; clearing the flag makes Emacs ask "Save file ...?", a modal
         ;; question in the middle of a test run.  The file is a throwaway
         ;; temp file, so drop the unsaved state instead.
         (with-current-buffer gptel-yatools-test--buf
           (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil))
           (kill-buffer gptel-yatools-test--buf))))))

(defmacro gptel-yatools-test--silencing-message (&rest body)
  "Run BODY with `message' made harmless, returning BODY's value."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
     ,@body))

(defmacro gptel-yatools-test--noninteractive (&rest body)
  "Run BODY with every user prompt turned into an error.

A test must never ask the user anything: in a batch run a modal
question reads from stdin and fails with `end-of-file', and in an
interactive session it steals focus and waits.  Turning prompts into
errors makes such a test fail immediately and point at the code path
that prompted, instead of hanging or corrupting the user's buffers."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'yes-or-no-p)
              (lambda (&rest args)
                (error "Test tried to ask the user a question: %S" args)))
             ((symbol-function 'y-or-n-p)
              (lambda (&rest args)
                (error "Test tried to ask the user a question: %S" args)))
             ((symbol-function 'read-string)
              (lambda (&rest args)
                (error "Test tried to read input from the user: %S" args)))
             ((symbol-function 'read-from-minibuffer)
              (lambda (&rest args)
                (error "Test tried to read input from the user: %S" args)))
             ((symbol-function 'completing-read)
              (lambda (&rest args)
                (error "Test tried to read input from the user: %S" args)))
             ((symbol-function 'select-safe-coding-system)
              (lambda (&rest args)
                (error "Test tried to make the user choose a coding system: %S"
                       args)))
             ((symbol-function 'kill-buffer--possibly-save)
              (lambda (&rest _) t)))
     ,@body))

(defun gptel-yatools-test--request-buffer (&optional name)
  "Return a fresh buffer that owns a buffer-local VFS, like a chat buffer.

The VFS is installed with `setq-local' and not with the `let'-based
`gptel-yatools-test--vfs' helper on purpose: a dynamic binding of an
automatically buffer-local variable is visible from every buffer, which
would hide exactly the bug these tests exist to catch."
  (let ((buffer (generate-new-buffer (or name " *gptel-yatools-test-request*"))))
    (with-current-buffer buffer
      (setq-local gptel-yatools-vfs (make-hash-table :test #'equal))
      (setq-local gptel-yatools-vfs--header-line-cache nil))
    buffer))

(defun gptel-yatools-test--kill-request-buffer (buffer)
  "Kill BUFFER without letting the unsynced-VFS guard ask a question."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (local-variable-p 'gptel-yatools-vfs) (clrhash gptel-yatools-vfs)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(defun gptel-yatools-test--accept-in (caller owner tool args)
  "Run TOOL with positional ARGS in OWNER, confirmed from CALLER.

The call goes through gptel's own dispatcher, `gptel--accept-tool-calls',
with a throwaway `gptel--fsm-last' pointing at OWNER -- the shape
`gptel--inspect-tool-calls' leaves behind.  Calling the tool function
directly would run in CALLER and pass even while the dispatch bug is
present, which is why no test in this section does that.

Returns whatever the tool returned."
  (with-current-buffer caller
    (let* ((result nil)
           (gptel--fsm-last
            (gptel-make-fsm :state 'TOOL :info (list :buffer owner))))
      (gptel--accept-tool-calls
       (list (list tool args (lambda (value) (setq result value)))))
      result)))

(defun gptel-yatools-test--advice-count (symbol advice)
  "Return how many times ADVICE is installed on SYMBOL."
  (let ((count 0))
    (advice-mapc (lambda (installed &rest _)
                   (when (eq installed advice) (setq count (1+ count))))
                 symbol)
    count))

(defun gptel-yatools-test-run (&optional selector)
  "Run the gptel-yatools regression tests, never prompting the user.

SELECTOR defaults to every `gptel-yatools-test-' test.  Returns the ERT
stats object; inspect it or look at the *ert* buffer for failures."
  (interactive)
  (require 'ert)
  (gptel-yatools-test--noninteractive
    (ert-run-tests-batch (or selector "^gptel-yatools-test-"))))

;;;; 1. Sync preview was rendered inside the diff buffer (empty VFS there)

(ert-deftest gptel-yatools-test-sync-preview-shows-both-sides ()
  "The sync preview must show '+' lines, not only '-' lines."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "a.txt" default-directory)))
      (gptel-yatools-test--with-file file "one\ntwo\n"
        (gptel-yatools-vfs-put file "one\nTWO\n")
        (let ((buf (gptel-yatools-vfs--build-sync-diff-buffer (list file))))
          (unwind-protect
              (with-current-buffer buf
                (should (string-match-p "^+TWO" (buffer-string)))
                (should (string-match-p "^-two" (buffer-string))))
            (kill-buffer buf)))))))

(ert-deftest gptel-yatools-test-sync-preview-new-file-has-hunk ()
  "A brand-new file must render a real hunk, not a bare header."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "new.txt" default-directory)))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (gptel-yatools-vfs-put file "hello\n")
          (let ((buf (gptel-yatools-vfs--build-sync-diff-buffer (list file))))
            (unwind-protect
                (with-current-buffer buf
                  ;; GNU diff omits the line count when it is 1, so the
                  ;; hunk header is "@@ -0,0 +1 @@", not "@@ ... +1,1 @@".
                  ;; `+' is a regexp repetition operator, hence the escape.
                  (should (string-match-p "@@ -0,0 \\+1 @@"
                                          (buffer-string)))
                  (should (string-match-p "^+hello" (buffer-string))))
              (kill-buffer buf))))))))

;;;; 2. write_file reported characters as bytes

(ert-deftest gptel-yatools-test-write-file-reports-bytes-not-chars ()
  "The reported size must be the encoded size, not the character count."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "uni.txt" default-directory)))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (let ((out (funcall (gptel-yatools-test--tool "write_file")
                              file "日本語 😀\n")))
            ;; 3+3+3 + 1 space + 4 (emoji) + 1 newline = 15 bytes, 9 chars.
            (should (string-match-p "15 bytes" out))))))))

;;;; 3. Sync transcoded files to UTF-8/unix

(ert-deftest gptel-yatools-test-sync-preserves-iso-latin-1 ()
  "Editing a Latin-1 file must not convert it to UTF-8."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "l1.txt" default-directory)))
      (gptel-yatools-test--write file (encode-coding-string "café\n" 'iso-latin-1))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (funcall (gptel-yatools-test--tool "write_file_diff")
                   file "café" "café!")
          (should (equal (gptel-yatools-vfs--sync-one file) '(:ok "synced")))
          (should (equal (gptel-yatools-test--raw file)
                         (encode-coding-string "café!\n" 'iso-latin-1))))))))

(ert-deftest gptel-yatools-test-sync-preserves-crlf ()
  "Editing a CRLF file must not silently switch it to LF.

VFS content is decoded text, so it contains plain LF: the file's
coding system (utf-8-dos here) is what turns those LFs back into
CRLF on sync.  Putting literal CRs in the VFS content would store
them as characters and make sync expand each LF into another CRLF."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "c.txt" default-directory)))
      (gptel-yatools-test--write file "one\r\ntwo\r\n")
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (gptel-yatools-vfs-put file "one\nTWO\n")
          (should (equal (gptel-yatools-vfs--sync-one file) '(:ok "synced")))
          (should (equal (gptel-yatools-test--raw file) "one\r\nTWO\r\n")))))))

(ert-deftest gptel-yatools-test-sync-preserves-bom ()
  "A UTF-8 BOM must survive an edit."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "bom.txt" default-directory)))
      (gptel-yatools-test--write file "\357\273\277hello\n")
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (gptel-yatools-vfs-put file "hello!\n")
          (should (equal (gptel-yatools-vfs--sync-one file) '(:ok "synced")))
          (should (equal (gptel-yatools-test--raw file) "\357\273\277hello!\n")))))))

(ert-deftest gptel-yatools-test-coding-change-is-a-conflict ()
  "A re-encoding on disk must count as a change, not be overwritten."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "e.txt" default-directory)))
      (gptel-yatools-test--write file "aaa\nbbb\n")
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (gptel-yatools-vfs-put file "aaa\nBBB\n")
          ;; Same decoded text, different line endings on disk.
          (gptel-yatools-test--write file "aaa\r\nbbb\r\n")
          (should (gptel-yatools-vfs--conflict-p file))
          (should (eq (car (gptel-yatools-vfs--sync-one file)) :failed)))))))

;;;; 4. write_file_diff could not edit non-UTF-8 files

(ert-deftest gptel-yatools-test-write-file-diff-handles-latin-1 ()
  "An edit matching decoded text must be found in a Latin-1 file."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "l2.txt" default-directory)))
      (gptel-yatools-test--write file (encode-coding-string "naïve café\n" 'iso-latin-1))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (should (string-match-p
                   "Applied edit"
                   (funcall (gptel-yatools-test--tool "write_file_diff")
                            file "café" "café!"))))))))

;;;; 5. A deleted file was reported as "new empty file"

(ert-deftest gptel-yatools-test-deleted-file-is-a-conflict-not-empty-file ()
  "A pending file deleted from disk must be a CONFLICT."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "g.txt" default-directory)))
      (gptel-yatools-test--with-file file "gone\n"
        (gptel-yatools-vfs-put file "")
        (delete-file file)
        (let ((text (gptel-yatools-vfs--format-one-diff file)))
          (should (string-match-p "CONFLICT" text))
          (should-not (string-match-p "new empty file" text)))))))

;;;; 6. Reloading doubled the tool list

(ert-deftest gptel-yatools-test-tools-have-no-duplicates ()
  "Each tool must be defined exactly once."
  (should (equal (length gptel-yatools--tools)
                 (length (delete-dups
                          (mapcar #'gptel-tool-name gptel-yatools--tools))))))

;;;; 7. "No pending changes" claimed vfs="true"

(ert-deftest gptel-yatools-test-no-pending-changes-reports-vfs-false ()
  "An empty VFS must be reported as vfs=\"false\"."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (should (string-match-p "vfs=\"false\""
                              (funcall (gptel-yatools-test--tool "vfs_diff"))))
      (should (string-match-p "vfs=\"false\""
                              (funcall (gptel-yatools-test--tool "vfs_discard")))))))

;;;; 8. Raw bytes made the response unserialisable (request died)

(ert-deftest gptel-yatools-test-responses-are-json-serialisable ()
  "A response carrying raw bytes must be escaped and serialisable."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (let ((out (gptel-yatools-vfs--wrap
                  nil "probe"
                  (string-to-multibyte (unibyte-string 233 0 255)))))
        (should-not (cl-some (lambda (c) (eq (char-charset c) 'eight-bit))
                             (string-to-list out)))
        (should (condition-case nil (progn (json-serialize out) t)
                  (error nil)))))))

(ert-deftest gptel-yatools-test-command-output-is-json-serialisable ()
  "Command output with raw bytes must not break the request either."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "raw.bin" default-directory)))
      (gptel-yatools-test--write file (unibyte-string 99 97 102 233 10))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (let ((out (funcall (gptel-yatools-test--tool "execute_command")
                              (format "cat %s" file))))
            (should (condition-case nil (progn (json-serialize out) t)
                      (error nil)))))))))

;;;; 9. Unrepresentable content silently corrupted the file

(ert-deftest gptel-yatools-test-unrepresentable-content-is-refused ()
  "Writing an emoji into a Latin-1 file must be refused up front."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "l3.txt" default-directory)))
      (gptel-yatools-test--write file (encode-coding-string "café\n" 'iso-latin-1))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (should (string-match-p
                   "cannot represent"
                   (funcall (gptel-yatools-test--tool "write_file")
                            file "café 😀\n")))
          (should-not (gptel-yatools-vfs-get file)))))))

(ert-deftest gptel-yatools-test-sync-refuses-unrepresentable ()
  "Sync must refuse rather than write replacement characters."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "l4.txt" default-directory)))
      (gptel-yatools-test--write file (encode-coding-string "café\n" 'iso-latin-1))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (let ((before (gptel-yatools-test--raw file)))
            ;; Bypass the write-time check to exercise the sync-time one.
            (puthash file (list :content "café 😀\n" :baseline "café\n"
                                :coding 'iso-latin-1-unix
                                :baseline-coding 'iso-latin-1-unix)
                     gptel-yatools-vfs)
            (should (eq (car (gptel-yatools-vfs--sync-one file)) :failed))
            (should (equal (gptel-yatools-test--raw file) before))))))))

(ert-deftest gptel-yatools-test-explicit-coding-converts ()
  "Passing CODING must write the file in that encoding."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "conv.txt" default-directory)))
      (gptel-yatools-test--write file (encode-coding-string "café\n" 'iso-latin-1))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (should (string-match-p
                   "Applied edit"
                   (funcall (gptel-yatools-test--tool "write_file_diff")
                            file "café" "café 😀" nil "utf-8")))
          (should (equal (gptel-yatools-vfs--sync-one file) '(:ok "synced")))
          (should (equal (gptel-yatools-test--raw file)
                         (encode-coding-string "café 😀\n" 'utf-8-unix))))))))

;;;; 10. Binary content looked unrepresentable (unibyte vs multibyte)

(ert-deftest gptel-yatools-test-binary-content-is-encodable ()
  "Binary content must not be rejected as unrepresentable."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "b.bin" default-directory)))
      (gptel-yatools-test--write file (unibyte-string 0 1 255 254 10))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (let* ((info (gptel-yatools-vfs--disk-content-with-coding file)))
            (should (gptel-yatools-vfs--encodable-p (car info) (cdr info)))
            (should (string-match-p
                     "No change needed"
                     (funcall (gptel-yatools-test--tool "write_file")
                              file (car info))))))))))

(ert-deftest gptel-yatools-test-binary-sync-is-byte-exact ()
  "A binary file must round-trip byte for byte."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "b2.bin" default-directory)))
      (gptel-yatools-test--write file (unibyte-string 0 1 255 254 10 0 7))
      (let ((before (gptel-yatools-test--raw file)))
        (with-temp-buffer
          (gptel-yatools-test--vfs
            ;; Same bytes as disk is a no-op, so force an entry.  The
            ;; baseline must be the real disk content: a fake baseline
            ;; would make this a conflict, and `gptel-yatools-vfs--sync-one'
            ;; correctly refuses to overwrite a file that changed on disk.
            (puthash file (list :content (gptel-yatools-vfs--disk-content file)
                                :baseline (gptel-yatools-vfs--disk-content file)
                                :coding 'no-conversion
                                :baseline-coding 'no-conversion)
                     gptel-yatools-vfs)
            (should (eq (car (gptel-yatools-vfs--sync-one file)) :ok))
            (should (equal (gptel-yatools-test--raw file) before))))))))

;;;; 11. Building the diff asked the user to pick a coding system

(ert-deftest gptel-yatools-test-unified-diff-never-prompts-for-coding ()
  "Diffing binary content must not invoke the coding-system prompt."
  (let ((select-safe-coding-system-function
         (lambda (&rest _) (error "asked the user for a coding system"))))
    (should (string-match-p
             "Binary files"
             (gptel-yatools-vfs--unified-diff (unibyte-string 0 1 2)
                                      (unibyte-string 0 1 3)
                                      "x.bin")))))

;;;; 12. Binary files were dumped as mojibake

(ert-deftest gptel-yatools-test-binary-read-is-withheld ()
  "Binary content must be reported, not returned."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "x.bin" default-directory)))
      (gptel-yatools-test--write file (unibyte-string 80 78 71 0 1 2))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (should (string-match-p
                   "binary file"
                   (funcall (gptel-yatools-test--tool "read_path") file))))))))

(ert-deftest gptel-yatools-test-binary-diff-edit-is-refused ()
  "Editing binary content as text must be refused."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "y.bin" default-directory)))
      (gptel-yatools-test--write file (unibyte-string 80 78 71 0 74 70 73 70))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (should (string-match-p
                   "binary file"
                   (funcall (gptel-yatools-test--tool "write_file_diff")
                            file "JFIF" "XXXX"))))))))

;;;; 13. An unknown coding system signalled a raw Lisp error

(ert-deftest gptel-yatools-test-invalid-coding-is-a-clean-message ()
  "An unknown coding system must produce a readable error string."
  (gptel-yatools-test--in-dir
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (should (string-match-p
                 "unknown coding system"
                 (funcall (gptel-yatools-test--tool "write_file")
                          (expand-file-name "n.txt" default-directory)
                          "x" nil "no-such-coding")))))))

;;;; 14. vfs_diff did not mark files that file_sync would skip

(ert-deftest gptel-yatools-test-dirty-buffer-is-marked-in-diff ()
  "A file blocked by an unsaved buffer must be marked NOT SYNCED."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "d.txt" default-directory)))
      (gptel-yatools-test--write file "orig\n")
      (gptel-yatools-test--with-open-buffer file
        (goto-char (point-max))
        (insert "unsaved\n")
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (gptel-yatools-vfs-put file "vfs\n")
            (should (string-match-p "NOT SYNCED"
                                    (gptel-yatools-vfs--format-one-diff file)))))))))

(ert-deftest gptel-yatools-test-blocker-reasons ()
  "`gptel-yatools-vfs--sync-blocker' must explain itself or return nil."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "blk.txt" default-directory)))
      (gptel-yatools-test--write file "orig\n")
      (gptel-yatools-test--with-open-buffer file
        ;; Dirty the visiting buffer itself: that is what the blocker
        ;; detects.  Doing this inside `with-temp-buffer' below would
        ;; modify the scratch buffer instead and leave the file clean.
        (goto-char (point-max))
        (insert "dirty\n")
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (gptel-yatools-vfs-put file "vfs\n")
            (should (string-match-p "unsaved changes"
                                    (gptel-yatools-vfs--sync-blocker file)))))))))

;;;; 15. Sync reverted the visiting buffer and destroyed unsaved edits

(ert-deftest gptel-yatools-test-unsaved-buffer-blocks-sync ()
  "Syncing must refuse and leave both disk and buffer untouched."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "u.txt" default-directory)))
      (gptel-yatools-test--write file "orig\n")
      (gptel-yatools-test--with-open-buffer file
        (goto-char (point-max))
        (insert "UNSAVED\n")
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (gptel-yatools-vfs-put file "vfs\n")
            (let ((result (gptel-yatools-vfs--sync-one file)))
              (should (eq (car result) :failed))
              (should (string-match-p "unsaved changes" (cadr result))))))
        (should (equal (gptel-yatools-vfs--disk-content file) "orig\n"))
        (should (buffer-modified-p))
        (should (string-match-p "UNSAVED" (buffer-string)))))))

(ert-deftest gptel-yatools-test-clean-buffer-is-refreshed ()
  "After a successful sync the visiting buffer must show the new text."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "c2.txt" default-directory)))
      (gptel-yatools-test--write file "orig\n")
      (gptel-yatools-test--with-open-buffer file
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (gptel-yatools-vfs-put file "vfs\n")
            (should (eq (car (gptel-yatools-vfs--sync-one file)) :ok))))
        (should (equal (buffer-string) "vfs\n"))
        (should-not (buffer-modified-p))))))

;;;; 16. A write during the review was destroyed (conflict not re-checked)

(ert-deftest gptel-yatools-test-sync-one-rechecks-conflict ()
  "`gptel-yatools-vfs--sync-one' must re-check conflicts right before writing."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "r.txt" default-directory)))
      (gptel-yatools-test--with-file file "base\n"
        (gptel-yatools-vfs-put file "vfs\n")
        ;; Simulates a write landing after the pre-check, before the sync.
        (gptel-yatools-test--write file "external\n")
        (let ((result (gptel-yatools-vfs--sync-one file)))
          (should (eq (car result) :failed))
          (should (string-match-p "conflict" (cadr result)))
          (should (equal (gptel-yatools-vfs--disk-content file) "external\n")))))))

(ert-deftest gptel-yatools-test-sync-skips-blocked-but-syncs-the-rest ()
  "One blocked file must not stop the others, and must be reported."
  (gptel-yatools-test--in-dir
    (let ((blocked (expand-file-name "b1.txt" default-directory))
          (ok (expand-file-name "ok.txt" default-directory)))
      (gptel-yatools-test--write blocked "orig\n")
      (gptel-yatools-test--write ok "orig\n")
      (gptel-yatools-test--with-open-buffer blocked
        (goto-char (point-max))
        (insert "unsaved\n")
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (gptel-yatools-vfs-put blocked "vfs\n")
            (gptel-yatools-vfs-put ok "vfs\n")
            (gptel-yatools-test--silencing-message
              ;; This test is about partial sync, not the review UI: stub
              ;; the confirmation so the suite stays non-interactive.
              (cl-letf (((symbol-function 'gptel-yatools-vfs--confirm-sync)
                         (lambda (&rest _) t)))
                (let ((out (funcall (gptel-yatools-test--tool "file_sync"))))
                  (should (string-match-p "Synced 1 file" out))
                  (should (string-match-p "Blocked" out)))))
            (should (equal (gptel-yatools-vfs--disk-content ok) "vfs\n"))
            (should (equal (gptel-yatools-vfs--disk-content blocked) "orig\n"))))))))

;;;; 17/18. Directory handling

(ert-deftest gptel-yatools-test-directory-read-gives-clear-error ()
  "Reading a directory as a file must explain itself."
  (gptel-yatools-test--in-dir
    (let ((dir (make-temp-file "sub" t)))
      (unwind-protect
          (with-temp-buffer
            (gptel-yatools-test--vfs
              (let ((err (should-error
                          (funcall (gptel-yatools-test--tool "read_file_from_offset")
                                   dir 1 1))))
                (should (string-match-p "is a directory, not a file"
                                        (cadr err))))))
        (ignore-errors (delete-directory dir t))))))

(ert-deftest gptel-yatools-test-empty-directory-listing ()
  "An empty directory must say so rather than return nothing."
  (gptel-yatools-test--in-dir
    (let ((dir (make-temp-file "empty" t)))
      (unwind-protect
          (with-temp-buffer
            (gptel-yatools-test--vfs
              (should (string-match-p
                       "(empty directory)"
                       (funcall (gptel-yatools-test--tool "read_path") dir)))))
        (ignore-errors (delete-directory dir t))))))

;;;; 20. An invalid regexp signalled a raw Lisp error

(ert-deftest gptel-yatools-test-invalid-regexp-is-a-clean-message ()
  "An invalid regexp must be reported, not signalled."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "rx.txt" default-directory)))
      (gptel-yatools-test--with-file file "abc\n"
        (should (string-match-p
                 "invalid regexp"
                 (funcall (gptel-yatools-test--tool
                           "fetch_lines_from_file_using_regex")
                          file "\\(unbalanced")))))))

;;;; 21/22/23. Response size limits

(ert-deftest gptel-yatools-test-truncate-caps-lines ()
  "Long output must be capped and say how much was withheld."
  (let* ((text (mapconcat #'number-to-string (number-sequence 1 3000) "\n"))
         (out (gptel-yatools-vfs--truncate text)))
    (should (< (length out) (+ gptel-yatools-vfs--output-char-limit 1000)))
    (should (string-match-p "first 2000 of 3000 lines" out))))

(ert-deftest gptel-yatools-test-truncate-caps-after-escaping ()
  "The size cap must hold once raw bytes are expanded to \\xNN."
  (let* ((raw (string-to-multibyte
               (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert (make-string 30000 255))
                 (buffer-string))))
         (out (gptel-yatools-vfs--truncate raw)))
    (should (<= (length out) (+ gptel-yatools-vfs--output-char-limit 400)))
    (should (string-match-p "truncated" out))))

(ert-deftest gptel-yatools-test-truncate-leaves-small-text-alone ()
  "A short response must be returned verbatim, with no banner."
  (should (equal (gptel-yatools-vfs--truncate "abc\n") "abc\n"))
  (should (equal (gptel-yatools-vfs--truncate "") "")))

(ert-deftest gptel-yatools-test-truncate-tolerates-nil ()
  "A nil body must not signal."
  (should (equal (gptel-yatools-vfs--truncate nil) "")))

(ert-deftest gptel-yatools-test-hard-cut-keeps-escapes-intact ()
  "A cut must not leave a half-written \\xNN escape."
  (should (equal (gptel-yatools-vfs--hard-cut "ab\\xffcd" 4) "ab"))
  (should (equal (gptel-yatools-vfs--hard-cut "ab\\xffcd" 6) "ab\\xff"))
  (should (equal (gptel-yatools-vfs--hard-cut "abc" 2) "ab")))

;;;; 25. FIFOs and devices would hang Emacs

(ert-deftest gptel-yatools-test-non-regular-file-is-refused ()
  "A device or FIFO must be refused rather than read."
  (skip-unless (file-exists-p "/dev/null"))
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (let ((err (should-error
                  (funcall (gptel-yatools-test--tool "read_path") "/dev/null"))))
        (should (string-match-p "not a regular file" (cadr err)))))))

(ert-deftest gptel-yatools-test-non-regular-write-is-refused ()
  "Writing to a device or FIFO must be refused."
  (skip-unless (file-exists-p "/dev/null"))
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (should (string-match-p
               "not a regular file"
               (funcall (gptel-yatools-test--tool "write_file")
                        "/dev/null" "x"))))))

;;;; 26. One unreadable file broke every tool

(ert-deftest gptel-yatools-test-unreadable-file-does-not-break-tools ()
  "An unreadable pending file must not break unrelated tool calls."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "np.txt" default-directory)))
      (gptel-yatools-test--write file "secret\n")
      (unwind-protect
          (with-temp-buffer
            (gptel-yatools-test--vfs
              (gptel-yatools-vfs-put file "pending\n")
              (set-file-modes file #o000)
              (should (null (gptel-yatools-vfs--disk-content file)))
              (should (equal (gptel-yatools-vfs--changed-paths) (list file)))
              (should (stringp (funcall (gptel-yatools-test--tool "vfs_diff"))))
              (should (stringp (funcall (gptel-yatools-test--tool "file_sync"))))))
        (ignore-errors (set-file-modes file #o644))))))

;;;; 27. Header line: correctness and cost

(ert-deftest gptel-yatools-test-header-line-count-tracks-vfs ()
  "The pending count must appear and disappear with the entries."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "h.txt" default-directory)))
      (gptel-yatools-test--with-file file "a\n"
        (should (null (gptel-yatools-vfs--header-line-label)))
        (gptel-yatools-vfs-put file "b\n")
        (should (string-match-p "1 file pending"
                                (gptel-yatools-vfs--header-line-label)))
        (gptel-yatools-vfs-remove file)
        (should (null (gptel-yatools-vfs--header-line-label)))))))

(ert-deftest gptel-yatools-test-header-line-cache-expires ()
  "A cached count is reused briefly, then recomputed."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "h2.txt" default-directory)))
      (gptel-yatools-test--with-file file "a\n"
        (gptel-yatools-vfs-put file "b\n")
        (should (string-match-p "1 file pending"
                                (gptel-yatools-vfs--header-line-label)))
        ;; Make the entry stop being pending without touching the VFS.
        (gptel-yatools-test--write file "b\n")
        (should (string-match-p "1 file pending"
                                (gptel-yatools-vfs--header-line-label)))
        (sleep-for (+ gptel-yatools-vfs--header-line-cache-seconds 0.2))
        (should (null (gptel-yatools-vfs--header-line-label)))))))

(ert-deftest gptel-yatools-test-header-line-cache-is-used ()
  "Repeated redisplay must not re-read the pending files."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "h3.txt" default-directory)))
      (gptel-yatools-test--with-file file "a\n"
        (gptel-yatools-vfs-put file "b\n")
        (gptel-yatools-vfs--header-line-label)
        (let ((reads 0))
          (cl-letf (((symbol-function 'gptel-yatools-vfs--changed-paths)
                     (lambda (&rest _) (setq reads (1+ reads)) nil)))
            (dotimes (_ 5) (gptel-yatools-vfs--header-line-label))
            (should (= reads 0))))))))

;;;; 28. One huge diff: no paging, and a misleading excerpt

(ert-deftest gptel-yatools-test-vfs-diff-paging-banner ()
  "A partial diff must be bannered, and offset/lines must page it."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "big.txt" default-directory)))
      (gptel-yatools-test--write
       file (mapconcat (lambda (n) (format "old %d" n))
                       (number-sequence 1 200) "\n"))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (gptel-yatools-vfs-put
           file (mapconcat (lambda (n) (format "new %d" n))
                           (number-sequence 1 200) "\n"))
          (let ((page1 (funcall (gptel-yatools-test--tool "vfs_diff") file 1 20))
                (page2 (funcall (gptel-yatools-test--tool "vfs_diff") file 21 20)))
            (should (string-match-p "PARTIAL DIFF" page1))
            (should (string-match-p "lines 1-20 of" page1))
            (should (string-match-p "lines 21-40 of" page2))
            (should-not (equal page1 page2))))))))

(ert-deftest gptel-yatools-test-vfs-diff-path-selects-one-file ()
  "Passing PATH must restrict the diff to that file."
  (gptel-yatools-test--in-dir
    (let ((a (expand-file-name "a.txt" default-directory))
          (b (expand-file-name "b.txt" default-directory)))
      (gptel-yatools-test--write a "a\n")
      (gptel-yatools-test--write b "b\n")
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (gptel-yatools-vfs-put a "a2\n")
          (gptel-yatools-vfs-put b "b2\n")
          (let ((out (funcall (gptel-yatools-test--tool "vfs_diff") a)))
            (should (string-match-p "a2" out))
            (should-not (string-match-p "b2" out))
            (should (string-match-p "1 other pending" out))))))))

;;;; 29. Paging out of range or with non-integer arguments

(ert-deftest gptel-yatools-test-vfs-diff-offset-past-end-is-clean ()
  "An offset beyond the diff must not signal a raw Lisp error."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "off.txt" default-directory)))
      (gptel-yatools-test--with-file file "old\n"
        (gptel-yatools-vfs-put file "new\n")
        (let ((out (funcall (gptel-yatools-test--tool "vfs_diff")
                            file 1000 20)))
          (should (stringp out))
          (should (string-match-p "OFFSET PAST END" out))
          (should (string-match-p "offset=1" out)))))))

(ert-deftest gptel-yatools-test-vfs-diff-last-page-does-not-suggest-past-end ()
  "The final page must not tell the caller to request offset TOTAL+1."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "last.txt" default-directory)))
      (gptel-yatools-test--with-file file "old\n"
        (gptel-yatools-vfs-put file "new\n")
        (let* ((diff (gptel-yatools-vfs--format-one-diff file))
               (total (length (split-string diff "\n")))
               (out (funcall (gptel-yatools-test--tool "vfs_diff")
                             file total 20)))
          (should (string-match-p "last chunk" out))
          (should-not (string-match-p (format "offset=%d" (1+ total))
                                      out)))))))

(ert-deftest gptel-yatools-test-vfs-diff-float-offset-is-clean ()
  "A float offset from JSON must be truncated, not passed to `nth'."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "float.txt" default-directory)))
      (gptel-yatools-test--with-file file "old\n"
        (gptel-yatools-vfs-put file "new\n")
        (let ((out (funcall (gptel-yatools-test--tool "vfs_diff")
                            file 1.5 2.0)))
          (should (stringp out))
          (should (string-match-p "PARTIAL DIFF" out)))))))

(ert-deftest gptel-yatools-test-read-file-offset-coerces-floats ()
  "Float offset/lines must work instead of signalling wrong-type-argument."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "lines.txt" default-directory)))
      (gptel-yatools-test--with-file file "a\nb\nc\nd\n"
        (let ((out (funcall (gptel-yatools-test--tool
                             "read_file_from_offset")
                            file 2.0 1.9)))
          (should (string-match-p "<tool_response>\nb\n" out)))))))

;;;; 30. Editing unreadable or special files

(ert-deftest gptel-yatools-test-write-file-diff-refuses-unreadable-and-special ()
  "An unreadable file or a device must yield a message, not nil internals."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "unreadable.txt" default-directory)))
      (gptel-yatools-test--write file "secret\n")
      (unwind-protect
          (progn
            (set-file-modes file #o000)
            (with-temp-buffer
              (gptel-yatools-test--vfs
                (should (string-match-p
                         "not a readable regular file"
                         (funcall (gptel-yatools-test--tool "write_file_diff")
                                  file "secret" "public"))))))
        (ignore-errors (set-file-modes file #o644)))
      (when (file-exists-p "/dev/null")
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (should (string-match-p
                     "not a readable regular file"
                     (funcall (gptel-yatools-test--tool "write_file_diff")
                              "/dev/null" "x" "y")))))))))

;;;; 31. Generic "undecided" coding crashed `gptel-yatools-vfs--resolve-coding'

(ert-deftest gptel-yatools-test-undecided-coding-is-clean ()
  "Passing coding=\"undecided\" must not signal a vector/fixnum error."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "undecided.txt" default-directory)))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (let ((out (funcall (gptel-yatools-test--tool "write_file")
                              file "x\n" nil "undecided")))
            (should (stringp out))
            (should (string-match-p "Wrote" out))
            (should (coding-system-p
                     (gptel-yatools-vfs--resolve-coding
                      (gptel-yatools-vfs--entry-coding file))))
            (should (equal (gptel-yatools-vfs--sync-one file) '(:ok "synced")))
            (should (equal (gptel-yatools-test--raw file) "x\n"))))))))

;;;; 32. Unreadable directories leaked a raw `file-error'

(ert-deftest gptel-yatools-test-unreadable-directory-is-clean ()
  "Reading an unreadable directory must explain itself."
  (gptel-yatools-test--in-dir
    (let ((dir (make-temp-file "noread" t)))
      (unwind-protect
          (progn
            (set-file-modes dir #o000)
            (with-temp-buffer
              (gptel-yatools-test--vfs
                (let ((err (should-error
                            (funcall (gptel-yatools-test--tool "read_path")
                                     dir))))
                  (should (string-match-p "cannot read directory"
                                          (cadr err)))))))
        (ignore-errors (set-file-modes dir #o755))
        (ignore-errors (delete-directory dir t))))))

;;;; 33. Writing a file over a virtual directory produced an unsyncable child

(ert-deftest gptel-yatools-test-write-file-cannot-shadow-virtual-directory ()
  "A target with pending VFS children must be rejected up front."
  (gptel-yatools-test--in-dir
    (let ((parent (expand-file-name "d" default-directory))
          (child (expand-file-name "d/child.txt" default-directory)))
      (with-temp-buffer
        (gptel-yatools-test--vfs
          (should (string-match-p
                   "Wrote"
                   (funcall (gptel-yatools-test--tool "write_file")
                            child "x\n")))
          (should (string-match-p
                   "directory in the VFS"
                   (funcall (gptel-yatools-test--tool "write_file")
                            parent "y\n")))
          (should-not (gptel-yatools-vfs-get parent))
          (should (gptel-yatools-vfs-get child))
          (should (equal (gptel-yatools-vfs--sync-one child) '(:ok "synced")))
          (should (equal (gptel-yatools-test--raw child) "x\n")))))))

;;;; 34. Header-line cache survived a VFS entry being reverted

(ert-deftest gptel-yatools-test-header-line-cache-invalidated-on-revert ()
  "Reverting a pending entry to disk content must clear the label at once."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "h4.txt" default-directory)))
      (gptel-yatools-test--with-file file "a\n"
        (gptel-yatools-vfs-put file "b\n")
        (should (string-match-p "1 file pending"
                                (gptel-yatools-vfs--header-line-label)))
        (gptel-yatools-vfs-put file "a\n")
        (should-not (gptel-yatools-vfs-get file))
        (should (null (gptel-yatools-vfs--header-line-label)))))))

;;;; 35. Missing external `diff' signalled instead of returning a string

(ert-deftest gptel-yatools-test-unified-diff-failure-is-a-clean-string ()
  "A missing `diff' executable must not make vfs_diff signal."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _)
               (signal 'file-missing
                       '("Searching for program"
                         "No such file or directory" "diff")))))
    (let ((out (gptel-yatools-vfs--unified-diff "a\n" "b\n" "x.txt")))
      (should (stringp out))
      (should (string-match-p "diff command failed" out)))))

;;;; 36. A nil regexp signalled wrong-type-argument

(ert-deftest gptel-yatools-test-nil-regex-is-a-clean-message ()
  "A non-string regexp must be reported, not signalled."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "nil-rx.txt" default-directory)))
      (gptel-yatools-test--with-file file "abc\n"
        (let ((out (funcall (gptel-yatools-test--tool
                             "fetch_lines_from_file_using_regex")
                            file nil)))
          (should (stringp out))
          (should (string-match-p "regexp must be a string" out)))))))

;;;; 37. Missing/wrong-typed required tool arguments

(ert-deftest gptel-yatools-test-non-string-tool-arguments-are-clean ()
  "A nil or numeric path/command must yield a readable error."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (dolist (case '(("read_path" (nil))
                      ("read_file_from_offset" (nil 1 1))
                      ("fetch_lines_from_file_using_regex" (nil "x"))
                      ("execute_command" (nil))
                      ("write_file" (nil "x"))
                      ("write_file_diff" (nil "a" "b"))
                      ("file_sync" (42))
                      ("vfs_diff" (42))
                      ("vfs_discard" (42))))
        (let* ((name (car case))
               (args (cadr case))
               (err (should-error
                     (apply (gptel-yatools-test--tool name) args))))
          (should (string-match-p "must be a string" (cadr err))))))))

;;;; 38. `file_sync' hung forever in a non-interactive Emacs

(ert-deftest gptel-yatools-test-file-sync-refuses-to-hang-in-batch ()
  "Non-interactive file_sync must refuse instead of entering recursive-edit."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "batch.txt" default-directory)))
      (gptel-yatools-test--with-file file "orig\n"
        (gptel-yatools-vfs-put file "vfs\n")
        (let ((noninteractive t)
              (out nil))
          (gptel-yatools-test--silencing-message
            (setq out (funcall (gptel-yatools-test--tool "file_sync"))))
          (should (stringp out))
          (should (string-match-p "non-interactively" out))
          ;; Nothing may be written without an actual confirmation.
          (should (equal (gptel-yatools-vfs--disk-content file) "orig\n"))
          (should (gptel-yatools-vfs-get file)))))))

(ert-deftest gptel-yatools-test-kill-buffer-guard-does-not-prompt-in-batch ()
  "The unsynced-changes kill guard must not block batch cleanup."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "kill.txt" default-directory)))
      (gptel-yatools-test--with-file file "orig\n"
        (gptel-yatools-vfs-put file "vfs\n")
        (let ((noninteractive t))
          (gptel-yatools-test--silencing-message
            (should (gptel-yatools-vfs--query-kill-buffer))))))))

;;;; 39. A failed buffer refresh after a successful write left a zombie entry

(ert-deftest gptel-yatools-test-sync-ok-even-if-buffer-refresh-fails ()
  "A refresh failure must not hide that the file was synced."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "refresh.txt" default-directory)))
      (gptel-yatools-test--write file "orig\n")
      (gptel-yatools-test--with-open-buffer file
        (with-temp-buffer
          (gptel-yatools-test--vfs
            (gptel-yatools-vfs-put file "vfs\n")
            (cl-letf (((symbol-function 'revert-buffer)
                       (lambda (&rest _) (error "refresh failed"))))
              (gptel-yatools-test--silencing-message
                (should (equal (gptel-yatools-vfs--sync-one file)
                               '(:ok "synced"))))))
          (should-not (gptel-yatools-vfs-get file))
          (should-not (gptel-yatools-vfs--changed-paths))
          (should (equal (gptel-yatools-vfs--disk-content file) "vfs\n")))))))

;;;; 40. `execute_elisp' output was unbounded

(ert-deftest gptel-yatools-test-execute-elisp-output-is-truncated ()
  "A `princ' loop must not return a 300k-character tool response."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (let ((out (funcall (gptel-yatools-test--tool "execute_elisp")
                          "(dotimes (_ 30000) (princ \"abcdefghij\"))")))
        (should (stringp out))
        (should (<= (length out) (+ gptel-yatools-vfs--output-char-limit 1000)))
        (should (string-match-p "truncated" out))
        (should (condition-case nil (progn (json-serialize out) t)
                  (error nil)))))))

;;;; 41. `overwrite="false"' silently discarded a conflict

(ert-deftest gptel-yatools-test-string-false-overwrite-keeps-conflict ()
  "A string \"false\" must behave as false, not reset the baseline."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "ow.txt" default-directory)))
      (gptel-yatools-test--with-file file "base\n"
        (gptel-yatools-vfs-put file "vfs\n")
        ;; External change lands after the VFS captured the file.
        (gptel-yatools-test--write file "external\n")
        (should (string-match-p
                 "Wrote"
                 (funcall (gptel-yatools-test--tool "write_file")
                          file "forced\n" "false")))
        ;; The conflict must survive; syncing must still refuse.
        (should (gptel-yatools-vfs--conflict-p file))
        (should (eq (car (gptel-yatools-vfs--sync-one file)) :failed))
        (should (equal (gptel-yatools-vfs--disk-content file) "external\n"))
        ;; ... while an explicit t does accept the disk content.
        (should (string-match-p
                 "Wrote"
                 (funcall (gptel-yatools-test--tool "write_file")
                          file "forced\n" t)))
        (should-not (gptel-yatools-vfs--conflict-p file))))))

;;;; 42. Loading the package must not depend on how gptel was loaded

(ert-deftest gptel-yatools-test-load-registers-without-enabling ()
  "Requiring the package must register every tool and enable none.

The tools have to be listed by `gptel-menu', which reads gptel's
registry, but nothing may be added to `gptel-tools': which tools a chat
sends is the user's decision, made with `gptel-yatools-enable'."
  (skip-unless (executable-find "emacs"))
  (let ((result
         (gptel-yatools-test--run-batch
          `(progn
             (require 'cl-lib)
             (require 'gptel-yatools)
             (princ (format "tools=%d enabled=%s registered=%d timeouts=%d\n"
                            (length gptel-yatools--tools)
                            gptel-tools
                            (length (cl-remove-if-not
                                     (lambda (tool)
                                       (gptel-get-tool (gptel-tool-name tool)))
                                     gptel-yatools--tools))
                            (cl-count-if
                             (lambda (tool)
                               (equal (plist-get
                                       (car (last (gptel-tool-args tool)))
                                       :name)
                                      "timeout"))
                             gptel-yatools--tools)))))))
    (should (equal (car result) 0))
    (should (string-match-p "tools=11 enabled=nil registered=11 timeouts=11"
                            (cdr result)))))

(ert-deftest gptel-yatools-test-package-compiles-without-warnings ()
  "The package must byte-compile, without a single warning.

This is the test the old `setf' workaround was written for: an accessor
the compiler cannot resolve becomes a call to an undefined
\`(setf ...)' function, which the compiler reports.  Compiling with
warnings promoted to errors pins that down for every accessor, not just
the one that used to break."
  (skip-unless (executable-find "emacs"))
  (let ((result
         (gptel-yatools-test--run-batch
          `(progn
             (require 'bytecomp)
             (let* ((dir (make-temp-file "gptel-yatools-elc-" t))
                    (copy (expand-file-name "gptel-yatools.el" dir)))
               (unwind-protect
                   (progn
                     (copy-file ,gptel-yatools-test--file copy nil 'silent)
                     (let ((byte-compile-error-on-warn t))
                       (unless (byte-compile-file copy)
                         (error "Could not compile %s" copy)))
                     (princ "compiled\n"))
                 (ignore-errors (delete-directory dir t))))))))
    (should (equal (car result) 0))
    (should (string-match-p "compiled" (cdr result)))))

(ert-deftest gptel-yatools-test-enable-all-is-idempotent ()
  "Enabling every tool twice must not send any tool twice."
  (let ((gptel-tools nil))
    (gptel-yatools-enable-all)
    (let ((once (length gptel-tools)))
      (gptel-yatools-enable-all)
      (should (= (length gptel-tools) once)))
    (should (= (length gptel-tools) (length gptel-yatools--tools)))
    (should (= (length gptel-tools)
               (length (delete-dups
                        (mapcar #'gptel-tool-name gptel-tools)))))))

(ert-deftest gptel-yatools-test-enable-one-category ()
  "Enabling a category must add exactly that category's tools."
  (let ((gptel-tools nil))
    (gptel-yatools-enable "filesystem")
    (should (equal (sort (mapcar #'gptel-tool-name gptel-tools) #'string<)
                   (sort (mapcar #'gptel-tool-name
                                 (cl-remove-if-not
                                  (lambda (tool)
                                    (equal (gptel-tool-category tool)
                                           "filesystem"))
                                  gptel-yatools--tools))
                         #'string<)))
    (should (< (length gptel-tools) (length gptel-yatools--tools)))))

(ert-deftest gptel-yatools-test-enable-keeps-other-tools ()
  "Enabling this package's tools must not drop anyone else's."
  (let* ((foreign (gptel--make-tool :name "foreign_tool" :description "x"
                                    :function #'ignore :args nil))
         (gptel-tools (list foreign)))
    (gptel-yatools-enable "shell")
    (should (memq foreign gptel-tools))
    (should (cl-find "execute_command" gptel-tools
                     :key #'gptel-tool-name :test #'equal))))

;;;; 43. Empty results were indistinguishable from an empty file

(ert-deftest gptel-yatools-test-empty-results-say-why ()
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "e.txt" default-directory)))
      (gptel-yatools-test--with-file file "alpha\nbeta\n"
        (let ((no-match (funcall (gptel-yatools-test--tool
                                  "fetch_lines_from_file_using_regex")
                                 file "zzz"))
              (past-end (funcall (gptel-yatools-test--tool
                                  "read_file_from_offset")
                                 file 99 5))
              (zero (funcall (gptel-yatools-test--tool
                              "read_file_from_offset")
                             file 1 0)))
          ;; A bare empty <tool_response> reads like an empty file.
          (should (string-match-p "no lines .* match the regexp" no-match))
          (should (string-match-p "offset 99 is past the end" past-end))
          (should (string-match-p "has 2 line(s)" past-end))
          (should (string-match-p "LINES was 0" zero)))))))

;;;; 44. overwrite: 0 (a number) counted as true

(ert-deftest gptel-yatools-test-overwrite-flag-rejects-zero ()
  "Numeric 0 must be false, like \"0\" and `:json-false'."
  (should-not (gptel-yatools-vfs--flag-p 0))
  (should-not (gptel-yatools-vfs--flag-p 0.0))
  (should-not (gptel-yatools-vfs--flag-p "0"))
  (should-not (gptel-yatools-vfs--flag-p :json-false))
  (should (gptel-yatools-vfs--flag-p 1))
  (should (gptel-yatools-vfs--flag-p t))
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "ow0.txt" default-directory)))
      (gptel-yatools-test--with-file file "base\n"
        (gptel-yatools-vfs-put file "vfs\n")
        (gptel-yatools-test--write file "external\n")
        (funcall (gptel-yatools-test--tool "write_file") file "forced\n" 0)
        (should (gptel-yatools-vfs--conflict-p file))))))

;;;; 45. A trailing newline was counted as an extra line

(ert-deftest gptel-yatools-test-truncate-line-count-ignores-trailing-newline ()
  "Text of exactly the line limit must survive; counts must be real."
  (let* ((text (concat (mapconcat #'number-to-string
                                  (number-sequence 1 gptel-yatools-vfs--output-line-limit)
                                  "\n")
                       "\n"))
         (longer (concat text "2501\n")))
    (should (equal (gptel-yatools-vfs--truncate text) text))
    (should (string-match-p
             (format "first %d of %d lines"
                     gptel-yatools-vfs--output-line-limit
                     (1+ gptel-yatools-vfs--output-line-limit))
             (gptel-yatools-vfs--truncate longer)))))

;;;; 46. Messages mixed absolute and workspace-relative paths

(ert-deftest gptel-yatools-test-tool-messages-use-relative-paths ()
  "Paths in tool messages must be relative to the workspace root."
  (gptel-yatools-test--in-dir
    (with-temp-buffer
      (gptel-yatools-test--vfs
        (funcall (gptel-yatools-test--tool "write_file") "p" "x\n")
        (let ((ancestor (funcall (gptel-yatools-test--tool "write_file")
                                 "p/child" "y\n"))
              (missing (funcall (gptel-yatools-test--tool "execute_command")
                                "true" "no/such"))
              (here (funcall (gptel-yatools-test--tool "execute_command")
                             "true")))
          (should (string-match-p "cannot write p/child: ancestor p"
                                  ancestor))
          (should-not (string-match-p (regexp-quote default-directory)
                                      ancestor))
          (should (string-match-p "does not exist: no/such" missing))
          ;; The workspace root itself is ".", not an empty string.
          (should (string-match-p "succeeded in \\. " here)))))))

;;;; 47. Buffer-local variables must stay special when compiled

(ert-deftest gptel-yatools-test-variables-are-declared-special ()
  "Variables that other files `let'-bind must be declared at top level.

A `defvar' hidden inside the quoted `use-package' body is invisible to
the byte compiler, which then binds the variable lexically and leaves
the real (buffer-local or global) value untouched."
  (dolist (symbol '(gptel-yatools-vfs gptel-yatools-vfs--header-line-cache
                   gptel-yatools--current-timeout gptel-yatools--timeout-suspended))
    (should (special-variable-p symbol))))

;;;; Invariants any future edit must not break

(ert-deftest gptel-yatools-test-all-tools-present ()
  "Every documented tool must stay registered."
  (dolist (name '("read_workspace_root" "read_path" "read_file_from_offset"
                  "fetch_lines_from_file_using_regex" "execute_command"
                  "write_file" "write_file_diff" "file_sync" "vfs_diff"
                  "vfs_discard" "execute_elisp"))
    (should (cl-find name gptel-yatools--tools
                     :key #'gptel-tool-name :test #'equal))))

(ert-deftest gptel-yatools-test-no-op-write-creates-no-entry ()
  "Writing identical content must not create a pending entry."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "same.txt" default-directory)))
      (gptel-yatools-test--with-file file "same\n"
        (should (string-match-p
                 "No change needed"
                 (funcall (gptel-yatools-test--tool "write_file") file "same\n")))
        (should-not (gptel-yatools-vfs-get file))))))

(ert-deftest gptel-yatools-test-sync-removes-entry ()
  "A successful sync must drop the pending entry."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "s.txt" default-directory)))
      (gptel-yatools-test--with-file file "orig\n"
        (gptel-yatools-vfs-put file "new\n")
        (should (gptel-yatools-vfs--sync-one file))
        (should-not (gptel-yatools-vfs-get file))
        (should-not (gptel-yatools-vfs--changed-paths))
        (should (equal (gptel-yatools-vfs--disk-content file) "new\n"))))))

;;;; 48. Tool calls could block Emacs forever

(defun gptel-yatools-test--occurrences (string substring)
  "Return how many times SUBSTRING occurs in STRING."
  (let ((count 0)
        (position 0)
        (step (length substring)))
    (while (and position (setq position (string-match (regexp-quote substring)
                                                      string position)))
      (setq count (1+ count)
            position (+ position step)))
    count))

(ert-deftest gptel-yatools-test-every-tool-declares-a-timeout ()
  "Every tool must accept TIMEOUT and tell the model not to raise it."
  (dolist (tool gptel-yatools--tools)
    (unless (gptel-tool-async tool)
      (let ((description (gptel-tool-description tool))
            (args (gptel-tool-args tool)))
        (should (equal (plist-get (car (last args)) :name) "timeout"))
        (should (= 1 (cl-count-if (lambda (arg)
                                    (equal (plist-get arg :name) "timeout"))
                                  args)))
        ;; Exactly one note: installed twice, it must not pile up.
        (should (= 1 (gptel-yatools-test--occurrences description "Timeouts: ")))
        (should (string-match-p "do not raise the timeout unless"
                                description))))))

(ert-deftest gptel-yatools-test-timeout-resolution ()
  "The default timeout must be used unless the model overrides it."
  (should (= (gptel-yatools--resolve-timeout nil) gptel-yatools-timeout))
  (should (= (gptel-yatools--resolve-timeout 45) 45))
  (should (= (gptel-yatools--resolve-timeout "30") 30))
  ;; Unusable values fall back on the default instead of signalling.
  (should (= (gptel-yatools--resolve-timeout :json-false) gptel-yatools-timeout))
  (should (= (gptel-yatools--resolve-timeout 0) gptel-yatools-timeout))
  ;; A non-numeric setting must not break every tool call either.
  (let ((gptel-yatools-timeout "not a number"))
    (should (= (gptel-yatools--resolve-timeout nil) 120))))

(ert-deftest gptel-yatools-test-timeout-kills-command ()
  "A command that outlives the timeout must be killed, keeping its output."
  (let ((start (float-time))
        (out (funcall (gptel-yatools-test--tool "execute_command")
                      "echo started; sleep 20; echo finished" nil 1)))
    (should (string-match-p "1 second timeout" out))
    (should (string-match-p "started" out))
    (should-not (string-match-p "finished" out))
    (should (< (- (float-time) start) 10))))

(ert-deftest gptel-yatools-test-timeout-aborts-elisp ()
  "A form that outlives the timeout must be abandoned."
  (let ((out (funcall (gptel-yatools-test--tool "execute_elisp")
                      "(progn (sleep-for 20) 'finished)" 1)))
    (should (string-match-p "did not finish within its 1 second timeout" out))
    ;; The form never ran to completion: no evaluation report is returned.
    (should-not (string-match-p "Return value:" out))
    (should-not (string-match-p "Printed output:" out))))

(ert-deftest gptel-yatools-test-timeout-ignores-user-wait ()
  "Time the tool spends waiting for the user must not count."
  (should (eq (gptel-yatools--call-with-timeout
               (lambda ()
                 (let ((gptel-yatools--timeout-suspended t))
                   (sleep-for 2))
                 'reviewed)
               nil 1)
              'reviewed)))

(ert-deftest gptel-yatools-test-timeout-leaves-no-timer ()
  "A finished call must cancel its deadline timer."
  (gptel-yatools-test--in-dir
    (let ((before (length timer-list)))
      (dotimes (_ 5)
        (funcall (gptel-yatools-test--tool "read_workspace_root")))
      (should (= (length timer-list) before)))))

(ert-deftest gptel-yatools-test-timeout-install-is-idempotent ()
  "Installing the timeout twice must not duplicate the argument or the note.

`gptel--make-tool' is used instead of `gptel-make-tool' because the
latter also registers the tool in `gptel--known-tools', which the
suite must not pollute."
  (let ((tool (gptel--make-tool
               :name "probe_tool"
               :description "Probe."
               :function (lambda (x) x)
               :args (list (list :name "x" :type 'string :description "x")))))
    (gptel-yatools--install-timeout tool)
    (gptel-yatools--install-timeout tool)
    (should (= 1 (cl-count-if (lambda (arg)
                                (equal (plist-get arg :name) "timeout"))
                              (gptel-tool-args tool))))
    (should (= 1 (gptel-yatools-test--occurrences
                  (gptel-tool-description tool) "Timeouts: ")))
    ;; The guard must still pass the real arguments through.
    (should (equal (funcall (gptel-tool-function tool) "value" 5) "value"))))

(ert-deftest gptel-yatools-test-timeout-skips-async-tools ()
  "An asynchronous tool must be left exactly as it was.

Its result arrives long after the call returns, so wrapping it in a
deadline would only mislabel it as timed out while it still runs."
  (let* ((function (lambda (callback x) (funcall callback x)))
         (tool (gptel--make-tool
                :name "async_probe_tool"
                :async t
                :description "Probe."
                :function function
                :args (list (list :name "x" :type 'string :description "x")))))
    (gptel-yatools--install-timeout tool)
    (should (eq (gptel-tool-function tool) function))
    (should (equal (mapcar (lambda (arg) (plist-get arg :name))
                           (gptel-tool-args tool))
                   '("x")))))

;;;; 49. `file_sync' lost the VFS when the review buffer was killed

(ert-deftest gptel-yatools-test-file-sync-keeps-the-vfs-buffer ()
  "A review that leaves another buffer current must not empty the VFS.

`gptel-yatools-vfs' is buffer-local, and the review shows a diff buffer and
kills it again.  Killing the buffer displayed in the selected window
leaves Emacs free to pick another buffer for that window, so the sync
that followed could run in a buffer whose VFS was a fresh, empty
table: every file was reported as \"no VFS entry\" and nothing was
synced, even though the files had been listed as pending a moment
before."
  (gptel-yatools-test--in-dir
    (let ((one (expand-file-name "r1.txt" default-directory))
          (two (expand-file-name "r2.txt" default-directory))
          (elsewhere (get-buffer-create " *gptel-yatools-test-elsewhere*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write one "orig\n")
            (gptel-yatools-test--write two "orig\n")
            (with-temp-buffer
              ;; The VFS is installed with `setq-local', exactly as the real
              ;; tools install it.  `gptel-yatools-test--vfs' cannot be used here:
              ;; it `let'-binds an automatically buffer-local variable, and
              ;; such a binding is visible from every buffer, which would hide
              ;; the very bug under test.
              (setq-local gptel-yatools-vfs (make-hash-table :test #'equal))
              (gptel-yatools-vfs-put one "vfs\n")
              (gptel-yatools-vfs-put two "vfs\n")
              (gptel-yatools-test--silencing-message
                (cl-letf (((symbol-function 'gptel-yatools-vfs--confirm-sync)
                           (lambda (&rest _)
                             ;; Mimic the review: the diff buffer was shown
                             ;; and killed, and the window now displays some
                             ;; other buffer.
                             (set-buffer elsewhere)
                             t)))
                  (let ((out (funcall (gptel-yatools-test--tool "file_sync"))))
                    (should (string-match-p "Synced 2 file(s)" out))
                    (should-not (string-match-p "no VFS entry" out)))))
              ;; The stray buffer must not have been handed a VFS of its own.
              (should-not (local-variable-p 'gptel-yatools-vfs elsewhere)))
            (should (equal (gptel-yatools-vfs--disk-content one) "vfs\n"))
            (should (equal (gptel-yatools-vfs--disk-content two) "vfs\n")))
        (kill-buffer elsewhere)))))

(ert-deftest gptel-yatools-test-confirm-sync-restores-the-caller-buffer ()
  "Accepting the review must return to the buffer the tool runs in.

`file_sync' keeps using buffer-local state (`gptel-yatools-vfs',
`default-directory') after the review, so leaving the user -- and the
tool -- in the review buffer, or in whatever buffer replaced it, is
not merely cosmetic."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "rev.txt" default-directory)))
      (ignore-errors (kill-buffer "*gptel VFS sync diff*"))
      (gptel-yatools-test--with-file file "orig\n"
        (gptel-yatools-vfs-put file "vfs\n")
        (let ((owner (current-buffer))
              ;; In batch nothing could otherwise be shown, and the review
              ;; refuses to run.  The acceptance comes from the timer below.
              (noninteractive nil))
          (run-at-time 0.2 nil
                       (lambda ()
                         (with-current-buffer (get-buffer "*gptel VFS sync diff*")
                           (gptel-yatools-write-diff-accept))))
          (should (gptel-yatools-vfs--confirm-sync (list file)))
          (should (eq (current-buffer) owner))
          (should-not (get-buffer "*gptel VFS sync diff*")))))))

;;;; 50. Tool calls must run in the buffer that owns the request

;; `gptel-yatools-vfs' and `default-directory' are buffer-local, so a tool call that
;; runs in another buffer silently uses that buffer's fresh, empty VFS and
;; resolves relative paths against that buffer's directory.  gptel anchors
;; the automatic path and the minibuffer confirmation path, but
;; `gptel--accept-tool-calls' is also reached from the
;; `*gptel-tool-calls*' inspection buffer, which is where the VFS used to be
;; lost.

(ert-deftest gptel-yatools-test-tool-call-runs-in-request-buffer ()
  "A write confirmed from another buffer must land in the chat's VFS."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (gptel-yatools-test--noninteractive
              (gptel-yatools-test--accept-in
               inspect chat (gptel-yatools-test--tool-spec "write_file")
               (list :path "f.txt" :content "new\n")))
            (should (equal (with-current-buffer chat (gptel-yatools-vfs-get file))
                           "new\n"))
            (should-not (with-current-buffer inspect (gptel-yatools-vfs-get file)))
            (should (equal (with-current-buffer chat
                             (gptel-yatools-vfs--changed-paths))
                           (list file))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-file-sync-runs-in-request-buffer ()
  "`file_sync' confirmed elsewhere must see the chat's pending changes.

Reporting \"no pending changes\" here is not a cosmetic difference: it
tells the model the work is done when nothing was written at all."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (with-current-buffer chat (gptel-yatools-vfs-put file "pending\n"))
            (let* ((noninteractive t)
                   (out (gptel-yatools-test--silencing-message
                          (gptel-yatools-test--noninteractive
                            (gptel-yatools-test--accept-in
                             inspect chat
                             (gptel-yatools-test--tool-spec "file_sync") nil)))))
              ;; Non-interactive Emacs cannot show the review, so the sync is
              ;; refused -- but only after finding the pending file.
              (should-not (string-match-p "no pending changes" out))
              (should (string-match-p "non-interactively" out))
              (should (equal (gptel-yatools-vfs--disk-content file) "orig\n"))
              (should (with-current-buffer chat (gptel-yatools-vfs-get file)))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-command-warns-about-request-buffer-vfs ()
  "`execute_command' confirmed elsewhere must report the chat's VFS state.

The XML provenance tag promises the model that the command ran against
disk and says whether pending VFS changes may explain the output.  Read
from the wrong buffer it claims there are none."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (with-current-buffer chat (gptel-yatools-vfs-put file "pending\n"))
            (let ((out (gptel-yatools-test--silencing-message
                         (gptel-yatools-test--noninteractive
                           (gptel-yatools-test--accept-in
                            inspect chat
                            (gptel-yatools-test--tool-spec "execute_command")
                            (list :command "true"))))))
              (should (string-match-p "vfs=\"true\"" out))
              (should (string-match-p "WARNING" out))
              (should (string-match-p "f.txt" out))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-auto-tool-call-uses-request-buffer ()
  "The unconfirmed path must also run in the request buffer.

gptel re-enters `(plist-get info :buffer)' itself here; this test pins
that down, so a future gptel change that drops the wrapper is noticed
rather than silently losing the VFS."
  (gptel-yatools-test--in-dir
    (let* ((file (expand-file-name "f.txt" default-directory))
           (chat (gptel-yatools-test--request-buffer))
           (decoy (gptel-yatools-test--request-buffer " *gptel-yatools-test-decoy*"))
           (tool (gptel-yatools-test--tool-spec "write_file"))
           (tool-call (list :name "write_file"
                            :args (list :path "f.txt" :content "auto\n")))
           (info (list :buffer chat :tools (list tool)
                       :tool-use (list tool-call)
                       :callback (lambda (&rest _) nil)
                       ;; `gptel--handle-tool-use' only requires a non-nil
                       ;; backend here; the request state is synthetic and no
                       ;; network call is made.
                       :backend 'gptel-yatools-test-backend
                       :data nil))
           (fsm (gptel-make-fsm :state 'TOOL :info info)))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            ;; Only the transition is stubbed: the tool itself must run.
            (cl-letf (((symbol-function 'gptel--fsm-transition)
                       (lambda (&rest _) nil)))
              (with-current-buffer decoy
                (gptel-yatools-test--noninteractive
                  (gptel--handle-tool-use fsm))))
            (should (equal (with-current-buffer chat (gptel-yatools-vfs-get file))
                           "auto\n"))
            (should-not (with-current-buffer decoy (gptel-yatools-vfs-get file))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer decoy)))))

(ert-deftest gptel-yatools-test-inspect-accept-runs-in-request-buffer ()
  "Accepting from `*gptel-tool-calls*' must not use that buffer's VFS.

This drives the real inspection command, so it also covers the
`quit-window' and `gptel--fsm-last' plumbing that a synthetic call
would skip."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (let ((tool-call (list (gptel-yatools-test--tool-spec "write_file")
                                   (list :path "f.txt" :content "inspected\n")
                                   (lambda (&rest _) nil))))
              (with-current-buffer inspect
                (setq gptel--fsm-last
                      (gptel-make-fsm
                       :state 'TOOL
                       :info (list :buffer chat
                                   :tool-display (list (list tool-call) nil))))
                (gptel-yatools-test--noninteractive
                  (gptel--inspect-accept-tool-calls))))
            (should (equal (with-current-buffer chat (gptel-yatools-vfs-get file))
                           "inspected\n"))
            (should-not (with-current-buffer inspect (gptel-yatools-vfs-get file))))
        (gptel-yatools-test--kill-request-buffer chat)
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-inspection-buffer-forgets-stale-vfs ()
  "A reused inspection buffer must not keep an old VFS.

`gptel--inspect-tool-calls' reuses `*gptel-tool-calls*' with
`erase-buffer', so a table left there by an earlier session would keep
its entries, and the kill guard would then ask about files nobody
touched from that buffer."
  (let ((chat (gptel-yatools-test--request-buffer))
        (inspect (get-buffer-create "*gptel-tool-calls*")))
    (unwind-protect
        (progn
          (with-current-buffer inspect
            ;; A *reused* inspection buffer is already in `lisp-data-mode',
            ;; so gptel skips the mode switch (and its
            ;; `kill-all-local-variables') on the second use.  Emulate that:
            ;; with the mode already set, buffer-local state survives.
            (lisp-data-mode)
            (setq-local gptel-yatools-vfs (make-hash-table :test #'equal))
            (puthash (expand-file-name "stale.txt" temporary-file-directory)
                     (list :content "x\n" :baseline "y\n" :coding 'utf-8-unix
                           :baseline-coding 'utf-8-unix)
                     gptel-yatools-vfs))
          (gptel-yatools-test--noninteractive
            (gptel--inspect-tool-calls
             (list (list (gptel-yatools-test--tool-spec "read_path")
                         (list :path "x") (lambda (&rest _) nil)))
             (list :buffer chat :tool-use nil :tools gptel-yatools--tools)))
          (with-current-buffer inspect
            (should-not (local-variable-p 'gptel-yatools-vfs))
            (should-not (local-variable-p 'gptel-yatools-vfs--header-line-cache))))
      (gptel-yatools-test--kill-request-buffer chat)
      (let ((kill-buffer-query-functions nil)) (kill-buffer inspect)))))

(ert-deftest gptel-yatools-test-tool-call-on-dead-owner-is-refused ()
  "A tool call whose chat buffer is gone must fail, not run elsewhere.

gptel itself raises `Selecting deleted buffer' in this situation; the
point of the check is that the tool never runs against some unrelated
buffer's VFS or directory."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (chat (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (gptel-yatools-test--kill-request-buffer chat)
            (let ((err (should-error
                        (gptel-yatools-test--noninteractive
                          (gptel-yatools-test--accept-in
                           inspect chat
                           (gptel-yatools-test--tool-spec "write_file")
                           (list :path "f.txt" :content "nowhere\n")))
                        :type 'user-error)))
              (should (string-match-p "no longer exists"
                                      (error-message-string err))))
            (should (equal (gptel-yatools-vfs--disk-content file) "orig\n"))
            (should-not (with-current-buffer inspect (gptel-yatools-vfs-get file))))
        (gptel-yatools-test--kill-request-buffer inspect)))))

(ert-deftest gptel-yatools-test-tool-calls-do-not-share-a-vfs ()
  "Anchoring the dispatcher must not merge two chats' VFS tables."
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "f.txt" default-directory))
          (first (gptel-yatools-test--request-buffer))
          (second (gptel-yatools-test--request-buffer))
          (inspect (gptel-yatools-test--request-buffer "*gptel-tool-calls*")))
      (unwind-protect
          (progn
            (gptel-yatools-test--write file "orig\n")
            (with-current-buffer second (gptel-yatools-vfs-put file "for-second\n"))
            (gptel-yatools-test--noninteractive
              (gptel-yatools-test--accept-in
               inspect first (gptel-yatools-test--tool-spec "write_file")
               (list :path "f.txt" :content "for-first\n")))
            (should (equal (with-current-buffer first (gptel-yatools-vfs-get file))
                           "for-first\n"))
            (should (equal (with-current-buffer second (gptel-yatools-vfs-get file))
                           "for-second\n"))
            (should (equal (with-current-buffer first
                             (gptel-yatools-vfs--changed-paths))
                           (list file)))
            (should (equal (with-current-buffer second
                             (gptel-yatools-vfs--changed-paths))
                           (list file))))
        (dolist (buffer (list first second inspect))
          (gptel-yatools-test--kill-request-buffer buffer))))))

(ert-deftest gptel-yatools-test-dispatch-advice-is-installed-once ()
  "Reloading the package must not stack dispatch advices.

Reloading in place is normal while developing, and the tool list is
rebuilt on every load, so every advice the file installs has to survive
that.  `advice-add' happens to ignore an identical second advice, but
the count is what pins the guarantee down."
  (load gptel-yatools-test--file nil t)
  (load gptel-yatools-test--file nil t)
  (should (= 1 (gptel-yatools-test--advice-count
                'gptel--accept-tool-calls
                #'gptel-yatools-vfs--accept-tool-calls-in-owner)))
  (should (= 1 (gptel-yatools-test--advice-count
                'gptel--inspect-tool-calls
                #'gptel-yatools-vfs--forget-inspection-vfs)))
  (should (advice-member-p #'gptel-yatools-vfs--accept-tool-calls-in-owner
                           'gptel--accept-tool-calls)))

(provide 'gptel-yatools-tests)
;;; gptel-yatools-tests.el ends here
