;;; org-typst-preview.el --- Live inline Typst math previews in Org buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Faysal Ariss

;; Author: Faysal Ariss <faysal.ariss@gmail.com>
;; Version: 0.2.0
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
;;     $x^2 + y^2 = z^2$                  inline math
;;     $$sum_(k=1)^n k = (n(n+1))/2$$     display-style math (one line)
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
;; exactly once, ever.  A fragment with a Typst syntax error simply stays
;; as plain text; the compiler's message lands in the
;; *org-typst-preview-errors* buffer.
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

;; A math fragment is $...$ or $$...$$ on a single line, whose content
;; starts and ends with a non-space character -- the same rule Org and
;; Obsidian use, so "I paid $5, then some more" is not mistaken for math.
;; Two prices on one line ("$10 ... 100$") CAN still pair up, exactly as
;; they would in Obsidian; write \$ to escape a literal dollar sign.
(defconst org-typst-preview--regexp
  "\\(\\$\\$?\\)\\([^$[:space:]]\\(?:[^$\n]*[^$[:space:]]\\)?\\)\\1")

(defvar org-typst-preview--inflight (make-hash-table :test #'equal)
  "Image files currently being compiled, to avoid duplicate typst runs.")

(defvar org-typst-preview--failed (make-hash-table :test #'equal)
  "Images whose compile failed, so broken math is not retried in a loop.
Editing the fragment gives it a new hash, which retries automatically.")

(defvar-local org-typst-preview--timer nil)

(defun org-typst-preview--image-format ()
  "Image format to render: SVG when Emacs can show it, else PNG."
  (if (image-type-available-p 'svg) 'svg 'png))

(defun org-typst-preview--font-pt ()
  "Typst text size (pt) that visually matches the buffer's default font.
Emacs displays SVG pt units 1:1 with logical pixels (measured on the
macOS build: a 100pt-wide SVG shows as 100px), so the font's pixel size
is the right pt value to hand Typst."
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

(defun org-typst-preview--source (math displayp size-pt color)
  "Build the Typst document that renders MATH at SIZE-PT in COLOR.
When DISPLAYP is non-nil, use display-style math."
  ;; fill: none = transparent background, so it sits on the theme's bg.
  ;; top/bottom-edge "bounds" makes the auto-sized page measure the real
  ;; ink extents; the default (cap-height..baseline) crops descenders
  ;; like the tail of y and anything raised above cap height (exponents).
  (concat "#set page(width: auto, height: auto, margin: 1.5pt, fill: none)\n"
          (format "#set text(size: %spt, fill: rgb(\"%s\"), top-edge: \"bounds\", bottom-edge: \"bounds\")\n"
                  size-pt color)
          (if displayp (format "$ %s $" math) (format "$%s$" math))))

(defun org-typst-preview--protected-p (pos)
  "Non-nil if POS is somewhere math should not render (code blocks etc.)."
  (and (derived-mode-p 'org-mode)
       (save-excursion
         (goto-char pos)
         (memq (org-element-type (org-element-at-point))
               '(src-block example-block export-block comment-block
                 comment keyword fixed-width latex-environment)))))

(defun org-typst-preview--fragments ()
  "Return a list of (START END DISPLAYP MATH) for fragments in the buffer."
  (let (frags)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-typst-preview--regexp nil t)
        (let ((start (match-beginning 0))
              (end (match-end 0))
              (displayp (= (length (match-string 1)) 2))
              (math (match-string-no-properties 2)))
          (unless (or (eq (char-before start) ?\\) ; \$ escapes a dollar sign
                      (save-match-data (org-typst-preview--protected-p start)))
            (push (list start end displayp math) frags)))))
    (nreverse frags)))

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

(defun org-typst-preview--image (img-file max-width)
  "Image spec for IMG-FILE, no wider than MAX-WIDTH pixels if non-nil."
  (let ((fmt (org-typst-preview--image-format)))
    (apply #'create-image img-file fmt nil
           :ascent 'center
           ;; PNGs are rendered at 192ppi (2.667px per pt); 72/192 shrinks
           ;; them back to 1px per pt, the same on-screen size as the SVGs.
           :scale (if (eq fmt 'png)
                      (* 0.375 org-typst-preview-scale)
                    org-typst-preview-scale)
           (when max-width (list :max-width max-width)))))

(defun org-typst-preview--overlay (start end img-file hash)
  "Cover START..END with the image in IMG-FILE, tagged with HASH."
  (let ((ov (make-overlay start end))
        (mw (org-typst-preview--max-width (current-buffer))))
    (overlay-put ov 'org-typst-preview t)
    (overlay-put ov 'org-typst-preview-hash hash)
    (overlay-put ov 'org-typst-preview-file img-file)
    (overlay-put ov 'org-typst-preview-max mw)
    (overlay-put ov 'display (org-typst-preview--image img-file mw))
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'modification-hooks '(org-typst-preview--on-modify))
    (overlay-put ov 'insert-in-front-hooks '(org-typst-preview--on-modify))
    (overlay-put ov 'insert-behind-hooks '(org-typst-preview--on-modify))
    ov))

(defun org-typst-preview--window-resize (frame)
  "Re-cap preview images in FRAME's windows after a size change.
Runs on `window-size-change-functions' so a preview is never left
wider than its (possibly narrowed) window, which redisplay cannot
always handle -- see `org-typst-preview--max-width'."
  (dolist (win (window-list frame 'nomini))
    (let ((buf (window-buffer win)))
      (when (buffer-local-value 'org-typst-preview-mode buf)
        (with-current-buffer buf
          (let ((mw (org-typst-preview--max-width buf)))
            (dolist (ov (overlays-in (point-min) (point-max)))
              (when (and (overlay-get ov 'org-typst-preview)
                         (not (eql mw (overlay-get ov 'org-typst-preview-max)))
                         (overlay-get ov 'org-typst-preview-file))
                (overlay-put ov 'org-typst-preview-max mw)
                (overlay-put ov 'display
                             (org-typst-preview--image
                              (overlay-get ov 'org-typst-preview-file)
                              mw))))))))))

(defun org-typst-preview--existing-p (start end hash)
  "Non-nil if a preview with HASH already covers exactly START..END.
Stale previews found in the region are deleted."
  (let (found)
    (dolist (ov (overlays-in start end))
      (when (overlay-get ov 'org-typst-preview)
        (if (and (= (overlay-start ov) start)
                 (= (overlay-end ov) end)
                 (equal (overlay-get ov 'org-typst-preview-hash) hash))
            (setq found t)
          (delete-overlay ov))))
    found))

(defun org-typst-preview--compile-async (source fmt img-file callback)
  "Compile SOURCE to IMG-FILE as FMT, then call CALLBACK with success flag."
  (unless (gethash img-file org-typst-preview--inflight)
    (puthash img-file t org-typst-preview--inflight)
    (let ((typ-file (concat img-file ".typ")))
      (write-region source nil typ-file nil 'silent)
      (make-process
       :name "org-typst-preview"
       :noquery t
       :buffer (generate-new-buffer " *org-typst-preview*")
       :command `(,org-typst-preview-program "compile"
                  "--format" ,(symbol-name fmt)
                  ,@(when (eq fmt 'png) '("--ppi" "192"))
                  ,typ-file ,img-file)
       :sentinel
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (remhash img-file org-typst-preview--inflight)
           (let ((ok (and (eq (process-status proc) 'exit)
                          (zerop (process-exit-status proc))
                          (file-exists-p img-file))))
             (unless ok
               (puthash img-file t org-typst-preview--failed)
               (with-current-buffer
                   (get-buffer-create "*org-typst-preview-errors*")
                 (goto-char (point-max))
                 (insert (format "--- %s ---\n%s\n"
                                 (format-time-string "%T") source))
                 (insert-buffer-substring (process-buffer proc))
                 (insert "\n")))
             (ignore-errors (delete-file typ-file))
             (kill-buffer (process-buffer proc))
             (funcall callback ok))))))))

(defun org-typst-preview--compile-then-place (source fmt img-file hash start end)
  "Compile SOURCE to IMG-FILE as FMT; overlay START..END tagged HASH.
The overlay is only placed if the fragment text is still unchanged when
the compile finishes."
  (let ((buf (current-buffer))
        (m-start (copy-marker start))
        (m-end (copy-marker end))
        (frag (buffer-substring-no-properties start end)))
    (org-typst-preview--compile-async
     source fmt img-file
     (lambda (ok)
       (when (and ok (buffer-live-p buf))
         (with-current-buffer buf
           (when (and org-typst-preview-mode
                      (marker-position m-start) (marker-position m-end)
                      (equal frag (buffer-substring-no-properties m-start m-end))
                      (not (and (<= m-start (point)) (<= (point) m-end))))
             (unless (org-typst-preview--existing-p (marker-position m-start)
                                                    (marker-position m-end)
                                                    hash)
               (org-typst-preview--overlay (marker-position m-start)
                                           (marker-position m-end)
                                           img-file hash)))))
       (set-marker m-start nil)
       (set-marker m-end nil)))))

(defun org-typst-preview--scan (buf)
  "Render every math fragment in BUF that the cursor is not inside."
  (when (and (buffer-live-p buf) (display-images-p))
    (with-current-buffer buf
      (when org-typst-preview-mode
        (let ((fmt (org-typst-preview--image-format))
              (size (org-typst-preview--font-pt))
              (color (org-typst-preview--color-hex)))
          (dolist (frag (org-typst-preview--fragments))
            (pcase-let ((`(,start ,end ,displayp ,math) frag))
              (unless (and (<= start (point)) (<= (point) end))
                (let* ((source (org-typst-preview--source math displayp size color))
                       (hash (sha1 source))
                       (img-file (expand-file-name
                                  (format "%s.%s" hash fmt)
                                  org-typst-preview-cache-dir)))
                  (unless (or (org-typst-preview--existing-p start end hash)
                              (gethash img-file org-typst-preview--failed))
                    (if (file-exists-p img-file)
                        (org-typst-preview--overlay start end img-file hash)
                      (org-typst-preview--compile-then-place
                       source fmt img-file hash start end))))))))))))

(defun org-typst-preview--post-command ()
  "Reveal any preview the cursor moved into; schedule a re-scan."
  (dolist (ov (overlays-in (max (1- (point)) (point-min))
                           (min (1+ (point)) (point-max))))
    (when (and (overlay-get ov 'org-typst-preview)
               (<= (overlay-start ov) (point))
               (<= (point) (overlay-end ov)))
      (delete-overlay ov)))
  (when (timerp org-typst-preview--timer)
    (cancel-timer org-typst-preview--timer))
  (setq org-typst-preview--timer
        (run-with-idle-timer org-typst-preview-delay nil
                             #'org-typst-preview--scan (current-buffer))))

;;;###autoload
(define-minor-mode org-typst-preview-mode
  "Render $...$ fragments as Typst images when the cursor is elsewhere.
Inline math uses single dollars ($x^2$), display-style math uses double
dollars ($$sum_(k=1)^n k$$), both on a single line.  Moving the cursor
into a rendered fragment reveals its source for editing."
  :lighter " Typ$"
  (if org-typst-preview-mode
      (progn
        (make-directory org-typst-preview-cache-dir t)
        (add-hook 'post-command-hook #'org-typst-preview--post-command nil t)
        ;; Global on purpose: resize handling must outlive any one buffer,
        ;; and the handler no-ops for windows without the mode.
        (add-hook 'window-size-change-functions
                  #'org-typst-preview--window-resize)
        (org-typst-preview--scan (current-buffer)))
    (remove-hook 'post-command-hook #'org-typst-preview--post-command t)
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
