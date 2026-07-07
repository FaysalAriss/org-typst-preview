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
           (lambda (file type &rest props) (append (list 'image :file file :type type) props))))

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
    (let ((ovs (preview-overlays)))
      (check "two fragments rendered, broken one skipped" (length ovs) 2)
      (check "overlays carry image displays"
             (cl-every (lambda (ov)
                         (let ((d (overlay-get ov 'display)))
                           (and (eq (car-safe d) 'image)
                                (file-exists-p (plist-get (cdr d) :file)))))
                       ovs)
             t)
      (check "baseline ascent computed and sane"
             (cl-every (lambda (ov)
                         (let ((a (org-typst-preview--ascent
                                   (plist-get (cdr (overlay-get ov 'display)) :file))))
                           (and (integerp a) (<= 10 a 100))))
                       ovs)
             t))

    ;; --- cursor moves INTO the first fragment -> source revealed ----------
    (goto-char (+ (point-min) 10))      ; inside $e^(i pi)...$
    (org-typst-preview--post-command)
    (check "reveal on cursor entry" (length (preview-overlays)) 1)

    ;; --- cursor leaves again -> re-rendered instantly from cache ----------
    (goto-char (point-max))
    (org-typst-preview--scan (current-buffer))   ; what the idle timer runs
    (check "re-rendered from cache without recompiling"
           (list (length (preview-overlays))
                 (hash-table-count org-typst-preview--inflight))
           '(2 0))

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
           (lambda (file type &rest props) (append (list 'image :file file :type type) props)))
          ;; pretend every window showing the buffer is 200px wide
          ((symbol-function 'org-typst-preview--max-width) (lambda (_) 200))
          ;; batch mode has no real font; render at a GUI-realistic 15pt
          ((symbol-function 'org-typst-preview--font-pt) (lambda () 15)))

  (with-temp-buffer
    (org-mode)
    (insert "Long: $x^2 + y^2 + z^2 + a^2 + b^2 + c^2 + d^2 + e^2 + f^2 + g^2 + h^2 = r^2 + s^2$ end.\n"
            "Unbreakable: $sqrt(a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_10 + a_11 + a_12)$ end.\n")
    (org-typst-preview-mode 1)
    (goto-char (point-max))
    (org-typst-preview--scan (current-buffer))
    (wait-for-compiles)                 ; unwrapped compiles + wrapped requests
    (wait-for-compiles)                 ; wrapped compiles
    (let* ((ovs (sort (preview-overlays)
                      (lambda (a b) (< (overlay-start a) (overlay-start b)))))
           (files (mapcar (lambda (ov)
                            (plist-get (cdr (overlay-get ov 'display)) :file))
                          ovs))
           (dims (mapcar #'org-typst-preview--image-dims files)))
      (check "both fragments still rendered" (length ovs) 2)
      (check "breakable math reflowed to fit 200px"
             (and (car dims)
                  (<= (car (car dims)) 200)
                  (> (cdr (car dims)) 30)) ; several lines tall
             t)
      (check "unbreakable math kept scaled unwrapped image"
             (and (cadr dims) (> (car (cadr dims)) 200))
             t)
      (check "failed wrap remembered (no retry loop)"
             (> (hash-table-count org-typst-preview--failed) 0)
             t))
    (org-typst-preview-clear)))

(if (> test-failures 0)
    (kill-emacs 1)
  (message "\nAll e2e tests passed."))
;;; test-org-typst-preview-e2e.el ends here
