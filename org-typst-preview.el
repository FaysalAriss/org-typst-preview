;;; org-typst-preview.el --- Live inline Typst math previews in Org buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faysal Ariss

;; Author: Faysal Ariss <faysal.ariss@gmail.com>
;; Version: 0.8.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: outlines, tex, wp
;; URL: https://github.com/faysalariss/org-typst-preview

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Obsidian-style live math previews for Org mode, with Typst as the math
;; language instead of LaTeX:
;;
;;     $x^2 + y^2 = z^2$                  inline math (one line)
;;     $$sum_(k=1)^n k = (n(n+1))/2$$     display-style math (may span lines)
;;
;; A fragment turns into a rendered image the moment the cursor is no
;; longer inside the dollar signs, and turns back into editable text when
;; the cursor moves onto it (click it or arrow into it).
;;
;; Setup: install the `typst' CLI (https://typst.app), put this file on
;; your `load-path', then:
;;
;;     (require 'org-typst-preview)
;;     (add-hook 'org-mode-hook #'org-typst-preview-mode)
;;
;; How it works: after you stop typing for a moment, the buffer is
;; scanned for $...$ fragments; each new one is handed to the typst CLI
;; asynchronously (Emacs never blocks) and the text is covered with an
;; overlay showing the resulting image.  Images are cached on disk keyed
;; by content, colour and font size, so each distinct fragment compiles
;; exactly once, ever.  A fragment with a Typst syntax error stays as
;; plain text with a red wavy underline; the compiler's message lands in
;; the *org-typst-preview-errors* buffer.  Math wider than the window is
;; re-laid-out by Typst at the window width so it flows onto multiple
;; lines at a constant font size, like text.
;;
;; Money is safe ("I paid $5 for coffee" renders nothing); if two dollar
;; signs on one line pair up when you didn't want math, escape one as \$.
;; Images follow your theme's foreground colour and font size, with a
;; transparent background.  Tune `org-typst-preview-scale' if the math
;; looks too small or large next to your text.

;;; Code:

(require 'org-element)

(declare-function org-element-type "org-element-ast")
(defvar org-typst-preview-mode)         ; defined by define-minor-mode below

(defgroup org-typst-preview nil
  "Live inline Typst math previews for Org mode."
  :group 'org
  :prefix "org-typst-preview-")

(defcustom org-typst-preview-program "typst"
  "Name or full path of the typst executable."
  :type 'string)

(defcustom org-typst-preview-scale 1.0
  "Extra scaling applied to rendered math images.
Nudge this up or down if the math looks too small or too large
next to your text."
  :type 'number)

(defcustom org-typst-preview-delay 0.25
  "Idle seconds before the buffer is re-scanned for math to render."
  :type 'number)

(defcustom org-typst-preview-cache-dir
  (expand-file-name "org-typst-preview-cache" user-emacs-directory)
  "Directory holding compiled math images.  Safe to delete at any time."
  :type 'directory)

(defcustom org-typst-preview-overflow-style 'wrap
  "How to handle math wider than the window.

`wrap'     Typst re-lays the math out at the window width so it flows
           onto multiple lines at a constant font size, like text in
           Obsidian.  Math with no legal break point shows as plain
           text while it cannot fit.

`scale'    Shrink the image to fit the window (the font appears
           smaller when space is tight)."
  :type '(choice (const :tag "Re-wrap at window width, like text" wrap)
                 (const :tag "Scale down to fit" scale)))

;; A math fragment's content has a non-space character at each end -- the
;; same rule Org and Obsidian use, so "I paid $5, then some more" is not
;; mistaken for math.  Two patterns keep the two delimiters honest:
;; display `$$...$$' may span several lines and open on its own line (the
;; leading/trailing `[:space:]*'), while inline `$...$' stays on a single
;; line and hugs no whitespace, so text and prices never pair up across
;; lines.  Neither content may contain a `$'.  Two prices on one line
;; ("$10 ... 100$") CAN still pair up, exactly as in Obsidian; write \$
;; to escape a literal dollar sign.
(defconst org-typst-preview--display-regexp
  "\\$\\$\\([[:space:]]*[^$[:space:]]\\(?:[^$]*[^$[:space:]]\\)?[[:space:]]*\\)\\$\\$"
  "Matches $$...$$ display math, whose content may span several lines.")

(defconst org-typst-preview--inline-regexp
  "\\$\\([^$[:space:]]\\(?:[^$\n]*[^$[:space:]]\\)?\\)\\$"
  "Matches single-line $...$ inline math.")

(defvar org-typst-preview--inflight (make-hash-table :test #'equal)
  "Image files currently being compiled, to avoid duplicate typst runs.")

(defface org-typst-preview-error
  '((t :underline (:style wave :color "Red1")))
  "Face for math fragments that Typst failed to compile.")

(defface org-typst-preview-error-message
  '((t :inherit error))
  "Face for the inline error message shown after broken math.")

(defvar org-typst-preview--failed (make-hash-table :test #'equal)
  "Images that could not be produced, so they are not retried in a loop.
The value is `error' for a Typst compile failure (the fragment gets a
red underline) or `no-reflow' for wrapped math that Typst could not
break (the scaled-down original stays).  Editing the fragment gives it
a new hash, which retries automatically.")

(defvar-local org-typst-preview--timer nil)

(defun org-typst-preview--image-format ()
  "Image format to render: SVG when Emacs can show it, else PNG."
  (if (image-type-available-p 'svg) 'svg 'png))

(defconst org-typst-preview--math-x-ratio 0.453
  "Ink height of a lowercase math letter per pt of Typst text size.
Measured: `$x$' at 100pt has 45.3pt of glyph ink with Typst's default
math font (New Computer Modern Math).  A unit test recompiles this so
a Typst upgrade that changes the default font is caught.")

(defvar org-typst-preview--font-pt-cache nil
  "Cons (FONT-NAME . SIZE-PT) memoizing the font calibration.")

(defun org-typst-preview--font-pt ()
  "Typst text size (pt) whose glyphs optically match the buffer font.
Chosen so a lowercase letter has the same ink height in both fonts
\(x-height matching, the idea behind CSS font-size-adjust): the buffer
font's `x' ink height in pixels divided by Typst's per-pt math ink.
SVG pt render 1:1 with logical pixels (measured), so px and pt align.
Falls back to matching the em when glyph metrics are unavailable."
  (let ((sig (ignore-errors (face-font 'default))))
    (if (and sig (equal sig (car org-typst-preview--font-pt-cache)))
        (cdr org-typst-preview--font-pt-cache)
      (let* ((ink (ignore-errors
                    (let* ((font (font-at 0 nil "x"))
                           (g (and font (font-get-glyphs font 0 1 "x"))))
                      (and g (> (length g) 0)
                           ;; glyph vector: ...[7]=ascent [8]=descent
                           (+ (aref (aref g 0) 7) (aref (aref g 0) 8))))))
             (size (if (and (numberp ink) (> ink 0))
                       (/ ink org-typst-preview--math-x-ratio)
                     (or (ignore-errors
                           (let ((px (aref (font-info (face-font 'default)) 2)))
                             (and (numberp px) (> px 0) px)))
                         (let ((h (face-attribute 'default :height)))
                           (if (integerp h) (/ h 10.0) 12))))))
        (when sig
          (setq org-typst-preview--font-pt-cache (cons sig size)))
        size))))

(defun org-typst-preview--color-hex ()
  "Buffer foreground colour as a #rrggbb string (follows your theme)."
  (let* ((fg (face-attribute 'default :foreground nil t))
         (vals (and (stringp fg) (color-values fg))))
    (if vals
        (format "#%02x%02x%02x"
                (ash (nth 0 vals) -8) (ash (nth 1 vals) -8) (ash (nth 2 vals) -8))
      "#000000")))

(defun org-typst-preview--source (math displayp size-pt color &optional wrap-w)
  "Build the Typst document that renders MATH at SIZE-PT in COLOR.
When DISPLAYP is non-nil, use display-style math.  When WRAP-W is
non-nil, fix the page width to WRAP-W pt so Typst line-wraps long
inline math instead of producing one wide line.

The document has TWO pages: page 1 is the image shown in the buffer;
page 2 renders the same math with the text box ending at the baseline
instead of the ink bounds, so its height reveals where the baseline
sits -- used to align the image with the surrounding text's baseline
\(the same idea as dvipng's depth output in org-latex-preview)."
  ;; fill: none = transparent background, so it sits on the theme's bg.
  ;; top/bottom-edge "bounds" makes the auto-sized page measure the real
  ;; ink extents; the default (cap-height..baseline) crops descenders
  ;; like the tail of y and anything raised above cap height (exponents).
  ;; Wrapped display math becomes inline-mode `$display(...)$': block
  ;; equations never line-break (they just clip at the page edge), but
  ;; inline-mode math flows across lines while display(...) keeps the
  ;; large operator glyphs, so the font size stays constant.
  (let ((body (cond ((and displayp wrap-w) (format "$display(%s)$" math))
                    (displayp (format "$ %s $" math))
                    (t (format "$%s$" math)))))
    (concat (if wrap-w
                (format "#set page(width: %dpt, height: auto, margin: 1.5pt, fill: none)\n"
                        wrap-w)
              "#set page(width: auto, height: auto, margin: 1.5pt, fill: none)\n")
            (format "#set text(size: %spt, fill: rgb(\"%s\"), top-edge: \"bounds\", bottom-edge: \"bounds\")\n"
                    size-pt color)
            body
            "\n#pagebreak()\n#set text(bottom-edge: \"baseline\")\n"
            body)))

(defun org-typst-preview--target (math displayp size color wrap-w)
  "Return (SOURCE HASH IMG-FILE) for rendering MATH.
DISPLAYP, SIZE, COLOR and WRAP-W as in `org-typst-preview--source'."
  (let* ((source (org-typst-preview--source math displayp size color wrap-w))
         (hash (sha1 source)))
    ;; -1 = the displayed image (page 1); its sibling -2 holds the
    ;; baseline-measurement page, see `org-typst-preview--source'.
    (list source hash
          (expand-file-name
           (format "%s-1.%s" hash (org-typst-preview--image-format))
           org-typst-preview-cache-dir))))

(defun org-typst-preview--ascent (img-file)
  "Baseline ascent percentage for IMG-FILE, or nil to center instead.
Compares the full-ink height (page 1) with the height down to the
baseline (page 2); the ratio tells Emacs what fraction of the image
belongs above the text baseline.  The 3pt of page margins cancel out."
  (when (string-suffix-p "-1.svg" img-file)
    (let* ((d1 (org-typst-preview--image-dims img-file))
           (d2 (org-typst-preview--image-dims
                (concat (substring img-file 0 -6) "-2.svg"))))
      (when (and d1 d2 (> (cdr d1) 3.0))
        (min 100 (max 10 (round (* 100 (/ (- (cdr d2) 3.0)
                                          (- (cdr d1) 3.0))))))))))

(defvar org-typst-preview--dims-cache (make-hash-table :test #'equal)
  "Maps SVG file names to their (WIDTH . HEIGHT) in pt.")

(defun org-typst-preview--image-dims (img-file)
  "Natural (WIDTH . HEIGHT) of the SVG in IMG-FILE in pt, or nil."
  (or (gethash img-file org-typst-preview--dims-cache)
      (and (string-suffix-p ".svg" img-file)
           (file-exists-p img-file)
           (with-temp-buffer
             (insert-file-contents img-file nil 0 400)
             (goto-char (point-min))
             (when (re-search-forward
                    "viewBox=\"0 0 \\([0-9.]+\\) \\([0-9.]+\\)\"" nil t)
               (puthash img-file
                        (cons (string-to-number (match-string 1))
                              (string-to-number (match-string 2)))
                        org-typst-preview--dims-cache))))))

(defun org-typst-preview--protected-p (pos)
  "Non-nil if POS is somewhere math should not render (code blocks etc.)."
  (and (derived-mode-p 'org-mode)
       (save-excursion
         (goto-char pos)
         (memq (org-element-type (org-element-at-point))
               '(src-block example-block export-block comment-block
                 comment keyword fixed-width latex-environment)))))

(defun org-typst-preview--in-region-p (start end regions)
  "Non-nil if START..END overlaps any (BEG . FIN) cons in REGIONS."
  (catch 'hit
    (dolist (r regions)
      (when (and (< start (cdr r)) (> end (car r)))
        (throw 'hit t)))))

(defun org-typst-preview--fragments ()
  "Return a list of (START END DISPLAYP MATH) for fragments in the buffer.
Inline `$...$' math stays on one line and hugs no whitespace; display
`$$...$$' math may span several lines and open on its own line.  The
list is ordered by buffer position."
  (let (display frags)
    (save-excursion
      ;; 1. display math first: $$...$$ may span lines.  Every match's
      ;; span is recorded so the inline pass does not dive into it and
      ;; mistake the inner text for a second, single-dollar fragment.
      (goto-char (point-min))
      (while (re-search-forward org-typst-preview--display-regexp nil t)
        (let ((start (match-beginning 0))
              (end (match-end 0)))
          (unless (or (eq (char-before start) ?\\) ; \$ escapes a dollar sign
                      (save-match-data (org-typst-preview--protected-p start)))
            (push (list start end t (match-string-no-properties 1)) frags))
          (push (cons start end) display)))
      ;; 2. inline math: single-line $...$ outside every display span.
      (goto-char (point-min))
      (while (re-search-forward org-typst-preview--inline-regexp nil t)
        (let ((start (match-beginning 0))
              (end (match-end 0)))
          (unless (or (eq (char-before start) ?\\)
                      (org-typst-preview--in-region-p start end display)
                      (save-match-data (org-typst-preview--protected-p start)))
            (push (list start end nil (match-string-no-properties 1)) frags)))))
    (sort frags (lambda (a b) (< (car a) (car b))))))

(defun org-typst-preview--on-modify (ov &rest _)
  "Delete overlay OV, revealing the source text, as soon as it is edited."
  (delete-overlay ov))

(defun org-typst-preview--max-width (buf)
  "Widest image (pixels) that fits every window showing BUF, or nil.
Images are capped at this width because Emacs's redisplay can hang in
an infinite loop on an image wider than its window when word wrap
\(`visual-line-mode') and `display-line-numbers-mode' are both active.
The value is quantized to 25px steps so dragging a frame edge doesn't
churn out a new image spec per pixel."
  (let (w)
    (dolist (win (get-buffer-window-list buf nil t))
      (let ((tw (with-selected-window win
                  (- (window-body-width win t)
                     ;; line numbers are drawn inside the body width
                     (or (ignore-errors (line-number-display-width t)) 0)
                     ;; slack for the wrap-indicator glyph
                     (* 2 (frame-char-width))))))
        (setq w (if w (min w tw) tw))))
    (and w (max 10 (* 25 (floor w 25))))))

(defvar text-scale-mode)                ; face-remap.el
(defvar text-scale-mode-step)
(defvar text-scale-mode-amount)

(defun org-typst-preview--text-scale ()
  "Current `text-scale-adjust' factor of this buffer, 1.0 when unscaled.
Previews follow \\[text-scale-adjust] zooming like the text does."
  (if (and (boundp 'text-scale-mode) text-scale-mode
           (boundp 'text-scale-mode-amount))
      (expt text-scale-mode-step text-scale-mode-amount)
    1.0))

(defun org-typst-preview--display-scale ()
  "Factor between an image's natural pt size and its on-screen pixels.
Every width decision (does this fit?  how wide should the wrap be?)
must use displayed sizes, or zoomed-in images overflow their window."
  (* org-typst-preview-scale (org-typst-preview--text-scale)))

(defun org-typst-preview--image (img-file max-width)
  "Image spec for IMG-FILE fitting into MAX-WIDTH pixels (nil = no limit).
The image sits on the text baseline when the measurement page is
available, and scales with the buffer's text scale.  In `scale' style
MAX-WIDTH shrinks the image via :max-width (in `wrap' style that cap
is only a safety net)."
  (let* ((fmt (org-typst-preview--image-format))
         (ascent (or (org-typst-preview--ascent img-file) 'center))
         (file img-file)
         (props nil))
    (when max-width
      (setq props (list :max-width max-width)))
    (apply #'create-image file fmt nil
           :ascent ascent
           ;; PNGs are rendered at 192ppi (2.667px per pt); 72/192 shrinks
           ;; them back to 1px per pt, the same on-screen size as the SVGs.
           :scale (* (if (eq fmt 'png)
                         (* 0.375 org-typst-preview-scale)
                       org-typst-preview-scale)
                     (org-typst-preview--text-scale))
           props)))

(defun org-typst-preview--make-overlay (start end hash)
  "Make a preview overlay over START..END, tagged HASH.
Sets the tag, hash and the edit hooks that make the overlay evaporate
\(revealing the source text) the moment the fragment is touched.  The
caller adds whatever it displays -- an image, or an error underline."
  (let ((ov (make-overlay start end)))
    (overlay-put ov 'org-typst-preview t)
    (overlay-put ov 'org-typst-preview-hash hash)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'modification-hooks '(org-typst-preview--on-modify))
    (overlay-put ov 'insert-in-front-hooks '(org-typst-preview--on-modify))
    (overlay-put ov 'insert-behind-hooks '(org-typst-preview--on-modify))
    ov))

(defun org-typst-preview--overlay (start end img-file hash)
  "Cover START..END with the image in IMG-FILE, tagged with HASH."
  (let ((ov (org-typst-preview--make-overlay start end hash))
        (mw (org-typst-preview--max-width (current-buffer))))
    (overlay-put ov 'org-typst-preview-file img-file)
    (overlay-put ov 'org-typst-preview-max mw)
    (overlay-put ov 'display (org-typst-preview--image img-file mw))
    ov))

(defun org-typst-preview--reflow-overlays (cap force-rebuild)
  "Reconcile every preview overlay in the current buffer with width CAP.
In `wrap' style, overlays now wider than CAP are removed -- their raw
text reappears at the normal, constant font size, to be re-wrapped by
the next scheduled scan.  Otherwise each overlay's width cap is set to
CAP and its image spec rebuilt: in `scale' style whenever the cap
changed, and always when FORCE-REBUILD is non-nil (e.g. after a zoom,
when the on-screen pixel size changed even though the cap did not).
No style leaves an image wider than its window unwittingly, which would
risk an Emacs redisplay hang -- see `org-typst-preview--max-width'."
  (let ((wrapp (eq org-typst-preview-overflow-style 'wrap))
        (scale (org-typst-preview--display-scale)))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (let ((file (and (overlay-get ov 'org-typst-preview)
                       (overlay-get ov 'org-typst-preview-file))))
        (when file
          (let ((dims (org-typst-preview--image-dims file)))
            (cond
             ((and wrapp cap dims (> (* (car dims) scale) cap))
              (delete-overlay ov))
             ((if wrapp
                  force-rebuild
                (or force-rebuild
                    (not (eql cap (overlay-get ov 'org-typst-preview-max)))))
              (overlay-put ov 'org-typst-preview-max cap)
              (overlay-put ov 'display
                           (org-typst-preview--image file cap)))))))))
  (org-typst-preview--schedule))

(defun org-typst-preview--window-resize (frame)
  "Adjust previews in FRAME's windows after a size change, per style.
`wrap': previews too wide for their window are removed -- the raw text
shows at the normal, constant font size until the re-wrapped image
arrives via the scheduled scan.  `scale': every preview's width cap is
refreshed so it shrinks or grows with the window."
  (dolist (win (window-list frame 'nomini))
    (let ((buf (window-buffer win)))
      (when (buffer-local-value 'org-typst-preview-mode buf)
        (with-current-buffer buf
          (org-typst-preview--reflow-overlays
           (org-typst-preview--max-width buf) nil))))))

(defun org-typst-preview--existing-with-hash (start end hash)
  "Non-nil if a preview with HASH already covers exactly START..END."
  (catch 'yes
    (dolist (ov (overlays-in start end))
      (when (and (overlay-get ov 'org-typst-preview)
                 (= (overlay-start ov) start)
                 (= (overlay-end ov) end)
                 (equal (overlay-get ov 'org-typst-preview-hash) hash))
        (throw 'yes t)))))

(defun org-typst-preview--place (start end img-file hash)
  "Replace any previews covering START..END with the image in IMG-FILE.
HASH tags the new overlay for later staleness checks."
  (dolist (ov (overlays-in start end))
    (when (overlay-get ov 'org-typst-preview)
      (delete-overlay ov)))
  (org-typst-preview--overlay start end img-file hash))

(defun org-typst-preview--mark-error (start end hash message)
  "Underline START..END as broken math and show MESSAGE after it.
HASH identifies the failed render, so the mark is not re-made every
scan.  Both underline and message disappear as soon as the fragment
is edited."
  (unless (org-typst-preview--existing-with-hash start end hash)
    (dolist (ov (overlays-in start end))
      (when (overlay-get ov 'org-typst-preview)
        (delete-overlay ov)))
    (let ((ov (org-typst-preview--make-overlay start end hash)))
      (overlay-put ov 'face 'org-typst-preview-error)
      (when message
        (overlay-put ov 'after-string
                     (propertize (format "  %s" message)
                                 'face 'org-typst-preview-error-message)))
      (overlay-put ov 'help-echo
                   "Full Typst output: buffer *org-typst-preview-errors*")
      ov)))

(defcustom org-typst-preview-max-processes 4
  "How many typst compiles may run at once; the rest wait in a queue.
Keeps a math-heavy file from forking one process per fragment when it
is first opened."
  :type 'natnum)

(defvar org-typst-preview--queue nil
  "Compile jobs waiting for a free process slot, oldest first.")

(defvar org-typst-preview--running 0
  "Number of typst processes currently running.")

(defun org-typst-preview--compile-async (source fmt img-file callback)
  "Compile SOURCE to IMG-FILE as FMT, then call CALLBACK with success flag.
Jobs beyond `org-typst-preview-max-processes' are queued."
  (unless (gethash img-file org-typst-preview--inflight)
    (puthash img-file t org-typst-preview--inflight)
    (setq org-typst-preview--queue
          (nconc org-typst-preview--queue
                 (list (list source fmt img-file callback))))
    (org-typst-preview--pump)))

(defun org-typst-preview--pump ()
  "Start queued compile jobs while process slots are free."
  (while (and org-typst-preview--queue
              (< org-typst-preview--running org-typst-preview-max-processes))
    (setq org-typst-preview--running (1+ org-typst-preview--running))
    (apply #'org-typst-preview--start-compile
           (pop org-typst-preview--queue))))

(defun org-typst-preview--start-compile (source fmt img-file callback)
  "Run typst on SOURCE producing IMG-FILE as FMT, then call CALLBACK.
The output name is turned into a {p} pattern because every render has
a second, baseline-measurement page (see `org-typst-preview--source')."
  (let ((typ-file (concat img-file ".typ"))
        (out-pattern (replace-regexp-in-string
                      "-1\\.\\([a-z]+\\)\\'" "-{p}.\\1" img-file)))
    (write-region source nil typ-file nil 'silent)
    ;; a pipe plus NO_COLOR keeps ANSI colour codes out of the error
    ;; output, which the inline error message is parsed from
    (let ((process-environment (cons "NO_COLOR=1" process-environment)))
      (make-process
       :name "org-typst-preview"
       :noquery t
       :connection-type 'pipe
       :buffer (generate-new-buffer " *org-typst-preview*")
     :command `(,org-typst-preview-program "compile"
                "--format" ,(symbol-name fmt)
                ,@(when (eq fmt 'png) '("--ppi" "192"))
                ,typ-file ,out-pattern)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (setq org-typst-preview--running
               (max 0 (1- org-typst-preview--running)))
         (remhash img-file org-typst-preview--inflight)
         ;; drain any stderr still in flight; the sentinel can fire
         ;; before the last output chunk has been delivered
         (accept-process-output proc 0.05)
         (let ((ok (and (eq (process-status proc) 'exit)
                        (zerop (process-exit-status proc))
                        (file-exists-p img-file))))
           (unless ok
             (let* ((output (with-current-buffer (process-buffer proc)
                              (buffer-string)))
                    (msg (if (string-match "^error: \\(.*\\)$" output)
                             (concat "error: " (match-string 1 output))
                           "error: typst compilation failed")))
               (puthash img-file (cons 'error msg)
                        org-typst-preview--failed)
               ;; This buffer holds only the most recent failure (the
               ;; per-fragment message lives inline in the org buffer),
               ;; so stale errors never linger here.
               (with-current-buffer
                   (get-buffer-create "*org-typst-preview-errors*")
                 (erase-buffer)
                 (insert (format "Most recent Typst error (%s):\n\n%s\n%s"
                                 (format-time-string "%T") source output)))))
           (ignore-errors (delete-file typ-file))
           (kill-buffer (process-buffer proc))
           (org-typst-preview--pump)
           (funcall callback ok))))))))

(defun org-typst-preview--wrap-failed-p (math displayp size color img-file)
  "Non-nil if the wrapped render in IMG-FILE did not actually reflow.
When Typst finds no legal break point in MATH, the fixed-width page
just clips it, recognizable by the height not growing.  DISPLAYP,
SIZE and COLOR identify the natural-size render to compare against."
  (let ((dims (org-typst-preview--image-dims img-file))
        (nat (org-typst-preview--image-dims
              (nth 2 (org-typst-preview--target math displayp size color nil)))))
    (and dims nat (< (cdr dims) (* 1.3 (cdr nat))))))

(defun org-typst-preview--render (buf start end displayp math size color wrap-w)
  "Ensure the fragment at START..END in BUF is displayed at a good width.
Inline math whose natural size is wider than the window is reflowed:
Typst re-lays it out at the window width (like Obsidian), with the
natural image shown scaled down while that compiles.  If Typst finds
no legal break point, the scaled version stays.  DISPLAYP, MATH, SIZE,
COLOR and WRAP-W as in `org-typst-preview--source'; compiles
asynchronously when an image is not cached yet."
  (pcase-let ((`(,source ,hash ,img-file)
               (org-typst-preview--target math displayp size color wrap-w)))
    (let* ((avail (and (null wrap-w)
                       (eq org-typst-preview-overflow-style 'wrap)
                       (org-typst-preview--max-width buf)))
           (dims (and avail (org-typst-preview--image-dims img-file)))
           (shown-w (and dims (* (car dims)
                                 (org-typst-preview--display-scale)))))
      (if (and shown-w (> shown-w avail))
          ;; Displayed size (natural x zoom) is too wide for the window.
          ;; Never show math scaled down -- the font size must not change
          ;; -- so reveal the raw text until the wrapped image (same font
          ;; size, laid out to fill the window at the current zoom) is
          ;; ready.
          (let ((wrap-pt (max 10 (round (/ avail (org-typst-preview--display-scale))))))
            (pcase-let ((`(,_ ,whash ,_)
                         (org-typst-preview--target math displayp size color
                                                    wrap-pt)))
              (dolist (ov (overlays-in start end))
                (when (and (overlay-get ov 'org-typst-preview)
                           (not (equal (overlay-get ov 'org-typst-preview-hash)
                                       whash)))
                  (delete-overlay ov)))
              (org-typst-preview--render buf start end displayp math size color
                                         wrap-pt)))
        (cond
         ((org-typst-preview--existing-with-hash start end hash) nil)
         ((eq (car-safe (gethash img-file org-typst-preview--failed)) 'error)
          (org-typst-preview--mark-error
           start end hash (cdr (gethash img-file org-typst-preview--failed))))
         ((gethash img-file org-typst-preview--failed) nil) ; no-reflow
         ((file-exists-p img-file)
          (if (and wrap-w (org-typst-preview--wrap-failed-p math displayp size
                                                            color img-file))
              (puthash img-file 'no-reflow org-typst-preview--failed)
            (org-typst-preview--place start end img-file hash)))
         (t
          (org-typst-preview--compile-then-render source img-file buf start end
                                                  displayp math size color
                                                  wrap-w)))))))

(defun org-typst-preview--compile-then-render (source img-file buf start end
                                                      displayp math size color
                                                      wrap-w)
  "Compile SOURCE to IMG-FILE, then render the fragment at START..END in BUF.
Rendering re-evaluates the window width, so an image that turns out too
wide immediately requests its wrapped variant.  Skipped if the fragment
text changed while compiling.  DISPLAYP, MATH, SIZE, COLOR and WRAP-W
as elsewhere."
  (let ((m-start (copy-marker start))
        (m-end (copy-marker end))
        (frag (buffer-substring-no-properties start end)))
    (org-typst-preview--compile-async
     source (org-typst-preview--image-format) img-file
     (lambda (ok)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (when (and org-typst-preview-mode
                      (marker-position m-start) (marker-position m-end)
                      (equal frag (buffer-substring-no-properties m-start m-end))
                      (not (and (<= m-start (point)) (<= (point) m-end))))
             (if ok
                 (org-typst-preview--render
                  buf (marker-position m-start) (marker-position m-end)
                  displayp math size color wrap-w)
               ;; compile failed: underline the culprit right away
               (org-typst-preview--mark-error
                (marker-position m-start) (marker-position m-end)
                (sha1 source)
                (cdr (gethash img-file org-typst-preview--failed)))))))
       (set-marker m-start nil)
       (set-marker m-end nil)))))

(defun org-typst-preview--scan (buf)
  "Render every math fragment in BUF that the cursor is not inside."
  (when (and (buffer-live-p buf) (display-images-p))
    (with-current-buffer buf
      (when org-typst-preview-mode
        (let ((size (org-typst-preview--font-pt))
              (color (org-typst-preview--color-hex)))
          (dolist (frag (org-typst-preview--fragments))
            (pcase-let ((`(,start ,end ,displayp ,math) frag))
              (unless (and (<= start (point)) (<= (point) end))
                (org-typst-preview--render buf start end displayp math
                                           size color nil)))))))))

(defun org-typst-preview--refresh-images ()
  "Rebuild the image specs of every preview in the current buffer.
Runs after \\[text-scale-adjust] so previews zoom along with the text.
In `wrap' style, previews that no longer fit their window at the new
zoom are removed (revealing the raw text) and re-wrapped by the
scheduled scan; the others are re-capped and re-scaled to the new zoom."
  (org-typst-preview--reflow-overlays
   (org-typst-preview--max-width (current-buffer)) t))

(defun org-typst-preview--schedule ()
  "Debounce a re-scan of the current buffer onto an idle timer."
  (when (timerp org-typst-preview--timer)
    (cancel-timer org-typst-preview--timer))
  (setq org-typst-preview--timer
        (run-with-idle-timer org-typst-preview-delay nil
                             #'org-typst-preview--scan (current-buffer))))

(defun org-typst-preview--post-command ()
  "Reveal any preview the cursor moved into; schedule a re-scan."
  (dolist (ov (overlays-in (max (1- (point)) (point-min))
                           (min (1+ (point)) (point-max))))
    (when (and (overlay-get ov 'org-typst-preview)
               (<= (overlay-start ov) (point))
               (<= (point) (overlay-end ov)))
      (delete-overlay ov)))
  (org-typst-preview--schedule))

;;;###autoload
(define-minor-mode org-typst-preview-mode
  "Render $...$ fragments as Typst images when the cursor is elsewhere.
Inline math uses single dollars ($x^2$) and stays on one line; display
math uses double dollars ($$sum_(k=1)^n k$$) and may span several lines.
Moving the cursor into a rendered fragment reveals its source for editing."
  :lighter " Typ$"
  (if org-typst-preview-mode
      (progn
        (make-directory org-typst-preview-cache-dir t)
        (add-hook 'post-command-hook #'org-typst-preview--post-command nil t)
        (add-hook 'text-scale-mode-hook #'org-typst-preview--refresh-images nil t)
        ;; Global on purpose: resize handling must outlive any one buffer,
        ;; and the handler no-ops for windows without the mode.
        (add-hook 'window-size-change-functions
                  #'org-typst-preview--window-resize)
        (org-typst-preview--scan (current-buffer)))
    (remove-hook 'post-command-hook #'org-typst-preview--post-command t)
    (remove-hook 'text-scale-mode-hook #'org-typst-preview--refresh-images t)
    (when (timerp org-typst-preview--timer)
      (cancel-timer org-typst-preview--timer))
    (remove-overlays (point-min) (point-max) 'org-typst-preview t)))

;;;###autoload
(defun org-typst-preview-buffer ()
  "Turn on Typst previews in this buffer and render everything now."
  (interactive)
  (org-typst-preview-mode 1)
  (org-typst-preview--scan (current-buffer)))

;;;###autoload
(defun org-typst-preview-clear ()
  "Remove all Typst previews and stop auto-rendering in this buffer."
  (interactive)
  (org-typst-preview-mode -1))

(provide 'org-typst-preview)
;;; org-typst-preview.el ends here
