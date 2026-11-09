;;; gptel-yatools-vfs.el --- The buffer-local virtual filesystem  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Vladislav Slobodenyuk

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
;; with the rest of the package -- the response envelope, `define-tool', path
;; resolution, the call context's deadline -- is in
;; `gptel-yatools-common.el', which this file requires;
;; `gptel-yatools.el' is the gptel glue that requires this file in turn and
;; draws the header-line labels this module contributes.
;;
;; Two functions answer "may this be written?", and the split between them is
;; deliberate enough to be worth knowing before changing either: the write
;; refuses what is fixed about the entry it is making -- content that is not
;; text, a control character in the path, a subtree already pending -- while
;; `gptel-yatools-vfs-refusal' refuses what a review left open can change --
;; the baseline, the policy, a visiting buffer, a target that became a
;; directory.  `gptel-yatools-vfs-refusal' says why in its docstring.
;;
;; A workspace can live on another machine: every path here is an ordinary
;; Emacs file name, so a TRAMP name such as "/ssh:host:/repo" works as a
;; workspace root, and reads, writes, encoding detection, conflict baselines
;; and the sync itself are performed by TRAMP on the host.  What that costs
;; is round trips -- each `file-exists-p', `file-regular-p' or
;; `insert-file-contents' is one -- so a structural check that walks a
;; directory chain must be written to stop on its own (see
;; `gptel-yatools-vfs--ancestors'): a name's top-most directory is
;; "/ssh:host:/", not "/", and a walk that does not notice will spin against
;; the host forever.  `execute_command' is the one tool that does not follow
;; the name to the host by itself; `gptel-yatools--run-process' carries that.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'gptel)
(require 'subr-x)
(require 'gptel-yatools-common)
(require 'gptel-yatools-media)

;; The tools defined here use `gptel-yatools-define-tool', which lives in
;; `gptel-yatools-common.el' and is available because this file requires it.
;; Everything below is either VFS storage or a tool built on it.

(defvar-local gptel-yatools-vfs nil
  "Buffer-local virtual filesystem.

A hash table mapping absolute file paths to entry plists of the form
\(:content STRING :baseline STRING-OR-NIL :coding CODING
:baseline-coding CODING).  An entry shadows the corresponding file on disk
for the read tools; only `file_sync' writes disk.

Created by `gptel-yatools-vfs--table'.")

(defvar-local gptel-yatools-vfs--header-line-cache nil
  "Cached (PATHS . TIME) for the header line, or nil when invalidated.

Invalidated when the VFS changes, and stale after
`gptel-yatools-vfs--header-line-cache-seconds'.")


;;-------------------------------------------------------------------------
;; Buffer-local VFS
;;
;; Each VFS entry is a plist:
;;   (:content  STRING          ; current VFS content
;;    :baseline STRING-OR-NIL)  ; disk content when the VFS first captured it
;;
;; The baseline is what conflict detection compares against: if disk no
;; longer matches it, somebody else changed the file, and `file_sync'
;; refuses to overwrite it without an explicit overwrite=true.
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs--table ()
  "Return this buffer's VFS hash table, creating it if needed.

Also installs the `kill-buffer' guard in
`kill-buffer-query-functions'."
  (unless gptel-yatools-vfs
    (setq gptel-yatools-vfs (make-hash-table :test #'equal)))
  (unless (memq #'gptel-yatools-vfs--query-kill-buffer kill-buffer-query-functions)
    (add-hook 'kill-buffer-query-functions
              #'gptel-yatools-vfs--query-kill-buffer nil t))
  gptel-yatools-vfs)

(defun gptel-yatools-vfs--query-kill-buffer ()
  "Ask before killing a buffer that still holds unsynced VFS changes.

Returns non-nil when the kill may proceed.  Always non-nil in batch, where
`yes-or-no-p' would read from stdin."
  (let ((paths (gptel-yatools-vfs--changed-paths)))
    (or noninteractive
        (null paths)
        (yes-or-no-p
         (format "%d unsynced VFS change(s) in this buffer (%s).  Kill anyway? "
                 (length paths)
                 (mapconcat #'gptel-yatools--display-path paths ", "))))))

(defun gptel-yatools-vfs--key (path)
  "Return PATH as an absolute VFS table key.

Signals an error when PATH is relative: callers must resolve paths with
`gptel-yatools--resolve-path' first."
  (if (file-name-absolute-p path)
      (expand-file-name path)
    (error "Error: internal error: the VFS was given the relative path %S; tool functions must resolve paths with `gptel-yatools--resolve-path' before calling the VFS"
           path)))

;;-------------------------------------------------------------------------
;; The pending-change module
;;
;; Two questions, spelled differently:
;;
;;   entry    "is there an entry here?"  No disk I/O, no reaping.
;;   pending  "...and does it still differ?"  One disk read; an entry disk
;;            has caught up with is dropped on the way.
;;
;; A path with an entry is *shadowed*, not necessarily *pending*.  Structural
;; checks need the cheap answer.  See
;; docs/adr/0001-pending-ness-keeps-a-cheap-predicate.md.
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs-entry (path)
  "Return PATH's VFS entry plist, or nil when there is no entry.

This is the cheap question: no disk read, no reaping.  For \"and does it
still differ?\" use `gptel-yatools-vfs-pending'.

The plist is the table's own value (`:content', `:baseline', `:coding',
`:baseline-coding'); do not modify it in place."
  (gethash (gptel-yatools-vfs--key path) (gptel-yatools-vfs--table)))

(defun gptel-yatools-vfs-pending (path)
  "Return PATH's VFS entry if it still differs from disk, else nil.

Costs one disk read.  An entry disk has caught up with is dropped from the
table as a side effect, and nil is returned."
  (let ((entry (gptel-yatools-vfs-entry path)))
    (cond
     ((null entry) nil)
     ((gptel-yatools-vfs--changed-p path) entry)
     (t
      (gptel-yatools-vfs-remove path)
      nil))))

(defun gptel-yatools-vfs--reap (paths)
  "Remove PATHS from the table, having found that disk caught up with them.

For callers that must not mutate the table while iterating it, such as
`gptel-yatools-vfs--changed-paths'."
  (dolist (path paths)
    (gptel-yatools-vfs-remove path)))

(defun gptel-yatools-vfs--entry-coding (path)
  "Return the coding system recorded for PATH's VFS entry, or nil."
  (when-let* ((entry (gptel-yatools-vfs-entry path)))
    (plist-get entry :coding)))

(defun gptel-yatools-vfs-put (path content &optional reset-baseline coding)
  "Store CONTENT at PATH in the VFS.

No entry is kept when CONTENT and CODING match what is on disk, so a
write that changes nothing leaves nothing pending.

RESET-BASELINE non-nil refreshes the baseline to the current disk content,
discarding any pending conflict.  The caller is responsible for having
obtained the user's consent.

CODING, when non-nil, is the coding system the file will be written with
on sync, which converts the file to another encoding.  The baseline coding
is left as it was."
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
  "Return (CONTENT . CODING) for the regular file PATH, or nil.

CODING is the coding system that decoded CONTENT, so re-encoding CONTENT
with it reproduces the file's bytes.

Nil for anything that is not a readable regular file: a FIFO would block,
and an unreadable file must not break its callers."
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
  "Return a coding system from CODING that can be written with.

CODING is a value recorded from `last-coding-system-used'.  Nil becomes
`utf-8-unix', and an auto-detected (\"undecided\") coding becomes UTF-8
with the same end-of-line convention, which is lossless for a file that
decoded cleanly."
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
  "Return the coding system a sync of PATH will use, or nil if unknown.

A pending entry wins over disk, since that is what the sync writes."
  (or (gptel-yatools-vfs--entry-coding path)
      (cdr-safe (gptel-yatools-vfs--disk-content-with-coding path))))

(defun gptel-yatools-vfs--first-unencodable (string coding)
  "Return the first distinct character of STRING that CODING cannot encode.

Nil when every character can be encoded."
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
  "Return non-nil if PATH's entry differs from disk, in text or encoding.

No side effects.  Use `gptel-yatools-vfs-pending' when the entry is
wanted too."
  (let ((entry (gptel-yatools-vfs-entry path)))
    (when entry
      (let ((disk-info (gptel-yatools-vfs--disk-content-with-coding path)))
        (or (not (equal (plist-get entry :content)
                        (car-safe disk-info)))
            (not (equal (gptel-yatools-vfs--resolve-coding (plist-get entry :coding))
                        (gptel-yatools-vfs--resolve-coding (cdr-safe disk-info)))))))))

(defun gptel-yatools-vfs--conflict-p (path)
  "Return non-nil if PATH's disk content changed since the VFS baseline.

Only meaningful for paths with an entry.  Both the decoded text and the
coding system are compared, so a pure re-encoding counts as a change.

Boolean form of one `gptel-yatools-vfs-refusal' kind."
  (let ((entry (gptel-yatools-vfs-entry path)))
    (when entry
      (let ((disk-info (gptel-yatools-vfs--disk-content-with-coding path)))
        (or (not (equal (plist-get entry :baseline)
                        (car-safe disk-info)))
            (not (equal (plist-get entry :baseline-coding)
                        (cdr-safe disk-info))))))))

(defun gptel-yatools-vfs--changed-paths ()
  "Return the sorted paths whose VFS content differs from disk.

Entries disk has caught up with are removed from the table on the way."
  (let (result stale)
    (maphash (lambda (path _entry)
               (if (gptel-yatools-vfs--changed-p path)
                   (push path result)
                 (push path stale)))
             (gptel-yatools-vfs--table))
    (gptel-yatools-vfs--reap stale)
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

Each line is TYPE, a tab, the name, and, for an entry that differs from
disk, a tab and a note: `(pending)' when the entry exists only in the VFS,
`(pending change)' when it shadows disk content.

Returns a plist of :text, the listing, and :pending, non-nil when any line
carries a note."
  (let* ((full-dir (file-name-as-directory (expand-file-name full)))
         (entries (make-hash-table :test #'equal))
         (pending nil)
         (stale nil))
    ;; One `file-name-all-completions' lists the directory and says which
    ;; entries are directories, in one TRAMP round trip.  `directory-files'
    ;; plus a `file-directory-p' per entry, and
    ;; `directory-files-and-attributes', both cost one round trip each.
    (when (file-directory-p full)
      (condition-case err
          (dolist (entry (file-name-all-completions "" full))
            (unless (member entry '("./" "../"))
              (puthash (directory-file-name entry)
                       (if (string-suffix-p "/" entry) "dir" "file")
                       entries)))
        (file-error
         (error "Error: cannot read directory %s: %s"
                (gptel-yatools--display-path full)
                (error-message-string err)))))
    ;; VFS entries (including nested ones).  One VFS key may be a file
    ;; whose disk twin is already listed, which is what `(pending
    ;; change)' marks.  The comparison reads disk, so it must not change
    ;; the table under `maphash': a caught-up entry is collected here and
    ;; reaped after the walk.
    (maphash
     (lambda (path _entry)
       (when (and (string-prefix-p full-dir path)
                  (> (length path) (length full-dir)))
         (if (not (gptel-yatools-vfs--changed-p path))
             (push path stale)
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
                      entries)))))
     (gptel-yatools-vfs--table))
    (gptel-yatools-vfs--reap stale)
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

;;-------------------------------------------------------------------------
;; The VFS label for the header line
;;
;; The drawing lives in `gptel-yatools.el'.  This module contributes the
;; label and caches the number it shows, because recomputing it reads every
;; pending file from disk.
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

Clicking the label echoes the pending paths."
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
;; `gptel-yatools.el' asks the registry.
(unless (memq #'gptel-yatools-vfs--header-line-label
              gptel-yatools-header-line-extra-functions)
  (add-to-list 'gptel-yatools-header-line-extra-functions
               #'gptel-yatools-vfs--header-line-label t))

;;-------------------------------------------------------------------------
;; Unified diff via external `diff'
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs--unified-diff (old new &optional labels)
  "Return a unified diff from string OLD to string NEW.

LABELS is nil, a string used as both file names (as \"a/LABEL\" and
\"b/LABEL\"), or a cons of (OLD-LABEL . NEW-LABEL).

Returns the empty string when OLD and NEW are equal, and a description of
the failure when `diff' exits with anything but 0 or 1."
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
            ;; Pin the coding: otherwise `write-region' asks the user to
            ;; choose one for content its default coding cannot represent
            ;; (binary data, or text read with `no-conversion').  UTF-8
            ;; passes raw eight-bit characters through unchanged.
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
  "Return a display string for PATH's pending change.

A plain unified diff from disk to VFS, or, for a conflicting file, both the
external change (baseline to disk) and what `file_sync' would apply (disk
to VFS)."
  (let* ((label (gptel-yatools--display-path path))
         (entry (gptel-yatools-vfs-entry path))
         (disk-info (gptel-yatools-vfs--disk-content-with-coding path))
         (disk (car-safe disk-info))
         (disk-coding (cdr-safe disk-info))
         (vfs  (plist-get entry :content))
         (baseline (plist-get entry :baseline))
         (baseline-coding (plist-get entry :baseline-coding)))
    (cond
     ;; Checked first: a file deleted from disk and rewritten to "" would
     ;; otherwise look like a new empty file, hiding the deletion.  Asked
     ;; of `gptel-yatools-vfs-refusal' so the diff header and the sync
     ;; partition agree.
     ((eq (plist-get (gptel-yatools-vfs-refusal path) :kind) :conflict)
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
with overwrite=true to force the VFS version (the user is asked to confirm).\n\n\
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
              ;; State the refusal here, so the diff and the review agree.
              (let ((refusal (gptel-yatools-vfs-refusal path)))
                (if refusal
                    (format "NOT SYNCED: %s\n" (plist-get refusal :reason))
                  ""))
              (gptel-yatools-vfs--coding-change-note path)
              (gptel-yatools-vfs--unified-diff (or disk "") (or vfs "") label))))))

(defun gptel-yatools-vfs--coding-change-note (path)
  "Return a note that syncing PATH will change its encoding, or \"\"."
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
;; What the rest of the package may call.  The two write entry points are
;; where a pending change is decided on: they validate the target, settle
;; the encoding, refuse content the encoding cannot carry, and record the
;; baseline conflicts are detected against.
;;-------------------------------------------------------------------------
;;-------------------------------------------------------------------------
;; Reading a text file
;;
;; One reader answers "what text is at this path, and where did it come
;; from?" for `read_path', `read-file-from-offset',
;; `fetch-lines-from-file-using-regex' and the skill file reader, and owns
;; the binary policy with it.
;;
;; The answer is a value with a `:kind': a tool has to be able to turn a
;; missing path into its own message, and the skill reader needs the text
;; before deciding how to frame it.  Refusal wording is separate, below.
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs--binary-p (text)
  "Return non-nil if TEXT contains a NUL byte."
  (and (stringp text) (string-match-p "\0" text)))

(defun gptel-yatools-vfs--text-size (text)
  "Return the number of bytes TEXT occupies when written unchanged."
  (or (condition-case nil
          (string-bytes (encode-coding-string text 'no-conversion))
        (error nil))
      (length text)))

(defun gptel-yatools-vfs--binary-notice (read)
  "Return a Result reporting that READ found binary content.

READ is what `gptel-yatools-vfs-read' returned; its `:size' and
`:provenance' are passed on."
  (let ((size (plist-get read :size)))
    (gptel-yatools-ok
     (format "\
%s is a binary file (%s), so its contents are not returned.

Binary files cannot be meaningfully read or edited as text: the
bytes do not form lines, and round-tripping them through text
editing would corrupt the file.  If you need information about it,
use the execute_command tool instead, for example:

  file %s
  ls -l %s
  sha256sum %s

If the goal is to replace the file, write it with write_file
without reading it first."
             (gptel-yatools--display-path (plist-get read :path))
             (if size (format "%d bytes" size) "size unknown")
             (gptel-yatools--display-path (plist-get read :path))
             (gptel-yatools--display-path (plist-get read :path))
             (gptel-yatools--display-path (plist-get read :path)))
     :provenance (plist-get read :provenance)
     :comment "Binary file; contents withheld.")))

(defun gptel-yatools-vfs--read-problem (read)
  "Return a sentence saying why READ is not text, or nil when it is.

Shared wording for `:missing', `:directory', `:special' and `:unreadable'.
A tool with something more useful to say branches on `:kind' itself."
  (pcase (plist-get read :kind)
    (:missing
     (format "Error: no such file: %s"
             (gptel-yatools--display-path (plist-get read :path))))
    (:directory
     (format "Error: %s is a directory, not a file."
             (gptel-yatools--display-path (plist-get read :path))))
    (:special
     (format "Error: %s is not a regular file (device, FIFO or socket); refusing to read it."
             (gptel-yatools--display-path (plist-get read :path))))
    (:unreadable
     (format "Error: %s is not readable (%s)."
             (gptel-yatools--display-path (plist-get read :path))
             (or (plist-get read :why) "permission denied or I/O error")))
    (:too-large
     (format "Error: %s is %s bytes, larger than the %s-byte ceiling this read accepts.  Use execute_command, or read it in parts"
             (gptel-yatools--display-path (plist-get read :path))
             (or (plist-get read :size) "an unknown number of")
             (or (plist-get read :max-size) "unstated")))
    (_ nil)))

(defun gptel-yatools-vfs-read (path &optional disk-only max-size)
  "Return the text at PATH, and say what kind of answer it is.

PATH must be absolute.  DISK-ONLY non-nil ignores a pending entry and
answers from disk.  MAX-SIZE, when non-nil, is the most bytes of disk
content to read.

The value is a plist carrying `:path' and a `:kind':

  :text        `:text' holds the contents, `:provenance' where they came
               from (`:disk' or `:vfs').
  :binary      `:text' holds the raw bytes, `:size' their count,
               `:provenance' where they came from.
  :too-large   disk content is over MAX-SIZE and was not read; `:size' is
               its size and `:max-size' the ceiling that applied.
  :missing     nothing exists at PATH.
  :directory   PATH is a directory.
  :special     PATH is not a regular file.
  :unreadable  PATH is a regular file that could not be read; `:why'
               says why.

A pending entry wins over disk and is never refused for its size; MAX-SIZE
bounds disk content only.

Ordinary outcomes do not signal; render them with
`gptel-yatools-vfs--read-problem' or branch on `:kind'."
  (let* ((full (gptel-yatools-vfs--key path))
         (entry (and (not disk-only) (gptel-yatools-vfs-pending full)))
         (vfs (plist-get entry :content)))
    (cond
     (vfs
      (if (gptel-yatools-vfs--binary-p vfs)
          (list :kind :binary :path full :text vfs :provenance :vfs
                :size (gptel-yatools-vfs--text-size vfs))
        (list :kind :text :path full :text vfs :provenance :vfs)))
     (t
      (gptel-yatools-vfs--read-from-disk full max-size)))))

(defun gptel-yatools-vfs--read-from-disk (full &optional max-size)
  "Return the attributes of the file at FULL in one round trip.

The value is the plist `gptel-yatools-vfs-read' documents, minus any
`:text': one `:kind', the `:path', and `:text', `:size', `:provenance' or
`:why' where that kind carries one.  MAX-SIZE is passed on as that
function's ceiling.

One `file-attributes' call answers existence, directory-ness, regularity
and size at once.  A symlink is asked about again, since
`file-attributes' does not follow it."
  (let* ((attrs (condition-case nil (file-attributes full) (file-error nil)))
         (type (and attrs (file-attribute-type attrs))))
    (cond
     ((null attrs) (list :kind :missing :path full))
     ((eq type t) (list :kind :directory :path full))
     ((stringp type)
      ;; A link: `file-directory-p' follows it, so a link to a directory
      ;; is listed rather than reported unreadable.  Its own size is the
      ;; length of the name it holds, so the size is asked for again.
      (if (file-directory-p full)
          (list :kind :directory :path full)
        (gptel-yatools-vfs--read-regular full max-size)))
     ((file-regular-p full)
      (gptel-yatools-vfs--read-regular full max-size (file-attribute-size attrs)))
     (t (list :kind :special :path full)))))

(defun gptel-yatools-vfs--read-regular (full max-size &optional size)
  "Return the answer for the regular file FULL, reading it once.

MAX-SIZE, when non-nil, is the most bytes that may be read from it: a
larger file answers `:too-large' and is not read.  SIZE is that file's size
when the caller has already asked for it."
  (let ((size (or size
                  (ignore-errors
                    (file-attribute-size (file-attributes full))))))
    (if (and max-size (numberp size) (> size max-size))
        (list :kind :too-large :path full :size size :max-size max-size
              :provenance :disk)
      (let ((content (gptel-yatools-vfs--disk-content full)))
        (cond
         ((null content)
          (list :kind :unreadable :path full
                :why "permission denied or I/O error"))
         ((gptel-yatools-vfs--binary-p content)
          (list :kind :binary :path full :text content :provenance :disk
                :size (gptel-yatools-vfs--text-size content)))
         (t (list :kind :text :path full :text content :provenance :disk)))))))

(defun gptel-yatools-vfs--read-refusal (read)
  "Return READ's reason as a Result, keeping READ's provenance.

READ is what `gptel-yatools-vfs-read' returned.  Provenance defaults to
`:disk' when READ has none."
  (gptel-yatools-ok
   (gptel-yatools-vfs--read-problem read)
   :provenance (or (plist-get read :provenance) :disk)
   :comment "Nothing was read."))

(defun gptel-yatools-vfs-with-text (read function)
  "Call FUNCTION with READ's text and provenance, or return READ's refusal.

FUNCTION is called as (FUNCTION TEXT PROVENANCE) and returns a Result.
It is not called when READ holds no text -- binary content, a missing
path, a directory, a special file, unreadable bytes -- in which case the
refusal is returned instead.

A Result is returned rather than a signal so that provenance survives."
  (pcase (plist-get read :kind)
    (:text (funcall function (plist-get read :text)
                    (plist-get read :provenance)))
    (:binary (gptel-yatools-vfs--binary-notice read))
    (_ (gptel-yatools-vfs--read-refusal read))))

(defun gptel-yatools-vfs--media-result (read)
  "Return a Result attaching READ's file as media, or nil.

Only disk content is considered, and only for a path read as a file: a
pending entry holds text.  The bytes READ already holds decide the type,
so no second disk read is made.

Nil means this is not an image the model can be shown; the caller supplies
its own answer."
  (when (and (eq (plist-get read :provenance) :disk)
             (memq (plist-get read :kind) '(:text :binary)))
    (when-let* ((outcome (gptel-yatools-media-attach
                          (plist-get read :path)
                          (gptel-yatools-media--head-from-text
                           (plist-get read :text))
                          (plist-get read :size))))
      (gptel-yatools-ok (plist-get outcome :message)
                        :provenance :disk
                        :comment (plist-get outcome :comment)))))

(defun gptel-yatools-vfs--coding (path coding)
  "Return the coding system a write to PATH should use, given CODING.

CODING is the tool argument: a coding system name, or nil to keep what
the file already has."
  (when (and coding (not (coding-system-p (intern coding))))
    (error "Error: unknown coding system '%s'.  Use an Emacs coding system name such as utf-8, iso-latin-1 or utf-8-dos"
           coding))
  (gptel-yatools-vfs--resolve-coding
   (or (and coding (intern coding))
       (gptel-yatools-vfs--target-coding path))))

;;-------------------------------------------------------------------------
;; What a write is not allowed to touch
;;
;; The directory list holds the package's own directory, and not all of
;; `user-emacs-directory', since repositories are commonly cloned inside
;; it.  What runs on the next start is named file by file instead.
;;-------------------------------------------------------------------------
(defcustom gptel-yatools-write-denied-directories
  (delq nil
        (list (file-name-directory
               (or load-file-name buffer-file-name
                   (ignore-errors (locate-library "gptel-yatools-common"))
                   ""))))
  "Directories that the writing tools refuse to put files in.

Defaults to this package's own directory.  Matching is by `file-truename'
on the target's directory, so a symlink into one of these is caught too.
Nil lets the agent edit the harness deliberately."
  :type '(repeat directory)
  :group 'gptel-yatools)

(defcustom gptel-yatools-write-denied-files
  (delq nil
        (mapcar #'expand-file-name
                (delq nil
                      (list user-init-file
                            (and (boundp 'early-init-file)
                                 (symbol-value 'early-init-file))
                            (expand-file-name "early-init.el"
                                              user-emacs-directory)
                            (expand-file-name "init.el"
                                              user-emacs-directory)))))
  "Files that the writing tools refuse to write, whatever directory they are in.

Defaults to the files Emacs loads at startup."
  :type '(repeat file)
  :group 'gptel-yatools)

(defcustom gptel-yatools-write-denied-file-names
  '(".dir-locals.el" ".dir-locals-2.el")
  "File names that the writing tools refuse to write, in any directory.

A `.dir-locals.el' is loaded whenever a file in its directory is
visited, so writing one turns the next visit anywhere in that tree into
code execution -- including the visit that would review the write."
  :type '(repeat string)
  :group 'gptel-yatools)

(defun gptel-yatools-vfs--truename-or-path (path)
  "Return PATH's truename if it has one, else PATH expanded."
  (or (ignore-errors (file-truename path))
      (expand-file-name path)))

(defun gptel-yatools-vfs--write-policy-refusal (full)
  "Return a one-line reason why FULL may not be written, or nil.

Asks the three denied lists in order -- file names, startup files,
directories -- so the message names the rule that applied."
  (let* ((true (gptel-yatools-vfs--truename-or-path full))
         (dir (file-name-directory true))
         (name (file-name-nondirectory true))
         (denied-dir
          (cl-find-if
           (lambda (d)
             (and (stringp d)
                  (string-prefix-p (file-name-as-directory
                                    (gptel-yatools-vfs--truename-or-path d))
                                   dir)))
           gptel-yatools-write-denied-directories)))
    (cond
     ((member name gptel-yatools-write-denied-file-names)
      (format "%s is loaded or applied by Emacs on its own, so writing it is denied by `gptel-yatools-write-denied-file-names'"
              name))
     ((member true (mapcar #'gptel-yatools-vfs--truename-or-path
                           gptel-yatools-write-denied-files))
      "it is a file Emacs loads at startup, denied by `gptel-yatools-write-denied-files'")
     (denied-dir
      (format "it is inside %s, denied by `gptel-yatools-write-denied-directories'"
              (gptel-yatools--display-path
               (file-name-as-directory
                (gptel-yatools-vfs--truename-or-path denied-dir)))))
     (t nil))))

(defun gptel-yatools-vfs--confirm-overwrite (full)
  "Ask the user to accept discarding FULL's external changes.

Signals an error, so nothing is written, unless the user agrees.  Always
signals in batch."
  (let ((name (gptel-yatools--display-path full)))
    (unless (and (not noninteractive)
                 (y-or-n-p
                  (format "%s changed on disk since this chat captured it.  Overwrite those changes with the VFS version? "
                          name)))
      (error "Error: cannot write %s: it changed on disk since the VFS captured it.  overwrite=true discards that change and needs the user's confirmation, which was not given.  Nothing was written.  Call vfs_discard and read the file again instead, or ask the user"
             name))))

(defun gptel-yatools-vfs-write (path content &optional overwrite coding)
  "Store CONTENT at PATH in the VFS, and return what changed.

Disk is not touched.  OVERWRITE accepts the current disk content as the
baseline, discarding a pending conflict.  CODING converts the file to
another encoding on sync.

Returns a plist of `:full' (the resolved path), `:changed' (nil when the
write was a no-op), `:bytes' (what the file will occupy on disk) and
`:coding' (what it will be written with).

Signals, having changed nothing, when PATH cannot be written -- see
`gptel-yatools-write-denied-directories' and its siblings, and the checks
in the body -- or when CODING cannot encode CONTENT.  OVERWRITE on a
conflicting file asks the user first."
  (let* ((full (gptel-yatools-vfs--key path))
         ;; The same walk the review's refusal makes, so the write and the
         ;; sync cannot disagree about whether a target is reachable.
         (ancestor (gptel-yatools-vfs--file-ancestor full))
         (policy-error (gptel-yatools-vfs--write-policy-refusal full))
         (target (gptel-yatools-vfs--coding full coding)))
    (cond
     ((not (stringp content))
      (error "Error: content must be a string"))
     ;; The remedy differs by where the blocking file lives.
     (ancestor
      (error "Error: cannot write %s: ancestor %s is a file %s"
             (gptel-yatools--display-path full)
             (gptel-yatools--display-path ancestor)
             (if (gptel-yatools-vfs-entry ancestor)
                 "in the VFS. Use vfs_discard to remove it first."
               "on disk.")))
     ;; A newline in the name would forge a line of a review heading, so
     ;; such a target is refused rather than escaped.
     ((string-match-p gptel-yatools--control-char-regexp full)
      (error "Error: cannot write %s: the path contains a control or invisible character.  Rename the file, or write it from the shell if you really mean it.  Nothing was written"
             (gptel-yatools--display-path full)))
     (policy-error
      (error "Error: cannot write %s: %s.  Nothing was written"
             (gptel-yatools--display-path full)
             policy-error))
     ((file-directory-p full)
      (error "Error: cannot write %s: it is a directory on disk"
             (gptel-yatools--display-path full)))
     ;; A file over a virtual directory would make every pending child
     ;; unsyncable ("File exists").
     ((gptel-yatools-vfs--has-children-p full)
      (error "Error: cannot write %s: it is a directory in the VFS because pending file(s) are stored under it.  Discard those entries first"
             (gptel-yatools--display-path full)))
     ;; A FIFO blocks until a reader appears; a device may fail or scribble.
     ((and (file-exists-p full) (not (file-regular-p full)))
      (error "Error: cannot write %s: it is not a regular file (device, FIFO or socket)"
             (gptel-yatools--display-path full)))
     ((not (gptel-yatools-vfs--encodable-p content target))
      (error "Error: %s cannot represent %s.  Nothing was written.  Either remove it, or pass coding=\"utf-8\" to convert %s to UTF-8 on sync"
             target
             (if-let* ((culprit (gptel-yatools-vfs--first-unencodable content target)))
                 (format "%S" culprit)
               "the content as given")
             (gptel-yatools--display-path full)))
     (t
      ;; Refreshing the baseline is what makes a conflict disappear, so the
      ;; check is placed here, where the discarding would happen.
      (when (and (gptel-yatools--flag-p overwrite)
                 (gptel-yatools-vfs--conflict-p full))
        (gptel-yatools-vfs--confirm-overwrite full))
      (gptel-yatools-vfs-put full content (gptel-yatools--flag-p overwrite)
                             (and coding (intern coding)))
      (list :full full
            :changed (and (gptel-yatools-vfs-entry full) t)
            :bytes (gptel-yatools-vfs--encodable-bytes content target)
            :coding target)))))

(defun gptel-yatools-vfs--replace-once (content old new)
  "Return CONTENT with its one occurrence of OLD replaced by NEW.

Signals when OLD occurs zero or more than once.  The match is literal:
`case-fold-search' is nil, so OLD occurs as written or not at all."
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
          (error "Error: the text to replace was not found.  Read the file again and copy the exact text, including whitespace and indentation"))
         ((> count 1)
          (error "Error: the text to replace occurs %d times.  It must be unique; include more surrounding context in old_string"
                 count))
         (t
          (goto-char first)
          (delete-region first (+ first (length old)))
          (insert new)
          (buffer-substring-no-properties (point-min) (point-max))))))))

(defun gptel-yatools-vfs-edit (path old new &optional overwrite coding)
  "Replace the one occurrence of OLD with NEW in PATH, and return what changed.

Applies to PATH's effective content, pending copy included, and stores
through `gptel-yatools-vfs-write'.  OVERWRITE and CODING are passed there.

Returns the same plist `gptel-yatools-vfs-write' does.  Signals, having
changed nothing, when OLD does not occur exactly once, when PATH is not
text, or when OLD or NEW is not a string."
  (unless (stringp old)
    (error "Error: old_string must be a string"))
  (unless (stringp new)
    (error "Error: new_string must be a string.  Use \"\" to delete the matched text"))
  (when (string-empty-p old)
    (error "Error: old_string must not be empty"))
  (let* ((read (gptel-yatools-vfs-read path))
         (kind (plist-get read :kind))
         (full (gptel-yatools-vfs--key path)))
    (cond
     ((eq kind :binary)
      ;; The read tools refuse to show binary content, so an edit here
      ;; could only be a blind guess at bytes the model has never seen.
      ;; Replacing such a file wholesale is fine.
      (error "Error: %s is a binary file (%s); it cannot be edited as text.  Use write_file to replace it wholesale, or execute_command to inspect it"
             (gptel-yatools--display-path full)
             (if-let* ((size (plist-get read :size)))
                 (format "%d bytes" size)
               "size unknown")))
     ((not (eq kind :text))
      (error "%s" (gptel-yatools-vfs--read-problem read)))
     (t
      (let ((new-content (gptel-yatools-vfs--replace-once
                          (plist-get read :text) old new)))
        (if (equal new-content (plist-get read :text))
            (list :full full :changed nil)
          (gptel-yatools-vfs-write path new-content overwrite coding)))))))

(defun gptel-yatools-vfs-pending-paths ()
  "Return the sorted paths whose VFS content differs from disk.

Reads disk now, rather than the header line's cached list."
  (gptel-yatools-vfs--changed-paths))

(defun gptel-yatools-vfs-diff-text (paths)
  "Return the unified diff from disk to the VFS for PATHS, concatenated."
  (mapconcat #'gptel-yatools-vfs--format-one-diff paths ""))

(defun gptel-yatools-vfs-disk-moved-externally ()
  "Invalidate the header line's cached pending list.

For callers that wrote to disk behind the VFS's back, such as
`execute_command'.  Does not redraw: an explicit `redisplay' belongs to
the announcement path in `gptel-yatools.el'."
  (gptel-yatools-vfs--invalidate-header-line))

(defun gptel-yatools-vfs-discard-pending (&optional path)
  "Drop PATH's pending change, or every entry when PATH is nil.

Returns the paths dropped.  With no PATH the table is emptied, which also
removes entries that disk has caught up with.  PATH must be absolute."
  (let ((paths (if path
                   (let ((full (gptel-yatools-vfs--key path)))
                     (and (gptel-yatools-vfs-entry full) (list full)))
                 (let (all)
                   (maphash (lambda (full _entry) (push full all))
                            (gptel-yatools-vfs--table))
                   (sort all #'string-lessp)))))
    (dolist (full paths) (gptel-yatools-vfs-remove full))
    paths))

(defun gptel-yatools-vfs-reset-buffer-state ()
  "Kill the buffer-local VFS variables in the current buffer.

For a buffer reused for something unrelated, and for the tool-call
inspection buffer."
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
    ;; As in a magit buffer: TAB folds, S-TAB folds or unfolds everything.
    ;; This shadows `diff-hunk-next', which is why `n'/`p' still step
    ;; between hunks -- the diff-mode bindings for that are left alone.
    (define-key map (kbd "TAB") #'gptel-yatools-write-diff-toggle)
    (define-key map (kbd "<backtab>") #'gptel-yatools-write-diff-cycle)
    map)
  "Keymap for `gptel-yatools-write-diff-mode'.")

(defun gptel-yatools-write-diff--visible-glyphless-display ()
  "Return a `glyphless-char-display' that draws invisible characters as hex.

Default drawing shows a bidi control or a zero-width character as a thin
space, which is indistinguishable from nothing."
  (let ((table (copy-sequence glyphless-char-display)))
    (when (char-table-p table)
      (set-char-table-range table (cons #x200b #x200f) 'hex-code)
      (set-char-table-range table (cons #x202a #x202e) 'hex-code)
      (set-char-table-range table (cons #x2066 #x2069) 'hex-code)
      (set-char-table-range table #x061c 'hex-code)
      (set-char-table-range table #x2060 'hex-code)
      (set-char-table-range table #xfeff 'hex-code))
    table))

(define-minor-mode gptel-yatools-write-diff-mode
  "Review a gptel file-write diff.

Disables bidi reordering, so each line is drawn in stored order, and draws
bidi controls and zero-width characters as their code points.

\\{gptel-yatools-write-diff-mode-map}"
  :lighter " gptel-diff"
  :keymap gptel-yatools-write-diff-mode-map
  (if gptel-yatools-write-diff-mode
      (progn
        (setq-local bidi-display-reordering nil)
        (setq-local glyphless-char-display
                    (gptel-yatools-write-diff--visible-glyphless-display)))
    (kill-local-variable 'bidi-display-reordering)
    (kill-local-variable 'glyphless-char-display)))

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
;; The review buffer: painted faces and folded sections
;;
;; The buffer is read once, by a person deciding whether to write to disk,
;; so it has to look right the first time it is shown.  Both halves of how
;; it does that are borrowed from magit's diff display:
;;
;; - Faces are painted onto the text as `font-lock-face' properties while
;;   the lines are inserted, and syntactic fontification is switched off
;;   with `font-lock-defaults' set to (nil t), as `magit-section-mode'
;;   does.  A face already on the text cannot arrive late; the
;;   keyword-driven kind can, because it runs on redisplay.
;;
;;   `font-lock-face' rather than `face' for the same reason magit uses
;;   it: fontifying a region strips the `face' property, while
;;   `font-lock-face' survives and is what font-lock displays.
;;
;; - Folding is a `hidden' flag per section plus an overlay with
;;   `invisible' and `intangible' over the body.  `invisible' alone is not
;;   enough: point would step from a heading into the hidden body and the
;;   section would look stuck open, so `cursor-intangible' goes on the
;;   same overlay.
;;
;; A section is a struct, not a text property: the buffer is never edited,
;; so the ranges recorded during insertion stay right.
;;-------------------------------------------------------------------------
(defface gptel-yatools-diff-file-heading
  '((t :inherit diff-file-header :weight bold))
  "Face for a file heading in the VFS review buffer."
  :group 'gptel-yatools)

(defface gptel-yatools-diff-hunk-heading
  '((t :inherit diff-hunk-header))
  "Face for a hunk heading in the VFS review buffer."
  :group 'gptel-yatools)

(defface gptel-yatools-diff-added
  '((t :inherit diff-added))
  "Face for an added line in the VFS review buffer."
  :group 'gptel-yatools)

(defface gptel-yatools-diff-removed
  '((t :inherit diff-removed))
  "Face for a removed line in the VFS review buffer."
  :group 'gptel-yatools)

(defface gptel-yatools-diff-context
  '((t :inherit diff-context))
  "Face for an unchanged line in the VFS review buffer."
  :group 'gptel-yatools)

(defface gptel-yatools-diff-note
  '((t :inherit font-lock-warning-face))
  "Face for a warning or explanation line in the VFS review buffer."
  :group 'gptel-yatools)

(cl-defstruct (gptel-yatools-diff-section
               (:constructor gptel-yatools-write-diff--make-section))
  "A foldable region of the VFS review buffer.

KIND is `file' or `hunk'.  START is the heading line, BODY-START the
first line that folds away, END one past the last.  HIDDEN says whether
the body is folded.  CHILDREN are the hunks belonging to a file."
  (kind 'file)
  (start 1)
  (body-start 1)
  (end 1)
  (hidden nil)
  (children nil))

(defvar-local gptel-yatools-write-diff--sections nil
  "The sections of the current review buffer, in buffer order.

Files precede their own hunks, so the last match for a position is the
innermost section containing it.")

(defun gptel-yatools-write-diff--line-face ()
  "Return the face for the review-buffer line at point."
  (cond
   ((looking-at "^@@") 'gptel-yatools-diff-hunk-heading)
   ((looking-at "^\\+\\+\\+") 'gptel-yatools-diff-file-heading)
   ((looking-at "^---") 'gptel-yatools-diff-file-heading)
   ((looking-at "^\\+") 'gptel-yatools-diff-added)
   ((looking-at "^-") 'gptel-yatools-diff-removed)
   ((looking-at "^\\(CONFLICT\\|NOT SYNCED\\|(encoding\\|(new empty\\|-- \\)")
    'gptel-yatools-diff-note)
   (t 'gptel-yatools-diff-context)))

(defun gptel-yatools-write-diff--paint (start end)
  "Attach faces to the lines between START and END.

The face goes on as `font-lock-face', so it is in place before the buffer
is displayed."
  (save-excursion
    (goto-char start)
    (while (< (point) end)
      (put-text-property (point) (min end (1+ (line-end-position)))
                         'font-lock-face (gptel-yatools-write-diff--line-face))
      (forward-line 1))))

(defun gptel-yatools-write-diff--summary (body)
  "Return a one-line summary of the diff text BODY, for a folded heading.

Of the form \"2 hunks, +12 -3\", or \"no text change\"."
  (let ((added 0) (removed 0) (hunks 0))
    (dolist (line (split-string body "\n"))
      (cond
       ((string-prefix-p "@@" line) (setq hunks (1+ hunks)))
       ((or (string-prefix-p "+++" line)
            (string-prefix-p "---" line))
        nil)
       ((string-prefix-p "+" line) (setq added (1+ added)))
       ((string-prefix-p "-" line) (setq removed (1+ removed)))))
    (if (zerop hunks)
        "no text change"
      (format "%d hunk%s, +%d -%d"
              hunks (if (= hunks 1) "" "s") added removed))))

(defun gptel-yatools-write-diff--hunk-sections (body-start body-end)
  "Return hunk sections between BODY-START and BODY-END."
  (let ((starts nil)
        (sections nil))
    (save-excursion
      (goto-char body-start)
      (while (re-search-forward "^@@" body-end t)
        (push (line-beginning-position) starts)))
    (setq starts (nreverse starts))
    (while starts
      (let* ((start (car starts))
             (end (or (cadr starts) body-end))
             (body (min end (save-excursion
                              (goto-char start)
                              (forward-line 1)
                              (point)))))
        (push (gptel-yatools-write-diff--make-section
               :kind 'hunk :start start :body-start body :end end)
              sections))
      (setq starts (cdr starts)))
    (nreverse sections)))

(defun gptel-yatools-write-diff--insert-file (path text)
  "Insert PATH's pending diff, given as TEXT, as a foldable section.

TEXT is what `gptel-yatools-vfs--format-one-diff' produced in the
caller's buffer: this buffer has its own, empty, buffer-local VFS, so
the diff has to be rendered before switching to it.  Its heading is
this buffer's own rendering; the body is the text the model is told and
`vfs_diff' shows, so the review cannot disagree with the reply that
preceded it.

Returns the sections it added: the file, then its hunks."
  (let* ((newline (string-search "\n" text))
         (body (if newline (substring text (1+ newline)) ""))
         (file (gptel-yatools-write-diff--make-section
                :kind 'file :start (point))))
    (insert " "
            (propertize (gptel-yatools--display-path path)
                        'font-lock-face 'gptel-yatools-diff-file-heading)
            (propertize (format "  (%s)" (gptel-yatools-write-diff--summary body))
                        'font-lock-face 'gptel-yatools-diff-note)
            "\n")
    (setf (gptel-yatools-diff-section-body-start file) (point))
    (let ((body-start (point)))
      (insert body)
      (unless (bolp) (insert "\n"))
      (gptel-yatools-write-diff--paint body-start (point))
      (let ((hunks (gptel-yatools-write-diff--hunk-sections body-start (point))))
        (setf (gptel-yatools-diff-section-children file) hunks)
        (setf (gptel-yatools-diff-section-end file) (point))
        (append (list file) hunks)))))

(defun gptel-yatools-write-diff--insert-preamble (skipped)
  "Insert the explanation of the buffer, and the SKIPPED files."
  (insert (propertize "Changes to apply to disk on sync.\n"
                      'font-lock-face 'gptel-yatools-diff-context))
  (insert (propertize (concat "  a/ = current disk content\n"
                              "  b/ = VFS content (post-sync disk)\n"
                              "  '-' lines will be removed from disk.\n"
                              "  '+' lines will be added to disk.\n\n")
                      'font-lock-face 'gptel-yatools-diff-context))
  (when skipped
    (insert (propertize "NOT SYNCED — these pending files are skipped (see reason):\n"
                        'font-lock-face 'gptel-yatools-diff-note))
    (dolist (pair skipped)
      (insert (propertize (format "  %s: %s\n"
                                  (gptel-yatools--display-path (car pair))
                                  (cdr pair))
                          'font-lock-face 'gptel-yatools-diff-note)))
    (insert "\n")))

(defun gptel-yatools-write-diff--section-at (position)
  "Return the innermost section containing POSITION, or nil."
  (let (found)
    (dolist (section gptel-yatools-write-diff--sections found)
      (when (and (<= (gptel-yatools-diff-section-start section) position)
                 (< position (gptel-yatools-diff-section-end section)))
        (setq found section)))))

(defun gptel-yatools-write-diff--overlays (section)
  "Return the overlays that fold SECTION's body."
  (let ((body-start (gptel-yatools-diff-section-body-start section))
        (end (gptel-yatools-diff-section-end section))
        overlays)
    (dolist (overlay (overlays-in body-start end) overlays)
      (when (eq (overlay-get overlay 'gptel-yatools-diff-body) section)
        (push overlay overlays)))))

(defun gptel-yatools-write-diff--hide (section)
  "Fold SECTION's body away."
  (setf (gptel-yatools-diff-section-hidden section) t)
  (let ((body-start (gptel-yatools-diff-section-body-start section))
        (end (gptel-yatools-diff-section-end section)))
    (when (and (< body-start (point)) (< (point) end))
      (goto-char (gptel-yatools-diff-section-start section)))
    (unless (gptel-yatools-write-diff--overlays section)
      (let ((overlay (make-overlay body-start end)))
        (overlay-put overlay 'evaporate t)
        (overlay-put overlay 'invisible t)
        ;; Without this, `C-n' walks from the heading into text the user
        ;; cannot see: the fold looks open because point went in.
        (overlay-put overlay 'intangible t)
        (overlay-put overlay 'gptel-yatools-diff-body section)
        (overlay-put overlay 'isearch-open-invisible
                     #'gptel-yatools-write-diff--isearch-open)))))

(defun gptel-yatools-write-diff--isearch-open (overlay)
  "Unfold the section OVERLAY hides, so isearch can show its match."
  (when-let* ((section (overlay-get overlay 'gptel-yatools-diff-body)))
    (gptel-yatools-write-diff--show section)))

(defun gptel-yatools-write-diff--show (section)
  "Unfold SECTION's body, keeping its children as they were."
  (setf (gptel-yatools-diff-section-hidden section) nil)
  (dolist (overlay (gptel-yatools-write-diff--overlays section))
    (delete-overlay overlay))
  (dolist (child (gptel-yatools-diff-section-children section))
    (if (gptel-yatools-diff-section-hidden child)
        (gptel-yatools-write-diff--hide child)
      (gptel-yatools-write-diff--show child))))

(defun gptel-yatools-write-diff-toggle ()
  "Fold or unfold the section at point.

This is `TAB', as it is in a magit buffer: on a file heading it folds
the whole file, on a hunk heading that hunk.  Inside a body it acts on
the innermost section there, which is the hunk."
  (interactive)
  (let ((section (gptel-yatools-write-diff--section-at (point))))
    (unless section
      (user-error "No diff section here"))
    (if (gptel-yatools-diff-section-hidden section)
        (gptel-yatools-write-diff--show section)
      (gptel-yatools-write-diff--hide section))))

(defun gptel-yatools-write-diff-show-all ()
  "Unfold every section of the review buffer."
  (interactive)
  (dolist (section gptel-yatools-write-diff--sections)
    (gptel-yatools-write-diff--show section)))

(defun gptel-yatools-write-diff-hide-all ()
  "Fold every file section of the review buffer.

Only the files are folded: their hunks are inside the same range, and a
second overlay per hunk would have to be tracked for no visible gain.
Their `hidden' flags are set too, so unfolding a file leaves the hunks
as they were."
  (interactive)
  (dolist (section gptel-yatools-write-diff--sections)
    (when (eq (gptel-yatools-diff-section-kind section) 'file)
      (dolist (child (gptel-yatools-diff-section-children section))
        (setf (gptel-yatools-diff-section-hidden child) t))
      (gptel-yatools-write-diff--hide section))))

(defun gptel-yatools-write-diff-cycle ()
  "Fold everything when it is all unfolded, and unfold it when it is not.

This is `S-TAB', as in a magit buffer."
  (interactive)
  (if (cl-every #'gptel-yatools-diff-section-hidden
                (cl-remove-if-not
                 (lambda (section)
                   (eq (gptel-yatools-diff-section-kind section) 'file))
                 gptel-yatools-write-diff--sections))
      (gptel-yatools-write-diff-show-all)
    (gptel-yatools-write-diff-hide-all)))

;;-------------------------------------------------------------------------
;; Sync helpers
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs--build-sync-diff-buffer (paths &optional skipped)
  "Build and return the review buffer for the pending PATHS.

Anything that will not be synced is listed separately in SKIPPED, an alist
of (PATH . REASON).

A `diff-mode' buffer, for `diff-hunk-next' and the rest of its
navigation, whose faces come from the painting above rather than from
`diff-mode''s keywords."
  ;; Generate every diff here, in the caller's buffer: `gptel-yatools-vfs' is
  ;; buffer-local, so rendering inside the new buffer would read a fresh,
  ;; empty table and preview the wrong bytes.
  (let ((texts (mapcar (lambda (path)
                         (cons path (gptel-yatools-vfs--format-one-diff path)))
                       paths))
        (diff-buf (generate-new-buffer "*gptel VFS sync diff*"))
        (sections nil))
    (with-current-buffer diff-buf
      (gptel-yatools-write-diff--insert-preamble skipped)
      (dolist (pair texts)
        (setq sections (append sections
                               (gptel-yatools-write-diff--insert-file
                                (car pair) (cdr pair)))))
      ;; The major mode wipes buffer-local variables, so the sections are
      ;; installed after it, and the text properties painted above simply
      ;; stay where they are.
      (diff-mode)
      (setq-local gptel-yatools-write-diff--sections sections)
      (setq-local diff-refine nil)
      ;; As in a magit buffer: no keyword fontification, because the faces
      ;; are already on the text and a keyword pass could only replace or
      ;; strip them.  `font-lock-ensure' then applies every `font-lock-face'
      ;; before the buffer is ever displayed.
      (setq-local font-lock-defaults '(nil t))
      (font-lock-mode 1)
      (font-lock-ensure)
      (setq-local gptel-yatools-write-diff--decision nil)
      (setq-local buffer-read-only t)
      (gptel-yatools-write-diff-mode 1)
      (goto-char (point-min)))
    diff-buf))

(defun gptel-yatools-vfs-refusal (full)
  "Return nil if FULL can be synced now, or say why it cannot.

The value is a plist of `:kind' and `:reason'.  `:kind' is `:conflict'
when disk has moved on since the VFS captured its baseline, and
`:blocked' for every other refusal.

Asked by the partition that decides what the user is shown, by the diff
header, and again by the write immediately before it writes, so the files
the user approves are the files applied.  Checks that belong to the
content being handed in stay in `gptel-yatools-vfs-write'; what is here
is what can change while the review sits open.  See ADR 0007."
  (let ((entry-coding (gptel-yatools-vfs--entry-coding full))
        (content (or (plist-get (gptel-yatools-vfs-entry full) :content) ""))
        (existing (get-file-buffer full))
        (policy (gptel-yatools-vfs--write-policy-refusal full)))
    (cond
     ((gptel-yatools-vfs--conflict-p full)
      (list :kind :conflict
            :reason "changed on disk since the VFS captured it"))
     ;; Asked again here, and not only when the write was buffered: the
     ;; review can sit open for minutes, and this answer is what the write
     ;; acts on.
     (policy
      (list :kind :blocked :reason policy))
     ((let ((ancestor (gptel-yatools-vfs--file-ancestor full)))
        (and ancestor
             (list :kind :blocked
                   :reason (format "ancestor %s is a file, not a directory"
                                   (gptel-yatools--display-path ancestor))))))
     ((let ((exists (file-exists-p full)))
        ;; The kind is asked once more before it is named: the reason is
        ;; the only description of what to fix.
        (and exists
             (not (file-regular-p full))
             (list :kind :blocked
                   :reason (if (file-directory-p full)
                               "target is a directory now"
                             "target is no longer a regular file (device, FIFO or socket)")))))
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

(defun gptel-yatools-vfs--ancestors (full)
  "Return FULL's ancestor directories, nearest first.

Stops when the name stops getting shorter, which is what makes it
terminate on a TRAMP name: \"/ssh:host:/\" is its own parent.  FULL
itself, \"/\" and \"\" are not included."
  (let ((ancestor (directory-file-name (file-name-directory full)))
        (ancestors nil)
        (next nil))
    (while (and ancestor
                (not (equal ancestor ""))
                (not (equal ancestor "/"))
                (not (equal ancestor full)))
      (push ancestor ancestors)
      (setq next (directory-file-name (file-name-directory ancestor)))
      ;; No progress means this is the top of the name space: keep it as
      ;; `ancestor' would have been, then stop.
      (setq ancestor (and (not (equal next ancestor)) next)))
    (nreverse ancestors)))

(defun gptel-yatools-vfs--file-ancestor (full)
  "Return FULL's nearest ancestor that is a file, or nil.

A file ancestor, on disk or in the VFS, makes the target unwritable
without removing it first."
  (cl-find-if (lambda (ancestor)
                (or (gptel-yatools-vfs-entry ancestor)
                    (file-regular-p ancestor)))
              (gptel-yatools-vfs--ancestors full)))

(defun gptel-yatools-vfs--confirm-sync (paths &optional skipped)
  "Show a diff of PATHS against disk and ask the user to accept it.

SKIPPED is an alist of (PATH . REASON) for pending files that will not be
synced; they are listed in the review buffer so the user sees the whole
change set.

Returns non-nil when the user accepted.  The caller's window layout and
current buffer are restored afterwards.  Time spent in the review does not
count against the tool's deadline."
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
          (gptel-yatools--with-deadline-suspended
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
  "Return non-nil if STRING round-trips through CODING unchanged.

Encoding an unrepresentable character does not signal in Emacs: it is
written as raw bytes or replaced, so the file would land corrupted.

Both sides are normalised with `string-to-multibyte', because content read
with `no-conversion' is multibyte text of raw eight-bit characters while
decoding returns the equivalent unibyte string."
  (equal (string-to-multibyte
          (condition-case nil
              (decode-coding-string (encode-coding-string string coding) coding)
            (error nil)))
         (string-to-multibyte string)))

(defun gptel-yatools-vfs--encodable-bytes (string coding)
  "Return the bytes STRING will occupy when written with CODING.

Unlike `string-bytes', this accounts for the coding system, including CRLF
expansion."
  (string-bytes (encode-coding-string string coding)))

(defun gptel-yatools-vfs--sync-one (full)
  "Sync FULL from VFS to disk.

FULL is expected to have a pending entry.  `gptel-yatools-vfs-refusal' is
asked again here, immediately before the write: the review can sit open
for as long as the user likes.

Returns (STATUS MESSAGE), STATUS being `:ok' or `:failed'."
  (let ((content (plist-get (gptel-yatools-vfs-entry full) :content)))
    (cond
     ((null content)
      (list :failed "no VFS entry"))
     ((let ((refusal (gptel-yatools-vfs-refusal full)))
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
;; Partition the pending files, ask for approval, write the ones that can
;; be written, report the rest.  Both callers are adapters over this:
;; `file_sync' renders the outcome as a tool response, the review buffer
;; renders it as a diff.
;;
;; The partition is computed once, before anything is written, so the diff
;; the user approves is the change set applied.  `--sync-one' still
;; re-checks each file before writing it: the review runs inside
;; `recursive-edit', and a file can change while someone reads a diff.
;;-------------------------------------------------------------------------
(defcustom gptel-yatools-sync-without-review nil
  "If non-nil, `file_sync' writes without showing a diff for review.

For unattended use -- a script, org-babel, a batch Emacs.  The checks
still run: a file that changed on disk, a visiting buffer with unsaved
changes, and content the encoding cannot represent are all refused and
reported as they are when a review is shown.

Writes still only happen when the model calls `file_sync'.  No tool
description mentions this option, so it cannot change what the model does."
  :type 'boolean
  :group 'gptel-yatools)

(defun gptel-yatools-vfs--sync-partition (targets)
  "Split TARGETS into what can be synced and what cannot.

Returns a plist of `:conflicts' (alist of PATH . REASON), `:blocked' (the
same, for files that cannot be written) and `:syncable' (the rest, in
order).  Each file is classified once, by `gptel-yatools-vfs-refusal', and
that reason is carried out, never asked for again."
  (let (conflicts blocked syncable)
    (dolist (file targets)
      (let ((refusal (gptel-yatools-vfs-refusal file)))
        (pcase (plist-get refusal :kind)
          ('nil (push file syncable))
          (:conflict (push (cons file (plist-get refusal :reason)) conflicts))
          (_ (push (cons file (plist-get refusal :reason)) blocked)))))
    (list :conflicts (nreverse conflicts)
          :blocked (nreverse blocked)
          :syncable (nreverse syncable))))

(defun gptel-yatools-vfs--sync-approve (syncable skipped review)
  "Return `:approved', `:rejected' or `:noninteractive' for SYNCABLE.

SKIPPED is shown alongside the diff.  REVIEW, when non-nil, is
authoritative, including in batch.  Only the default review is refused in
batch, where `recursive-edit' would block forever."
  (cond
   (gptel-yatools-sync-without-review :approved)
   (review (if (funcall review syncable skipped) :approved :rejected))
   (noninteractive :noninteractive)
   ((gptel-yatools-vfs--confirm-sync syncable skipped) :approved)
   (t :rejected)))

(defun gptel-yatools-vfs--sync-write (syncable)
  "Write SYNCABLE from the VFS to disk, returning (SYNCED . FAILED).

SYNCED is the paths written, in order; FAILED is an alist of PATH .
REASON."
  (let (synced failed)
    (dolist (file syncable)
      (pcase-let ((`(,status ,message) (gptel-yatools-vfs--sync-one file)))
        (pcase status
          (:ok (push file synced))
          (:failed (push (cons file message) failed)))))
    (cons (nreverse synced) (nreverse failed))))

(defun gptel-yatools-vfs-sync (&optional path review)
  "Sync the VFS to disk, and return what happened as a plist.

PATH, when non-nil, limits the sync to that file and must be absolute.
REVIEW is the adapter that asks the user to approve the change set; nil
uses the interactive review, or refuses the sync in batch.

Returns a plist:

  :status     `:nothing' (nothing pending at all), `:no-target' (PATH has
              no pending change), `:declined' (not approved) or `:done'.
  :requested  PATH as given, or nil.
  :reason     for `:declined', `:noninteractive' or `:user'.
  :synced     paths written, in order.
  :conflicts  paths changed on disk since the VFS captured them.
  :blocked    alist of PATH . REASON for files that cannot be written.
  :failed     alist of PATH . REASON for files that could not be written.

The buffer the operation started in is re-entered before writing, since
the review shows a buffer of its own."
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
             (conflict-entries (plist-get partition :conflicts))
             (conflicts (mapcar #'car conflict-entries))
             (blocked (plist-get partition :blocked))
             (syncable (plist-get partition :syncable))
             ;; Both halves of what will not be synced, as the alist the
             ;; review wants.  The reasons came out of the partition.
             (skipped (append blocked conflict-entries))
             (approval (and syncable
                            (gptel-yatools-vfs--sync-approve
                             syncable skipped review))))
        (cond
         ((eq approval :noninteractive)
          ;; The hint names the option, so it goes to the user: the model
          ;; cannot set it.
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
                 (outcome (list :status :done :requested path
                                :synced synced :conflicts conflicts
                                :blocked blocked :failed failed)))
            ;; Someone is watching this happen, and the tool reply is the
            ;; report they may never read.
            (when-let* ((line (gptel-yatools-vfs--sync-message outcome)))
              (message "%s" line))
            outcome))))))))


;;-------------------------------------------------------------------------
;; The sync report: one composition, two adapters
;;
;; A sync outcome is a four-part answer (synced, conflicts, blocked,
;; failed).  It is composed once into sections, and each reader adapts the
;; sections: the reply renders every section in full, the echo area renders
;; the counts.
;;-------------------------------------------------------------------------
(defun gptel-yatools-vfs--sync-report (outcome)
  "Return OUTCOME's four parts as sections, in the order they are read.

Each section is a plist with a :kind -- `:synced', `:conflicts',
`:blocked' or `:failed' -- and either :paths (files written) or :entries
\(an alist of PATH . REASON).  An empty part is left out rather than
kept with no entries, so a report with one kind of problem reads as one
section and not as four with three blanks."
  (let ((synced (plist-get outcome :synced))
        (conflicts (plist-get outcome :conflicts))
        (blocked (plist-get outcome :blocked))
        (failed (plist-get outcome :failed))
        (sections nil))
    (when synced (push (list :kind :synced :paths synced) sections))
    (when conflicts (push (list :kind :conflicts :paths conflicts) sections))
    (when blocked (push (list :kind :blocked :entries blocked) sections))
    (when failed (push (list :kind :failed :entries failed) sections))
    (nreverse sections)))

(defun gptel-yatools-vfs--sync-entries (section)
  "Return SECTION's files: a list of paths or an alist of PATH . REASON."
  (or (plist-get section :paths) (plist-get section :entries)))

(defun gptel-yatools-vfs--sync-count (sections kind)
  "Return how many files SECTIONS reports for KIND."
  (if-let* ((section (cl-find kind sections
                              :key (lambda (section) (plist-get section :kind))
                              :test #'eq)))
      (length (gptel-yatools-vfs--sync-entries section))
    0))

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

(defun gptel-yatools-vfs--sync-section-text (section)
  "Return SECTION as the block of text the model reads."
  (let ((entries (gptel-yatools-vfs--sync-entries section)))
    (pcase (plist-get section :kind)
      (:synced
       (format "Synced %d file(s) to disk:\n%s\n"
               (length entries)
               (gptel-yatools-vfs--sync-file-list entries)))
      (:conflicts
       (format "\nConflicts (%d file(s), NOT synced — disk changed since VFS baseline):\n%s\nResolve with vfs_discard + re-read, or write_file with overwrite=true, which asks the user before it discards anything.\n"
               (length entries)
               (gptel-yatools-vfs--sync-file-list entries)))
      (:blocked
       (format "\nBlocked (%d file(s), NOT synced):\n%s\n"
               (length entries)
               (gptel-yatools-vfs--sync-reason-list entries)))
      (:failed
       (format "\nFailed (%d file(s), NOT synced):\n%s\n"
               (length entries)
               (gptel-yatools-vfs--sync-reason-list entries))))))

(defun gptel-yatools-vfs--sync-message (outcome)
  "Return what OUTCOME means for the user, as one echo-area line, or nil.

Nil when everything landed: a line announcing a clean sync would train the
user to ignore the line that matters.  Built from the same report as the
tool reply, so the two cannot disagree."
  (let* ((sections (gptel-yatools-vfs--sync-report outcome))
         (synced (gptel-yatools-vfs--sync-count sections :synced))
         (conflicts (gptel-yatools-vfs--sync-count sections :conflicts))
         (blocked (gptel-yatools-vfs--sync-count sections :blocked))
         (failed (gptel-yatools-vfs--sync-count sections :failed))
         (not-synced (+ conflicts blocked failed)))
    (cond
     ((zerop not-synced) nil)
     ;; Nothing could be attempted, for one reason: say that reason rather
     ;; than a four-part total with three zeroes.
     ((and (zerop synced) (zerop failed) (zerop conflicts))
      (format "gptel: nothing synced — %d file(s) blocked." blocked))
     ((and (zerop synced) (zerop failed) (zerop blocked))
      (format "gptel: nothing synced — %d file(s) conflict with disk."
              conflicts))
     (t
      (format "gptel: synced %d file(s); %d NOT synced (conflicts: %d, blocked: %d, failed: %d). See the tool result for details."
              synced not-synced conflicts blocked failed)))))

(defun gptel-yatools-vfs--render-sync (outcome)
  "Render OUTCOME, from `gptel-yatools-vfs-sync', as a tool result."
  (let ((status (plist-get outcome :status))
        (path (plist-get outcome :requested)))
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
       (let* ((sections (gptel-yatools-vfs--sync-report outcome))
              (kinds (mapcar (lambda (section) (plist-get section :kind))
                             sections))
              (has-problems (or (plist-get outcome :conflicts)
                                (plist-get outcome :blocked)
                                (plist-get outcome :failed))))
         (cond
          ;; One kind of problem and nothing else: say it plainly, rather
          ;; than a four-part report with three empty sections.
          ((equal kinds '(:blocked))
           (gptel-yatools-ok
            (format "These files could not be synced:\n%s\n"
                    (gptel-yatools-vfs--sync-reason-list
                     (gptel-yatools-vfs--sync-entries (car sections))))
            :provenance :vfs
            :comment "All pending changes are blocked; nothing synced."))
          ((equal kinds '(:conflicts))
           (gptel-yatools-ok
            (format "The following file(s) changed on disk since the VFS captured them; refusing to overwrite:\n%s\n\nResolve with vfs_discard + re-read, or write_file with overwrite=true, which asks the user before it discards anything.\n"
                    (gptel-yatools-vfs--sync-file-list
                     (gptel-yatools-vfs--sync-entries (car sections))))
            :provenance :vfs
            :comment "All pending changes conflict with disk; nothing synced."))
          (t
           (gptel-yatools-ok
            (concat
             (unless (memq :synced kinds) "No files were synced.\n")
             (mapconcat #'gptel-yatools-vfs--sync-section-text sections ""))
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
  "Read a path relative to the workspace root. If PATH is a directory, return a listing (merged with VFS entries). If PATH is a file, return its contents. An image the model can see (PNG, JPEG, GIF or WebP, recognized by its bytes rather than its name) is attached to the conversation instead, so it can be looked at rather than described: the reply says so, and the image stays attached to later turns until the user removes it. Anything else binary is reported, not returned. Pending VFS changes take precedence over disk contents; the reply says whether it describes pending changes or disk."
  :args '((:name "path"
                 :type string
                 :description "Path to read, relative to the workspace root or absolute."))
  (let* ((full (gptel-yatools--resolve-path path))
         (read (gptel-yatools-vfs-read full)))
    ;; An image is not text, but a model that can see one does not need it
    ;; read out: it is attached to the conversation.  This is checked before
    ;; the read is interpreted, because the image path and the binary path
    ;; both start from the same bytes and only one of them can answer.
    (or (gptel-yatools-vfs--media-result read)
        (pcase (plist-get read :kind)
          ;; A directory is the one kind this tool answers differently from
          ;; every other reader, which is why the branch stays here and the
          ;; rest goes through `gptel-yatools-vfs-with-text'.
          (:directory
           (let* ((listing (gptel-yatools-vfs--directory-listing full))
                  (text (plist-get listing :text)))
             (gptel-yatools-ok
              (if (string-empty-p text) "(empty directory)" text)
              :provenance (if (plist-get listing :pending) :mixed :disk))))
          (:missing
           ;; A directory can exist in the VFS alone, when pending files are
           ;; stored under it and nothing was ever created on disk.
           (if (gptel-yatools-vfs--has-children-p full)
               (gptel-yatools-ok
                (plist-get (gptel-yatools-vfs--directory-listing full) :text)
                :provenance :vfs)
             (gptel-yatools-vfs--read-refusal read)))
          (_
           (gptel-yatools-vfs-with-text
            read
            (lambda (text provenance)
              (gptel-yatools-ok text :provenance provenance))))))))

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
  (let* ((full (gptel-yatools--resolve-path path))
         (read (gptel-yatools-vfs-read full)))
    (gptel-yatools-vfs-with-text
     read
     (lambda (content provenance)
       (let ((offset (gptel-yatools--coerce-integer offset 1 1))
             (lines  (gptel-yatools--coerce-integer lines 0 0)))
         (with-temp-buffer
           (insert content)
           (let ((total (gptel-yatools--line-count content)))
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
               :provenance provenance)))))))))

(gptel-yatools-define-tool gptel-yatools-fetch-lines-from-file-using-regex
  :name "fetch_lines_from_file_using_regex"
  :category "filesystem"
  :description
  "Return lines from a file that match an Emacs regexp. Each match is prefixed with its 1-based line number. Use this when you know which file to search and want every matching line of it: unlike the grep tool it does not walk the tree, is not capped, and matches the case exactly as written. Pending VFS changes shadow disk content; the reply says which it came from. Binary files (containing NUL bytes) are reported, not searched."
  :args '((:name "path"
                 :type string
                 :description "File path to search.")
          (:name "regex"
                 :type string
                 :description "Emacs regular expression to match against each line."))
  (let* ((full (gptel-yatools--resolve-path path))
         (read (gptel-yatools-vfs-read full)))
    ;; The file is read first and the regexp validated second, so a call
    ;; that is wrong twice -- no such file, and a broken pattern -- is
    ;; told about the file.
    (gptel-yatools-vfs-with-text
     read
     (lambda (content provenance)
       (let ((regex-error
              (condition-case err
                  (progn (string-match-p regex "") nil)
                (invalid-regexp (error-message-string err)))))
         (when regex-error
           (error "Error: invalid regexp %S: %s" regex regex-error))
         ;; `string-match-p' honours the ambient `case-fold-search' (t by
         ;; default), so a regexp with no case construct matches
         ;; case-insensitively.  A model that wants an exact case writes one
         ;; into the regexp ([A-Z], \\`...\\'); binding `case-fold-search'
         ;; here would make the tool's matching disagree with Emacs, which
         ;; is the model's mental model of an "Emacs regexp".
         ;; `gptel-yatools-vfs--replace-once' must be exact and binds it.
         (let ((matches '()))
           (gptel-yatools--map-lines
            content
            (lambda (number line)
              (when (string-match-p regex line)
                (push (format "%d:%s" number line) matches))))
           (gptel-yatools-ok
            ;; An empty body would be indistinguishable from an
            ;; empty file, so say that nothing matched.
            (if matches
                (mapconcat #'identity (nreverse matches) "\n")
              (format "(no lines in %s match the regexp %S.)"
                      (gptel-yatools--display-path full)
                      regex))
            :provenance provenance)))))))

(gptel-yatools-define-tool gptel-yatools-write-file
  :name "write_file"
  :category "filesystem"
  :description
  "Write CONTENT to the file at PATH. The write is stored in a buffer-local virtual filesystem (VFS) and does NOT touch disk. Call the file_sync tool to review the accumulated diffs and write them to disk. CONTENT must be the file's full new contents, not a patch. No user-facing diff review happens here; it happens at file_sync. The path must be writable: no ancestor of the target may be a regular file (on disk or in the VFS), and the target itself must not be a directory on disk. A path holding a control character is refused, and so is a target the write policy protects — the Emacs startup files, `.dir-locals.el', and this package's own source — with an error naming the setting that denies it; both refusals are deliberate, so report them to the user rather than working around them through the shell. Content is rejected at write time if the file's encoding cannot represent it; pass CODING (e.g. \"utf-8\") to deliberately convert the file to another encoding on sync. Pass overwrite=true to accept the current disk content as the new baseline and discard any pending conflict (see file_sync); the user is asked to confirm that, and otherwise a pre-existing conflict is preserved."
  :args '((:name "path"
                 :type string
                 :description "File path to write, relative to the workspace root or absolute.")
          (:name "content"
                 :type string
                 :description "The complete new contents of the file (not a patch).")
          (:name "overwrite"
                 :type boolean
                 :description "If true, accept the current disk content as the VFS baseline, discarding any pending conflict. The user is asked to confirm whenever this would discard a conflict, so passing it does not make the check go away."
                 :optional t)
          (:name "coding"
                 :type string
                 :description "Optional Emacs coding system to write the file with on sync, e.g. \"utf-8\" or \"utf-8-dos\". Use this to convert a file to another encoding when the new content needs characters the current encoding cannot represent."
                 :optional t))
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
                 :description "If true, accept the current disk content as the VFS baseline, discarding any pending conflict. The user is asked to confirm whenever this would discard a conflict, so passing it does not make the check go away."
                 :optional t)
          (:name "coding"
                 :type string
                 :description "Optional Emacs coding system to write the file with on sync, e.g. \"utf-8\". Use this to convert the file to another encoding when the edit needs characters the current encoding cannot represent."
                 :optional t))
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
  (gptel-yatools-vfs--render-sync
   (gptel-yatools-vfs-sync (and path (gptel-yatools--resolve-path path)))))

(defconst gptel-yatools-vfs--diff-banner-reserve 400
  "Characters reserved for `vfs_diff''s banner when it pages a diff.

The banner is prepended to the page, and the boundary's size limit counts
both.  Reserving room for it keeps the promise `gptel-yatools-page' makes
-- that the envelope cannot cut a page after the tool has said what it
showed -- so the number is the length of the longest banner plus slack,
not the length of a typical one.")

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
             (paging (gptel-yatools-page
                      diff-text
                      (gptel-yatools--coerce-integer offset 1 1)
                      (gptel-yatools--coerce-integer
                       lines (- gptel-yatools--output-line-limit 10) 1)
                      ;; Room for the banner below.  It is added to the
                      ;; page, so the envelope's size limit counts it: a
                      ;; page that used the whole budget left the banner
                      ;; to push the reply over the limit, and the
                      ;; truncation cut the last line the page had just
                      ;; claimed to show.
                      gptel-yatools-vfs--diff-banner-reserve))
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
