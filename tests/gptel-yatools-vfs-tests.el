;;; gptel-yatools-vfs-tests.el --- Tests for the virtual filesystem  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The filesystem tools, the virtual filesystem they share, and the sync
;; review UI.  The helpers live in `gptel-yatools-test-lib.el', the glue and
;; timeout tests in `gptel-yatools-tests.el', the shell and Elisp tools in
;; that same file, and Agent Skills in `gptel-yatools-skills-tests.el'.
;;
;; Run everything with the recipe in the README; no test prompts the user.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-yatools)
(unless (featurep 'gptel-yatools-test-lib)
  ;; Loaded by path, not by feature: a suite has to work from a checkout
  ;; without the tests directory being on `load-path'.
  (load (expand-file-name "gptel-yatools-test-lib.el"
                          (file-name-directory
                           (or load-file-name buffer-file-name)))
        nil 'nosuffix))

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


;;;; 7. "No pending changes" claimed vfs="true"

(ert-deftest gptel-yatools-test-no-pending-changes-reports-vfs-false ()
  "An empty VFS must be reported as vfs=\"false\"."
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (should (string-match-p "vfs=\"false\""
                              (funcall (gptel-yatools-test--tool "vfs_diff"))))
      (should (string-match-p "vfs=\"false\""
                              (funcall (gptel-yatools-test--tool "vfs_discard")))))))


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
  "Reading a directory as a file must explain itself, in the envelope."
  (gptel-yatools-test--in-dir
    (let ((dir (make-temp-file "sub" t)))
      (unwind-protect
          (with-temp-buffer
            (gptel-yatools-test--vfs
              (let ((out (funcall (gptel-yatools-test--tool "read_file_from_offset")
                                  dir 1 1)))
                (should (string-match-p "is a directory, not a file" out))
                (gptel-yatools-test--should-be-enveloped out))))
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


;;;; 25. FIFOs and devices would hang Emacs

(ert-deftest gptel-yatools-test-non-regular-file-is-refused ()
  "A device or FIFO must be refused rather than read."
  (skip-unless (file-exists-p "/dev/null"))
  (with-temp-buffer
    (gptel-yatools-test--vfs
      (let ((out (funcall (gptel-yatools-test--tool "read_path") "/dev/null")))
        (should (string-match-p "not a regular file" out))
        (gptel-yatools-test--should-be-enveloped out)))))

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
  "Reading an unreadable directory must explain itself, in the envelope."
  (gptel-yatools-test--in-dir
    (let ((dir (make-temp-file "noread" t)))
      (unwind-protect
          (progn
            (set-file-modes dir #o000)
            (with-temp-buffer
              (gptel-yatools-test--vfs
                (let ((out (funcall (gptel-yatools-test--tool "read_path") dir)))
                  (should (string-match-p "cannot read directory" out))
                  (gptel-yatools-test--should-be-enveloped out)))))
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
  (should-not (gptel-yatools--flag-p 0))
  (should-not (gptel-yatools--flag-p 0.0))
  (should-not (gptel-yatools--flag-p "0"))
  (should-not (gptel-yatools--flag-p :json-false))
  (should (gptel-yatools--flag-p 1))
  (should (gptel-yatools--flag-p t))
  (gptel-yatools-test--in-dir
    (let ((file (expand-file-name "ow0.txt" default-directory)))
      (gptel-yatools-test--with-file file "base\n"
        (gptel-yatools-vfs-put file "vfs\n")
        (gptel-yatools-test--write file "external\n")
        (funcall (gptel-yatools-test--tool "write_file") file "forced\n" 0)
        (should (gptel-yatools-vfs--conflict-p file))))))


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



(provide 'gptel-yatools-vfs-tests)
;;; gptel-yatools-vfs-tests.el ends here
