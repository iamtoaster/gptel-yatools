;;; gptel-yatools-search.el --- Finding files and lines without knowing the path  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The two tools that answer "where is it?", which `read_path' cannot: it
;; needs the path it is asked for, and a model that does not know the tree
;; can only guess one.  `glob' finds file names by a shell wildcard, `grep'
;; finds lines by an Emacs regexp.
;;
;; Both are the same walk.  Emacs does the searching, in Elisp, on every
;; workspace: no `rg', no `fd', no external program, so what a workspace
;; needs installed is what Emacs itself needs.  The walk visits one directory
;; per `directory-files-and-attributes' call -- one round trip for the whole
;; listing, rather than one per name -- and yields a candidate per regular
;; file with the size and modification time that listing already reported.
;;
;; A workspace on another machine is the exception, and the reason this
;; module has a second half.  Reading a remote tree name by name costs a
;; round trip each, so the walk itself would be minutes; instead a POSIX
;; `sh' script walks the host and streams file metadata -- and, for `grep',
;; contents -- back through one process.  The script transports; it never
;; matches.  Matching stays here, which is what keeps one dialect and one
;; VFS rule on both sides of the connection.
;;
;; A search that read disk alone would break the package's promise: write a
;; file, search for it, be told it does not exist while `read_path' returns
;; it.  So pending entries are searched, VFS-only files are found, and a hit
;; from a pending entry is marked.  What the search reports is therefore
;; `:mixed' whenever anything pending took part.
;;
;; Nothing here returns the whole answer.  A tree can be larger than a call,
;; a model's context and a shell's patience, so both tools stop at a budget
;; and say where they stopped: silently truncating a search teaches the
;; model that a file it needs does not exist.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gptel)
(require 'gptel-yatools-common)
(require 'gptel-yatools-vfs)

(defgroup gptel-yatools-search nil
  "Finding files and lines in the workspace."
  :group 'gptel-yatools)

;;-------------------------------------------------------------------------
;; How much of a tree one call may look at
;;
;; Every limit below ends in a sentence the model is told, so a partial
;; answer is never mistaken for a complete one.
;;-------------------------------------------------------------------------
(defcustom gptel-yatools-search-skip-directories
  '(".git" ".hg" ".svn" ".eldev" ".eldev-cache" ".venv" "venv"
    "node_modules" "__pycache__" ".mypy_cache" ".pytest_cache" ".tox"
    ".gradle" ".cache")
  "Directory names the search tools do not descend into.

By name and at any depth.  These hold machine-generated bulk -- version
control objects, installed dependencies, byte-code caches -- that dwarfs
the source around it and is never what a search is looking for.

Not consulted for `.gitignore', which would mean parsing ignore files at
every level and getting their precedence rules right; a user who needs more
skipped adds a name here."
  :type '(repeat string)
  :group 'gptel-yatools-search)

(defcustom gptel-yatools-search-max-file-size 1048576
  "Bytes of a file the search tools will read.

A larger file is skipped rather than searched, and the model is told how
many were skipped.  Both tools read a file whole to match it, so this is
also the cost of one candidate."
  :type 'integer
  :group 'gptel-yatools-search)

(defcustom gptel-yatools-search-file-limit 4000
  "Files one search call may visit before it stops.

Counted per call, not per directory.  A tree this large is searched by
scoping the call with its PATH argument, which is why the limit is
reported rather than hidden."
  :type 'integer
  :group 'gptel-yatools-search)

(defcustom gptel-yatools-search-seconds-limit 20
  "Seconds one search call may spend walking before it stops.

The backstop for a workspace on a slow host, where the per-file cost is a
network round trip rather than a disk read."
  :type 'number
  :group 'gptel-yatools-search)

(defcustom gptel-yatools-glob-result-limit 200
  "Paths one `glob' call returns."
  :type 'integer
  :group 'gptel-yatools-search)

(defcustom gptel-yatools-grep-match-limit 200
  "Lines one `grep' call returns."
  :type 'integer
  :group 'gptel-yatools-search)

(defcustom gptel-yatools-grep-matches-per-file-limit 20
  "Lines one `grep' call returns from a single file.

Beyond this the file is reported as having more, so that one file full of
matches cannot crowd out every other file in the workspace."
  :type 'integer
  :group 'gptel-yatools-search)

(defcustom gptel-yatools-search-remote-chunk-bytes 524288
  "Bytes of file contents one remote transfer may carry.

A remote `grep' has no way to match without the text, so the text travels;
this bounds one round trip.  A tree that needs more is transferred in
several, until the call's time budget runs out.

Well under `gptel-yatools--job-output-limit', because past that a process's
output is cut and marked truncated, which would break the records apart."
  :type 'integer
  :group 'gptel-yatools-search)

(defcustom gptel-yatools-search-remote-chunk-records 2000
  "Files one remote transfer may report.

Bounds a metadata-only transfer, where no content sets the size: a tree of
a hundred thousand files would otherwise fill the process buffer with
names alone."
  :type 'integer
  :group 'gptel-yatools-search)

;;-------------------------------------------------------------------------
;; The walk
;;
;; One question is asked of the filesystem per directory, and the answer
;; carries the name, type, size and modification time of every entry in it.
;; Anything cheaper per entry -- a `file-attributes' call each -- costs a
;; round trip per name on a remote host, which is the cost this module
;; exists to avoid.
;;-------------------------------------------------------------------------
(defun gptel-yatools-search--entries (directory)
  "Return DIRECTORY's entries as a list of (NAME . ATTRIBUTES), sorted.

One `directory-files-and-attributes' call answers for the whole directory.
Nil when it cannot be read: an unreadable directory costs its own subtree
and nothing else."
  (condition-case nil
      (directory-files-and-attributes directory nil nil t)
    (file-error nil)))

(defun gptel-yatools-search--regular-p (name attributes directory)
  "Return non-nil when NAME, with ATTRIBUTES, is a regular file in DIRECTORY.

A symbolic link is followed when it leads to a regular file and left alone
otherwise: a link to a directory may point back up the tree, and a walk that
follows one does not terminate."
  (let ((type (file-attribute-type attributes)))
    (cond
     ((null type) t)
     ((stringp type)
      (file-regular-p (expand-file-name name directory)))
     (t nil))))

(defun gptel-yatools-search--directory-p (attributes)
  "Return non-nil when ATTRIBUTES describe a directory."
  (eq (file-attribute-type attributes) t))

(defun gptel-yatools-search--candidate (path attributes)
  "Return the candidate plist for PATH, described by ATTRIBUTES.

The keys are `:path' (absolute), `:size' and `:mtime', which is the time
value `file-attribute-modification-time' returns."
  (list :path path
        :size (file-attribute-size attributes)
        :mtime (file-attribute-modification-time attributes)))

(cl-defun gptel-yatools-search--walk (directory visit)
  "Call VISIT for each regular file under DIRECTORY.

VISIT receives one candidate plist, as `gptel-yatools-search--candidate'
builds it, and stops the walk by returning non-nil.  Directories named in
`gptel-yatools-search-skip-directories' are not descended into.

Returns a plist of `:files' (how many were visited), `:stopped' (nil, or
`files', `seconds' or `visit') and `:seconds' (how long it took)."
  (let* ((start (float-time))
         (deadline (+ start gptel-yatools-search-seconds-limit))
         (files 0)
         (stopped nil))
    (cl-labels
        ((descend (dir)
           (dolist (entry (gptel-yatools-search--entries dir))
             (unless stopped
               (let ((name (car entry))
                     (attributes (cdr entry)))
                 (cond
                  ;; `directory-files-and-attributes' lists the directory
                  ;; itself and its parent, which are two ways up the tree
                  ;; rather than entries in it.
                  ((member name '("." "..")))
                  ((gptel-yatools-search--directory-p attributes)
                   (unless (member name gptel-yatools-search-skip-directories)
                     (descend (expand-file-name name dir))))
                  ((gptel-yatools-search--regular-p name attributes dir)
                   (setq files (1+ files))
                   (when (funcall visit
                                  (gptel-yatools-search--candidate
                                   (expand-file-name name dir) attributes))
                     (setq stopped 'visit))
                   (cond
                    (stopped)
                    ((>= files gptel-yatools-search-file-limit)
                     (setq stopped 'files))
                    ((>= (float-time) deadline)
                     (setq stopped 'seconds))))))))))
      (descend (file-name-as-directory (expand-file-name directory))))
    (list :files files
          :stopped stopped
          :seconds (- (float-time) start))))


;;-------------------------------------------------------------------------
;; What the model wrote, as a pattern
;;
;; Shell wildcards rather than an Emacs regexp: a model reaching for "find
;; files called this" writes `*.el', and answering "that is not a regexp"
;; would cost a turn to learn something it already knew how to say.
;;-------------------------------------------------------------------------
(defun gptel-yatools-search--glob-regexp (pattern)
  "Return PATTERN, a shell wildcard, as an anchored Emacs regexp.

`*' matches any run of characters within one path component, `**' any run
across components, `**/' zero or more whole components, `?' one character
that is not a slash, and `[...]' a set, where a leading `!' or `^' negates
it.  Every other character stands for itself, including the ones an Emacs
regexp would read as syntax."
  (let ((i 0)
        (length (length pattern))
        (out "\\`"))
    (while (< i length)
      (let ((char (aref pattern i)))
        (cond
         ((and (eq char ?*) (< (1+ i) length) (eq (aref pattern (1+ i)) ?*))
          (if (and (< (+ i 2) length) (eq (aref pattern (+ i 2)) ?/))
              (progn
                (setq out (concat out "\\(?:[^/]*/\\)*"))
                (setq i (+ i 3)))
            (setq out (concat out "\\(?:.\\|\n\\)*"))
            (setq i (+ i 2))))
         ((eq char ?*) (setq out (concat out "[^/]*")) (setq i (1+ i)))
         ((eq char ??) (setq out (concat out "[^/]")) (setq i (1+ i)))
         ((eq char ?\[)
          (let ((close (cl-position ?\] pattern :start (1+ i))))
            (if close
                (let* ((body (substring pattern (1+ i) close))
                       (first (aref pattern (1+ i)))
                       (negated (memq first '(?! ?^))))
                  (setq out (concat out "["
                                    (if negated "^" "")
                                    (if negated (substring body 1) body)
                                    "]"))
                  (setq i (1+ close)))
              ;; An unterminated bracket is a literal one, as a shell would
              ;; read it.
              (setq out (concat out "\\["))
              (setq i (1+ i)))))
         (t (setq out (concat out (regexp-quote (char-to-string char))))
            (setq i (1+ i))))))
    (concat out "\\'")))

(defun gptel-yatools-search--glob-anchored-p (pattern)
  "Return non-nil when PATTERN names a position in the tree, not just a name.

A pattern with a slash in it matches the relative path; one without matches
the file name at any depth, which is what makes \"*.el\" useful in a tree
whose depth the model does not know."
  (and (string-search "/" pattern) t))

(defun gptel-yatools-search--format-time (time)
  "Return TIME as \"YYYY-MM-DD HH:MM\", or a dash when it is unknown."
  (if (or (null time) (equal time 0))
      "-"
    (format-time-string "%Y-%m-%d %H:%M" (if (integerp time)
                                              (seconds-to-time time)
                                            time))))

;;-------------------------------------------------------------------------
;; The tools
;;-------------------------------------------------------------------------
(defun gptel-yatools-search--stop-sentence (stopped files seconds)
  "Return a sentence saying where a walk stopped, or nil if it did not.

STOPPED is what `gptel-yatools-search--walk' reported, FILES how many it
visited and SECONDS how long it took."
  (pcase stopped
    ('nil nil)
    ('visit nil)
    ('files
     (format "Stopped after %d files, the `gptel-yatools-search-file-limit'. Results below are partial: pass PATH to search a smaller part of the tree."
             files))
    ('seconds
     (format "Stopped after %.0f seconds, the `gptel-yatools-search-seconds-limit', having visited %d files. Results below are partial: pass PATH to search a smaller part of the tree."
             seconds files))
    (_ nil)))

(defun gptel-yatools-search--glob (pattern path)
  "Return the Result for the `glob' tool, matching PATTERN under PATH."
  (gptel-yatools--require-string pattern "pattern")
  (when (string-empty-p pattern)
    (error "Error: pattern must not be empty. Pass a shell wildcard such as \"*.el\" or \"src/**/*.c\""))
  (let ((root (gptel-yatools--workspace-root))
        (directory (gptel-yatools--resolve-path (or path ""))))
    (if (not (file-directory-p directory))
        (gptel-yatools-ok
         (format "Error: %s is not a directory. Give PATH as a directory to search under, and PATTERN as the file names wanted."
                 (gptel-yatools--display-path directory))
         :comment "Nothing was searched.")
      (let* ((regexp (gptel-yatools-search--glob-regexp pattern))
             (anchored (gptel-yatools-search--glob-anchored-p pattern))
             (hits nil)
             (walk (gptel-yatools-search--walk
                    directory
                    (lambda (candidate)
                      (let* ((full (plist-get candidate :path))
                             (subject (if anchored
                                          (file-relative-name full root)
                                        (file-name-nondirectory full))))
                        (when (string-match-p regexp subject)
                          (push (cons full candidate) hits))
                        (>= (length hits) gptel-yatools-glob-result-limit))))))
        (gptel-yatools-ok
         (gptel-yatools-search--glob-body hits pattern directory walk))))))

(defun gptel-yatools-search--glob-sort (hits)
  "Return HITS, an alist of path to candidate, newest first.

Ties are broken by path, so two calls a second apart agree with each other."
  (sort (copy-sequence hits)
        (lambda (a b)
          (let ((ta (plist-get (cdr a) :mtime))
                (tb (plist-get (cdr b) :mtime)))
            (if (time-equal-p ta tb)
                (string-lessp (car a) (car b))
              (time-less-p tb ta))))))

(defun gptel-yatools-search--glob-body (hits pattern directory walk)
  "Return the body of a `glob' reply.

HITS is an alist of absolute path to candidate, PATTERN what was asked for,
DIRECTORY where the walk started and WALK what `gptel-yatools-search--walk'
reported."
  (let* ((sorted (gptel-yatools-search--glob-sort hits))
         (limit gptel-yatools-glob-result-limit)
         (shown (cl-subseq sorted 0 (min limit (length sorted))))
         (lines (mapcar (lambda (hit)
                          (format "%s\t%s"
                                  (gptel-yatools--display-path (car hit))
                                  (gptel-yatools-search--format-time
                                   (plist-get (cdr hit) :mtime))))
                        shown))
         (notes (delq nil
                      (list
                       (when (> (length sorted) limit)
                         (format "Showing the %d most recently modified of %d matching files. Make PATTERN more specific, or pass PATH, to narrow the search."
                                 limit (length sorted)))
                       (gptel-yatools-search--stop-sentence
                        (plist-get walk :stopped)
                        (plist-get walk :files)
                        (plist-get walk :seconds))))))
    (if (null lines)
        (format "No files under %s match the pattern %S. Check the pattern, or call read_path on that directory to see what is already there."
                (gptel-yatools--display-path directory)
                pattern)
      (concat (mapconcat #'identity lines "\n")
              (when notes (concat "\n\n" (mapconcat #'identity notes "\n")))))))

(gptel-yatools-define-tool gptel-yatools-glob
  :name "glob"
  :category "filesystem"
  :description
  "Find files by name. PATTERN is a shell wildcard: `*' matches within one path component, `**' crosses components, `?` one character, `[abc]` a set. A pattern with no slash matches the file name at any depth, so \"*.el\" finds every Emacs Lisp file under the workspace; a pattern with a slash matches the path relative to the workspace root, so \"src/**/*.c\" finds C files under src/. Returns one line per file, newest first: the path relative to the workspace root, a tab, and the modification time. Directories listed in `gptel-yatools-search-skip-directories' are not entered, files larger than `gptel-yatools-search-max-file-size' are ignored, and the call stops at `gptel-yatools-search-file-limit' files or `gptel-yatools-search-seconds-limit' seconds, saying so when it does. Use this instead of guessing a path and calling read_path on it. Pending VFS files exist here too: a file you wrote with write_file is found before it is synced."
  :args '((:name "pattern"
                 :type string
                 :description "Shell wildcard to match file names with, such as \"*.el\", \"src/**/*.c\" or \"Makefile\".")
          (:name "path"
                 :type string
                 :description "Optional directory to search under, relative to the workspace root or absolute. Defaults to the workspace root."
                 :optional t))
  (gptel-yatools-search--glob pattern path))

(provide 'gptel-yatools-search)
;;; gptel-yatools-search.el ends here
