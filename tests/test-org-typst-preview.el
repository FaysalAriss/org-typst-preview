;;; test-org-typst-preview.el --- batch tests for org-typst-preview.el -*- lexical-binding: t; -*-

(require 'cl-lib)
;; isolate the image cache in a throwaway directory
(setq user-emacs-directory (file-name-as-directory (make-temp-file "org-typst-preview-test" t)))
(load (expand-file-name "../org-typst-preview.el" (file-name-directory load-file-name)))
(require 'org)

(defvar test-failures 0)
(defun check (name got expected)
  (if (equal got expected)
      (message "PASS  %s" name)
    (setq test-failures (1+ test-failures))
    (message "FAIL  %s\n  got:      %S\n  expected: %S" name got expected)))

;; --- 1. fragment scanning -------------------------------------------------
(with-temp-buffer
  (org-mode)
  (insert "Pythagoras says $x^2 + y^2 = z^2$ in every triangle.\n"
          "I paid $5, then some more later.\n"
          "Escaped: \\$not math\\$ stays text.\n"
          "Display: $$sum_(k=1)^n k = (n(n+1))/2$$ done.\n"
          "Two on a line: $alpha$ and $beta/2$.\n"
          "#+begin_src python\nx = \"$never$\"\n#+end_src\n"
          "Edge: $$x$$ and $y$\n")
  (let ((frags (org-typst-preview--fragments)))
    (check "fragment math strings"
           (mapcar (lambda (f) (nth 3 f)) frags)
           '("x^2 + y^2 = z^2"
             "sum_(k=1)^n k = (n(n+1))/2"
             "alpha" "beta/2"
             "x" "y"))
    (check "display flags"
           (mapcar (lambda (f) (nth 2 f)) frags)
           '(nil t nil nil t nil))
    ;; positions line up with the actual text
    (check "fragment text round-trip"
           (mapcar (lambda (f)
                     (buffer-substring-no-properties (nth 0 f) (nth 1 f)))
                   frags)
           '("$x^2 + y^2 = z^2$"
             "$$sum_(k=1)^n k = (n(n+1))/2$$"
             "$alpha$" "$beta/2$"
             "$$x$$" "$y$"))))

;; --- 1b. multi-line display math ------------------------------------------
(with-temp-buffer
  (org-mode)
  (insert "Aligned block:\n"
          "$$\n  a = b + c \\\n    = d\n$$\n"
          "and inline $x^2$ stays put.\n"
          "Not math across lines: cost was $5\nand later $10 total.\n")
  (let ((frags (org-typst-preview--fragments)))
    ;; the multi-line $$...$$ is one fragment; the cross-line $...$ money
    ;; pair is rejected because inline math must stay on a single line
    (check "multi-line display math strings"
           (mapcar (lambda (f) (nth 3 f)) frags)
           '("\n  a = b + c \\\n    = d\n" "x^2"))
    (check "multi-line display flags"
           (mapcar (lambda (f) (nth 2 f)) frags)
           '(t nil))
    (check "multi-line fragment round-trip"
           (mapcar (lambda (f)
                     (buffer-substring-no-properties (nth 0 f) (nth 1 f)))
                   frags)
           '("$$\n  a = b + c \\\n    = d\n$$" "$x^2$"))))

;; --- 2. typst source generation -------------------------------------------
(check "inline source"
       (org-typst-preview--source "x^2" nil 12 "#ffffff")
       (concat "#set page(width: auto, height: auto, margin: 1.5pt, fill: none)\n"
               "#set text(size: 12pt, fill: rgb(\"#ffffff\"), top-edge: \"bounds\", bottom-edge: \"bounds\")\n"
               "$x^2$\n#pagebreak()\n#set text(bottom-edge: \"baseline\")\n$x^2$"))
(check "display source uses spaced dollars"
       (string-suffix-p "$ x^2 $"
                        (org-typst-preview--source "x^2" t 12 "#ffffff"))
       t)
(check "wrapped source fixes the page width"
       (string-prefix-p "#set page(width: 250pt,"
                        (org-typst-preview--source "x^2" nil 12 "#ffffff" 250))
       t)
(check "wrapped display source uses inline display() so it can break"
       (string-suffix-p "$display(x^2)$"
                        (org-typst-preview--source "x^2" t 12 "#ffffff" 250))
       t)

;; --- 3. real compilation through the async path ---------------------------
(make-directory org-typst-preview-cache-dir t)
(let* ((results nil)
       (cases `(("good-inline"  ,(org-typst-preview--source
                                  "integral_0^1 x^2 dif x = 1/3" nil 11.25 "#bbc2cf"))
                ("good-display" ,(org-typst-preview--source
                                  "sum_(k=1)^n k = (n(n+1))/2" t 11.25 "#bbc2cf"))
                ("bad-syntax"   ,(org-typst-preview--source
                                  "x^{unclosed" nil 11.25 "#bbc2cf")))))
  (dolist (c cases)
    (let* ((name (car c))
           (source (cadr c))
           (file (expand-file-name (concat (sha1 source) "-1.svg")
                                   org-typst-preview-cache-dir)))
      (org-typst-preview--compile-async
       source 'svg file
       (lambda (ok) (push (cons name ok) results)))))
  (let ((deadline (+ (float-time) 30)))
    (while (and (< (length results) 3) (< (float-time) deadline))
      (accept-process-output nil 0.1)))
  (check "compile results"
         (sort (mapcar (lambda (r) (format "%s=%s" (car r) (cdr r))) results)
               #'string<)
         '("bad-syntax=nil" "good-display=t" "good-inline=t"))
  ;; the good SVGs exist and contain drawing paths (2 pages per compile:
  ;; the displayed image and the baseline-measurement page)
  (let ((svgs (directory-files org-typst-preview-cache-dir t "\\.svg\\'")))
    (check "svg count" (length svgs) 4)
    (check "svgs non-trivial"
           (cl-every (lambda (f)
                       (with-temp-buffer
                         (insert-file-contents f)
                         (and (> (buffer-size) 500)
                              (search-forward "<svg" nil t))))
                     svgs)
           t)
    ;; no leftover .typ files after compilation
    (check "typ files cleaned up"
           (directory-files org-typst-preview-cache-dir nil "\\.typ\\'")
           nil))
  ;; error was logged for the bad fragment, with the message extracted
  (check "error logged"
         (and (get-buffer "*org-typst-preview-errors*")
              (with-current-buffer "*org-typst-preview-errors*"
                (> (buffer-size) 0)))
         t)
  (check "error message parsed for inline display"
         (let ((msg (cdr (gethash (expand-file-name
                                   (concat (sha1 (cadr (nth 2 cases))) "-1.svg")
                                   org-typst-preview-cache-dir)
                                  org-typst-preview--failed))))
           (and (stringp msg) (string-prefix-p "error:" msg) t))
         t))

;; --- 3b. the hardcoded math ink ratio still matches this typst ------------
(let* ((source (org-typst-preview--source "x" nil 100 "#000000"))
       (file (expand-file-name (concat (sha1 source) "-1.svg")
                               org-typst-preview-cache-dir))
       (done nil))
  (org-typst-preview--compile-async source 'svg file (lambda (_) (setq done t)))
  (let ((deadline (+ (float-time) 15)))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.1)))
  (check "math x ink ratio close to the calibration constant"
         (let ((dims (org-typst-preview--image-dims file)))
           ;; ink height = page height minus 2 x 1.5pt margins, at 100pt
           (and dims
                (< (abs (- (/ (- (cdr dims) 3.0) 100)
                           org-typst-preview--math-x-ratio))
                   0.02)))
         t))

;; --- 4. cursor-position logic used by the scanner --------------------------
(with-temp-buffer
  (org-mode)
  (insert "before $x^2$ after")
  ;; the scan skips a fragment when point is within [start, end]
  (let* ((frag (car (org-typst-preview--fragments)))
         (start (nth 0 frag)) (end (nth 1 frag)))
    (goto-char (1+ start))
    (check "point inside -> skipped"
           (and (<= start (point)) (<= (point) end)) t)
    (goto-char (1+ end))
    (check "point after -> rendered"
           (and (<= start (point)) (<= (point) end)) nil)))

(if (> test-failures 0)
    (kill-emacs 1)
  (message "\nAll tests passed."))
;;; test-org-typst-preview.el ends here
