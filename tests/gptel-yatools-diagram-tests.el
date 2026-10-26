;;; gptel-yatools-diagram-tests.el --- Tests for diagrams in chat buffers  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Copyright (C) 2025  Vladislav Slobodenyuk

;; Author: Vladislav Slobodenyuk <toastergithubmail@gmail.com>
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The diagram module has one external dependency, PlantUML, and these
;; tests do not pretend otherwise: they are skipped when it is absent
;; rather than mocking the process away.  What remains testable without it
;; -- content addressing, the token scan, the transcript reader, the
;; overlay, the cheat sheet and every refusal -- is tested directly.
;;
;; Nothing here prompts, and everything writes only into a private cache
;; directory inside a throwaway temp directory.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'gptel-yatools)
(require 'gptel-yatools-diagram)
(unless (featurep 'gptel-yatools-test-lib)
  ;; Loaded by path, not by feature: a suite has to work from a checkout
  ;; without the tests directory being on `load-path'.
  (load (expand-file-name "gptel-yatools-test-lib.el"
                          (file-name-directory
                           (or load-file-name buffer-file-name)))
        nil 'nosuffix))

(defconst gptel-yatools-diagram-test--source
  "@startuml\nAlice -> Bob: hello\n@enduml"
  "A source that renders under every configuration.")

(defmacro gptel-yatools-diagram-test--cache (&rest body)
  "Run BODY with a private diagram cache directory."
  (declare (indent 0) (debug t))
  `(let ((gptel-yatools-diagram-cache-directory
          (expand-file-name "cache/"
                            (file-name-as-directory
                             (make-temp-file "gptel-diagram-" t))))
         (gptel-yatools-plantuml-command
          (or (executable-find "plantuml") gptel-yatools-plantuml-command)))
     (gptel-yatools-diagram--ensure-cache-directory)
     ,@body))

(defun gptel-yatools-diagram-test--plantuml-p ()
  "Return non-nil when PlantUML is installed."
  (and (executable-find gptel-yatools-plantuml-command) t))

(defun gptel-yatools-diagram-test--fake-run (files)
  "Stand in for PlantUML: a plausible SVG beside every file given.

The cache entry of a `.puml' is its own name with another extension, so
a stand-in can produce one without a JVM.  Tests that care about what
PlantUML says stub `--run' with this or with a failure of their own."
  (dolist (file files)
    (write-region "<svg width=\"10\" height=\"10\"/>" nil
                  (concat (file-name-sans-extension file) ".svg") nil 'silent))
  (list :status 'exited :exit 0 :output ""))

;;;; Content addressing

(ert-deftest gptel-yatools-diagram-test-token-is-a-prefix-of-the-cache-name ()
  "The token and the file name are two lengths of one digest."
  (let* ((source gptel-yatools-diagram-test--source)
         (token (gptel-yatools-diagram--token source))
         (hash (gptel-yatools-diagram--hash source)))
    (should (= (length token) gptel-yatools-diagram--token-length))
    (should (= (length hash) gptel-yatools-diagram--hash-length))
    (should (string-prefix-p token hash))
    (should (string-match-p "\\`[0-9a-f]+\\'" hash))))

(ert-deftest gptel-yatools-diagram-test-token-is-stable-and-content-dependent ()
  "The same source yields the same token; a changed byte yields another."
  (let ((a (gptel-yatools-diagram--token "A -> B"))
        (b (gptel-yatools-diagram--token "A -> B"))
        (c (gptel-yatools-diagram--token "A -> C")))
    (should (equal a b))
    (should-not (equal a c))))

(ert-deftest gptel-yatools-diagram-test-cache-name-follows-the-hash ()
  "A cache path is the digest plus the extension, under the cache directory."
  (gptel-yatools-diagram-test--cache
    (let* ((source "A -> B")
           (hash (gptel-yatools-diagram--hash source))
           (svg (gptel-yatools-diagram--svg-file source)))
      (should (equal svg (expand-file-name (concat hash ".svg")
                                           gptel-yatools-diagram-cache-directory)))
      (should (equal (file-name-extension
                      (gptel-yatools-diagram--source-file source))
                     "puml")))))

;;;; The tool boundary

(ert-deftest gptel-yatools-diagram-test-render-is-registered-in-its-own-category ()
  "A rendering tool, not a filesystem one, and it is not confirmed."
  (let ((tool (gptel-yatools-test--tool-spec "render_diagram")))
    (should (equal (gptel-tool-category tool) "diagram"))
    (should-not (gptel-tool-confirm tool))))

(ert-deftest gptel-yatools-diagram-test-empty-source-is-refused-without-running-plantuml ()
  "An empty source is caught before the executable is looked for."
  (gptel-yatools-diagram-test--cache
    (let ((gptel-yatools-plantuml-command "/nonexistent/plantuml"))
      (let ((reply (funcall (gptel-yatools-test--tool "render_diagram") "" nil)))
        (gptel-yatools-test--should-be-enveloped reply)
        (should (string-match-p "The source is empty" reply))
        (should-not (string-match-p "PlantUML is needed" reply))))))

(ert-deftest gptel-yatools-diagram-test-two-diagrams-are-refused ()
  "Two documents in one call are refused, and the count is named."
  (gptel-yatools-diagram-test--cache
    (let ((reply (funcall (gptel-yatools-test--tool "render_diagram")
                          "@startuml\nA -> B\n@enduml\n@startuml\nC -> D\n@enduml"
                          nil)))
      (gptel-yatools-test--should-be-enveloped reply)
      (should (string-match-p "contains 2 diagrams" reply))
      (should (string-match-p "One diagram per call" reply)))))

(ert-deftest gptel-yatools-diagram-test-a-missing-plantuml-is-named ()
  "Without PlantUML the model is told which setting to fix."
  (gptel-yatools-diagram-test--cache
    (let ((gptel-yatools-plantuml-command "/nonexistent/plantuml"))
      (let ((reply (funcall (gptel-yatools-test--tool "render_diagram")
                            gptel-yatools-diagram-test--source nil)))
        (gptel-yatools-test--should-be-enveloped reply)
        (should (string-match-p "not found" reply))
        (should (string-match-p "gptel-yatools-plantuml-command" reply))
        (should-not (string-match-p "Error: Error:" reply))
        ;; Nothing was left behind by the refusal.
        (should-not (file-exists-p
                     (gptel-yatools-diagram--svg-file
                      gptel-yatools-diagram-test--source)))))))

(ert-deftest gptel-yatools-diagram-test-help-returns-a-section-and-runs-nothing ()
  "The cheat sheet answers without PlantUML, and names the topics."
  (gptel-yatools-diagram-test--cache
    (let ((gptel-yatools-plantuml-command "/nonexistent/plantuml"))
      (let ((reply (funcall (gptel-yatools-test--tool "render_diagram")
                            nil "class")))
        (gptel-yatools-test--should-be-enveloped reply)
        (should (string-match-p "PlantUML class" reply))
        (should (string-match-p "\\*--" reply))
        (should (string-match-p "Nothing was rendered" reply)))
      (let ((reply (funcall (gptel-yatools-test--tool "render_diagram")
                            nil "nonsense")))
        (should (string-match-p "No cheat sheet for nonsense" reply))
        (should (string-match-p "sequence, class" reply)))
      (let ((reply (funcall (gptel-yatools-test--tool "render_diagram")
                            nil "")))
        (should (string-match-p "Ask again with one of" reply))))))

(ert-deftest gptel-yatools-diagram-test-every-topic-resolves ()
  "Each advertised topic has a section, and none of them is empty."
  (dolist (topic gptel-yatools-diagram--topics)
    (let ((text (gptel-yatools-diagram-cheatsheet-text topic)))
      (should (string-match-p (format "PlantUML %s" (regexp-quote topic)) text))
      (should (> (length text) 80)))))

(ert-deftest gptel-yatools-diagram-test-cheatsheet-is-a-variable-users-can-edit ()
  "The sheet is a defcustom string, so a user can correct it without a build."
  (should (custom-variable-p 'gptel-yatools-diagram-cheatsheet))
  (should (stringp (default-value 'gptel-yatools-diagram-cheatsheet))))

;;;; Rendering, when PlantUML is installed

(ert-deftest gptel-yatools-diagram-test-render-writes-svg-and-puml ()
  "A good source renders, and both cache entries are named by the digest."
  (skip-unless (gptel-yatools-diagram-test--plantuml-p))
  (gptel-yatools-diagram-test--cache
    (let* ((source gptel-yatools-diagram-test--source)
           (hash (gptel-yatools-diagram--hash source))
           (reply (funcall (gptel-yatools-test--tool "render_diagram")
                           source nil)))
      (gptel-yatools-test--should-be-enveloped reply)
      (should (string-match-p (format "\\[diagram:%s\\]"
                                      (gptel-yatools-diagram--token source))
                              reply))
      (should (file-exists-p (expand-file-name (concat hash ".svg")
                                               gptel-yatools-diagram-cache-directory)))
      (should (file-exists-p (expand-file-name (concat hash ".puml")
                                               gptel-yatools-diagram-cache-directory)))
      ;; The puml holds the exact source: that is the cache invariant.
      (should (equal (with-temp-buffer
                       (insert-file-contents
                        (expand-file-name (concat hash ".puml")
                                          gptel-yatools-diagram-cache-directory))
                       (buffer-string))
                     source))
      ;; The reply is factual: dimensions and a link line, no image.
      (should (string-match-p "To show it, write this on its own line" reply)))))

(ert-deftest gptel-yatools-diagram-test-second-render-reuses-the-cache ()
  "The same source twice starts no second PlantUML process."
  (skip-unless (gptel-yatools-diagram-test--plantuml-p))
  (gptel-yatools-diagram-test--cache
    (funcall (gptel-yatools-test--tool "render_diagram")
             gptel-yatools-diagram-test--source nil)
    (let ((calls 0))
      (cl-letf (((symbol-function 'gptel-yatools-diagram--run)
                 (lambda (files)
                   (setq calls (1+ calls))
                   (gptel-yatools-diagram-test--fake-run files))))
        (let ((reply (funcall (gptel-yatools-test--tool "render_diagram")
                              gptel-yatools-diagram-test--source nil)))
          (should (zerop calls))
          (should (string-match-p "\\[diagram:" reply)))))))

(ert-deftest gptel-yatools-diagram-test-syntax-error-returns-the-line-and-no-image ()
  "A broken source reports PlantUML's own line and leaves no picture."
  (skip-unless (gptel-yatools-diagram-test--plantuml-p))
  (gptel-yatools-diagram-test--cache
    (let* ((source "@startuml\nclass A {\n@enduml")
           (reply (funcall (gptel-yatools-test--tool "render_diagram")
                           source nil)))
      (gptel-yatools-test--should-be-enveloped reply)
      (should (string-match-p "could not render" reply))
      (should (string-match-p "line 2\\|Error line" reply))
      ;; No error image, and the source stays behind for the retry.
      (should-not (file-exists-p (gptel-yatools-diagram--svg-file source)))
      (should (file-exists-p (gptel-yatools-diagram--source-file source)))
      ;; The hint is attached, and no cache path leaks into the reply.
      (should (string-match-p "unclosed brace" reply))
      (should-not (string-match-p (regexp-quote
                                   gptel-yatools-diagram-cache-directory)
                                  reply)))))

(ert-deftest gptel-yatools-diagram-test-local-include-is-refused-with-a-way-out ()
  "The default profile refuses a local include, and the hint names the setting."
  (skip-unless (gptel-yatools-diagram-test--plantuml-p))
  (gptel-yatools-diagram-test--cache
    (let ((reply (funcall (gptel-yatools-test--tool "render_diagram")
                          "@startuml\n!include ./nope.puml\nA -> B\n@enduml"
                          nil)))
      (should (string-match-p "security profile" reply))
      (should (string-match-p "gptel-yatools-plantuml-security-profile" reply)))))

;;;; Rebuilding from the transcript

(ert-deftest gptel-yatools-diagram-test-transcript-source-is-recovered ()
  "gptel's printed tool call is enough to recover the exact source."
  (with-temp-buffer
    (insert "Some answer.\n\n"
            (prin1-to-string (list :name "render_diagram"
                                   :args (list :source
                                               gptel-yatools-diagram-test--source)))
            "\n\nMore text.\n")
    (let ((sources (gptel-yatools-diagram--sources-in-buffer)))
      (should (equal sources (list gptel-yatools-diagram-test--source))))))

(ert-deftest gptel-yatools-diagram-test-transcript-source-survives-org-escaping ()
  "An Org tool block escapes the call; the source still comes back whole."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_tool (render_diagram \"@startuml\\n*not a heading*\\n@enduml\")\n"
            (org-escape-code-in-string
             (prin1-to-string
              (list :name "render_diagram"
                    :args (list :source "@startuml\n*not a heading*\n@enduml"))))
            "\n#+end_tool\n")
    (let ((sources (gptel-yatools-diagram--sources-in-buffer)))
      (should (equal sources (list "@startuml\n*not a heading*\n@enduml"))))))

(ert-deftest gptel-yatools-diagram-test-a-token-points-at-a-cache-file ()
  "A token resolves to the file the digest names, and no other."
  (gptel-yatools-diagram-test--cache
    (let* ((source gptel-yatools-diagram-test--source)
           (found (progn
                    (gptel-yatools-diagram--write-source source)
                    (write-region "<svg/>" nil
                                  (gptel-yatools-diagram--svg-file source)
                                  nil 'silent)
                    (gptel-yatools-diagram--resolve-token
                     (gptel-yatools-diagram--token source)))))
      (should (eq (plist-get found :kind) 'found))
      (should (equal (plist-get found :file)
                     (gptel-yatools-diagram--svg-file source))))))

(ert-deftest gptel-yatools-diagram-test-a-token-that-names-nothing-is-missing ()
  "No file is an answer, not a signal."
  (gptel-yatools-diagram-test--cache
    (let ((found (gptel-yatools-diagram--resolve-token "abcdef")))
      (should (eq (plist-get found :kind) 'missing))
      (should-not (plist-get found :file)))))

(ert-deftest gptel-yatools-diagram-test-two-files-under-one-token-are-ambiguous ()
  "A collision is surfaced and never resolved by picking one.

Two files are forged rather than found, because a six-digit collision is
not something a test can render on demand -- and the point is what the
resolver does with two matches, not how they came to exist."
  (gptel-yatools-diagram-test--cache
    (write-region "<svg/>" nil
                  (expand-file-name "abcdef01.svg"
                                    gptel-yatools-diagram-cache-directory)
                  nil 'silent)
    (write-region "<svg/>" nil
                  (expand-file-name "abcdef02.svg"
                                    gptel-yatools-diagram-cache-directory)
                  nil 'silent)
    (let ((found (gptel-yatools-diagram--resolve-token "abcdef")))
      (should (eq (plist-get found :kind) 'ambiguous))
      (should (= 2 (length (plist-get found :files))))
      (should-not (plist-get found :file)))
    ;; Drawing stays quiet about it: a mention is not an error, and this
    ;; runs once per response.  The open command is where the user asks.
    (with-temp-buffer
      (insert "[diagram:abcdef]\n")
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
                ((symbol-function 'create-image)
                 (lambda (&rest _) '(image :type svg))))
        (should (zerop (gptel-yatools-diagram--refresh)))
        (should-not gptel-yatools-diagram--overlays))
      (goto-char (point-min))
      (let ((err (should-error (gptel-yatools-diagram-open-at-point)
                               :type 'user-error)))
        (should (string-match-p "ambiguous" (error-message-string err)))))))

(ert-deftest gptel-yatools-diagram-test-rebuild-renders-only-what-is-missing ()
  "One batch call for the missing entries, and nothing for the present ones."
  (gptel-yatools-diagram-test--cache
    (let* ((present "@startuml\nA -> B\n@enduml")
           (absent "@startuml\nC -> D\n@enduml")
           (rendered nil))
      (gptel-yatools-diagram--write-source present)
      (write-region "<svg/>" nil (gptel-yatools-diagram--svg-file present)
                    nil 'silent)
      (gptel-yatools-diagram--write-source absent)
      (with-temp-buffer
        (insert (prin1-to-string
                 (list :name "render_diagram" :args (list :source present)))
                "\n"
                (prin1-to-string
                 (list :name "render_diagram" :args (list :source absent)))
                "\n")
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
                  ((symbol-function 'gptel-yatools-diagram--run)
                   (lambda (files)
                     (setq rendered files)
                     (gptel-yatools-diagram-test--fake-run files))))
          (gptel-yatools-diagram--rebuild-missing)))
      (should (= 1 (length rendered)))
      (should (equal rendered (list (gptel-yatools-diagram--source-file absent)))))))

(ert-deftest gptel-yatools-diagram-test-rebuild-says-when-it-could-not ()
  "A rebuild that fails is one sentence, not silence.

The old batch path dropped the process status on the floor, so a failed
rebuild looked exactly like a successful one: everything in the buffer
stayed a six-character token and nothing said why."
  (gptel-yatools-diagram-test--cache
    (let* ((source "@startuml\nC -> D\n@enduml")
           (messages nil))
      (gptel-yatools-diagram--write-source source)
      (with-temp-buffer
        (insert (prin1-to-string
                 (list :name "render_diagram" :args (list :source source))))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
                  ((symbol-function 'gptel-yatools-diagram--run)
                   (lambda (_files)
                     (list :status 'exited :exit 1
                           :output "Error line 2: nope")))
                  ((symbol-function 'message)
                   (lambda (format &rest args)
                     (push (apply #'format format args) messages))))
          (gptel-yatools-diagram--rebuild-missing)))
      (let ((said (car (seq-filter (lambda (m) (string-match-p "rebuilt" m))
                                   messages))))
        (should said)
        (should (string-match-p "1 of 1" said))
        (should (string-match-p "nope" said))))))

(ert-deftest gptel-yatools-diagram-test-ensure-returns-one-entry ()
  "The cache-hit rule, the render and the description answer together."
  (gptel-yatools-diagram-test--cache
    (let* ((source gptel-yatools-diagram-test--source)
           (calls 0)
           (entry nil))
      (cl-letf (((symbol-function 'gptel-yatools-diagram--run)
                 (lambda (files)
                   (setq calls (1+ calls))
                   (gptel-yatools-diagram-test--fake-run files))))
        (setq entry (gptel-yatools-diagram--ensure source))
        (should (= 1 calls))
        (should (equal (plist-get entry :token)
                       (gptel-yatools-diagram--token source)))
        (should (equal (plist-get entry :svg)
                       (gptel-yatools-diagram--svg-file source)))
        (should (string-match-p "10x10 px" (plist-get entry :description)))
        ;; The second ask is answered by the file that exists.
        (gptel-yatools-diagram--ensure source)
        (should (= 1 calls))))))

(ert-deftest gptel-yatools-diagram-test-insert-renders-before-it-inserts ()
  "A source that will not render leaves no dead token behind."
  (gptel-yatools-diagram-test--cache
    (with-temp-buffer
      (cl-letf (((symbol-function 'gptel-yatools-diagram--run)
                 (lambda (_files)
                   (list :status 'exited :exit 1 :output "boom"))))
        (should-error (gptel-yatools-diagram-insert
                       gptel-yatools-diagram-test--source))
        (should (string-empty-p (buffer-string)))
        ;; And a source that renders inserts exactly one token.
        (cl-letf (((symbol-function 'gptel-yatools-diagram--run)
                   #'gptel-yatools-diagram-test--fake-run))
          (gptel-yatools-diagram-insert gptel-yatools-diagram-test--source)
          (should (equal (buffer-string)
                         (format "[diagram:%s]"
                                 (gptel-yatools-diagram--token
                                  gptel-yatools-diagram-test--source)))))))))

(ert-deftest gptel-yatools-diagram-test-rebuild-does-nothing-without-images ()
  "On a terminal the rebuild is skipped, so no JVM starts for nothing."
  (gptel-yatools-diagram-test--cache
    (gptel-yatools-diagram--write-source gptel-yatools-diagram-test--source)
    (with-temp-buffer
      (insert (prin1-to-string
               (list :name "render_diagram"
                     :args (list :source gptel-yatools-diagram-test--source))))
      (let ((ran nil))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil))
                  ((symbol-function 'gptel-yatools-diagram--run)
                   (lambda (&rest _) (setq ran t) (cons 0 ""))))
          (gptel-yatools-diagram--rebuild-missing))
        (should-not ran)))))

;;;; The overlay

(ert-deftest gptel-yatools-diagram-test-overlay-is-drawn-and-is-idempotent ()
  "A token with a cache file gets one overlay, however often we redraw."
  (gptel-yatools-diagram-test--cache
    (let* ((source gptel-yatools-diagram-test--source)
           (token (gptel-yatools-diagram--token source)))
      (write-region "<svg/>" nil (gptel-yatools-diagram--svg-file source)
                    nil 'silent)
      (with-temp-buffer
        (insert (format "Here:\n\n[diagram:%s]\n\nand more.\n" token))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) '(image :type svg))))
          (gptel-yatools-diagram--refresh)
          (should (= 1 (length gptel-yatools-diagram--overlays)))
          (let ((overlay (car gptel-yatools-diagram--overlays)))
            (should (equal (overlay-get overlay 'gptel-yatools-diagram) token))
            (should (overlay-get overlay 'display))
            (should (overlay-get overlay 'evaporate))
            (should (equal (overlay-get overlay 'help-echo)
                           (gptel-yatools-diagram--svg-file source))))
          (gptel-yatools-diagram--refresh)
          (should (= 1 (length gptel-yatools-diagram--overlays)))
          ;; The text is never replaced, so a terminal still has the token.
          (should (string-match-p (format "\\[diagram:%s\\]" token)
                                  (buffer-string))))))))

(ert-deftest gptel-yatools-diagram-test-overlay-needs-an-image-capable-frame ()
  "With no image support nothing is drawn and the text is untouched."
  (gptel-yatools-diagram-test--cache
    (let* ((source gptel-yatools-diagram-test--source)
           (token (gptel-yatools-diagram--token source)))
      (write-region "<svg/>" nil (gptel-yatools-diagram--svg-file source)
                    nil 'silent)
      (with-temp-buffer
        (insert (format "[diagram:%s]\n" token))
        (let ((before (buffer-string)))
          (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) nil)))
            (gptel-yatools-diagram--refresh))
          (should-not gptel-yatools-diagram--overlays)
          (should (equal before (buffer-string))))))))

(ert-deftest gptel-yatools-diagram-test-overlay-is-not-drawn-for-a-dead-token ()
  "A token whose file is absent stays as text; a mention is not an error."
  (gptel-yatools-diagram-test--cache
    (with-temp-buffer
      (insert "[diagram:abcdef]\n")
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'image-type-available-p) (lambda (&rest _) t)))
        (gptel-yatools-diagram--refresh))
      (should-not gptel-yatools-diagram--overlays))))

(ert-deftest gptel-yatools-diagram-test-toggling-off-removes-the-overlays ()
  "The switch is the user's way out, and it leaves the text alone."
  (gptel-yatools-diagram-test--cache
    (let* ((source gptel-yatools-diagram-test--source)
           (token (gptel-yatools-diagram--token source)))
      (write-region "<svg/>" nil (gptel-yatools-diagram--svg-file source)
                    nil 'silent)
      (with-temp-buffer
        (insert (format "[diagram:%s]\n" token))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) '(image :type svg))))
          (gptel-yatools-diagram--refresh)
          (should (= 1 (length gptel-yatools-diagram--overlays)))
          (gptel-yatools-diagram-toggle-inline -1)
          (should-not gptel-yatools-diagram--overlays)
          (should (string-match-p (format "\\[diagram:%s\\]" token)
                                  (buffer-string))))))))

(ert-deftest gptel-yatools-diagram-test-open-at-point-names-a-dead-token ()
  "Resolving a token that has no file is a refusal, not a wrong file."
  (gptel-yatools-diagram-test--cache
    (with-temp-buffer
      (insert "[diagram:abcdef]\n")
      (goto-char (point-min))
      (should-error (gptel-yatools-diagram-open-at-point) :type 'user-error))))

(ert-deftest gptel-yatools-diagram-test-an-evaporated-overlay-does-not-stop-the-next-draw ()
  "A token whose text was deleted must not break every later redraw.

The overlay evaporates with its text, and a deleted overlay reports nil
bounds.  Comparing those with the region signalled
`wrong-type-argument number-or-marker-p nil' from inside the response
hook, so after the first edited turn no diagram in that buffer was drawn
again -- the failure this pins."
  (gptel-yatools-diagram-test--cache
    (let* ((source gptel-yatools-diagram-test--source)
           (token (gptel-yatools-diagram--token source)))
      (write-region "<svg/>" nil (gptel-yatools-diagram--svg-file source)
                    nil 'silent)
      (with-temp-buffer
        (insert (format "[diagram:%s]\n" token))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) '(image :type svg))))
          (gptel-yatools-diagram--refresh)
          (should (= 1 (length gptel-yatools-diagram--overlays)))
          ;; The user edits the turn away: the overlay evaporates, and the
          ;; list keeps a dead one.
          (erase-buffer)
          (insert (format "rewritten [diagram:%s]\n" token))
          (should-not (overlay-start (car gptel-yatools-diagram--overlays)))
          ;; A later response draws again, and without signalling.
          (should (= 1 (gptel-yatools-diagram--refresh (point-min)
                                                       (point-max))))
          (should (= 1 (length gptel-yatools-diagram--overlays)))
          (should (overlay-start (car gptel-yatools-diagram--overlays))))))))

(ert-deftest gptel-yatools-diagram-test-post-response-survives-a-missing-region ()
  "A response with no markers of its own draws the whole buffer."
  (gptel-yatools-diagram-test--cache
    (let* ((source gptel-yatools-diagram-test--source)
           (token (gptel-yatools-diagram--token source)))
      (write-region "<svg/>" nil (gptel-yatools-diagram--svg-file source)
                    nil 'silent)
      (with-temp-buffer
        (insert (format "[diagram:%s]\n" token))
        (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                  ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) '(image :type svg))))
          ;; gptel passes marker positions, but a tool-result round leaves
          ;; them nil, and nil used to reach `narrow-to-region'.
          (gptel-yatools-diagram--post-response nil nil)
          (should (= 1 (length gptel-yatools-diagram--overlays)))
          ;; Out-of-range positions are clamped rather than signalled.
          (gptel-yatools-diagram--post-response 1 100000)
          (should (= 1 (length gptel-yatools-diagram--overlays))))))))

;;;; Nothing goes through the VFS

(ert-deftest gptel-yatools-diagram-test-render-leaves-no-pending-change ()
  "The diagram module writes outside the VFS, deliberately (ADR 0003)."
  (skip-unless (gptel-yatools-diagram-test--plantuml-p))
  (gptel-yatools-test--in-dir
    (gptel-yatools-test--vfs
      (gptel-yatools-diagram-test--cache
        (funcall (gptel-yatools-test--tool "render_diagram")
                 gptel-yatools-diagram-test--source nil)
        (should-not (gptel-yatools-vfs-pending-paths))))))

;;; gptel-yatools-diagram-tests.el ends here
