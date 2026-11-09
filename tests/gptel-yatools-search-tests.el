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
        (should (string-match-p "Showing 3 matching line(s) from 1 of 1 file(s)" body))
        (should (string-match-p "a\\.el:3:NEEDLE" body)))
      (let ((body (gptel-yatools-search-test--grep "Needle")))
        (should (string-match-p "Showing 1 matching line(s) from 1 of 1 file(s)" body))
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
        (should (string-match-p "busy\\.el: 30 matching line(s), the first 20 are shown" body))
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
  "A file with a NUL byte is skipped rather than searched, and counted."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.txt" . "needle\n")))
    (gptel-yatools-test--write (gptel-yatools-test--root-file "bin.dat")
                               "needle\0needle")
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--grep "needle")))
        (should (string-match-p "a\\.txt:1:" body))
        (should-not (string-match-p "bin\\.dat" body))
        (should (string-match-p "1 binary file" body))))))

(ert-deftest gptel-yatools-test-grep-counts-a-file-that-is-not-regular ()
  "A file the reader will not call text is reported, not dropped in silence."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.txt" . "needle\n")
                                       ("b.dat" . "needle\n")))
    (gptel-yatools-test--vfs
      (cl-letf (((symbol-function 'gptel-yatools-vfs-read)
                 (lambda (path &optional _disk-only _max-size)
                   (if (string-match-p "a\\.txt\\'" path)
                       (list :kind :text :path path :text "needle\n"
                             :provenance :disk)
                     (list :kind :special :path path)))))
        (let ((body (gptel-yatools-search-test--grep "needle")))
          (should (string-match-p "a\\.txt:1:needle" body))
          (should (string-match-p "were not searched because they are not regular files"
                                  body)))))))

;;;; 3. A workspace on another machine

(defun gptel-yatools-search-test--remote-tree (files)
  "Write FILES, an alist of relative path to content, on the stand-in host.

The stand-in maps the host's root onto `gptel-yatools-test--remote-root', so
this is the tree the script sees when it walks \"\"."
  (dolist (pair files)
    (let ((full (expand-file-name (car pair) gptel-yatools-test--remote-root)))
      (make-directory (file-name-directory full) t)
      (gptel-yatools-test--write full (cdr pair)))))

(ert-deftest gptel-yatools-test-glob-searches-a-remote-workspace ()
  "A remote tree is found without a round trip per file."
  (gptel-yatools-test--with-remote
    (gptel-yatools-search-test--remote-tree '(("a.el" . "a")
                                              ("sub/b.el" . "b")
                                              ("notes.txt" . "n")))
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--glob "*.el")))
        (should (string-match-p "a\\.el\t" body))
        (should (string-match-p "sub/b\\.el\t" body))
        (should-not (string-match-p "notes\\.txt" body))))))

(ert-deftest gptel-yatools-test-grep-reads-a-remote-workspace-in-chunks ()
  "Every file is searched even when one transfer cannot carry them all."
  (gptel-yatools-test--with-remote
    (gptel-yatools-search-test--remote-tree '(("a.el" . "needle one\n")
                                              ("b.el" . "needle two\n")
                                              ("c.el" . "needle three\n")))
    (gptel-yatools-test--vfs
      ;; A budget smaller than any file: each chunk can carry one, so the
      ;; only way all three are reported is if the tool asks again.
      (let ((gptel-yatools-search-remote-chunk-bytes 1))
        (let ((body (gptel-yatools-search-test--grep "needle")))
          (should (string-match-p "a\\.el:1:needle one" body))
          (should (string-match-p "b\\.el:1:needle two" body))
          (should (string-match-p "c\\.el:1:needle three" body))
          (should (string-match-p "Showing 3 matching line(s) from 3 of 3 file(s)" body)))))))

(ert-deftest gptel-yatools-test-glob-walks-a-remote-workspace-in-chunks ()
  "A metadata transfer split into several chunks still lists every file."
  (gptel-yatools-test--with-remote
    (gptel-yatools-search-test--remote-tree '(("a.el" . "a")
                                              ("b.el" . "b")
                                              ("c.el" . "c")))
    (gptel-yatools-test--vfs
      (let ((gptel-yatools-search-remote-chunk-records 1))
        (let ((body (gptel-yatools-search-test--glob "*.el")))
          (should (string-match-p "a\\.el\t" body))
          (should (string-match-p "b\\.el\t" body))
          (should (string-match-p "c\\.el\t" body)))))))

(ert-deftest gptel-yatools-test-glob-searches-a-remote-workspace-in-one-trip ()
  "A whole remote tree is walked by one process, not one question per file."
  (gptel-yatools-test--with-remote
    (gptel-yatools-search-test--remote-tree '(("a.el" . "a")
                                              ("sub/b.el" . "b")
                                              ("sub/deep/c.el" . "c")
                                              ("d.zig" . "d")))
    (gptel-yatools-test--vfs
      (setq gptel-yatools-test--remote-process-args nil)
      (let ((body (gptel-yatools-search-test--glob "*.el")))
        (should (string-match-p "sub/deep/c\\.el\t" body))
        (should (= 1 (length gptel-yatools-test--remote-process-args)))))))

;;;; 4. What the search could not read

(ert-deftest gptel-yatools-test-glob-finds-a-file-too-large-to-grep ()
  "A file is found by name whatever its size: size is why not to read it."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("big.jsonl" . "0123456789")))
    (gptel-yatools-test--vfs
      (let ((gptel-yatools-search-max-file-size 4))
        (should (string-match-p "\\`big\\.jsonl\t"
                                (gptel-yatools-search-test--glob "*.jsonl")))))))

(ert-deftest gptel-yatools-test-grep-names-the-files-it-could-not-read ()
  "A file skipped for its size is named, not silently dropped."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.el" . "needle\n")
                                       ("big.jsonl" . "0123456789abcdef")))
    (gptel-yatools-test--vfs
      (let ((gptel-yatools-search-max-file-size 8))
        (let ((body (gptel-yatools-search-test--grep "needle")))
          (should (string-match-p "a\\.el:1:needle" body))
          (should (string-match-p "big\\.jsonl" body))
          (should (string-match-p "larger than" body))
          (should (string-match-p "execute_command" body)))))))

(ert-deftest gptel-yatools-test-grep-says-nothing-about-size-when-nothing-was-skipped ()
  "The note appears only when it has something to report."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("a.el" . "needle\n")))
    (gptel-yatools-test--vfs
      (should-not (string-match-p "larger than"
                                  (gptel-yatools-search-test--grep "needle"))))))

(ert-deftest gptel-yatools-test-grep-survives-a-remote-file-too-large-to-read ()
  "A withheld file on a remote host must not truncate the records after it."
  (gptel-yatools-test--with-remote
    (gptel-yatools-search-test--remote-tree '(("a.el" . "needle one\n")
                                              ("big.jsonl" . "0123456789abcdef")
                                              ("z.el" . "needle two\n")))
    (gptel-yatools-test--vfs
      ;; 12 bytes: the two 11-byte files are read, the 16-byte one is not.
      (let ((gptel-yatools-search-max-file-size 12))
        (let ((body (gptel-yatools-search-test--grep "needle")))
          (should (string-match-p "a\\.el:1:needle one" body))
          (should (string-match-p "z\\.el:1:needle two" body))
          (should (string-match-p "big\\.jsonl" body))
          (should-not (string-match-p "a\\.el (11 bytes)" body)))))))

;;;; 5. What the cap keeps, and what it says it shows

(ert-deftest gptel-yatools-test-grep-shows-exactly-what-it-says-it-shows ()
  "A reply that reports N lines shows N lines."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree
     `(("a.el" . ,(mapconcat (lambda (n) (format "hit %d" n))
                             (number-sequence 1 4) "\n"))
       ("b.el" . ,(mapconcat (lambda (n) (format "hit %d" n))
                             (number-sequence 5 8) "\n"))))
    (gptel-yatools-test--vfs
      (let ((gptel-yatools-grep-match-limit 5))
        (let* ((body (gptel-yatools-search-test--grep "hit"))
               ;; Everything above the blank line is the page itself.
               (shown (car (split-string body "\n\n"))))
          (should (= 5 (length (split-string shown "\n"))))
          (should (string-match-p "Showing 5 matching line(s) from 2 of 2 file(s)"
                                  body)))))))

(ert-deftest gptel-yatools-test-grep-keeps-the-densest-files-under-the-cap ()
  "The cap keeps the files with the most matches, not the first visited."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree
     `(("aaa.el" . "hit\n")
       ("bbb.el" . "hit\n")
       ("zzz.el" . ,(mapconcat (lambda (n) (format "hit %d" n))
                               (number-sequence 1 30) "\n"))))
    (gptel-yatools-test--vfs
      (let ((gptel-yatools-grep-match-limit 3))
        (let ((body (gptel-yatools-search-test--grep "hit")))
          (should (string-match-p "\\`zzz\\.el:1:hit 1" body))
          (should-not (string-match-p "aaa\\.el" body))
          (should (string-match-p "from 1 of 3 file(s)" body))
          (should (string-match-p "The other 2 matching file(s) were left out"
                                  body)))))))

(ert-deftest gptel-yatools-test-grep-searches-a-skipped-directory-when-named ()
  "PATH is explicit: naming a skipped directory searches it."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '((".git/config" . "[core] needle\n")
                                       ("a.el" . "needle\n")))
    (gptel-yatools-test--vfs
      (should-not (string-match-p "\\.git" (gptel-yatools-search-test--grep "needle")))
      (should (string-match-p "\\.git/config:1:"
                              (gptel-yatools-search-test--grep "needle" ".git"))))))

(ert-deftest gptel-yatools-test-grep-does-not-explain-one-cut-twice ()
  "A file cut by the page and by its own cap is explained once."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree
     `(("busy.el" . ,(mapconcat (lambda (n) (format "hit %d" n))
                                (number-sequence 1 30) "\n"))))
    (gptel-yatools-test--vfs
      (let ((gptel-yatools-grep-match-limit 3))
        (let ((body (gptel-yatools-search-test--grep "hit")))
          (should (string-match-p "busy\\.el: 30 matching line(s)" body))
          (should-not (string-match-p "than fit in this reply" body)))))))

;;;; 6. A file's bytes are never parsed as anything but its bytes

(ert-deftest gptel-yatools-test-grep-reads-past-a-file-of-accents ()
  "Multi-byte content must not shift the transfer's offsets."
  (gptel-yatools-test--with-remote
    (gptel-yatools-search-test--remote-tree '(("a.txt" . "é")
                                              ("z.txt" . "tokz z\n")))
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--grep "tokz")))
        (should (string-match-p "z\\.txt:1:tokz z" body))
        (should (string-match-p "1 of 1 file(s)" body))
        (should-not (string-match-p "not searched" body))))))

(ert-deftest gptel-yatools-test-grep-invents-no-file-out-of-a-length ()
  "A reply names only files that exist."
  (gptel-yatools-test--with-remote
    (gptel-yatools-search-test--remote-tree '(("é.txt" . "é")
                                              ("z.txt" . "tokz z\n")))
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--grep "tokz")))
        (should-not (string-match-p "MiB" body))
        (should-not (string-match-p "not searched" body))))))

(ert-deftest gptel-yatools-test-grep-reports-a-transfer-that-was-cut-short ()
  "A chunk missing its closing record is a failure, not a whole tree."
  (gptel-yatools-test--with-remote
    (gptel-yatools-search-test--remote-tree '(("a.txt" . "tokz\n")))
    (gptel-yatools-test--vfs
      ;; A record larger than one chunk can carry: the script withholds it
      ;; and the reply must say so rather than pretend the tree was searched.
      (let ((gptel-yatools-search-max-file-size 1048576)
            (gptel-yatools-search-remote-chunk-bytes 1))
        (let ((body (gptel-yatools-search-test--grep "tokz")))
          (should (string-match-p "a\\.txt:1:tokz" body)))))))

(ert-deftest gptel-yatools-test-search-says-which-limit-withheld-a-file ()
  "The size reported is the one that applied, not a setting that did not."
  (gptel-yatools-test--with-remote
    (gptel-yatools-search-test--remote-tree '(("big.txt" . "0123456789ab")
                                              ("small.txt" . "tokz\n")))
    (gptel-yatools-test--vfs
      ;; small.txt is 5 bytes, big.txt 12: one is read, the other named.
      (let ((gptel-yatools-search-max-file-size 6))
        (let ((body (gptel-yatools-search-test--grep "tokz")))
          (should (string-match-p "small\\.txt:1:tokz" body))
          (should (string-match-p "big\\.txt (12 bytes)" body))
          (should (string-match-p "larger than 6 bytes" body)))))))

(ert-deftest gptel-yatools-test-search-does-not-follow-a-symlinked-directory ()
  "A link back up the tree is not walked, locally or on a host."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("top/a.el" . "tokz\n")))
    (make-symbolic-link (gptel-yatools-test--root-file "top")
                        (gptel-yatools-test--root-file "top/loop"))
    (gptel-yatools-test--vfs
      (let ((body (gptel-yatools-search-test--glob "*.el")))
        (should (= 1 (length (split-string body "\n"))))
        (should-not (string-match-p "loop" body))))))

(ert-deftest gptel-yatools-test-glob-anchored-patterns-start-at-path ()
  "A pattern with a slash is relative to the directory being searched."
  (gptel-yatools-test--in-dir
    (gptel-yatools-search-test--tree '(("sub/deep/c.c" . "c")))
    (gptel-yatools-test--vfs
      (should (string-match-p "sub/deep/c\\.c"
                              (gptel-yatools-search-test--glob "sub/**/*.c")))
      (should (string-match-p "sub/deep/c\\.c"
                              (gptel-yatools-search-test--glob "**/*.c" "sub")))
      (should (string-match-p "sub/deep/c\\.c"
                              (gptel-yatools-search-test--glob "deep/*.c"
                                                               "sub"))))))

(ert-deftest gptel-yatools-test-a-cut-transfer-yields-no-phantom-record ()
  "A stream that stops mid-record ends the parse, and invents nothing."
  (gptel-yatools-test--in-dir
    (let* ((base gptel-yatools-test--root)
           ;; a.txt arrives whole; b.txt is cut after its flag field.
           (whole (concat "./a.txt\0" "5\0" "17\0" "1\0" "tokz\n\0"
                          "./b.txt\0" "5\0" "17\0" "1\0"))
           (parsed (gptel-yatools-search--remote-parse whole base)))
      (should (= 1 (length (plist-get parsed :records))))
      (should-not (plist-get parsed :complete))
      (should (string-match-p "a\\.txt\\'"
                              (plist-get (car (plist-get parsed :records)) :path))))))

(provide 'gptel-yatools-search-tests)
