;;; gptel-yatools-vfs.el --- The buffer-local virtual filesystem  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A buffer-local virtual filesystem layered over the real one, and the
;; filesystem tools built on it.  Reads come from disk unless a buffered copy
;; exists, writes are buffered until the user reviews and syncs them, and
;; every pending change is shown as a unified diff before it lands.
;;
;; The table itself, its conflict detection, the header-line indicator and the
;; sync review UI all live here, along with the tools that drive them:
;; reading, writing, diffing, syncing and discarding.  What the tools share
;; with the rest of the package -- the response envelope, path resolution, the
;; timeout guard -- is in `gptel-yatools.el', which loads this file.

;;; Code:

(require 'cl-lib)
(require 'gptel)
(require 'subr-x)
(require 'gptel-yatools-common)

;; The tools defined here use `gptel-yatools-define-tool', which lives in
;; `gptel-yatools-common.el' and is available because this file requires it.
;; Everything below is either VFS storage or a tool built on it.

(defvar-local gptel-yatools-vfs nil
  "Buffer-local virtual filesystem.

A hash table mapping absolute file paths to plists of the form
\(:content STRING :baseline STRING-OR-NIL :coding CODING :baseline-coding CODING).
A file present here shadows the corresponding file on disk for
gptel's read tools.  The disk is only written by the `file_sync' tool.

See `gptel-yatools-vfs--table'.")

(defvar-local gptel-yatools-vfs--header-line-cache nil
  "Cached (PATHS . TIME) for the header line, or nil when invalidated.

The header line is re-evaluated on every redisplay, and computing the
pending list reads every pending file from disk.  Caching keeps
redisplay free of I/O; the cache is cleared whenever the VFS changes,
and expires after `gptel-yatools-vfs--header-line-cache-seconds' so that
changes made outside Emacs (a git checkout, another editor) are
picked up too.")


;;-------------------------------------------------------------------------
;; Buffer-local VFS
;;
;; Each VFS entry is a plist:
;;   (:content  STRING          ; current VFS content
;;    :baseline STRING-OR-NIL)  ; disk content when the VFS first captured it
;;
;; The baseline is what enables conflict detection: if the file on disk no
;; longer matches the baseline, we know somebody else (execute_command, an
;; external editor, etc.) has changed it, and file_sync will refuse to
;; overwrite it without an explicit overwrite=true.
;;
;; The variables `gptel-yatools-vfs' and `gptel-yatools-vfs--header-line-cache' are
;; declared at the top of this file, see the comment there.
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs--table ()
  "Return this buffer's VFS hash table, creating it if needed.

Also installs the kill-buffer guard, so a buffer holding unsynced
changes cannot be killed by accident.  The guard is (re)installed on
every call because the table may already exist from before this
guard was introduced, and `add-hook' is idempotent."
  (unless gptel-yatools-vfs
    (setq gptel-yatools-vfs (make-hash-table :test #'equal)))
  (unless (memq #'gptel-yatools-vfs--query-kill-buffer kill-buffer-query-functions)
    (add-hook 'kill-buffer-query-functions
              #'gptel-yatools-vfs--query-kill-buffer nil t))
  gptel-yatools-vfs)

(defun gptel-yatools-vfs--query-kill-buffer ()
  "Ask before killing a buffer that still holds unsynced VFS changes.

In a non-interactive Emacs there is nobody to ask (and
`yes-or-no-p' would read from stdin and fail), so let the kill
proceed instead of breaking batch cleanup."
  (let ((paths (gptel-yatools-vfs--changed-paths)))
    (or noninteractive
        (null paths)
        (yes-or-no-p
         (format "%d unsynced VFS change(s) in this buffer (%s). Kill anyway? "
                 (length paths)
                 (mapconcat #'gptel-yatools--display-path paths ", "))))))

(defun gptel-yatools-vfs--key (path)
  "Return PATH as a VFS table key, insisting that it is absolute.

The VFS interface takes resolved paths only.  A tool turns the model's
text into an absolute path once, at its own edge, through
`gptel-yatools--resolve-path'; past that point a path is a fact, not an
interpretation.  A relative path arriving here is a bug in this
package, so it is reported as one instead of being silently resolved
against whichever buffer is current -- the failure that made
`write_file' and `read_path' disagree about what \"p.txt\" names."
  (if (file-name-absolute-p path)
      (expand-file-name path)
    (error "gptel-yatools: internal error: the VFS was given the relative path %S; tool functions must resolve paths with `gptel-yatools--resolve-path' before calling the VFS"
           path)))

(defun gptel-yatools-vfs--entry (path)
  "Return the VFS entry plist for PATH, or nil."
  (gethash (gptel-yatools-vfs--key path) (gptel-yatools-vfs--table)))

(defun gptel-yatools-vfs-get (path)
  "Return the VFS contents of PATH, or nil if PATH is not in the VFS."
  (when-let* ((entry (gptel-yatools-vfs--entry path)))
    (plist-get entry :content)))

(defun gptel-yatools-vfs--baseline (path)
  "Return PATH's baseline (disk content at VFS capture time), or nil."
  (when-let* ((entry (gptel-yatools-vfs--entry path)))
    (plist-get entry :baseline)))

(defun gptel-yatools-vfs--entry-coding (path)
  "Return the coding system recorded for PATH's VFS entry, or nil."
  (when-let* ((entry (gptel-yatools-vfs--entry path)))
    (plist-get entry :coding)))

(defun gptel-yatools-vfs--baseline-coding (path)
  "Return the coding system PATH had on disk when the VFS captured it."
  (when-let* ((entry (gptel-yatools-vfs--entry path)))
    (plist-get entry :baseline-coding)))

(defun gptel-yatools-vfs-put (path content &optional reset-baseline coding)
  "Store CONTENT at PATH in the VFS.

If CONTENT equals the file's current disk content, the entry is
removed (a write that produces no change is a no-op) -- unless
CODING asks for a different encoding than the file has on disk, in
which case an entry is kept so the sync re-encodes the file.

When RESET-BASELINE is non-nil, the recorded baseline is refreshed
to the current disk content, discarding any prior conflict.  Use
this only when the caller has explicitly accepted the on-disk
version of the file (e.g. `overwrite' in `write_file').

When CODING is non-nil it becomes the encoding the file will be
written with on sync, which is how a caller converts a file from
one coding system to another.  The baseline coding is left alone,
since it describes what the disk had when the VFS captured it."
  (let* ((full (gptel-yatools-vfs--key path))
         (disk-info (gptel-yatools-vfs--disk-content-with-coding full))
         (disk (car-safe disk-info))
         (disk-coding (cdr-safe disk-info))
         (existing (gethash full (gptel-yatools-vfs--table)))
         (target (or coding
                     (and existing (plist-get existing :coding))
                     disk-coding)))
    (if (and (equal content disk)
             (equal (gptel-yatools-vfs--resolve-coding target)
                    (gptel-yatools-vfs--resolve-coding disk-coding)))
        (remhash full (gptel-yatools-vfs--table))
      (puthash full
               (if (and existing (not reset-baseline))
                   (plist-put (plist-put (copy-sequence existing)
                                         :content content)
                              :coding target)
                 (list :content content :baseline disk
                       :coding target :baseline-coding disk-coding))
               (gptel-yatools-vfs--table)))
    ;; Invalidate even when the write turned out to be a no-op and
    ;; removed a previous entry: the header line may currently be
    ;; displaying that now-gone path.
    (gptel-yatools-vfs--invalidate-header-line)
    (force-mode-line-update t)))

(defun gptel-yatools-vfs-remove (path)
  "Remove PATH from the VFS."
  (remhash (gptel-yatools-vfs--key path) (gptel-yatools-vfs--table))
  (gptel-yatools-vfs--invalidate-header-line)
  (force-mode-line-update t))

(defun gptel-yatools-vfs--disk-content-with-coding (path)
  "Return (CONTENT . CODING) for PATH, or nil if PATH is not a regular file.

CONTENT is PATH decoded from disk and CODING is the coding system
that performed the decoding, so re-encoding CONTENT with CODING
reproduces the file's bytes exactly.  Recording it is what keeps a
sync from silently transcoding line endings (CRLF) or legacy 8-bit
encodings (ISO-8859-1, Shift-JIS, ...) to UTF-8/unix.

Only regular files are considered: reading a FIFO blocks forever and
reading /dev/zero or /dev/urandom never ends.  An unreadable file
(permission denied, I/O error) yields nil instead of signalling, so a
single unreadable pending file cannot break every tool call and every
redisplay of the header line."
  (when (file-regular-p path)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents path)
          (cons (buffer-substring-no-properties (point-min) (point-max))
                last-coding-system-used))
      (file-error nil))))

(defun gptel-yatools-vfs--disk-content (path)
  "Return PATH's contents from disk, or nil if PATH does not exist."
  (car-safe (gptel-yatools-vfs--disk-content-with-coding path)))

(defun gptel-yatools-vfs--resolve-coding (coding)
  "Return a concrete coding system suitable for writing with CODING.

CODING is a value previously recorded from `last-coding-system-used'.
Auto-detected (\"undecided\") coding systems are replaced by their
UTF-8 equivalent with the same end-of-line convention: a file that
was decoded successfully as `undecided' is by definition valid UTF-8
(or plain ASCII), so re-encoding it as UTF-8 is lossless."
  (cond
   ((null coding) 'utf-8-unix)
   ((eq (coding-system-base coding) 'undecided)
    ;; `coding-system-eol-type' returns a vector for the generic
    ;; `undecided' coding system, which `coding-system-change-eol-
    ;; conversion' cannot use.  Treat it as Unix; an actually
    ;; auto-detected file has already been decoded into a concrete
    ;; coding system by `insert-file-contents'.
    (coding-system-change-eol-conversion
     'utf-8
     (let ((eol (coding-system-eol-type coding)))
       (if (integerp eol) eol 'unix))))
   (t coding)))

(defun gptel-yatools-vfs--target-coding (path)
  "Return the coding a sync of PATH would use, or nil if unknown.

A pending VFS entry wins over the disk, because that is what the
sync will write.  For a file that does not exist yet, nil is
returned and `gptel-yatools-vfs--resolve-coding' turns that into UTF-8."
  (or (gptel-yatools-vfs--entry-coding path)
      (cdr-safe (gptel-yatools-vfs--disk-content-with-coding path))))

(defun gptel-yatools-vfs--first-unencodable (string coding)
  "Return the first character of STRING that CODING cannot represent.

Only distinct characters are tried, so this stays cheap on large
input.  Returns nil when every character is representable."
  (let ((seen (make-hash-table :test #'eq))
        (result nil)
        (i 0))
    (while (and (null result) (< i (length string)))
      (let ((c (aref string i)))
        (unless (gethash c seen)
          (puthash c t seen)
          (unless (gptel-yatools-vfs--encodable-p (char-to-string c) coding)
            (setq result (char-to-string c)))))
      (setq i (1+ i)))
    result))

(defun gptel-yatools-vfs--changed-p (path)
  "Return non-nil if PATH differs between the VFS and disk.

Both the text and the encoding are compared, so a pending
encoding conversion is a change even when the text is identical."
  (let ((entry (gptel-yatools-vfs--entry path)))
    (when entry
      (let ((disk-info (gptel-yatools-vfs--disk-content-with-coding path)))
        (or (not (equal (plist-get entry :content)
                        (car-safe disk-info)))
            (not (equal (gptel-yatools-vfs--resolve-coding (plist-get entry :coding))
                        (gptel-yatools-vfs--resolve-coding (cdr-safe disk-info)))))))))

(defun gptel-yatools-vfs--conflict-p (path)
  "Return non-nil if PATH's disk content has changed since the VFS baseline.

Only meaningful for paths that have a pending VFS entry.  A
conflict means the file was modified on disk outside the VFS
after the VFS first captured it, and syncing would overwrite
those external changes.  Both the decoded text and the coding
system are compared, so a pure re-encoding (for example CRLF
turned into LF) also counts as a change."
  (let ((entry (gptel-yatools-vfs--entry path)))
    (when entry
      (let ((disk-info (gptel-yatools-vfs--disk-content-with-coding path)))
        (or (not (equal (plist-get entry :baseline)
                        (car-safe disk-info)))
            (not (equal (plist-get entry :baseline-coding)
                        (cdr-safe disk-info))))))))

(defun gptel-yatools-vfs--changed-paths ()
  "Return a list of paths whose VFS content differs from disk.

Entries that no longer differ are dropped on the way: disk caught up
with the pending copy, so there is nothing left to sync.  This is the
one place that already reads every pending file to answer, which is why
the reaping is here and not in the callers -- and why `vfs_discard' does
not rely on this list to find entries, only `vfs-pending-p' -- the cheap
\"is there an entry?\" question -- still answers about them.

The removal happens after the walk: `maphash' must not see its table
change underneath it."
  (let (result stale)
    (maphash (lambda (path _entry)
               (if (gptel-yatools-vfs--changed-p path)
                   (push path result)
                 (push path stale)))
             (gptel-yatools-vfs--table))
    (dolist (path stale)
      (gptel-yatools-vfs-remove path))
    (sort result #'string-lessp)))

(defun gptel-yatools-vfs--has-children-p (full)
  "Return non-nil if any VFS entries exist under directory FULL."
  (let* ((full-dir (file-name-as-directory (expand-file-name full)))
         (found nil))
    (maphash
     (lambda (path _entry)
       (when (and (string-prefix-p full-dir path)
                  (> (length path) (length full-dir)))
         (setq found t)))
     (gptel-yatools-vfs--table))
    found))

(defun gptel-yatools-vfs--directory-listing (full)
  "Return a listing of directory FULL, merging disk and VFS entries.

Every VFS path under FULL contributes its first path component, so
intermediate virtual directories appear correctly.

Each line is TYPE, a tab, the name, and -- when the entry is not simply
what disk holds -- a third tab-separated note saying so: `(pending)' for
an entry that exists only in the VFS, `(pending change)' for one whose
disk content a pending write shadows.  Without the note the listing is
indistinguishable from one of a directory that is entirely on disk,
which is how a merged reply came to be described as a description of
disk.

Returns a plist of :text and :pending (non-nil when any line carries a
note), so the caller can say which provenance the reply has instead of
guessing."
  (let* ((full-dir (file-name-as-directory (expand-file-name full)))
         (entries (make-hash-table :test #'equal))
         (pending nil))
    ;; Disk entries.  `directory-files' signals a raw `file-error'
    ;; for an unreadable directory or one deleted between the checks
    ;; above; turn that into a readable tool error instead.
    (when (file-directory-p full)
      (condition-case err
          (dolist (entry (directory-files full t))
            (let ((name (file-name-nondirectory (directory-file-name entry))))
              (unless (member name '("." ".."))
                (puthash name (if (file-directory-p entry) "dir" "file")
                         entries))))
        (file-error
         (error "Error: cannot read directory %s: %s"
                (gptel-yatools--display-path full)
                (error-message-string err)))))
    ;; VFS entries (including nested ones).  One VFS key may be a file
    ;; whose disk twin is already listed, which is what `(pending
    ;; change)' marks.
    (maphash
     (lambda (path _entry)
       (when (and (string-prefix-p full-dir path)
                  (> (length path) (length full-dir)))
         (let* ((rel   (substring path (length full-dir)))
                (slash (cl-position ?/ rel :test #'char-equal))
                (name  (if slash (substring rel 0 slash) rel))
                (type  (if slash "dir" "file"))
                (on-disk (gethash name entries)))
           (setq pending t)
           (puthash name
                    (cond
                     ((null on-disk) (cons type "(pending)"))
                     ;; An existing disk name whose content a pending
                     ;; write shadows: the entry is real, its content is
                     ;; not what disk holds.
                     ((equal on-disk type) (cons type "(pending change)"))
                     (t (cons type "(pending)")))
                    entries))))
     (gptel-yatools-vfs--table))
    (let (lines)
      (maphash (lambda (name value)
                 (let ((type (if (consp value) (car value) value))
                       (note (and (consp value) (cdr value))))
                   (push (if note
                             (format "%s\t%s\t%s" type name note)
                           (format "%s\t%s" type name))
                         lines)))
               entries)
      (list :text (mapconcat #'identity (sort lines #'string-lessp) "\n")
            :pending pending))))

(defun gptel-yatools-vfs--validate-insertable (full)
  "Return nil if FULL can be written into, or a descriptive error string.

Walks up FULL's directory chain.  If any ancestor exists as a
regular file on disk or in the VFS, writing is impossible without
deleting that file first.

Both paths are shown workspace-relative, like every other message
the tools return."
  (let ((ancestor (directory-file-name (file-name-directory full))))
    (cond
     ((or (null ancestor)
          (equal ancestor "")
          (equal ancestor "/")
          (equal ancestor full))
      nil)
     ((gptel-yatools-vfs-get ancestor)
      (format "Error: cannot write %s: ancestor %s is a file in the VFS. Use vfs_discard to remove it first."
              (gptel-yatools--display-path full)
              (gptel-yatools--display-path ancestor)))
     ((file-regular-p ancestor)
      (format "Error: cannot write %s: ancestor %s is a file on disk."
              (gptel-yatools--display-path full)
              (gptel-yatools--display-path ancestor)))
     (t (gptel-yatools-vfs--validate-insertable ancestor)))))

;;-------------------------------------------------------------------------
;; The VFS label for the header line
;;
;; The drawing lives in `gptel-yatools.el', with the rest of the gptel
;; adaptation.  This module contributes one label and caches the number it
;; shows, because recomputing it reads every pending file from disk.
;;-------------------------------------------------------------------------
(defconst gptel-yatools-vfs--header-line-cache-seconds 1.0
  "How long the header-line pending list may be reused before recomputing.")

(defun gptel-yatools-vfs--invalidate-header-line ()
  "Forget the cached pending list so the header line is recomputed."
  (setq gptel-yatools-vfs--header-line-cache nil))

(defun gptel-yatools-vfs--header-line-paths ()
  "Return the pending VFS paths, using the cache when it is still fresh."
  (let ((cache gptel-yatools-vfs--header-line-cache))
    (if (and cache
             (< (- (float-time) (cdr cache))
                gptel-yatools-vfs--header-line-cache-seconds))
        (car cache)
      (let ((paths (gptel-yatools-vfs--changed-paths)))
        (setq gptel-yatools-vfs--header-line-cache
              (cons paths (float-time)))
        paths))))

(defun gptel-yatools-vfs--header-line-label ()
  "Return the header-line text for pending VFS changes, or nil.

Clicking the label echoes the pending paths; the actual review
happens through the `vfs_diff' and `file_sync' tools."
  (let ((paths (gptel-yatools-vfs--header-line-paths)))
    (when paths
      (propertize
       (buttonize
        (format "[VFS: %d file%s pending]"
                (length paths) (if (= (length paths) 1) "" "s"))
        (lambda (&rest _)
          (message "Unsynced VFS changes: %s"
                   (mapconcat #'gptel-yatools--display-path paths ", "))))
       'mouse-face 'highlight
       'help-echo (format "Pending VFS changes: %s"
                          (mapconcat #'gptel-yatools--display-path paths ", "))))))

;; Registered like any other module's label: the drawer in
;; `gptel-yatools.el' asks the registry, so the VFS is not a special case.
(unless (memq #'gptel-yatools-vfs--header-line-label
              gptel-yatools-header-line-extra-functions)
  (add-to-list 'gptel-yatools-header-line-extra-functions
               #'gptel-yatools-vfs--header-line-label t))

;;-------------------------------------------------------------------------
;; Unified diff via external `diff'
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs--unified-diff (old new &optional labels)
  "Return a unified diff between strings OLD and NEW.

OLD is the \"before\" side, NEW is the \"after\" side.  Lines
prefixed with `-' are present only in OLD (removed when going from
OLD to NEW); lines prefixed with `+' are present only in NEW (added
when going from OLD to NEW).

LABELS is either nil, a string LABEL (in which case the `---'/`+++'
headers are set to \"a/LABEL\" and \"b/LABEL\" respectively), or a
cons (OLD-LABEL . NEW-LABEL) for arbitrary header text.

Returns the empty string when OLD and NEW are identical, or an
error string if `diff' fails."
  (if (equal old new)
      ""
    (let* ((old-label (pcase labels
                        (`(,ol . ,_nl) ol)
                        ((pred stringp) (concat "a/" labels))))
           (new-label (pcase labels
                        (`(,_ol . ,nl) nl)
                        ((pred stringp) (concat "b/" labels))))
           (old-file (make-temp-file "gptel-yatools-vfs-old-"))
           (new-file (make-temp-file "gptel-yatools-vfs-new-")))
      (unwind-protect
          (progn
            ;; Pin the coding: without it `write-region' sees content that
            ;; its default coding cannot represent (binary data, or text
            ;; read with `no-conversion') and asks the USER to choose a
            ;; coding system -- a modal prompt in the middle of a diff.
            ;; Emacs's utf-8 writes raw eight-bit characters through
            ;; unchanged, so this reproduces the bytes exactly for both
            ;; text and binary, and keeps `diff' free to decide whether
            ;; the files are binary.
            (let ((coding-system-for-write 'utf-8-unix))
              (with-temp-file old-file (insert old))
              (with-temp-file new-file (insert new)))
            (with-temp-buffer
              (let* ((args (append
                            (list "-u")
                            (when old-label (list "--label" old-label))
                            (when new-label (list "--label" new-label))
                            (list old-file new-file)))
                     (exit (condition-case err
                               (apply #'call-process "diff" nil t nil args)
                             ;; A missing/broken external `diff' must
                             ;; not make vfs_diff and the file_sync
                             ;; preview signal a raw `file-missing'.
                             (error
                              (format "error: %s"
                                      (error-message-string err)))))
                     (out  (buffer-substring-no-properties
                            (point-min) (point-max))))
                (if (memq exit '(0 1))
                    out
                  (format "diff command failed (exit %s): %s" exit out)))))
        (ignore-errors (delete-file old-file))
        (ignore-errors (delete-file new-file))))))

(defun gptel-yatools-vfs--format-one-diff (path)
  "Return a display string describing the pending diff for PATH.

For non-conflicting files, this is a plain unified diff from disk
to VFS.  For conflicting files, both the external change (baseline
to disk) and what file_sync would apply (disk to VFS) are shown so
the caller can see what would be lost."
  (let* ((label (gptel-yatools--display-path path))
         (disk-info (gptel-yatools-vfs--disk-content-with-coding path))
         (disk (car-safe disk-info))
         (disk-coding (cdr-safe disk-info))
         (vfs  (gptel-yatools-vfs-get path))
         (baseline (gptel-yatools-vfs--baseline path))
         (baseline-coding (gptel-yatools-vfs--baseline-coding path)))
    (cond
     ;; Conflict is checked first: a pending file that was deleted from
     ;; disk and rewritten to "" would otherwise be reported as a new
     ;; empty file, hiding the deletion.
     ((gptel-yatools-vfs--conflict-p path)
      (let ((external
             (gptel-yatools-vfs--unified-diff
              (or baseline "") (or disk "")
              (cons (format "a/%s (baseline)" label)
                    (format "b/%s (disk now)" label))))
            (planned
             (gptel-yatools-vfs--unified-diff
              (or disk "") (or vfs "")
              (cons (format "a/%s (disk now)" label)
                    (format "b/%s (VFS)" label)))))
        (format "===== %s =====\n\
CONFLICT: file changed on disk since the VFS captured its baseline.\n\
Syncing would overwrite those external changes.  Resolve by running\n\
`vfs_discard' for this path and re-reading, or by calling `write_file'\n\
with overwrite=true to force the VFS version.\n\n\
-- External changes on disk since baseline (would be lost if synced):\n\
%s\n\
-- What `file_sync' would write to disk:\n\
%s\n"
                label
                (cond
                 ((not (string-empty-p external)) external)
                 ;; Text identical: only the coding system moved.
                 ((and (equal baseline disk) (not (equal baseline-coding disk-coding)))
                  (format "(no text change; the file's encoding changed on disk: %s -> %s)\n"
                          (or baseline-coding "none") (or disk-coding "none")))
                 (t "(nothing)\n"))
                (cond
                 ((not (string-empty-p planned)) planned)
                 ((equal vfs "") "(the file would be written as an empty file)\n")
                 (t "(nothing)\n")))))
     ((and (null disk) (equal vfs ""))
      (format "===== %s =====\n(new empty file will be created on sync)\n\n"
              label))
     (t
      (format "===== %s =====\n%s%s%s\n"
              label
              ;; Say up front when file_sync will refuse this file, so
              ;; vfs_diff and the sync review buffer never disagree.
              (let ((refusal (gptel-yatools-vfs--refusal path)))
                (if refusal
                    (format "NOT SYNCED: %s\n" (plist-get refusal :reason))
                  ""))
              (gptel-yatools-vfs--coding-change-note path)
              (gptel-yatools-vfs--unified-diff (or disk "") (or vfs "") label))))))

(defun gptel-yatools-vfs--coding-change-note (path)
  "Return a one-line note if syncing PATH will change its encoding, else \"\".

The note is empty when the encoding is unchanged, so callers can
concatenate it unconditionally."
  (let* ((disk-coding (cdr-safe (gptel-yatools-vfs--disk-content-with-coding path)))
         (target (gptel-yatools-vfs--resolve-coding (gptel-yatools-vfs--entry-coding path)))
         (current (gptel-yatools-vfs--resolve-coding disk-coding)))
    (if (equal target current)
        ""
      (format "(encoding will change on sync: %s -> %s)\n"
              current target))))

;;-------------------------------------------------------------------------
;; The VFS interface
;;
;; What the rest of the package may call.  Everything else in this file --
;; the entry plists, the coding bookkeeping, the baseline comparisons -- is
;; implementation, and stays private so a change to the shape of an entry
;; cannot ripple out to the tools.
;;
;; The two write entry points are where a pending change is decided on:
;; they validate the target, settle the encoding, refuse content the
;; encoding cannot carry, and record the baseline conflicts are detected
;; against.  Both the tools and the skill code go through them, which is
;; why a rule can only be changed in one place.
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs-read (path)
  "Return what PATH holds, or nil if it exists nowhere.

PATH must be absolute: resolution happens at the tool's edge, in
`gptel-yatools--resolve-path'.

The value is a plist with :content and :from-vfs, the latter non-nil when
the content is a pending change rather than what is on disk.

A directory, a device, a FIFO or an unreadable file signals an error
naming the reason: a caller that can do something about it (list the
directory, refuse to read a device) checks for that case first, and a
caller that cannot gets a message the model can act on."
  (let* ((full (gptel-yatools-vfs--key path))
         (vfs (gptel-yatools-vfs-get full)))
    ;; An entry whose content disk now holds is not a pending change, so
    ;; it must not shadow what disk holds -- and since finding that out
    ;; costs the same disk read the fallthrough below would make, the
    ;; stale entry is dropped here too.  See
    ;; `gptel-yatools-vfs--changed-paths' for the other place this
    ;; happens, and `gptel-yatools-vfs-pending-p' for why the cheap
    ;; "entry exists" question has a different answer.
    (when (and vfs (not (gptel-yatools-vfs--changed-p full)))
      (gptel-yatools-vfs-remove full)
      (setq vfs nil))
    (cond
     (vfs (list :content vfs :from-vfs t))
     ((file-directory-p full)
      (error "Error: %s is a directory, not a file."
             (gptel-yatools--display-path full)))
     ((not (file-exists-p full)) nil)
     ((not (file-regular-p full))
      (error "Error: %s is not a regular file (device, FIFO or socket); refusing to read it."
             (gptel-yatools--display-path full)))
     ((not (file-readable-p full))
      (error "Error: %s is not readable (permission denied)."
             (gptel-yatools--display-path full)))
     (t (let ((content (gptel-yatools-vfs--disk-content full)))
          (unless content
            (error "Error: cannot read %s (permission denied or I/O error)."
                   (gptel-yatools--display-path full)))
          (list :content content :from-vfs nil))))))

(defun gptel-yatools-vfs--coding (path coding)
  "Return the coding system a write to PATH should use, given CODING.

CODING is the tool argument: a coding system name, or nil to keep what
the file already has."
  (when (and coding (not (coding-system-p (intern coding))))
    (error "Error: unknown coding system '%s'. Use an Emacs coding system name such as utf-8, iso-latin-1 or utf-8-dos."
           coding))
  (gptel-yatools-vfs--resolve-coding
   (or (and coding (intern coding))
       (gptel-yatools-vfs--target-coding path))))

(defun gptel-yatools-vfs-write (path content &optional overwrite coding)
  "Store CONTENT at PATH in the VFS, and return what changed.

The disk is not touched.  OVERWRITE accepts the current disk content as
the baseline, discarding a pending conflict; CODING converts the file to
another encoding on sync.

The value is a plist with :full (the resolved path), :changed (nil when
the write was a no-op, so nothing is pending), :bytes (what the file will
occupy on disk) and :coding (what it will be written with).

Signals an error, having changed nothing, when PATH cannot be written --
an ancestor that is a file, a directory, a device -- or when CODING
cannot represent CONTENT."
  (let* ((full (gptel-yatools-vfs--key path))
         (validate-error (gptel-yatools-vfs--validate-insertable full))
         (target (gptel-yatools-vfs--coding full coding)))
    (cond
     ((not (stringp content))
      (error "Error: content must be a string."))
     (validate-error (error "%s" validate-error))
     ((file-directory-p full)
      (error "Error: cannot write %s: it is a directory on disk."
             (gptel-yatools--display-path full)))
     ;; Writing a file over a virtual directory would make every pending
     ;; child unsyncable ("File exists"), so reject it at write time.
     ((gptel-yatools-vfs--has-children-p full)
      (error "Error: cannot write %s: it is a directory in the VFS because pending file(s) are stored under it. Discard those entries first."
             (gptel-yatools--display-path full)))
     ;; Writing to a FIFO blocks until a reader appears, and to a device it
     ;; may fail or scribble on hardware.
     ((and (file-exists-p full) (not (file-regular-p full)))
      (error "Error: cannot write %s: it is not a regular file (device, FIFO or socket)."
             (gptel-yatools--display-path full)))
     ((not (gptel-yatools-vfs--encodable-p content target))
      (error "Error: %s cannot represent %s. Nothing was written. Either remove it, or pass coding=\"utf-8\" to convert %s to UTF-8 on sync."
             target
             (if-let* ((culprit (gptel-yatools-vfs--first-unencodable content target)))
                 (format "%S" culprit)
               "the content as given")
             (gptel-yatools--display-path full)))
     (t
      (gptel-yatools-vfs-put full content (gptel-yatools--flag-p overwrite)
                             (and coding (intern coding)))
      (list :full full
            :changed (and (gptel-yatools-vfs-get full) t)
            :bytes (gptel-yatools-vfs--encodable-bytes content target)
            :coding target)))))

(defun gptel-yatools-vfs--replace-once (content old new)
  "Replace the one occurrence of OLD in CONTENT with NEW.

Signals unless OLD occurs exactly once, which is what makes an edit
unambiguous.  The search runs over the decoded text the caller already
has, so it sees the same characters the model saw -- where an external
grep would only ever see bytes -- and it runs in a temp buffer, so
`search-forward' does the scanning at C speed instead of walking the
string in Lisp.

The match is literal: `case-fold-search' is bound to nil, so `old_string'
either occurs in CONTENT as written or it does not.  Left ambient it
defaults to t, and an edit for \"hello\" would silently land on \"Hello\"
-- the opposite of the exact match this function promises."
  (with-temp-buffer
    (let ((case-fold-search nil))
      (insert content)
      (goto-char (point-min))
      (let ((count 0)
            (first nil))
        (while (search-forward old nil t)
          (setq count (1+ count))
          (unless first (setq first (match-beginning 0))))
        (cond
         ((zerop count)
          (error "Error: the text to replace was not found. Read the file again and copy the exact text, including whitespace and indentation."))
         ((> count 1)
          (error "Error: the text to replace occurs %d times. It must be unique; include more surrounding context in old_string."
                 count))
         (t
          (goto-char first)
          (delete-region first (+ first (length old)))
          (insert new)
          (buffer-substring-no-properties (point-min) (point-max))))))))

(defun gptel-yatools-vfs-edit (path old new &optional overwrite coding)
  "Replace the one occurrence of OLD with NEW in PATH, and return what changed.

The edit applies to PATH's effective content -- a pending VFS copy if
there is one -- and is stored through `gptel-yatools-vfs-write', so the
encoding rules and the baseline bookkeeping are the same as a write.
OLD must occur exactly once; otherwise nothing is changed and an error
says why.

OLD and NEW must be strings.  The write interface owns the write rules,
so the check is made here and not only at the tool's edge: `insert'
accepts a character, and a JSON number reaching it would replace the
match with that character, while nil is not a way to spell \"delete\" --
\"\" is."
  (unless (stringp old)
    (error "Error: old_string must be a string."))
  (unless (stringp new)
    (error "Error: new_string must be a string. Use \"\" to delete the matched text."))
  (when (string-empty-p old)
    (error "Error: old_string must not be empty."))
  (let* ((read (gptel-yatools-vfs-read path))
         (full (gptel-yatools-vfs--key path)))
    (cond
     ((null read)
      (error "Error: no such file: %s"
             (gptel-yatools--display-path full)))
     ;; The read tools refuse to show binary content, so an edit here
     ;; could only be a blind guess at bytes the model has never seen.
     ;; Replacing such a file wholesale is fine.
     ((gptel-yatools--binary-p (plist-get read :content))
      (error "Error: %s is a binary file (%s); it cannot be edited as text. Use write_file to replace it wholesale, or execute_command to inspect it."
             (gptel-yatools--display-path full)
             (if-let* ((size (file-attribute-size (file-attributes full))))
                 (format "%d bytes" size)
               "size unknown")))
     (t
      (let ((new-content (gptel-yatools-vfs--replace-once
                          (plist-get read :content) old new)))
        (if (equal new-content (plist-get read :content))
            (list :full full :changed nil)
          (gptel-yatools-vfs-write path new-content overwrite coding)))))))

(defun gptel-yatools-vfs-pending-p (path)
  "Return non-nil if PATH has a VFS entry in this buffer's VFS.

This answers the cheap question -- \"is there an entry?\" -- and not the
pending-change question the name suggests: an entry whose content disk
already holds is still an entry until a read or an enumeration notices
and drops it (see `gptel-yatools-vfs--changed-paths').  Callers that
need to know whether something would be synced want
`gptel-yatools-vfs-pending-paths', which looks at disk.

Unlike `gptel-yatools-vfs-read', this never looks at disk, and never
reads a file to find out."
  (and (gptel-yatools-vfs-get (gptel-yatools-vfs--key path)) t))

(defun gptel-yatools-vfs-pending-paths ()
  "Return the paths whose VFS content differs from disk, sorted."
  (gptel-yatools-vfs--changed-paths))

(defun gptel-yatools-vfs-diff-text (paths)
  "Return the unified diff from disk to the VFS for PATHS, concatenated."
  (mapconcat #'gptel-yatools-vfs--format-one-diff paths ""))

(defun gptel-yatools-vfs-forget-pending-cache ()
  "Drop the cached pending list, so the header line recomputes it.

Needed after something outside the VFS changed the disk -- a shell
command, typically -- since the cache is what keeps redisplay free of
I/O and cannot know that."
  (gptel-yatools-vfs--invalidate-header-line))

(defun gptel-yatools-vfs-discard-pending (&optional path)
  "Drop PATH's pending change, or every VFS entry when PATH is nil.

With no PATH the table is emptied rather than filtered through the
pending-change list: an entry that disk has caught up with is still an
entry, and \"discard everything\" is the one command that must leave
nothing behind to surprise a later reader.

PATH must be absolute when given: resolution happens at the tool's edge."
  (let ((paths (if path
                   (let ((full (gptel-yatools-vfs--key path)))
                     (and (gptel-yatools-vfs-get full) (list full)))
                 (let (all)
                   (maphash (lambda (full _entry) (push full all))
                            (gptel-yatools-vfs--table))
                   (sort all #'string-lessp)))))
    (dolist (full paths) (gptel-yatools-vfs-remove full))
    paths))

(defun gptel-yatools-vfs-reset-buffer-state ()
  "Forget every buffer-local VFS variable in the current buffer.

Used when a buffer is reused for something that has nothing to do with
the VFS any more, and by the tool-call inspection buffer, whose entries
would otherwise outlive the chat they came from."
  (when (local-variable-p 'gptel-yatools-vfs)
    (kill-local-variable 'gptel-yatools-vfs))
  (when (local-variable-p 'gptel-yatools-vfs--header-line-cache)
    (kill-local-variable 'gptel-yatools-vfs--header-line-cache)))

;;;; Review UI: a minor mode with local keybindings, active in the diff buffer.
;;;; `recursive-edit' is used so the user can freely scroll, jump between
;;;; hunks, fold, etc. before making a decision.


(defvar-local gptel-yatools-write-diff--decision nil
  "Decision from reviewing a gptel write diff.
One of `accept', `reject', or nil while still pending.")

(defvar gptel-yatools-write-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'gptel-yatools-write-diff-accept)
    (define-key map (kbd "C-c C-k") #'gptel-yatools-write-diff-reject)
    map)
  "Keymap for `gptel-yatools-write-diff-mode'.")

(define-minor-mode gptel-yatools-write-diff-mode
  "Review a gptel file-write diff.

\\{gptel-yatools-write-diff-mode-map}"
  :lighter " gptel-diff"
  :keymap gptel-yatools-write-diff-mode-map)

(defun gptel-yatools-write-diff-accept ()
  "Accept the pending gptel write diff."
  (interactive)
  (setq gptel-yatools-write-diff--decision 'accept)
  (exit-recursive-edit))

(defun gptel-yatools-write-diff-reject ()
  "Reject the pending gptel write diff."
  (interactive)
  (setq gptel-yatools-write-diff--decision 'reject)
  (exit-recursive-edit))

;;-------------------------------------------------------------------------
;; Sync helpers
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs--build-sync-diff-buffer (paths &optional skipped)
  "Build and return a `diff-mode' buffer with per-file VFS-vs-disk diffs.

Only non-conflicting, non-blocked paths should be passed in PATHS;
anything that will not be synced is listed separately in SKIPPED, an
alist of (PATH . REASON)."
  ;; Generate the diff text HERE, in the caller's buffer.  `gptel-yatools-vfs' is
  ;; buffer-local, so doing this inside the new diff buffer would run every
  ;; VFS lookup against a fresh, empty table: files would render as an
  ;; all-`-' hunk (disk -> empty) or as a bare `===== path =====' header
  ;; with no hunk at all (empty -> empty), and conflicts would never be
  ;; marked.  The sync itself would still write the right bytes, so the
  ;; preview, not the disk, is what silently lies.
  (let ((diff-text (mapconcat #'gptel-yatools-vfs--format-one-diff paths ""))
        (diff-buf (generate-new-buffer "*gptel VFS sync diff*")))
    (with-current-buffer diff-buf
      (insert "Changes to apply to disk on sync.\n")
      (insert "  a/ = current disk content\n")
      (insert "  b/ = VFS content (post-sync disk)\n")
      (insert "  '-' lines will be removed from disk.\n")
      (insert "  '+' lines will be added to disk.\n\n")
      (when skipped
        (insert "NOT SYNCED — these pending files are skipped (see reason):\n")
        (dolist (pair skipped)
          (insert (format "  %s: %s\n"
                          (gptel-yatools--display-path (car pair))
                          (cdr pair))))
        (insert "\n"))
      (insert diff-text)
      (diff-mode)
      (setq-local diff-refine nil)
      (setq-local gptel-yatools-write-diff--decision nil)
      (gptel-yatools-write-diff-mode 1)
      (goto-char (point-min)))
    diff-buf))

(defun gptel-yatools-vfs--refusal (full)
  "Return nil if FULL can be synced now, or say why it cannot.

The value is a plist of :kind and :reason.  :kind is `:conflict' when
disk has moved on since the VFS captured its baseline -- the case where
syncing would destroy somebody else's work -- and `:blocked' for every
other refusal.

This is the single answer to \"can this file be written right now?\".
It is asked by the partition that decides what the user is shown, by the
diff header that says so file by file, and again by the write itself
immediately before it writes.  Asking one function is what keeps the
review honest: the set of files the user approves is the set that will
be applied, because there is no second opinion to disagree with.  The
write still re-asks, because the review sits in `recursive-edit' for as
long as the user likes and a file can become a FIFO while they read.

The order is the order in which the reasons matter: a conflict is
reported as a conflict even when the file would also fail an encoding
test, and a target that is no longer a regular file is caught before
`write-region' blocks on it forever."
  (let ((entry-coding (gptel-yatools-vfs--entry-coding full))
        (content (or (gptel-yatools-vfs-get full) ""))
        (existing (get-file-buffer full)))
    (cond
     ((gptel-yatools-vfs--conflict-p full)
      (list :kind :conflict
            :reason "changed on disk since the VFS captured it"))
     ((let ((ancestor (gptel-yatools-vfs--file-ancestor full)))
        (and ancestor
             (list :kind :blocked
                   :reason (format "ancestor %s is a file, not a directory"
                                   (gptel-yatools--display-path ancestor))))))
     ((and (file-exists-p full) (not (file-regular-p full)))
      (list :kind :blocked
            :reason "target is no longer a regular file (device, FIFO or socket)"))
     ((and existing (buffer-modified-p existing))
      (list :kind :blocked
            :reason (format "buffer %s has unsaved changes"
                            (buffer-name existing))))
     ((let ((coding (gptel-yatools-vfs--resolve-coding entry-coding)))
        (not (gptel-yatools-vfs--encodable-p content coding)))
      (list :kind :blocked
            :reason (format "content cannot be represented in %s"
                            (gptel-yatools-vfs--resolve-coding entry-coding))))
     (t nil))))

(defun gptel-yatools-vfs--file-ancestor (full)
  "Return FULL's nearest ancestor that is a file, or nil.

An ancestor that is a file -- on disk or as a VFS entry -- makes the
target unwritable without deleting it first.  Checked here so that the
review never offers a file whose write is certain to fail."
  (let ((ancestor (directory-file-name (file-name-directory full)))
        (found nil))
    (while (and (not found)
                ancestor
                (not (equal ancestor ""))
                (not (equal ancestor "/"))
                (not (equal ancestor full)))
      (when (or (gptel-yatools-vfs-get ancestor)
                (file-regular-p ancestor))
        (setq found ancestor))
      (setq ancestor (directory-file-name (file-name-directory ancestor))))
    found))

(defun gptel-yatools-vfs--confirm-sync (paths &optional skipped)
  "Show a diff of PATHS (VFS vs disk) and ask the user to accept or reject.

SKIPPED is an alist of (PATH . REASON) for pending files that will
NOT be synced (conflicts, blocked files).  They are listed in the
review buffer so the user sees the full picture instead of approving
a change set that is not the one that will be applied.

Return non-nil if the user accepted, nil otherwise.  This is the
interactive adapter for the review; whether a review happens at all is
`gptel-yatools-vfs-sync''s decision, not this function's.

The caller's window layout and current buffer are restored afterwards:
the caller keeps using buffer-local state (its VFS, its
`default-directory') and the review buffer is killed, so leaving the
user -- and the tool -- in whatever buffer replaced it in a window
would be a correctness problem, not just a cosmetic one."
  (let ((diff-buf (gptel-yatools-vfs--build-sync-diff-buffer paths skipped))
        (decision nil))
    (unwind-protect
        ;; `save-window-excursion' puts the caller's window layout and
        ;; current buffer back when the review ends.  Without it, killing
        ;; the review buffer leaves its window showing whatever buffer
        ;; Emacs falls back to -- not necessarily the one the tool was
        ;; called from, whose buffer-local VFS the caller is about to use.
        ;; Only the window layout is restored, so the user can still
        ;; scroll, fold and inspect the diff freely while it is shown.
        (save-window-excursion
          (pop-to-buffer diff-buf '((display-buffer-same-window)))
          (message "Review VFS sync.  C-c C-c accept, C-c C-k reject.%s"
                   (if skipped
                       (format "  WARNING: %d file(s) will NOT be synced."
                               (length skipped))
                     ""))
          ;; The user may study the diff for minutes; that time must not
          ;; count against the tool timeout.
          (let ((gptel-yatools--timeout-suspended t))
            (condition-case nil
                (recursive-edit)
              (quit nil)))
          (setq decision
                (and (buffer-live-p diff-buf)
                     (buffer-local-value 'gptel-yatools-write-diff--decision
                                         diff-buf))))
      (when (buffer-live-p diff-buf) (kill-buffer diff-buf)))
    (eq decision 'accept)))

(defun gptel-yatools-vfs--encodable-p (string coding)
  "Return non-nil if STRING survives a round trip through CODING.

Encoding a character that CODING cannot represent does not signal an
error in Emacs: the character is silently written as raw bytes or
replaced, so the file on disk ends up corrupted (for example a
non-Latin-1 character written into an ISO-8859-1 file).  Detect that
by encoding and decoding again and comparing with the original.

Both sides are normalised with `string-to-multibyte' first: a binary
file read with `no-conversion' gives multibyte text made of raw
eight-bit characters, while decoding returns the equivalent unibyte
string.  The bytes are identical, so comparing the strings directly
would wrongly call such content unrepresentable."
  (equal (string-to-multibyte
          (condition-case nil
              (decode-coding-string (encode-coding-string string coding) coding)
            (error nil)))
         (string-to-multibyte string)))

(defun gptel-yatools-vfs--encodable-bytes (string coding)
  "Return the number of bytes STRING will occupy when written with CODING.

Unlike `string-bytes' this accounts for the coding system, so it
matches the file size that will land on disk (including CRLF
expansion for DOS-style codings)."
  (string-bytes (encode-coding-string string coding)))

(defun gptel-yatools-vfs--sync-one (full)
  "Sync FULL from VFS to disk.

FULL is expected to have a pending VFS entry.  `--refusal' is asked
again here, immediately before the write: the review buffer sits in
`recursive-edit' for as long as the user likes, and anything that
changes the file meanwhile must not be silently overwritten.  Callers
may pre-filter for a nicer message, but correctness does not depend on
them doing so.

Returns (STATUS MESSAGE) where STATUS is `:ok' or `:failed'."
  (let ((content (gptel-yatools-vfs-get full)))
    (cond
     ((null content)
      (list :failed "no VFS entry"))
     ((let ((refusal (gptel-yatools-vfs--refusal full)))
        (and refusal
             (list :failed (plist-get refusal :reason)))))
     (t
      (let ((coding (gptel-yatools-vfs--resolve-coding
                     (gptel-yatools-vfs--entry-coding full)))
            (existing (get-file-buffer full)))
        (condition-case err
            (progn
              (make-directory (file-name-directory full) t)
              (let ((coding-system-for-write coding))
                (with-temp-file full (insert content)))
              ;; Remove the entry as soon as the bytes are on disk.
              ;; If refreshing the visiting buffer fails afterwards,
              ;; the sync has still happened; keeping the entry would
              ;; leave a zombie that `vfs_diff' never reports (the
              ;; content now equals disk) and `file_sync' can never
              ;; clear.
              (gptel-yatools-vfs-remove full)
              (when existing
                (condition-case err
                    (with-current-buffer existing
                      (revert-buffer t t t))
                  (error
                   (message "gptel: synced %s but could not refresh buffer %s: %s"
                            full (buffer-name existing)
                            (error-message-string err)))))
              (list :ok "synced"))
          (error (list :failed (error-message-string err)))))))))

;;-------------------------------------------------------------------------
;; The sync operation
;;
;; What a sync does, as opposed to how it reads to the model or how the
;; review looks to a human: partition the pending files, ask for approval,
;; write the ones that can be written, and report what happened to the rest.
;; Both callers are adapters over this -- `file_sync' renders the outcome as
;; a tool response, and the review buffer renders it as a diff -- which is
;; why nothing here formats a sentence for the model.
;;
;; The partition is computed once, before anything is written, so the diff
;; the user approves is the change set that is applied.  `--sync-one' still
;; re-checks each file immediately before writing it: the review runs inside
;; `recursive-edit', and a file can change while someone reads a diff.
;;-------------------------------------------------------------------------
(defcustom gptel-yatools-sync-without-review nil
  "If non-nil, `file_sync' writes without showing a diff for review.

For unattended use -- a script, org-babel, a batch Emacs -- where nobody is
present to press a key.  The files are still checked: a file that changed
on disk since the VFS captured it, one whose visiting buffer has unsaved
changes, and content the file's encoding cannot represent are all refused
and reported exactly as they are when a review is shown.  This waives the
review, not the checks.

It does not make writes automatic: the model still has to call `file_sync'.
Nothing is written because `write_file' was called.

The model is never told about this option and no tool description mentions
it, so switching it on cannot change what the model does; it only changes
what you are asked."
  :type 'boolean
  :group 'gptel-yatools)

(defun gptel-yatools-vfs--sync-partition (targets)
  "Split TARGETS into what can be synced and what cannot.

TARGETS is a list of paths with pending changes.  Returns a plist of
:conflicts (changed on disk since the VFS captured them), :blocked
\(alist of PATH . REASON for files that cannot be written right now) and
:syncable (the rest, in their original order).

Every file is classified by `--refusal', so the set shown to the user,
the reasons printed beside each file, and the set the write will accept
all come from one answer.  Splitting conflicts out is only a matter of
which section of the report they appear in, not a second opinion about
whether they can be written."
  (let (conflicts blocked syncable)
    (dolist (file targets)
      (let ((refusal (gptel-yatools-vfs--refusal file)))
        (pcase (plist-get refusal :kind)
          ('nil (push file syncable))
          (:conflict (push file conflicts))
          (_ (push (cons file (plist-get refusal :reason)) blocked)))))
    (list :conflicts (nreverse conflicts)
          :blocked (nreverse blocked)
          :syncable (nreverse syncable))))

(defun gptel-yatools-vfs--sync-approve (syncable skipped review)
  "Return `:approved', `:rejected' or `:noninteractive' for SYNCABLE.

SKIPPED is shown alongside the diff so the user approves the change set
that will actually be applied.  `gptel-yatools-sync-without-review'
answers for the user, and does so before anything else.

REVIEW, when non-nil, is the adapter that asks the user; it is
authoritative, including in a non-interactive Emacs, because a caller
that passes one is not a user at a keyboard.  Only the *default* review
needs refusing in batch: `recursive-edit' would block forever there, so
nothing is written without the option or an explicit adapter."
  (cond
   (gptel-yatools-sync-without-review :approved)
   (review (if (funcall review syncable skipped) :approved :rejected))
   (noninteractive :noninteractive)
   ((gptel-yatools-vfs--confirm-sync syncable skipped) :approved)
   (t :rejected)))

(defun gptel-yatools-vfs--sync-write (syncable)
  "Write SYNCABLE from the VFS to disk and return (SYNCED . FAILED).

SYNCED is the list of paths written, in order; FAILED is an alist of
PATH . REASON.  Also tells the user, when anything was left behind: the
model's reply is not the only reader, and it is the one that may be
skipped."
  (let (synced failed)
    (dolist (file syncable)
      (pcase-let ((`(,status ,message) (gptel-yatools-vfs--sync-one file)))
        (pcase status
          (:ok (push file synced))
          (:failed (push (cons file message) failed)))))
    (cons (nreverse synced) (nreverse failed))))

(defun gptel-yatools-vfs-sync (&optional path review)
  "Sync the VFS to disk, and return what happened as a plist.

PATH, when non-nil, limits the sync to that one file and must be
absolute: resolution happens at the tool's edge.  REVIEW is the
adapter that asks the user to approve the change set; when non-nil it is
authoritative, and when nil the interactive review is used, or the sync is
refused in a non-interactive Emacs.  Nothing is written without either an
accepted review or `gptel-yatools-sync-without-review'.

Returns a plist:

  :status     `:nothing' (nothing pending at all), `:no-target' (PATH has
              no pending change), `:declined' (the review was not
              approved) or `:done'.
  :requested  PATH as given, or nil.
  :reason     for `:declined', either `:noninteractive' or `:user'.
  :synced     paths written, in order.
  :conflicts  paths changed on disk since the VFS captured them.
  :blocked    alist of PATH . REASON for files that cannot be written.
  :failed     alist of PATH . REASON for files that could not be written.

The vfs-buffer the operation started in is re-entered before anything is
written: the review shows a buffer of its own, and a killed buffer leaves
its window showing whatever Emacs falls back to, so a VFS lookup after the
review could otherwise run against a fresh, empty table and sync nothing."
  (let* ((vfs-buffer (current-buffer))
         (all (gptel-yatools-vfs-pending-paths))
         (targets (if path
                      (and (member path all) (list path))
                    all)))
    (cond
     ((null all)
      (list :status :nothing :requested path))
     ((null targets)
      (list :status :no-target :requested path))
     (t
      (let* ((partition (gptel-yatools-vfs--sync-partition targets))
             (conflicts (plist-get partition :conflicts))
             (blocked (plist-get partition :blocked))
             (syncable (plist-get partition :syncable))
             (skipped (append blocked
                              (mapcar (lambda (file)
                                        (cons file (plist-get (gptel-yatools-vfs--refusal file)
                                                              :reason)))
                                      conflicts)))
             (approval (and syncable
                            (gptel-yatools-vfs--sync-approve
                             syncable skipped review))))
        (cond
         ((eq approval :noninteractive)
          ;; The hint names the option, so it goes to the user and not to
          ;; the model: `gptel-yatools-sync-without-review' must stay
          ;; invisible to the model, which cannot set it anyway.
          (message "gptel: cannot show the sync review in a non-interactive Emacs; nothing synced. Set `gptel-yatools-sync-without-review' to sync unattended.")
          (list :status :declined :reason :noninteractive :requested path
                :conflicts conflicts :blocked blocked))
         ((eq approval :rejected)
          (list :status :declined :reason :user :requested path
                :conflicts conflicts :blocked blocked))
         (t
          (let* ((written (with-current-buffer vfs-buffer
                            (gptel-yatools-vfs--sync-write syncable)))
                 (synced (car written))
                 (failed (cdr written))
                 (left (length conflicts))
                 (not-written (+ (length blocked) (length failed))))
            (cond
             ;; Nothing could even be attempted.
             ((and (null synced) (null failed) (null conflicts) blocked)
              (message "gptel: nothing synced — %d file(s) blocked."
                       (length blocked)))
             ((and (null synced) (null failed) (null blocked) conflicts)
              (message "gptel: nothing synced — %d file(s) conflict with disk."
                       left))
             ((or conflicts failed blocked)
              (message "gptel: synced %d file(s); %d NOT synced (conflicts: %d, blocked: %d, failed: %d). See the tool result for details."
                       (length synced) (+ left not-written)
                       left (length blocked) (length failed))))
            (list :status :done :requested path
                  :synced synced :conflicts conflicts
                  :blocked blocked :failed failed)))))))))


;;-------------------------------------------------------------------------
;; The sync tool's rendering
;;
;; `gptel-yatools-vfs-sync' decides what happens; this turns its outcome into
;; the reply the model reads.  Keeping the two apart is what lets the sync
;; operation be tested by calling it, instead of by pretending to be a user
;; looking at a diff.
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs--sync-file-list (paths)
  "Return PATHS as an indented, one-per-line list of display paths."
  (mapconcat (lambda (file)
               (format "  %s" (gptel-yatools--display-path file)))
             paths "\n"))

(defun gptel-yatools-vfs--sync-reason-list (pairs)
  "Return PAIRS, an alist of PATH . REASON, as an indented list."
  (mapconcat (lambda (pair)
               (format "  %s: %s"
                       (gptel-yatools--display-path (car pair))
                       (cdr pair)))
             pairs "\n"))

(defun gptel-yatools-vfs--render-sync (outcome)
  "Render OUTCOME, from `gptel-yatools-vfs-sync', as a tool result."
  (let* ((status (plist-get outcome :status))
         (path (plist-get outcome :requested))
         (synced (plist-get outcome :synced))
         (conflicts (plist-get outcome :conflicts))
         (blocked (plist-get outcome :blocked))
         (failed (plist-get outcome :failed)))
    (pcase status
      (:nothing
       (gptel-yatools-ok "The virtual filesystem has no pending changes."
                         :comment "Nothing to sync."))
      (:no-target
       (gptel-yatools-ok
        (format "%s has no pending VFS change."
                (gptel-yatools--display-path path))
        :comment "Nothing to sync for the requested path."))
      (:declined
       (if (eq (plist-get outcome :reason) :noninteractive)
           (gptel-yatools-ok
          "This Emacs is running non-interactively (e.g. batch), so the review diff cannot be shown and NOTHING was written to disk. The pending VFS changes are intact; run file_sync from an interactive Emacs session."
          :provenance :vfs
          :comment "Sync needs an interactive user; nothing synced.")
         (gptel-yatools-ok
          "User rejected the sync. Pending VFS changes are intact; call file_sync again after the user changes their mind."
          :provenance :vfs
          :comment "Sync rejected by user. VFS still holds the changes.")))
      (:done
       (cond
        ;; Nothing could even be attempted, for one reason only: say it
        ;; plainly instead of printing a four-part report with three empty
        ;; sections.
        ((and (null synced) (null failed) (null conflicts) blocked)
         (gptel-yatools-ok
          (format "These files could not be synced:\n%s\n"
                  (gptel-yatools-vfs--sync-reason-list blocked))
          :provenance :vfs
          :comment "All pending changes are blocked; nothing synced."))
        ;; One reason only: say it plainly instead of printing a four-part
        ;; report with three empty sections.  `blocked' must be empty too,
        ;; or the blocked files would not be named anywhere.
        ((and (null synced) (null failed) (null blocked) conflicts)
         (gptel-yatools-ok
          (format "The following file(s) changed on disk since the VFS captured them; refusing to overwrite:\n%s\n\nResolve with vfs_discard + re-read, or write_file with overwrite=true.\n"
                  (gptel-yatools-vfs--sync-file-list conflicts))
          :provenance :vfs
          :comment "All pending changes conflict with disk; nothing synced."))
        (t
         (let ((has-problems (or conflicts failed blocked)))
           (gptel-yatools-ok
            (concat
             (if synced
                 (format "Synced %d file(s) to disk:\n%s\n"
                         (length synced)
                         (gptel-yatools-vfs--sync-file-list synced))
               "No files were synced.\n")
             (when conflicts
               (format "\nConflicts (%d file(s), NOT synced — disk changed since VFS baseline):\n%s\nResolve with vfs_discard + re-read, or write_file with overwrite=true.\n"
                       (length conflicts)
                       (gptel-yatools-vfs--sync-file-list conflicts)))
             (when blocked
               (format "\nBlocked (%d file(s), NOT synced):\n%s\n"
                       (length blocked)
                       (gptel-yatools-vfs--sync-reason-list blocked)))
             (when failed
               (format "\nFailed (%d file(s), NOT synced):\n%s\n"
                       (length failed)
                       (gptel-yatools-vfs--sync-reason-list failed))))
            :provenance (if has-problems :vfs :disk)
            :comment (if has-problems
                         "Sync partial: some files were not synced."
                       "VFS synced to disk.")))))))))

;;-------------------------------------------------------------------------
;; The filesystem tools
;;
;; Each is one definition: `gptel-yatools-define-tool' writes the
;; implementation, the boundary gptel calls, and the registration.  The
;; order here is the order the tools appear in `gptel-yatools--tools', and
;; therefore in `gptel-menu'.
;;-------------------------------------------------------------------------
(gptel-yatools-define-tool gptel-yatools-read-path
  :name "read_path"
  :category "filesystem"
  :description
  "Read a path relative to the workspace root. If PATH is a directory, return a listing (merged with VFS entries). If PATH is a file, return its contents. Pending VFS changes take precedence over disk contents; the reply says whether it describes pending changes or disk."
  :args '((:name "path"
                 :type string
                 :description "Path to read, relative to the workspace root or absolute."))
  (gptel-yatools--require-string path "path")
  (let* ((full (gptel-yatools--resolve-path path))
         (vfs  (gptel-yatools-vfs-get full)))
    ;; An entry that no longer differs from disk is not a pending change:
    ;; drop it and read what disk holds, so the reply's provenance is the
    ;; truth rather than a leftover.  `gptel-yatools-vfs-read' does the
    ;; same for the other read tools.
    (when (and vfs (not (gptel-yatools-vfs--changed-p full)))
      (gptel-yatools-vfs-remove full)
      (setq vfs nil))
    (cond
     ;; VFS-only file (shadows disk if any)
     (vfs
      (if (gptel-yatools--binary-p vfs)
          (gptel-yatools--binary-notice full vfs t)
        (gptel-yatools-ok vfs :provenance :vfs)))
     ;; Real directory (not shadowed by a VFS file)
     ((file-directory-p full)
      (let* ((listing (gptel-yatools-vfs--directory-listing full))
             (text (plist-get listing :text)))
        (gptel-yatools-ok
         (if (string-empty-p text) "(empty directory)" text)
         :provenance (if (plist-get listing :pending) :mixed :disk))))
     ;; Disk file, not shadowed
     ((file-regular-p full)
      (let ((read (gptel-yatools-vfs-read full)))
        (if (gptel-yatools--binary-p (plist-get read :content))
            (gptel-yatools--binary-notice full (plist-get read :content) nil)
          (gptel-yatools-ok (plist-get read :content)))))
     ;; Something that exists but is not a readable file: a device, FIFO
     ;; or socket.  Reading it could block forever or never stop, so
     ;; refuse instead of trying.
     ((file-exists-p full)
      (error "Error: %s is not a regular file (device, FIFO or socket); refusing to read it."
             (gptel-yatools--display-path full)))
     ;; Virtual directory (only VFS ancestors exist)
     ((gptel-yatools-vfs--has-children-p full)
      (gptel-yatools-ok
       (plist-get (gptel-yatools-vfs--directory-listing full) :text)
       :provenance :vfs))
     (t (error "Path does not exist: %s"
               (gptel-yatools--display-path full))))))

(gptel-yatools-define-tool gptel-yatools-read-file-from-offset
  :name "read_file_from_offset"
  :category "filesystem"
  :description
  "Read LINES lines from a file starting at 1-based line OFFSET. Returns the raw text of those lines. Pending VFS changes shadow disk content; the reply says which it came from. Binary files (containing NUL bytes) are reported, not returned."
  :args '((:name "path"
                 :type string
                 :description "File path to read.")
          (:name "offset"
                 :type integer
                 :description "1-based line number to start reading from.")
          (:name "lines"
                 :type integer
                 :description "Number of lines to read."))
  (gptel-yatools--require-string path "path")
  (let* ((full (gptel-yatools--resolve-path path))
         (read (gptel-yatools-vfs-read full))
         (content (plist-get read :content)))
    (unless read
      (error "File does not exist: %s" (gptel-yatools--display-path full)))
    (if (gptel-yatools--binary-p content)
        (gptel-yatools--binary-notice full content (plist-get read :from-vfs))
      (let ((offset (gptel-yatools--coerce-integer offset 1 1))
            (lines  (gptel-yatools--coerce-integer lines 0 0)))
        (with-temp-buffer
          (insert content)
          ;; `count-lines' counts the lines that exist, not the
          ;; empty field after a trailing newline.
          (let ((total (count-lines (point-min) (point-max))))
            (goto-char (point-min))
            (forward-line (1- offset))
            (let* ((beg (point))
                   (text (progn
                           (forward-line lines)
                           (buffer-substring-no-properties
                            beg (point)))))
              (gptel-yatools-ok
               (cond
                ;; An empty body would read like an empty file,
                ;; so say what the empty result means.
                ((not (string-empty-p text)) text)
                ((zerop lines)
                 (format "(no lines requested: LINES was 0. %s has %d line(s).)"
                         (gptel-yatools--display-path full) total))
                ((> offset total)
                 (format "(no lines: %s has %d line(s), so offset %d is past the end. Use offset %d or less.)"
                         (gptel-yatools--display-path full) total offset
                         (max 1 total)))
                (t
                 (format "(no text in %s after line %d.)"
                         (gptel-yatools--display-path full) offset)))
               :provenance (if (plist-get read :from-vfs) :vfs :disk)))))))))

(gptel-yatools-define-tool gptel-yatools-fetch-lines-from-file-using-regex
  :name "fetch_lines_from_file_using_regex"
  :category "filesystem"
  :description
  "Return lines from a file that match an Emacs regexp. Each match is prefixed with its 1-based line number. Pending VFS changes shadow disk content; the reply says which it came from. Binary files (containing NUL bytes) are reported, not searched."
  :args '((:name "path"
                 :type string
                 :description "File path to search.")
          (:name "regex"
                 :type string
                 :description "Emacs regular expression to match against each line."))
  (gptel-yatools--require-string path "path")
  (let* ((full (gptel-yatools--resolve-path path))
         (read (gptel-yatools-vfs-read full))
         (content (plist-get read :content))
         (regex-error
          (cond
           ((not (stringp regex)) "regexp must be a string")
           (t (condition-case err
                  (progn (string-match-p regex "") nil)
                (invalid-regexp (error-message-string err)))))))
    (unless read
      (error "File does not exist: %s" (gptel-yatools--display-path full)))
    (cond
     (regex-error
      (error "Error: invalid regexp %S: %s" regex regex-error))
     ((gptel-yatools--binary-p content)
      (gptel-yatools--binary-notice full content (plist-get read :from-vfs)))
     (t
      (with-temp-buffer
        (insert content)
        (goto-char (point-min))
        (let ((line-num 0)
              (matches '()))
          ;; Known and deliberate: `string-match-p' honours the ambient
          ;; `case-fold-search' (t by default), so a regexp with no case
          ;; construct matches case-insensitively.  A model that wants an
          ;; exact case writes one into the regexp ([A-Z], \\`...\\'); the
          ;; alternative -- binding `case-fold-search' here -- would make
          ;; the tool's matching disagree with Emacs, which is the model's
          ;; mental model of an "Emacs regexp".  Deferred, not overlooked;
          ;; see `gptel-yatools-vfs--replace-once', which must be exact and
          ;; binds it.
          (while (not (eobp))
            (setq line-num (1+ line-num))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position)
                         (line-end-position))))
              (when (string-match-p regex line)
                (push (format "%d:%s" line-num line) matches)))
            (forward-line 1))
          (gptel-yatools-ok
           ;; An empty body would be indistinguishable from an
           ;; empty file, so say that nothing matched.
           (if matches
               (mapconcat #'identity (nreverse matches) "\n")
             (format "(no lines in %s match the regexp %S.)"
                     (gptel-yatools--display-path full)
                     regex))
           :provenance (if (plist-get read :from-vfs) :vfs :disk))))))))

(gptel-yatools-define-tool gptel-yatools-write-file
  :name "write_file"
  :category "filesystem"
  :description
  "Write CONTENT to the file at PATH. The write is stored in a buffer-local virtual filesystem (VFS) and does NOT touch disk. Call the file_sync tool to review the accumulated diffs and write them to disk. CONTENT must be the file's full new contents, not a patch. No user-facing diff review happens here; it happens at file_sync. The path must be writable: no ancestor of the target may be a regular file (on disk or in the VFS), and the target itself must not be a directory on disk. Content is rejected at write time if the file's encoding cannot represent it; pass CODING (e.g. \"utf-8\") to deliberately convert the file to another encoding on sync. Pass overwrite=true to accept the current disk content as the new baseline and discard any pending conflict (see file_sync); otherwise a pre-existing conflict is preserved."
  :args '((:name "path"
                 :type string
                 :description "File path to write, relative to the workspace root or absolute.")
          (:name "content"
                 :type string
                 :description "The complete new contents of the file (not a patch).")
          (:name "overwrite"
                 :type boolean
                 :description "If true, accept the current disk content as the VFS baseline, discarding any pending conflict."
                 :optional t)
          (:name "coding"
                 :type string
                 :description "Optional Emacs coding system to write the file with on sync, e.g. \"utf-8\" or \"utf-8-dos\". Use this to convert a file to another encoding when the new content needs characters the current encoding cannot represent."
                 :optional t))
  (gptel-yatools--require-string path "path")
  (let* ((written (gptel-yatools-vfs-write (gptel-yatools--resolve-path path)
                                           content overwrite coding))
         (full (plist-get written :full)))
    (if (plist-get written :changed)
        (gptel-yatools-ok
         (format "Wrote %s to the VFS (file is now %d bytes, encoding on sync: %s). Call file_sync to write these changes to disk."
                 (gptel-yatools--display-path full)
                 (plist-get written :bytes)
                 (plist-get written :coding))
         :provenance :vfs)
      (gptel-yatools-ok
       (format "%s already has the requested content on disk. No VFS entry created."
               (gptel-yatools--display-path full))
       :comment "No change needed."))))

(gptel-yatools-define-tool gptel-yatools-write-file-diff
  :name "write_file_diff"
  :category "filesystem"
  :description
  "Edit the file at PATH by replacing OLD_STRING with NEW_STRING in the virtual filesystem (VFS). OLD_STRING must match the file's effective (VFS-or-disk) contents exactly, including whitespace and indentation, and must occur exactly once; if it is missing or ambiguous the edit is refused and nothing is changed. The change is stored in the VFS and does NOT touch disk. Call file_sync to review the accumulated diffs and write them to disk. To create a new file or rewrite one wholesale, use write_file instead. The edit is rejected at write time if the file's encoding cannot represent NEW_STRING; pass CODING to convert the file to another encoding on sync. Pass overwrite=true to accept the current disk content as the VFS baseline, discarding any pending conflict."
  :args '((:name "path"
                 :type string
                 :description "File path to edit, relative to the workspace root or absolute.")
          (:name "old_string"
                 :type string
                 :description "The exact text to replace. Must match the effective file contents byte for byte (including indentation) and must be unique within the file; add surrounding context to disambiguate if needed.")
          (:name "new_string"
                 :type string
                 :description "The text to replace old_string with. Must not be identical to old_string.")
          (:name "overwrite"
                 :type boolean
                 :description "If true, accept the current disk content as the VFS baseline, discarding any pending conflict."
                 :optional t)
          (:name "coding"
                 :type string
                 :description "Optional Emacs coding system to write the file with on sync, e.g. \"utf-8\". Use this to convert the file to another encoding when the edit needs characters the current encoding cannot represent."
                 :optional t))
  (gptel-yatools--require-string path "path")
  (gptel-yatools--require-string old_string "old_string")
  (gptel-yatools--require-string new_string "new_string")
  (let* ((edited (gptel-yatools-vfs-edit (gptel-yatools--resolve-path path)
                                         old_string new_string overwrite coding))
         (full (plist-get edited :full)))
    (if (plist-get edited :changed)
        (gptel-yatools-ok
         (format "Applied edit to %s in the VFS (file is now %d bytes, encoding on sync: %s). Call file_sync to write these changes to disk."
                 (gptel-yatools--display-path full)
                 (plist-get edited :bytes)
                 (plist-get edited :coding))
         :provenance :vfs)
      (gptel-yatools-ok
       (format "%s already has the requested content."
               (gptel-yatools--display-path full))
       :comment "No change needed."))))

(gptel-yatools-define-tool gptel-yatools-file-sync
  :name "file_sync"
  :category "filesystem"
  :description
  "Sync the buffer-local virtual filesystem to real files on disk. Shows the user a unified diff for each syncable file and writes only after acceptance. Files whose disk contents have changed since the VFS captured them are NOT synced and are reported as conflicts (see vfs_discard and write_file overwrite=true to resolve). On success, the synced entries are removed from the VFS and subsequent reads come from disk. Pass PATH to sync a single file; omit PATH to sync everything."
  :args '((:name "path"
                 :type string
                 :description "Optional path to sync. If omitted, sync all pending non-conflicting VFS changes."
                 :optional t))
  (when path
    (gptel-yatools--require-string path "path"))
  (gptel-yatools-vfs--render-sync
   (gptel-yatools-vfs-sync (and path (gptel-yatools--resolve-path path)))))

(gptel-yatools-define-tool gptel-yatools-vfs-diff
  :name "vfs_diff"
  :category "filesystem"
  :description
  "Show a unified diff from the current disk contents (a/) to the pending VFS contents (b/) for all changed files. Lines prefixed with `-' will be removed from disk on sync; lines prefixed with `+' will be added. For files whose disk contents have changed since the VFS captured them, both the external change (which would be lost) and the pending sync are shown, with a CONFLICT marker. Does not modify anything. Use it to preview pending changes before calling file_sync. Pass PATH to show only that file; pass OFFSET and LINES to page through a diff that is too big for one response (a partial excerpt is marked with a PARTIAL DIFF banner and is never the whole story)."
  :args '((:name "path"
                 :type string
                 :description "Optional path to show the diff for. If omitted, all pending files are shown."
                 :optional t)
          (:name "offset"
                 :type integer
                 :description "Optional 1-based line of the diff text to start at. Use after a PARTIAL DIFF banner to read the rest."
                 :optional t)
          (:name "lines"
                 :type integer
                 :description "Optional number of diff lines to return, defaulting to the response line limit."
                 :optional t))
  (when path
    (gptel-yatools--require-string path "path"))
  (let* ((changed (gptel-yatools-vfs-pending-paths))
         (selected (if path
                       (let ((full (gptel-yatools--resolve-path path)))
                         (and (member full changed) (list full)))
                     changed)))
    (cond
     ((null changed)
      (gptel-yatools-ok "The virtual filesystem matches disk; there are no pending changes."
                        :comment "No pending VFS changes."))
     ((null selected)
      (gptel-yatools-ok
       (format "%s has no pending VFS change."
               (gptel-yatools--display-path (gptel-yatools--resolve-path path)))
       :comment "No pending VFS change for the requested path."))
     (t
      (let* ((diff-text (gptel-yatools-vfs-diff-text selected))
             (omitted (- (length changed) (length selected)))
             (paging (gptel-yatools--page-text
                      diff-text
                      (gptel-yatools--coerce-integer offset 1 1)
                      (gptel-yatools--coerce-integer
                       lines (- gptel-yatools--output-line-limit 10) 1)))
             (start (plist-get paging :start))
             (end (plist-get paging :end))
             (total (plist-get paging :total))
             (past-end (plist-get paging :past-end))
             (paged-p (plist-get paging :partial))
             (banner
              (cond
               (past-end
                (format "!!! OFFSET PAST END — the diff text has %d line(s); offset %d is past the end. Call vfs_diff with offset=1 to start over.\n\n"
                        total start))
               ;; A truncated diff can show only '-' lines, which
               ;; reads exactly like "the file is being emptied".
               ;; Say so before the excerpt, not only after it.
               (paged-p
                (format "!!! PARTIAL DIFF — lines %d-%d of %d. This excerpt is INCOMPLETE and may contain only '-' or only '+' lines; do not conclude the file is being deleted or emptied. %s\n\n"
                        start end total
                        (if (< end total)
                            (format "Call vfs_diff with offset=%d for the next chunk."
                                    (1+ end))
                          "This is the last chunk of the diff."))))))
        (gptel-yatools-ok
         (concat (or banner "") (plist-get paging :text))
         :provenance :vfs
         :comment
         (concat
          (if (> omitted 0)
              (format "Unified diff from disk (a/) to VFS (b/) for the requested path only (%d other pending file(s) not shown; call vfs_diff without a path to see them)." omitted)
            "Unified diff from disk (a/) to VFS (b/); this is what file_sync will apply. Files with conflicts are marked and show both the external change and the pending sync.")
          (if paged-p
              (format " Showing lines %d-%d of %d of the diff text." start end total)
            ""))))))))

(gptel-yatools-define-tool gptel-yatools-vfs-discard
  :name "vfs_discard"
  :category "filesystem"
  :description
  "Discard pending virtual-filesystem changes without writing them to disk. Pass PATH to discard a single file's pending changes, or omit PATH to discard all pending changes. Use this to recover from conflicts (vfs_discard then re-read to refresh the baseline), to abandon unwanted edits, or to clear any stuck entry (for example one that file_sync cannot apply because an ancestor path is not writable). This does not touch disk."
  :args '((:name "path"
                 :type string
                 :description "Optional path to discard. If omitted, discard all pending VFS changes."
                 :optional t))
  (when path
    (gptel-yatools--require-string path "path"))
  (let ((discarded (gptel-yatools-vfs-discard-pending
                    (and path (gptel-yatools--resolve-path path)))))
    (cond
     ((and path discarded)
      (gptel-yatools-ok
       (format "Removed pending VFS change for %s."
               (gptel-yatools--display-path (car discarded)))
       :provenance :vfs
       :comment "VFS entry discarded."))
     (path
      (gptel-yatools-ok
       (format "%s has no pending VFS entry."
               (gptel-yatools--display-path (gptel-yatools--resolve-path path)))
       :comment "No pending VFS change."))
     ((null discarded)
      (gptel-yatools-ok "The virtual filesystem has no pending changes."
                        :comment "No pending VFS changes."))
     (t
      (gptel-yatools-ok
       (format "Discarded VFS entries for %d file(s):\n%s"
               (length discarded)
               (mapconcat (lambda (f)
                            (format "  %s" (gptel-yatools--display-path f)))
                          discarded "\n"))
       :provenance :vfs
       :comment "All VFS entries discarded.")))))


(provide 'gptel-yatools-vfs)
;;; gptel-yatools-vfs.el ends here
