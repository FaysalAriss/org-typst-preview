;;; test-org-typst-preview-e2e.el --- end-to-end overlay lifecycle test -*- lexical-binding: t; -*-
(require 'cl-lib)
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

(defun wait-for-compiles ()
  (let ((deadline (+ (float-time) 30)))
    (while (and (> (hash-table-count org-typst-preview--inflight) 0)
                (< (float-time) deadline))
      (accept-process-output nil 0.1))
    ;; give sentinels' callbacks a beat
    (accept-process-output nil 0.2)))

(defun preview-overlays ()
  (seq-filter (lambda (ov) (overlay-get ov 'org-typst-preview))
              (overlays-in (point-min) (point-max))))

;; Pretend we are a graphical session that can show SVGs.
(cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
          ((symbol-function 'image-type-available-p) (lambda (type) (eq type 'svg)))
          ((symbol-function 'create-image)
           (lambda (file type &optional _data-p &rest props)
             (append (list 'image :file file :type type) props))))

  (with-temp-buffer
    (org-mode)
    (insert "Euler: $e^(i pi) + 1 = 0$ is neat.\n"
            "Block: $$integral_0^oo e^(-x^2) dif x = sqrt(pi)/2$$\n"
            "Broken: $x^{oops$ stays text.\n")
    (org-typst-preview-mode 1)
    (goto-char (point-max))

    ;; --- first scan: everything compiles asynchronously ------------------
    (org-typst-preview--scan (current-buffer))
    (wait-for-compiles)
    (let* ((ovs (preview-overlays))
           (imgs (seq-filter (lambda (o) (overlay-get o 'display)) ovs))
           (errs (seq-filter (lambda (o) (eq (overlay-get o 'face)
                                             'org-typst-preview-error))
                             ovs)))
      (check "two fragments rendered as images" (length imgs) 2)
      (check "broken math underlined in red" (length errs) 1)
      (check "typst's error message shown inline"
             (and errs
                  (let ((s (overlay-get (car errs) 'after-string)))
                    (and (stringp s) (string-match-p "error:" s) t)))
             t)
      (check "overlays carry image displays"
             (cl-every (lambda (ov)
                         (let ((d (overlay-get ov 'display)))
                           (and (eq (car-safe d) 'image)
                                (file-exists-p (plist-get (cdr d) :file)))))
                       imgs)
             t)
      (check "baseline ascent computed and sane"
             (cl-every (lambda (ov)
                         (let ((a (org-typst-preview--ascent
                                   (plist-get (cdr (overlay-get ov 'display)) :file))))
                           (and (integerp a) (<= 10 a 100))))
                       imgs)
             t))

    ;; --- cursor moves INTO the first fragment -> source revealed ----------
    (goto-char (+ (point-min) 10))      ; inside $e^(i pi)...$
    (org-typst-preview--post-command)
    (check "reveal on cursor entry" (length (preview-overlays)) 2)

    ;; --- cursor leaves again -> re-rendered instantly from cache ----------
    (goto-char (point-max))
    (org-typst-preview--scan (current-buffer))   ; what the idle timer runs
    (check "re-rendered from cache without recompiling"
           (list (length (preview-overlays))
                 (hash-table-count org-typst-preview--inflight))
           '(3 0))

    ;; --- editing a rendered fragment kills its overlay --------------------
    (let* ((ov (car (preview-overlays)))
           (pos (overlay-start ov)))
      (save-excursion (goto-char (1+ pos)) (insert "2"))
      (check "edit reveals source" (overlay-buffer ov) nil))

    ;; --- clearing removes everything and stops the mode -------------------
    (org-typst-preview--scan (current-buffer))
    (wait-for-compiles)
    (org-typst-preview-clear)
    (check "clear removes all previews + mode"
           (list (length (preview-overlays)) org-typst-preview-mode)
           '(0 nil))))

;; --- wrapping of long inline math at window width ---------------------------
(cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
          ((symbol-function 'image-type-available-p) (lambda (type) (eq type 'svg)))
          ((symbol-function 'create-image)
           (lambda (file type &optional _data-p &rest props)
             (append (list 'image :file file :type type) props)))
          ;; pretend every window showing the buffer is 200px wide
          ((symbol-function 'org-typst-preview--max-width) (lambda (_) 200))
          ;; batch mode has no real font; render at a GUI-realistic 15pt
          ((symbol-function 'org-typst-preview--font-pt) (lambda () 15)))

  (with-temp-buffer
    (org-mode)
    (insert "Long: $x^2 + y^2 + z^2 + a^2 + b^2 + c^2 + d^2 + e^2 + f^2 + g^2 + h^2 = r^2 + s^2$ end.\n"
            "Unbreakable: $sqrt(a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_10 + a_11 + a_12)$ end.\n"
            "Display: $$x^2 + y^2 + z^2 + a^2 + b^2 + c^2 + d^2 + e^2 + f^2 + g^2 + h^2 = r^2 + s^2$$ end.\n")
    (org-typst-preview-mode 1)
    (goto-char (point-max))
    (org-typst-preview--scan (current-buffer))
    (wait-for-compiles)                 ; unwrapped compiles + wrapped requests
    (wait-for-compiles)                 ; wrapped compiles
    (wait-for-compiles)
    (let* ((ovs (sort (preview-overlays)
                      (lambda (a b) (< (overlay-start a) (overlay-start b)))))
           (files (mapcar (lambda (ov)
                            (plist-get (cdr (overlay-get ov 'display)) :file))
                          ovs))
           (dims (mapcar #'org-typst-preview--image-dims files)))
      ;; the unbreakable fragment gets NO overlay: raw text at the normal
      ;; font size, never a scaled-down image
      (check "wrappable fragments rendered, unbreakable stays text"
             (length ovs) 2)
      (check "breakable math reflowed to fit 200px"
             (and (car dims)
                  (<= (car (car dims)) 200)
                  (> (cdr (car dims)) 30)) ; several lines tall
             t)
      (check "display math reflowed at constant size too"
             (and (cadr dims)
                  (<= (car (cadr dims)) 200)
                  (> (cdr (cadr dims)) 30))
             t)
      (check "no overlay on the unbreakable line"
             (let ((case-fold-search nil))
               (save-excursion
                 (goto-char (point-min))
                 (search-forward "Unbreakable:")
                 (seq-some (lambda (o) (overlay-get o 'org-typst-preview))
                           (overlays-in (line-beginning-position)
                                        (line-end-position)))))
             nil)
      (check "failed wrap remembered (no retry loop)"
             (> (hash-table-count org-typst-preview--failed) 0)
             t))
    (org-typst-preview-clear)))

;; --- zoom-aware wrapping -----------------------------------------------------
;; at 1.5x text-scale, an image fitting the window at natural size can
;; still overflow on screen; it must wrap at the correspondingly SMALLER
;; pt width so the displayed result fills but never overflows the window
(cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
          ((symbol-function 'image-type-available-p) (lambda (type) (eq type 'svg)))
          ((symbol-function 'create-image)
           (lambda (file type &optional _data-p &rest props)
             (append (list 'image :file file :type type) props)))
          ((symbol-function 'org-typst-preview--max-width) (lambda (_) 200))
          ((symbol-function 'org-typst-preview--font-pt) (lambda () 15))
          ((symbol-function 'org-typst-preview--text-scale) (lambda () 1.5)))
  (with-temp-buffer
    (org-mode)
    ;; natural width ~170pt: fits 200px unzoomed, overflows at 1.5x
    (insert "Zoomed: $x^2 + y^2 + z^2 + a^2 + b^2$ end.\n")
    (org-typst-preview-mode 1)
    (goto-char (point-max))
    (org-typst-preview--scan (current-buffer))
    (wait-for-compiles) (wait-for-compiles)
    (let* ((ov (car (preview-overlays)))
           (dims (and ov (org-typst-preview--image-dims
                          (plist-get (cdr (overlay-get ov 'display)) :file)))))
      (check "zoomed math wraps at the reduced pt width"
             (and dims
                  (<= (car dims) 134)   ; 200px / 1.5 = 133pt page
                  (> (cdr dims) 20))    ; more than one line tall
             t))
    (org-typst-preview-clear)))

;; --- scale and overflow styles ----------------------------------------------
;; with wrapping off, the natural-size image is always placed: capped
;; (scale) or uncapped (overflow), and no wrapped variant is compiled
(dolist (style '(scale overflow))
  (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
            ((symbol-function 'image-type-available-p) (lambda (type) (eq type 'svg)))
            ((symbol-function 'create-image)
             (lambda (file type &optional _data-p &rest props)
             (append (list 'image :file file :type type) props)))
            ((symbol-function 'org-typst-preview--max-width) (lambda (_) 200))
            ((symbol-function 'org-typst-preview--font-pt) (lambda () 15)))
    (let ((org-typst-preview-overflow-style style))
      (with-temp-buffer
        (org-mode)
        (insert "Long: $x^2 + y^2 + z^2 + a^2 + b^2 + c^2 + d^2"
                " + e^2 + f^2 + g^2 + h^2 = r^2 + s^2$ end.\n")
        (org-typst-preview-mode 1)
        (goto-char (point-max))
        (org-typst-preview--scan (current-buffer))
        (wait-for-compiles) (wait-for-compiles)
        (let* ((ov (car (preview-overlays)))
               (img (and ov (cdr (overlay-get ov 'display))))
               (file (and img (plist-get img :file))))
          (pcase style
            ('scale
             (check "scale style: natural-size image, capped to the window"
                    (and file
                         (> (car (org-typst-preview--image-dims file)) 200)
                         (plist-get img :max-width))
                    200))
            ('overflow
             (check "overflow style: clipped-at-the-edge derivative, no cap"
                    (list (and file (string-suffix-p "-crop200.svg" file))
                          (and file (car (org-typst-preview--image-dims file)))
                          (plist-get img :max-width))
                    '(t 200 nil))
             (check "overflow style: clip keeps natural height"
                    (let ((orig (org-typst-preview--image-dims
                                 (overlay-get ov 'org-typst-preview-file))))
                      (and orig
                           (> (car orig) 200) ; original untouched
                           (equal (cdr (org-typst-preview--image-dims file))
                                  (cdr orig))))
                    t))))
        (org-typst-preview-clear)))))

(if (> test-failures 0)
    (kill-emacs 1)
  (message "\nAll e2e tests passed."))
;;; test-org-typst-preview-e2e.el ends here
