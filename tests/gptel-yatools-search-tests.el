;;; gptel-yatools-search-tests.el --- Tests for finding files and lines  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2026  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The `glob' and `grep' tools: the local walk, the wildcard and regexp
;; dialects, the VFS merge, the budgets that keep a walk inside a call, and
;; the remote courier that does the same work in one round trip.  The
;; helpers live in `gptel-yatools-test-lib.el'; the rest of the filesystem
;; tools are in `gptel-yatools-vfs-tests.el'.
;;
;; Every assertion goes through the tool boundary, so it sees the text the
;; model would.

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


;;;; Helpers

(defun gptel-yatools-search-test--body (text)
  "Return TEXT's body, unwrapped from the envelope the tool boundary adds.

The boundary is the seam these tests go through, so what it returns is the
envelope; the assertions are about the body inside it.  A reply without a
body tag is returned unchanged, which makes a broken envelope fail loudly
rather than silently matching nothing."
  (if (string-match "<tool_response>\n\\(\\(?:.\\|\n\\)*\\)\n</tool_response>\\'"
                    text)
      (match-string 1 text)
    text))

(defun gptel-yatools-search-test--glob (pattern &optional path)
  "Call the `glob' tool with PATTERN and PATH, and return its body."
  (gptel-yatools-search-test--body
   (funcall (gptel-yatools-test--tool "glob") pattern path)))

(defun gptel-yatools-search-test--grep (pattern &optional path)
  "Call the `grep' tool with PATTERN and PATH, and return its body."
  (gptel-yatools-search-test--body
   (funcall (gptel-yatools-test--tool "grep") pattern path)))

(defun gptel-yatools-search-test--tree (files)
  "Write FILES, an alist of relative path to content, under the workspace root."
  (dolist (pair files)
    (let ((full (gptel-yatools-test--root-file (car pair))))
      (make-directory (file-name-directory full) t)
      (gptel-yatools-test--write full (cdr pair)))))

(defun gptel-yatools-search-test--age (relative seconds)
  "Set the mtime of RELATIVE, under the workspace root, SECONDS into the past."
  (set-file-times (gptel-yatools-test--root-file relative)
                  (time-subtract (current-time) (seconds-to-time seconds))))


;;;; 1. glob finds files the model could not have named

(ert-deftest gptel-yatools-test-glob-finds-by-basename-at-any-depth ()
  "A pattern with no slash matches the file name at every depth."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.el" . "a")
                                       ("notes.txt" . "n")
                                       ("sub/deep/b.el" . "b")))
    (gptel-yatools-test--vfs
      ;; Order is a separate question (`-orders-newest-first' settles it),
      ;; so these assertions name the lines and not their positions.
      (let ((body (gptel-yatools-search-test--glob "*.el")))
        (should (string-match-p "\\(?:\\`\\|\n\\)a\\.el\t" body))
        (should (string-match-p "\\(?:\\`\\|\n\\)sub/deep/b\\.el\t" body))
        (should-not (string-match-p "notes\\.txt" body))))))

(ert-deftest gptel-yatools-test-glob-double-star-crosses-directories ()
  "`**' crosses directories while a single `*' does not."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("sub/a.el" . "a")
                                       ("sub/deep/b.el" . "b")))
    (gptel-yatools-test--vfs
      (should (string-match-p "sub/deep/b\\.el"
                              (gptel-yatools-search-test--glob "sub/**/*.el")))
      (should-not (string-match-p "deep"
                                  (gptel-yatools-search-test--glob "sub/*.el"))))))

(ert-deftest gptel-yatools-test-glob-orders-newest-first ()
  "The most recently written file comes first."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("old.el" . "o")
                                       ("new.el" . "n")))
    (gptel-yatools-search-test--age "old.el" 3600)
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--glob "*.el")))
        (should (string-match-p "\\`new\\.el" body))
        (should (string-match-p "\nold\\.el" body))))))

(ert-deftest gptel-yatools-test-glob-skips-version-control-directories ()
  "Nothing under a skipped directory name is returned."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.el" . "a")
                                       (".git/objects/b.el" . "b")
                                       ("node_modules/c/d.el" . "d")))
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--glob "*.el")))
        (should (string-match-p "\\`a\\.el" body))
        (should-not (string-match-p "\\.git" body))
        (should-not (string-match-p "node_modules" body))))))

(ert-deftest gptel-yatools-test-glob-scopes-the-walk-to-a-path ()
  "PATH limits the walk to that directory, and returned paths stay root-relative."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("keep/x.el" . "x")
                                       ("drop/y.el" . "y")))
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--glob "*.el" "keep")))
        (should (string-match-p "\\`keep/x\\.el" body))
        (should-not (string-match-p "drop" body))))))

(ert-deftest gptel-yatools-test-glob-says-so-when-nothing-matches ()
  "An empty result is a sentence, not an empty body."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.el" . "a")))
    (gptel-yatools-test--vfs
      (should (string-match-p "\\`No files under"
                              (gptel-yatools-search-test--glob "*.zig"))))))

(ert-deftest gptel-yatools-test-glob-finds-a-file-that-exists-only-in-the-vfs ()
  "A file written but not yet synced is found, and marked as pending."
  (gptel-yatools-test--in-dir
    (gptel-yatools-test--vfs
      (let ((file (gptel-yatools-test--root-file "fresh.el")))
        (gptel-yatools-vfs-put file "(provide 'fresh)")
        (let ((body (gptel-yatools-search-test--glob "*.el")))
          (should (string-match-p "\\`fresh\\.el\t.*(pending)" body)))))))

(ert-deftest gptel-yatools-test-glob-marks-a-pending-change-to-a-disk-file ()
  "A file on disk whose content is pending appears once, marked."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.el" . "old")))
    (gptel-yatools-test--vfs
      (gptel-yatools-vfs-put (gptel-yatools-test--root-file "a.el") "new")
      (let ((body (gptel-yatools-search-test--glob "*.el")))
        (should (= 1 (length (split-string body "\n"))))
        (should (string-match-p "\\`a\\.el\t.*(pending)" body))))))

;;;; 2. grep finds lines, in a tree nobody named

(ert-deftest gptel-yatools-test-grep-finds-lines-across-the-tree ()
  "Every matching line is reported with its file and 1-based line number."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.el" . "one\nneedle here\n")
                                       ("sub/b.el" . "nothing\n")
                                       ("sub/deep/c.el" . "also a needle\n")))
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--grep "needle")))
        (should (string-match-p "a\\.el:2:needle here" body))
        (should (string-match-p "sub/deep/c\\.el:1:also a needle" body))
        (should-not (string-match-p "b\\.el" body))))))

(ert-deftest gptel-yatools-test-grep-is-case-insensitive-unless-the-pattern-is-not ()
  "A lowercase pattern matches any case; one with a capital is exact."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.el" . "Needle\nneedle\nNEEDLE\n")))
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--grep "needle")))
        (should (string-match-p "3 matching line(s) in 1 file(s)" body))
        (should (string-match-p "a\\.el:3:NEEDLE" body)))
      (let ((body (gptel-yatools-search-test--grep "Needle")))
        (should (string-match-p "1 matching line(s) in 1 file(s)" body))
        (should (string-match-p "a\\.el:1:Needle" body))
        (should-not (string-match-p "a\\.el:2:" body))))))

(ert-deftest gptel-yatools-test-grep-caps-the-lines-one-file-may-contribute ()
  "One busy file cannot crowd every other file out of the reply."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree
     `(("busy.el" . ,(mapconcat (lambda (n) (format "hit %d" n))
                                (number-sequence 1 30) "\n"))
       ("quiet.el" . "hit once\n")))
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--grep "hit")))
        (should (string-match-p "quiet\\.el:1:hit once" body))
        (should (string-match-p "busy\\.el: more than 20 matching lines" body))
        (should-not (string-match-p "busy\\.el:21:" body))))))

(ert-deftest gptel-yatools-test-grep-reads-pending-text-not-disk ()
  "A line written to the VFS is found, and the disk line it shadows is not."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.el" . "on disk\n")))
    (gptel-yatools-test--vfs
      (gptel-yatools-vfs-put (gptel-yatools-test--root-file "a.el")
                             "in the vfs needle\n")
      (let ((body (gptel-yatools-search-test--grep "needle")))
        (should (string-match-p "a\\.el:1:in the vfs needle\t(pending)" body)))
      (let ((body (gptel-yatools-search-test--grep "on disk")))
        (should-not (string-match-p "a\\.el" body))))))

(ert-deftest gptel-yatools-test-grep-leaves-binary-files-alone ()
  "A file with a NUL byte is skipped rather than searched."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.txt" . "needle\n")))
    (gptel-yatools-test--write (gptel-yatools-test--root-file "bin.dat")
                               "needle\0needle")
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--grep "needle")))
        (should (string-match-p "a\\.txt:1:" body))
        (should-not (string-match-p "bin\\.dat" body))))))

(provide 'gptel-yatools-search-tests)
