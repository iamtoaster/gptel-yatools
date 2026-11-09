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
builds it.  Directories named in `gptel-yatools-search-skip-directories' are
not descended into.

Returns a plist of `:files' (how many were visited), `:stopped' (nil,
`files' or `seconds') and `:seconds' (how long it took)."
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
                   (funcall visit
                            (gptel-yatools-search--candidate
                             (expand-file-name name dir) attributes))
                   (cond
                    ((>= files gptel-yatools-search-file-limit)
                     (setq stopped 'files))
                    ((>= (float-time) deadline)
                     (setq stopped 'seconds))))))))))
      (descend (file-name-as-directory (expand-file-name directory))))
    (list :files files
          :stopped stopped
          :seconds (- (float-time) start))))


;;-------------------------------------------------------------------------
;; The courier: one round trip for a workspace on another machine
;;
;; Every question asked of a remote filesystem is a command and a wait, so
;; the walk above would cost one round trip per file and take minutes.  This
;; half does it the other way round: one `sh' script walks the host, in one
;; process, and streams the answers back.
;;
;; The script is a courier, not a matcher.  It reports a path, a size, a
;; modification time and -- when contents were wanted -- the bytes, and Emacs
;; does the matching.  That is what keeps one regexp dialect and one VFS rule
;; on both sides of the connection: a `grep -E' would be a second dialect to
;; explain, a second case rule to get right, and a second matcher for the
;; pending entries this side holds.
;;
;; It walks "." rather than a path it was given, because that is what travels
;; correctly: a process on the host runs in its own directory, so "." means
;; the same tree to the script as the file name means to Emacs, over TRAMP
;; and over the stand-in handler the tests use.
;;
;; Records are NUL-separated -- path, size, modification time, a flag, and
;; then the contents when the flag is "1" -- so no file name, however
;; strange, can forge one, and a file whose contents were withheld cannot be
;; mistaken for one whose contents happen to start with a dash.  Contents are
;; read by size rather than to a delimiter for the same reason: a NUL inside
;; a file is data, not the end of a record.
;;
;; The output is read as bytes (`:coding binary'), so the sizes the script
;; writes and the offsets the parser counts are in the same unit.  Decoded
;; first, every non-ASCII file would shift the parse and desynchronise it.
;;
;; A symbolic link to a directory is not followed: a link pointing at an
;; ancestor walks a tree that is not the one asked for, until the kernel
;; refuses.
;;
;; One process cannot carry a whole tree, so a chunk stops at a byte budget
;; and the next starts where it stopped.  A chunk that stopped because of the
;; budget always stops between records, so the count Emacs advances by is
;; exact.
;;-------------------------------------------------------------------------
(defconst gptel-yatools-search--remote-script
  "\
exec 2>/dev/null
start=$1 want=$2 budget=$3 maxsize=$4 skips=$5 contents=$6
count=0 used=0 emitted=0 stop=0
walk() {
  for path in \"$1\"/* \"$1\"/.[!.]*; do
    if [ \"$stop\" -eq 1 ]; then return; fi
    [ -e \"$path\" ] || continue
    base=${path##*/}
    case \" $skips \" in *\" $base \"*) continue;; esac
    if [ -d \"$path\" ]; then
      if [ ! -h \"$path\" ]; then walk \"$path\"; fi
      continue
    fi
    [ -f \"$path\" ] || continue
    if [ \"$want\" -gt 0 ] && [ \"$emitted\" -ge \"$want\" ]; then stop=1; return; fi
    count=$((count+1))
    [ \"$count\" -le \"$start\" ] && continue
    size=$(wc -c < \"$path\") || size=0
    case $size in ''|*[!0-9]*) size=0;; esac
    mtime=$(stat -c %Y \"$path\" || stat -f %m \"$path\" || echo 0)
    case $mtime in ''|*[!0-9]*) mtime=0;; esac
    if [ \"$contents\" -eq 1 ] && [ \"$size\" -le \"$maxsize\" ]; then
      cost=$((size + ${#path} + 32))
      if [ \"$emitted\" -gt 0 ] && [ $((used + cost)) -gt \"$budget\" ]; then
        stop=1; count=$((count-1)); return
      fi
      used=$((used + cost))
      printf '%s\\000%s\\000%s\\0001\\000' \"$path\" \"$size\" \"$mtime\"
      head -c \"$size\" \"$path\"
      printf '\\000'
    else
      printf '%s\\000%s\\000%s\\0000\\000' \"$path\" \"$size\" \"$mtime\"
    fi
    emitted=$((emitted+1))
  done
}
walk .
if [ \"$stop\" -eq 0 ]; then reached=1; else reached=0; fi
printf '#\\000%s\\000%s\\000' \"$count\" \"$reached\"
"
  "The script that walks a remote tree and streams what it finds.

Positional arguments: the number of files already consumed, how many files
this chunk may report, the byte budget for contents, the largest file whose
contents are worth sending, the directory names to skip as a space-separated
list, and 1 when contents are wanted.

Every record is four NUL-terminated fields -- path, size, modification time,
and \"1\" when the contents follow or \"0\" when they do not -- with the
contents, when they follow, being exactly the size reported.  The last record
starts with \"#\": the number of files consumed by this chunk, and 1 when the
walk reached the end of the tree.")

(defun gptel-yatools-search--remote-field (string position)
  "Return the NUL-terminated field of STRING at POSITION, as a cons.

The car is the field's text and the cdr the position just past its
terminator, or nil at the end of STRING."
  (if (>= position (length string))
      nil
    (let ((end (string-search "\0" string position)))
      (if end
          (cons (substring string position end) (1+ end))
        (cons (substring string position) (length string))))))

(defun gptel-yatools-search--remote-record (string position base)
  "Return the record of STRING at POSITION, with BASE as its directory.

The value is a cons of the record and the position just past it, or nil
when STRING ends inside a record -- a chunk cut short, which the caller
reports rather than guesses at.  A record is a plist of `:path', `:size',
`:mtime' and, when the transfer carried them, `:text' with `:contents' set.

STRING is bytes, so the size the script wrote and the substring taken here
are in the same unit."
  (let ((path-field (gptel-yatools-search--remote-field string position)))
    (when path-field
      (let* ((path (car path-field))
             (position (cdr path-field)))
        (if (string-prefix-p "#" path)
            (let* ((total (gptel-yatools-search--remote-field string position))
                   (reached (and total
                                 (gptel-yatools-search--remote-field
                                  string (cdr total)))))
              (cons (list :summary t
                          :total (string-to-number (or (car total) "0"))
                          :reached (equal (and reached (car reached)) "1"))
                    (or (and reached (cdr reached)) (length string))))
          (let* ((size-field (gptel-yatools-search--remote-field string position))
                 (size (string-to-number (or (car size-field) "0")))
                 (position (cdr size-field))
                 (mtime-field (gptel-yatools-search--remote-field string position))
                 (mtime (string-to-number (or (car mtime-field) "0")))
                 (position (cdr mtime-field))
                 (flag-field (gptel-yatools-search--remote-field string position))
                 (has-contents (equal (car flag-field) "1"))
                 (position (cdr flag-field))
                 (record (list :path (expand-file-name
                                      (string-remove-prefix "./" path) base)
                               :size size :mtime mtime)))
            (cond
             ((not has-contents) (cons record position))
             ((> (+ position size) (length string)) nil)
             (t
              (let ((text (substring string position (+ position size)))
                    (after (+ position size)))
                ;; The byte after the contents is the record's terminator.
                (unless (and (< after (length string))
                             (eq (aref string after) ?\0))
                  (setq after (length string)))
                (when (< after (length string))
                  (setq after (1+ after)))
                (cons (plist-put (plist-put record :text
                                            (gptel-yatools-search--decode text))
                                 :contents t)
                      after))))))))))

(defun gptel-yatools-search--decode (bytes)
  "Return BYTES decoded as UTF-8, keeping what will not decode.

A file is matched as text, and a byte sequence that is not UTF-8 stays a
raw byte rather than becoming an error: a search reads trees that contain
every encoding, and refusing one file would cost the whole walk."
  (decode-coding-string bytes 'utf-8))

(defun gptel-yatools-search--remote-parse (output base)
  "Return the records in OUTPUT, one remote chunk's bytes.

BASE is the directory the script walked, which is prepended to the relative
names the script reports.  The value is a plist of `:records', `:total',
`:reached' and `:complete'.

`:complete' is nil when the parse ended inside a record -- a chunk cut short
by the output limit, or a stream that desynchronised.  The caller reports
that instead of presenting a partial chunk as the whole tree."
  (let ((position 0)
        (records nil)
        (summary nil)
        (complete t)
        (base (file-name-as-directory base)))
    (while (and (< position (length output)) (not summary))
      (let ((parsed (gptel-yatools-search--remote-record output position base)))
        (if (null parsed)
            (setq complete nil
                  position (length output))
          (setq position (cdr parsed))
          (if (plist-get (car parsed) :summary)
              (setq summary (car parsed))
            (push (car parsed) records)))))
    (list :records (nreverse records)
          :total (if summary (plist-get summary :total) 0)
          :reached (if summary (plist-get summary :reached) nil)
          :complete (and complete (not (null summary))))))

(defun gptel-yatools-search--remote-ceiling ()
  "Return the largest file a remote transfer will carry contents for.

The job output buffer stops at `gptel-yatools--job-output-limit', and a
record cut there loses the rest of its chunk, so a file has to be small
enough to arrive whole.  The answer is the smaller of
`gptel-yatools-search-max-file-size' and what one transfer can hold."
  (min gptel-yatools-search-max-file-size
       (max 1 (- gptel-yatools--job-output-limit 65536))))

(defun gptel-yatools-search--remote-scan (directory start want budget contents)
  "Return one chunk of DIRECTORY, walked on its own host.

DIRECTORY is remote; START is how many files earlier chunks consumed, WANT
how many this one may report, BUDGET the bytes of contents it may carry, and
CONTENTS whether contents are wanted at all.  The value is what
`gptel-yatools-search--remote-parse' returns.

The output is read as bytes, because the parse is driven by lengths the
script wrote in bytes."
  (let* ((skip (mapconcat #'identity gptel-yatools-search-skip-directories " "))
         (outcome
          (gptel-yatools--run-process
           (list "sh" "-c" gptel-yatools-search--remote-script
                 "gptel-yatools-search"
                 (number-to-string start)
                 (number-to-string (max 0 want))
                 (number-to-string (max 1 budget))
                 (number-to-string (gptel-yatools-search--remote-ceiling))
                 skip
                 (if contents "1" "0"))
           :directory directory
           :coding 'binary)))
    (if (eq (plist-get outcome :status) 'exited)
        (gptel-yatools-search--remote-parse
         (plist-get outcome :output) directory)
      ;; A walk that could not run is not a tree with nothing in it.
      (list :records nil
            :total 0
            :reached nil
            :complete nil
            :failed (if (eq (plist-get outcome :status) 'timed-out)
                        "the search timed out on the remote host"
                      (string-trim (plist-get outcome :output)))))))

(defun gptel-yatools-search--remote-collect (directory contents)
  "Return what lies under DIRECTORY, a remote directory, in a few trips.

CONTENTS says whether the bytes are wanted.  Chunks are asked for until the
tree is exhausted or `gptel-yatools-search-seconds-limit' is spent, and the
value is a plist of `:candidates', `:skipped', `:files', `:stopped' and
`:failed' -- the same shape a local walk answers in.

A record without contents in a contents-transfer was withheld for its size,
and is reported rather than dropped.  A chunk that ended inside a record is
reported as a failure: what it did not reach is unknown, and saying so beats
presenting half a tree as the whole of one."
  (let* ((timeout (gptel-yatools--call-deadline))
         (start (float-time))
         (deadline (min (+ start gptel-yatools-search-seconds-limit)
                        (- (+ start timeout) 1.0)))
         (candidates nil)
         (skipped nil)
         (files 0)
         (total 0)
         (stopped nil)
         (failed nil)
         (end nil))
    (while (and (not end) (not stopped))
      (let* ((chunk (gptel-yatools-search--remote-scan
                     directory files
                     (if contents 0 gptel-yatools-search-remote-chunk-records)
                     gptel-yatools-search-remote-chunk-bytes
                     contents))
             (records (plist-get chunk :records)))
        (setq total (or (plist-get chunk :total) total))
        (when (plist-get chunk :failed)
          (setq failed (plist-get chunk :failed)
                stopped 'failed))
        (unless (plist-get chunk :complete)
          (setq failed "the transfer from the remote host was cut short"
                stopped 'failed))
        (dolist (record records)
          (if (or (not contents) (plist-get record :contents))
              (push record candidates)
            (push (list :path (plist-get record :path)
                        :reason :too-large
                        :size (plist-get record :size))
                  skipped)))
        (setq files (+ files (length records)))
        (cond
         (stopped nil)
         ((null records) (setq end t))
         ((plist-get chunk :reached) (setq end t))
         ((>= files gptel-yatools-search-file-limit) (setq stopped 'files))
         ((>= (float-time) deadline) (setq stopped 'seconds)))))
    (list :candidates (nreverse candidates)
          :skipped (nreverse skipped)
          :files (max files total)
          :stopped stopped
          :failed failed
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
;; Pending entries, seen by a search
;;
;; A search that read disk alone would tell the model its own file does not
;; exist.  So the VFS answers for a path it holds -- preferring its text, the
;; same choice `read_path' makes -- and a path it alone holds is a file the
;; search finds, marked, before it is synced.
;;
;; The cheap question is asked: is there an entry, not does it still differ
;; (ADR 0001).  `gptel-yatools-vfs-put' drops an entry that matches disk, so
;; an entry that exists is nearly always a pending change, and the one case
;; it is not -- disk changed to meet the VFS afterwards -- costs a stale
;; "(pending)" note rather than a wrong answer.
;;-------------------------------------------------------------------------
(defun gptel-yatools-search--vfs-candidates (directory)
  "Return candidates for the VFS entries under DIRECTORY that disk lacks.

Each is a candidate plist with `:pending' and `:text' set, in path order.
Only entries with no file on disk need this pass: one that shadows a disk
file is reached by the walk itself, and marked where it is merged."
  (let ((full-dir (file-name-as-directory (expand-file-name directory)))
        (now (current-time))
        (found nil))
    (maphash (lambda (path entry)
               (when (and (string-prefix-p full-dir path)
                          (> (length path) (length full-dir))
                          (not (file-exists-p path)))
                 (let ((text (or (plist-get entry :content) "")))
                   (push (list :path path
                               :size (length text)
                               :mtime now
                               :text text
                               :pending t)
                         found))))
             (gptel-yatools-vfs--table))
    (sort found (lambda (a b) (string-lessp (plist-get a :path)
                                            (plist-get b :path))))))

;;-------------------------------------------------------------------------
;; Collecting what is under a directory
;;
;; One shape, two ways of producing it: a local walk, and the courier for a
;; workspace on another machine.  Everything above this line -- matching,
;; ranking, marking, reporting -- is then the same for both, which is what
;; stops a search from answering differently depending on where the files
;; happen to live.
;;-------------------------------------------------------------------------
(defun gptel-yatools-search--local-collect (directory contents)
  "Return what lies under DIRECTORY, a local directory, by walking it.

CONTENTS says whether each candidate carries its text.  A file whose text
was wanted but not read -- because it is too large, or not a regular file --
is reported in `:skipped' with the reason, so that a caller can say so
instead of dropping it in silence."
  (let* ((candidates nil)
         (skipped nil)
         (walk (gptel-yatools-search--walk
                directory
                (lambda (candidate)
                  (let ((path (plist-get candidate :path)))
                    (if (not contents)
                        (push candidate candidates)
                      (let ((read (gptel-yatools-search--content path)))
                        (if (eq (plist-get read :kind) :text)
                            (push (plist-put (copy-sequence candidate)
                                             :text (plist-get read :text))
                                  candidates)
                          (push (list :path path
                                      :reason (plist-get read :kind)
                                      :size (or (plist-get read :size)
                                                (plist-get candidate :size)))
                                skipped)))))))))
    (list :candidates (nreverse candidates)
          :skipped (nreverse skipped)
          :files (plist-get walk :files)
          :stopped (plist-get walk :stopped)
          :seconds (plist-get walk :seconds))))

(defun gptel-yatools-search--collect (directory contents)
  "Return what lies under DIRECTORY, saying how far the search got.

CONTENTS says whether candidates should carry their text.  The value is a
plist of `:candidates', `:skipped', `:files', `:stopped' (nil, `files',
`seconds' or `failed') and `:failed', the reason a remote walk could not
run."
  (if (file-remote-p directory)
      (gptel-yatools-search--remote-collect directory contents)
    (gptel-yatools-search--local-collect directory contents)))

(defun gptel-yatools-search--skipped-sentence (skipped ceiling)
  "Return a sentence naming what SKIPPED, or nil when nothing was.

SKIPPED is the list `gptel-yatools-search--collect' reports: plists of
`:path', `:size' and `:reason'.  CEILING is the size that applied, which is
not always `gptel-yatools-search-max-file-size': a remote transfer carries
less.  Only the largest few are named, since the point is to hand the model
a decision it can act on, not to list a tree."
  (when skipped
    (let* ((large (cl-remove-if-not (lambda (skip)
                                      (eq (plist-get skip :reason) :too-large))
                                    skipped))
           (shown (cl-subseq large 0 (min 5 (length large))))
           (names (mapconcat (lambda (skip)
                               (format "%s (%s)"
                                       (gptel-yatools--display-path
                                        (plist-get skip :path))
                                       (gptel-yatools-search--format-size
                                        (plist-get skip :size))))
                             shown ", ")))
      (when large
        (format "%d file(s) were not searched because they are larger than %s, the most this tool reads: %s%s. Search one deliberately with execute_command, or call fetch_lines_from_file_using_regex on a file you know contains what you want."
                (length large)
                (gptel-yatools-search--format-size ceiling)
                names
                (if (> (length large) (length shown)) ", and more" ""))))))

(defun gptel-yatools-search--format-size (bytes)
  "Return BYTES as a short human unit, such as \"1.4 MiB\"."
  (let ((n (or bytes 0)))
    (cond
     ((>= n 1048576) (format "%.1f MiB" (/ n 1048576.0)))
     ((>= n 1024) (format "%.1f KiB" (/ n 1024.0)))
     (t (format "%d bytes" n)))))

(defun gptel-yatools-search--merge-pending (directory candidates)
  "Return CANDIDATES, gathered under DIRECTORY, with the VFS's answer.

A path the VFS holds contributes its pending text -- the same choice
`read_path' makes -- and is marked, so the reply can say which lines are not
on disk yet.  A path the VFS alone holds is added: the model wrote that file,
so a search must find it before it is synced."
  (let ((merged
         (mapcar (lambda (candidate)
                   (let* ((path (plist-get candidate :path))
                          (entry (gptel-yatools-vfs-entry path)))
                     (if entry
                         (plist-put (plist-put (copy-sequence candidate)
                                               :text
                                               (plist-get entry :content))
                                    :pending t)
                       candidate)))
                 candidates))
        (seen (make-hash-table :test #'equal)))
    (dolist (candidate merged)
      (puthash (plist-get candidate :path) t seen))
    (append merged
            (cl-remove-if (lambda (candidate)
                            (gethash (plist-get candidate :path) seen))
                          (gptel-yatools-search--vfs-candidates directory)))))

;;-------------------------------------------------------------------------
;; The tools
;;-------------------------------------------------------------------------
(defun gptel-yatools-search--stop-sentence (stopped files seconds)
  "Return a sentence saying where a walk stopped, or nil if it did not.

STOPPED is what `gptel-yatools-search--walk' reported, FILES how many it
visited and SECONDS how long it took."
  (pcase stopped
    ('nil nil)
    ('failed nil)
    ('files
     (format "Stopped after %d files, the `gptel-yatools-search-file-limit'. Results below are partial: pass PATH to search a smaller part of the tree."
             files))
    ('seconds
     (format "Stopped after %.0f seconds, the `gptel-yatools-search-seconds-limit', having visited %d files. Results below are partial: pass PATH to search a smaller part of the tree."
             seconds files))
    (_ nil)))

(defun gptel-yatools-search--failure-sentence (failed)
  "Return a sentence saying the search itself failed, or nil.

FAILED is the reason `gptel-yatools-search--collect' reported, which is
what a remote walk says when the process could not run or was killed."
  (when failed
    (format "The search could not finish: %s. What is reported below is what it had gathered; a local read_path still works."
            failed)))

(defun gptel-yatools-search--relative (path root)
  "Return PATH relative to ROOT, a directory with a trailing slash.

A plain prefix removal: unlike `file-relative-name' it asks the filesystem
nothing, which matters for a path that has no file -- a pending entry."
  (if (string-prefix-p root path)
      (substring path (length root))
    path))

(defun gptel-yatools-search--glob-subject (path directory anchored)
  "Return the part of PATH a `glob' pattern is matched against.

DIRECTORY is the directory being searched and ANCHORED says whether the
pattern names a position in the tree: then PATH relative to DIRECTORY, else
just the file name, which is what makes \"*.el\" work at every depth."
  (if anchored
      (gptel-yatools-search--relative path directory)
    (file-name-nondirectory path)))

(defun gptel-yatools-search--glob (pattern path)
  "Return the Result for the `glob' tool, matching PATTERN under PATH."
  (gptel-yatools--require-string pattern "pattern")
  (when (string-empty-p pattern)
    (error "Error: pattern must not be empty.  Pass a shell wildcard such as \"*.el\" or \"src/**/*.c\""))
  (let* ((directory (file-name-as-directory
                     (gptel-yatools--resolve-path (or path ""))))
         (regexp (gptel-yatools-search--glob-regexp pattern))
         (anchored (gptel-yatools-search--glob-anchored-p pattern))
         (match (lambda (full)
                  (string-match-p
                   regexp (gptel-yatools-search--glob-subject
                           full directory anchored)))))
    (if (not (file-directory-p directory))
        (gptel-yatools-ok
         (format "Error: %s is not a directory.  Give PATH as a directory to search under, and PATTERN as the file names wanted."
                 (gptel-yatools--display-path directory))
         :comment "Nothing was searched.")
      (let* ((collected (gptel-yatools-search--collect directory nil))
             (candidates (gptel-yatools-search--merge-pending
                          directory (plist-get collected :candidates)))
             (hits (cl-loop for candidate in candidates
                            when (funcall match (plist-get candidate :path))
                            collect (cons (plist-get candidate :path)
                                          candidate)))
             (any-pending (cl-some (lambda (hit)
                                     (plist-get (cdr hit) :pending))
                                   hits)))
        (gptel-yatools-ok
         (gptel-yatools-search--glob-body
          hits pattern directory
          (list :stopped (plist-get collected :stopped)
                :files (plist-get collected :files)
                :seconds (plist-get collected :seconds)
                :failed (plist-get collected :failed)))
         :provenance (if any-pending :mixed :disk)
         :comment (when any-pending
                    "This reply mixes pending virtual-filesystem changes with disk content: entries marked (pending) exist only in the VFS. Run the file_sync tool to persist them."))))))

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
reported.  A candidate with `:pending' set is marked as such in its line, as
a directory listing marks one."
  (let* ((sorted (gptel-yatools-search--glob-sort hits))
         (limit gptel-yatools-glob-result-limit)
         (shown (cl-subseq sorted 0 (min limit (length sorted))))
         (lines (mapcar (lambda (hit)
                          (concat (gptel-yatools--display-path (car hit))
                                  "\t"
                                  (gptel-yatools-search--format-time
                                   (plist-get (cdr hit) :mtime))
                                  (if (plist-get (cdr hit) :pending)
                                      "\t(pending)"
                                    "")))
                        shown))
         (notes (delq nil
                      (list
                       (when (> (length sorted) limit)
                         (format "Showing the %d most recently modified of %d matching files. Make PATTERN more specific, or pass PATH, to narrow the search."
                                 limit (length sorted)))
                       (gptel-yatools-search--failure-sentence
                        (plist-get walk :failed))
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
  "Find files by name. PATTERN is a shell wildcard: `*' matches within one path component, `**' crosses components, `?` one character, `[abc]` a set. A pattern with no slash matches the file name at any depth, so \"*.el\" finds every Emacs Lisp file under the workspace; a pattern with a slash matches the path relative to the workspace root, so \"src/**/*.c\" finds C files under src/. Returns one line per file, newest first: the path relative to the workspace root, a tab, and the modification time. No file is too large to be found: only names are read. Directories listed in `gptel-yatools-search-skip-directories' are not entered unless PATH names one, and the call stops at `gptel-yatools-search-file-limit' files or `gptel-yatools-search-seconds-limit' seconds, saying so when it does. Use this instead of guessing a path and calling read_path on it. Pending VFS files exist here too: a file you wrote with write_file is found before it is synced."
  :args '((:name "pattern"
                 :type string
                 :description "Shell wildcard to match file names with, such as \"*.el\", \"src/**/*.c\" or \"Makefile\".")
          (:name "path"
                 :type string
                 :description "Optional directory to search under, relative to the workspace root or absolute. Defaults to the workspace root."
                 :optional t))
  (gptel-yatools-search--glob pattern path))

;;-------------------------------------------------------------------------
;; Matching, and how much of a match is reported
;;
;; The pattern is an Emacs regexp, case-insensitive unless it has a capital
;; in it: ripgrep's smart-case, which is what a model means by "grep foo"
;; and by "grep Foo", without an argument to say so.
;;-------------------------------------------------------------------------
(defun gptel-yatools-search--smart-case-p (regexp)
  "Return non-nil when REGEXP should be matched case-insensitively.

True unless REGEXP contains an uppercase letter, which is the sign that the
capital was meant.  `case-fold-search' is bound so that the character class
means \"uppercase\" rather than \"the same letter in either case\", which is
what it matches when folding is on."
  (let ((case-fold-search nil))
    (not (string-match-p "[[:upper:]]" regexp))))

(defun gptel-yatools-search--content (path)
  "Return PATH's text as a plist, or say why it was not read.

The `:kind' is `:text', with the contents under `:text'; or `:too-large',
with `:size' in bytes; or `:special' for anything that is not a regular
file; or `:unreadable'.

The VFS answers for a path it holds, as `read_path' does, and a pending
entry is never refused for its size: it is already in memory.  Disk content
comes only from a regular file no larger than
`gptel-yatools-search-max-file-size', so that a search reads a tree rather
than one enormous log."
  (let ((entry (gptel-yatools-vfs-entry path)))
    (cond
     (entry (list :kind :text :text (plist-get entry :content)))
     ((not (file-regular-p path)) (list :kind :special))
     (t
      (let ((size (file-attribute-size (file-attributes path))))
        (if (and (numberp size) (> size gptel-yatools-search-max-file-size))
            (list :kind :too-large :size size)
          (let ((text (gptel-yatools-vfs--disk-content path)))
            (if text
                (list :kind :text :text text)
              (list :kind :unreadable)))))))))

(defun gptel-yatools-search--binary-p (text)
  "Return non-nil when TEXT holds a NUL byte."
  (and (stringp text) (string-match-p "\0" text)))

(defun gptel-yatools-search--line-matches (text regexp)
  "Return the lines of TEXT that match REGEXP, as (KEPT . TOTAL).

KEPT is the matches themselves, as (LINE-NUMBER . LINE-TEXT) conses, at most
`gptel-yatools-grep-matches-per-file-limit' of them.  TOTAL is how many the
file holds, counted past the cap.

Counting them all is what lets a capped reply rank files by how much they
match rather than by how many lines fit, and say a real number instead of
\"more than twenty\"."
  (if (gptel-yatools-search--binary-p text)
      (cons nil 0)
    (let ((case-fold-search (gptel-yatools-search--smart-case-p regexp))
          (number 0)
          (total 0)
          (kept nil))
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (while (not (eobp))
          (setq number (1+ number))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (when (string-match-p regexp line)
              (setq total (1+ total))
              (when (< (length kept) gptel-yatools-grep-matches-per-file-limit)
                (push (cons number line) kept))))
          (forward-line 1)))
      (cons (nreverse kept) total))))

(defun gptel-yatools-search--grep-collect (regexp candidates)
  "Return the per-file matches for REGEXP over CANDIDATES, densest first.

Each value is a plist of `:path', the kept `:lines', the `:line-count' the
file really holds, a `:more' flag for a file that holds more than were kept,
and `:pending'.  Files with no match are left out at once.

The order is by `:line-count', descending, with the path breaking ties.  The
walk visits files in whatever order the filesystem reports, which is not an
order at all: ranking by density is what lets a capped reply keep the files
most likely to answer the question, rather than whichever ones happened to be
visited before the cap was reached."
  (let ((found nil))
    (dolist (candidate candidates)
      (let ((text (plist-get candidate :text)))
        (when text
          (let* ((path (plist-get candidate :path))
                 (scan (gptel-yatools-search--line-matches text regexp))
                 (matches (car scan))
                 (total (cdr scan)))
            (when matches
              (push (list :path path
                          :lines matches
                          :line-count total
                          :more (> total (length matches))
                          :pending (plist-get candidate :pending))
                    found))))))
    (sort found
          (lambda (a b)
            (let ((na (plist-get a :line-count))
                  (nb (plist-get b :line-count)))
              (if (= na nb)
                  (string-lessp (plist-get a :path) (plist-get b :path))
                (> na nb)))))))

(defun gptel-yatools-search--grep-lines (files limit)
  "Return the reply lines of FILES, keeping exactly LIMIT of them.

FILES is what `gptel-yatools-search--grep-collect' returns.  A file is cut
in the middle rather than dropped whole when the limit falls inside it,
which is what makes the page land exactly on LIMIT: a reply that says it
shows 200 lines has to show 200.

The value is a plist of `:lines', `:files' (how many contributed one),
`:matched-files' (how many had any) and `:partial' -- the file the page cut
short and how many of its lines it kept, or nil."
  (let ((lines nil)
        (shown nil)
        (partial nil))
    (catch 'done
      (dolist (file files)
        (let ((room (- limit (length lines))))
          (when (<= room 0) (throw 'done nil))
          (let* ((all (plist-get file :lines))
                 (kept (cl-subseq all 0 (min room (length all))))
                 (path (plist-get file :path))
                 (pending (plist-get file :pending)))
            (dolist (match kept)
              (push (concat (format "%s:%d:%s"
                                    (gptel-yatools--display-path path)
                                    (car match) (cdr match))
                            (when pending "\t(pending)"))
                    lines))
            (push path shown)
            (when (< (length kept) (length all))
              (setq partial (cons path (length kept))))))))
    (list :lines (nreverse lines)
          :files (length shown)
          :matched-files (length files)
          :partial partial)))

(defun gptel-yatools-search--grep (regexp path)
  "Return the Result for the `grep' tool, matching REGEXP under PATH."
  (gptel-yatools--require-string regexp "regex")
  (when (string-empty-p regexp)
    (error "Error: regex must not be empty.  Pass an Emacs regular expression, such as \"defun gptel-yatools-\" or \"TODO\""))
  (let ((directory (gptel-yatools--resolve-path (or path ""))))
    (if (not (file-directory-p directory))
        (gptel-yatools-ok
         (format "Error: %s is not a directory.  Give PATH as a directory to search under, and REGEX as the text wanted. To search one file you already know, use fetch_lines_from_file_using_regex."
                 (gptel-yatools--display-path directory))
         :comment "Nothing was searched.")
      (let* ((collected (gptel-yatools-search--collect directory t))
             (candidates (gptel-yatools-search--merge-pending
                          directory (plist-get collected :candidates)))
             (files (gptel-yatools-search--grep-collect regexp candidates))
             (page (gptel-yatools-search--grep-lines
                    files gptel-yatools-grep-match-limit))
             (any-pending (cl-some (lambda (file)
                                     (and (plist-get file :pending) t))
                                   files)))
        (gptel-yatools-ok
         (gptel-yatools-search--grep-body
          regexp directory page files
          (list :stopped (plist-get collected :stopped)
                :files (plist-get collected :files)
                :seconds (plist-get collected :seconds)
                :failed (plist-get collected :failed)
                :ceiling (or (plist-get collected :ceiling)
                             gptel-yatools-search-max-file-size)
                :skipped (plist-get collected :skipped)))
         :provenance (if any-pending :mixed :disk)
         :comment (when any-pending
                    "This reply mixes pending virtual-filesystem changes with disk content: lines marked (pending) are not on disk yet. Run the file_sync tool to persist them."))))))

(defun gptel-yatools-search--grep-body (regexp directory page files walk)
  "Return the body of a `grep' reply, given what the search found.

REGEXP is what was asked for, DIRECTORY where the walk started, PAGE what
`gptel-yatools-search--grep-lines' kept, FILES every file that matched as
`gptel-yatools-search--grep-collect' ordered them, and WALK what
`gptel-yatools-search--collect' reported.

Every count in the summary is the page's own.  A reply that shows 200 lines
and then calls them 202, or that says the cap applies only to this call while
silently dropping the files it never reached, answers a question nobody
asked."
  (let ((lines (plist-get page :lines))
        (skipped (gptel-yatools-search--skipped-sentence
                  (plist-get walk :skipped)
                  (or (plist-get walk :ceiling)
                      gptel-yatools-search-max-file-size)))
        (left-out (- (plist-get page :matched-files) (plist-get page :files))))
    (if (null lines)
        (format "No line under %s matches %S. Check the expression, or call glob to see what files are there.%s"
                (gptel-yatools--display-path directory)
                regexp
                (if skipped (concat "\n\n" skipped) ""))
      (concat
       (mapconcat #'identity lines "\n")
       "\n\n"
       (mapconcat
        #'identity
        (delq nil
              (list
               (format "Showing %d matching line(s) from %d of %d file(s) that matched."
                       (length lines) (plist-get page :files)
                       (plist-get page :matched-files))
               ;; A file cut by the page is only worth a note of its own
               ;; when the per-file cap is not already explaining it.
               (when (and (plist-get page :partial)
                          (not (plist-get (cl-find (car (plist-get page :partial))
                                                   files
                                                   :key (lambda (file)
                                                          (plist-get file :path))
                                                   :test #'equal)
                                          :more)))
                 (format "%s has more matching lines than fit in this reply: %d are shown. Use fetch_lines_from_file_using_regex on it to see them all."
                         (gptel-yatools--display-path (car (plist-get page :partial)))
                         (cdr (plist-get page :partial))))
               (when (> left-out 0)
                 (format "The other %d matching file(s) were left out to stay within `gptel-yatools-grep-match-limit'. The files shown are the ones with the most matches; make the expression more specific, or pass PATH, to search a smaller part of the tree."
                         left-out))
               (mapconcat
                (lambda (file)
                  (format "%s: %d matching line(s), the first %d are shown. Use fetch_lines_from_file_using_regex on it to see them all."
                          (gptel-yatools--display-path (plist-get file :path))
                          (plist-get file :line-count)
                          (length (plist-get file :lines))))
                (cl-remove-if-not (lambda (file) (plist-get file :more)) files)
                "\n")
               skipped
               (gptel-yatools-search--failure-sentence
                (plist-get walk :failed))
               (gptel-yatools-search--stop-sentence
                (plist-get walk :stopped)
                (plist-get walk :files)
                (plist-get walk :seconds))))
        "\n")))))

(gptel-yatools-define-tool gptel-yatools-grep
  :name "grep"
  :category "filesystem"
  :description
  "Find lines by content. REGEX is an Emacs regular expression, matched case-insensitively unless it contains an uppercase letter. Searches every file under PATH, returning one line per match: the path relative to the workspace root, a colon, the 1-based line number, a colon, and the line. Directories listed in `gptel-yatools-search-skip-directories' are not entered unless PATH names one, which is how a deliberate search of `.git' or `.github' works. Binary files are skipped, a file larger than `gptel-yatools-search-max-file-size' is skipped and named in the reply, and one file contributes at most `gptel-yatools-grep-matches-per-file-limit' lines so that it cannot crowd out every other file. The reply says how many lines it shows, out of how many files matched, and says which files it left out when the limit bit: the files shown are the ones with the most matches, so a cap keeps what is likely to answer you rather than whatever the tree listed first. Pending VFS text is what is searched for a file the VFS holds, so a line you just wrote with write_file is found before it is synced; such a line is marked (pending). Use glob first when the tree is large, and fetch_lines_from_file_using_regex when you already know the file: this tool's answer is a summary of where to look, not every line of a file."
  :args '((:name "regex"
                 :type string
                 :description "Emacs regular expression to match against each line, such as \"defun gptel-yatools-\" or \"TODO\\(\\.org\\)?\".")
          (:name "path"
                 :type string
                 :description "Optional directory to search under, relative to the workspace root or absolute. Defaults to the workspace root."
                 :optional t))
  (gptel-yatools-search--grep regex path))

(provide 'gptel-yatools-search)
;;; gptel-yatools-search.el ends here
