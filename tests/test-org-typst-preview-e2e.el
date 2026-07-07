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

(if (> test-failures 0)
    (kill-emacs 1)
  (message "\nAll e2e tests passed."))
;;; test-org-typst-preview-e2e.el ends here
