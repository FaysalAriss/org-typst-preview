;;; org-typst-preview.el --- Live inline Typst math previews in Org buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faysal Ariss

;; Author: Faysal Ariss <faysal.ariss@gmail.com>
;; Assisted-by: Claude Code:claude-opus-4-8
;; Version: 0.8.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: outlines, tex, wp
;; URL: https://github.com/FaysalAriss/org-typst-preview

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

(defcustom org-typst-preview-cache-max-bytes 50000000
  "Soft cap on the image cache size, in bytes (nil disables the cap).
When the cache is pruned and exceeds this, whole fragments are deleted
oldest-first until it fits.  Deleted images recompile on demand, so the
cap only trades a little disk for the odd millisecond recompile."
  :type '(choice (const :tag "No size cap" nil) natnum))

(defcustom org-typst-preview-cache-max-age-days 30
  "Delete cached images untouched for more than this many days (nil = keep).
Applied whenever the cache is pruned; deleted images recompile on demand."
  :type '(choice (const :tag "No age limit" nil) natnum))

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

(defun org-typst-preview--font-pt ()
  "Typst text size (pt) matching the buffer font's size.
Typst renders 1pt as 1 logical pixel (measured), so the buffer font's
pixel size is used directly; nudge `org-typst-preview-scale' if the math
reads a little large or small next to your text.  Falls back to the face
height in points when the pixel size is unavailable."
  (or (ignore-errors
        (let ((px (aref (font-info (face-font 'default)) 2)))
          (and (numberp px) (> px 0) px)))
      (let ((h (face-attribute 'default :height)))
        (if (integerp h) (/ h 10.0) 12))))

(defun org-typst-preview--color-hex ()
  "Buffer foreground colour as a #rrggbb string (follows your theme)."
  (let* ((fg (face-attribute 'default :foreground nil t))
         (vals (and (stringp fg) (color-values fg))))
    (if vals
        (format "#%02x%02x%02x"
                (ash (nth 0 vals) -8) (ash (nth 1 vals) -8) (ash (nth 2 vals) -8))
      "#000000")))

(defconst org-typst-preview--baseline-drop 1000
  "Height in pt of the invisible marker that measures the math baseline.
On page 2 a marker whose top sits on the line baseline hangs this many
pt below it; the page's ink then bottoms out at the marker, so page-2
height minus this value gives the ink above the baseline.  It must
exceed any fragment's descent below the baseline -- 1000pt is safe at
any font size -- and it is subtracted back out in
`org-typst-preview--ascent'.")

(defun org-typst-preview--source (math displayp size-pt color &optional wrap-w)
  "Build the Typst document that renders MATH at SIZE-PT in COLOR.
When DISPLAYP is non-nil, use display-style math.  When WRAP-W is
non-nil, fix the page width to WRAP-W pt so Typst line-wraps long
inline math instead of producing one wide line.

The document has TWO pages: page 1 is the image shown in the buffer;
page 2 renders the same math followed by a marker that hangs from the
line baseline, so page 2's height locates the baseline -- used to sit
the image on the surrounding text's baseline (the same idea as dvipng's
depth output in org-latex-preview)."
  ;; fill: none = transparent background, so it sits on the theme's bg.
  ;; top/bottom-edge "bounds" makes the auto-sized page measure the real
  ;; ink extents; the default (cap-height..baseline) crops descenders
  ;; like the tail of y and anything raised above cap height (exponents).
  ;; Wrapped display math becomes `#math.display($...$)': block equations
  ;; never line-break (they just clip at the page edge), but an inline
  ;; equation flows across lines while math.display keeps the large
  ;; operator glyphs, so the font size stays constant.  The equation is
  ;; passed as one content argument (not `$display(...)$', whose body a
  ;; top-level comma would split into stray function arguments).
  ;;
  ;; The page-2 marker is a box shifted so its TOP rests on the line
  ;; baseline, hanging `--baseline-drop' pt below it; a leading #h(-1pt)
  ;; cancels its width so it never adds a wrapped line.  We cannot ask
  ;; Typst for the baseline directly: `bottom-edge: "baseline"' reports
  ;; the baseline of the LOWEST internal line, which for stacked math
  ;; (deep fractions, matrices, cases) sits far below the inline baseline
  ;; the equation actually aligns on -- placing such math much too high.
  (let ((body (cond ((and displayp wrap-w) (format "#math.display($%s$)" math))
                    (displayp (format "$ %s $" math))
                    (t (format "$%s$" math)))))
    (concat (if wrap-w
                (format "#set page(width: %dpt, height: auto, margin: 1.5pt, fill: none)\n"
                        wrap-w)
              "#set page(width: auto, height: auto, margin: 1.5pt, fill: none)\n")
            (format "#set text(size: %spt, fill: rgb(\"%s\"), top-edge: \"bounds\", bottom-edge: \"bounds\")\n"
                    size-pt color)
            body
            "\n#pagebreak()\n"
            body
            (format "#h(-1pt)#box(baseline: %dpt, width: 1pt, height: %dpt, fill: black)"
                    org-typst-preview--baseline-drop
                    org-typst-preview--baseline-drop))))

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
Page 1 gives the full ink height; page 2 is the same math plus the
baseline marker, so its height is the ink above the baseline plus
`org-typst-preview--baseline-drop'.  Subtracting the marker leaves the
ascent, and the ratio to the full height is the fraction of the image
above the text baseline.  The 3pt of page margins cancel out."
  (when (string-suffix-p "-1.svg" img-file)
    (let* ((d1 (org-typst-preview--image-dims img-file))
           (d2 (org-typst-preview--image-dims
                (concat (substring img-file 0 -6) "-2.svg"))))
      (when (and d1 d2 (> (cdr d1) 3.0))
        (min 100 (max 10 (round (* 100 (/ (- (cdr d2) 3.0
                                             org-typst-preview--baseline-drop)
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

(defconst org-typst-preview--cache-file-regexp
  "\\`\\([0-9a-f]+\\)-[12]\\.\\(?:svg\\|png\\)\\'"
  "Names written by the current cache scheme: <hash>-1/-2.<ext>.
Group 1 is the fragment's content hash; both pages share it.")

(defvar org-typst-preview--pruned nil
  "Non-nil once the image cache has been pruned this Emacs session.")

;;;###autoload
(defun org-typst-preview-prune-cache ()
  "Trim the image cache: drop stale files, then enforce the size/age caps.
Images left by older versions of this package (a different naming
scheme) are always removed.  Then whole <hash> fragment groups are
deleted, oldest first, until nothing is older than
`org-typst-preview-cache-max-age-days' days and the total is under
`org-typst-preview-cache-max-bytes'.  Deleted images recompile on
demand, so pruning is safe at any time."
  (interactive)
  (when (file-directory-p org-typst-preview-cache-dir)
    (let ((groups (make-hash-table :test #'equal)) ; hash -> (FILES SIZE MTIME)
          (total 0))
      (dolist (f (directory-files org-typst-preview-cache-dir t))
        (let ((name (file-name-nondirectory f)))
          (cond
           ((not (file-regular-p f)) nil) ; . .. and any subdirectory
           ((string-match org-typst-preview--cache-file-regexp name)
            (let* ((hash (match-string 1 name))
                   (attrs (file-attributes f))
                   (size (or (file-attribute-size attrs) 0))
                   (mtime (float-time (file-attribute-modification-time attrs)))
                   (g (gethash hash groups)))
              (setq total (+ total size))
              (if g
                  (setf (nth 0 g) (cons f (nth 0 g))
                        (nth 1 g) (+ (nth 1 g) size)
                        (nth 2 g) (max (nth 2 g) mtime))
                (puthash hash (list (list f) size mtime) groups))))
           ;; an image the current scheme would never write: a leftover
           ;; from an older version.  (Non-image files, e.g. a compile's
           ;; .typ, are left for the compiler to clean up.)
           ((string-match-p "\\.\\(?:svg\\|png\\)\\'" name)
            (ignore-errors (delete-file f))))))
      (let ((glist nil)
            (cutoff (and org-typst-preview-cache-max-age-days
                         (- (float-time)
                            (* 86400 org-typst-preview-cache-max-age-days)))))
        (maphash (lambda (_ g) (push g glist)) groups)
        (setq glist (sort glist (lambda (a b) (< (nth 2 a) (nth 2 b))))) ; oldest first
        (dolist (g glist)
          ;; delete a whole fragment when it is too old, or while the
          ;; cache is still over its size cap (oldest fragments first)
          (when (or (and cutoff (< (nth 2 g) cutoff))
                    (and org-typst-preview-cache-max-bytes
                         (> total org-typst-preview-cache-max-bytes)))
            (dolist (file (nth 0 g)) (ignore-errors (delete-file file)))
            (setq total (- total (nth 1 g)))))))))

;;;###autoload
(defun org-typst-preview-clear-cache ()
  "Delete every cached math image, reclaiming all the disk they used.
Also clears the in-memory dimension and failure tables, so fragments
recompile fresh the next time they are shown."
  (interactive)
  (when (file-directory-p org-typst-preview-cache-dir)
    (dolist (f (directory-files org-typst-preview-cache-dir t
                                "\\.\\(?:svg\\|png\\|typ\\)\\'"))
      (ignore-errors (delete-file f))))
  (clrhash org-typst-preview--dims-cache)
  (clrhash org-typst-preview--failed)
  ;; Drop overlays still displaying the just-deleted images and re-render
  ;; from scratch.  A left-behind overlay keeps showing its old image from
  ;; Emacs's own image cache; because its file (and cached dimensions) are
  ;; now gone, a later re-wrap cannot tell it no longer fits the window and
  ;; may leave it too wide -- which wedges redisplay under `visual-line-mode'
  ;; plus `display-line-numbers-mode' (see `org-typst-preview--max-width').
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'org-typst-preview-mode buf)
      (with-current-buffer buf
        (remove-overlays (point-min) (point-max) 'org-typst-preview t)
        (org-typst-preview--schedule))))
  (when (called-interactively-p 'interactive)
    (message "org-typst-preview: image cache cleared")))

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
        ;; garbage-collect the cache once per session, before rendering
        (unless org-typst-preview--pruned
          (setq org-typst-preview--pruned t)
          (org-typst-preview-prune-cache))
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
