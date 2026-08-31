;;; variable-spacing.el --- Variable line spacing for Org paragraphs -*- lexical-binding: t -*-

;; Author: Brad
;; Version: 0.1.0

;;; Commentary:

;; `variable-spacing-mode' applies proportional line spacing to bare
;; paragraphs in an Org buffer, leaving code blocks, drawers, tables,
;; and similar structured elements at their natural line height.
;;
;; Usage:
;;
;;   (setq-local variable-spacing-ratio 1.6)
;;   (variable-spacing-mode 1)
;;
;; Spacing is applied lazily via jit-lock, so large buffers are not
;; penalised on open.  The spacers are pixel-height `line-prefix' /
;; `wrap-prefix' display properties computed from the rendered font at
;; the time of fontification, so they respond correctly to
;; `text-scale-mode' adjustments.

;;; Code:

(require 'org)
(require 'org-element)
(require 'jit-lock)

;;; User option

(defcustom variable-spacing-ratio 1.5
  "Line-spacing ratio applied to Org paragraphs by `variable-spacing-mode'.
A value of 1.5 gives roughly 1.5× the rendered font height as the
total line height (i.e. ~half a line of extra space above each line).
Must be a positive number; values ≤ 0 are treated as disabling spacing."
  :type 'number
  :group 'variable-spacing)
(make-variable-buffer-local 'variable-spacing-ratio)

;;; Internal constants

(defconst variable-spacing--prop
  'variable-spacing--paragraph-spacing
  "Text property sentinel marking ranges that received spacing from
`variable-spacing-mode'.  Used to clear only our own properties without
clobbering those set by other packages.")

(defconst variable-spacing--excluded-parents
  '(src-block example-block quote-block verse-block
    drawer property-drawer table)
  "Org element types whose paragraph children are skipped by
`variable-spacing-apply'.  These are structured / fixed-pitch elements
where proportional line spacing would look wrong.")

;;; Internal state

(defvar-local variable-spacing--jit-installed nil
  "Non-nil when `variable-spacing--jit' is registered with jit-lock
in the current buffer.")

;;; Pixel-height spacer

(defun variable-spacing--spacer (ratio pos)
  "Return a `space' display spec for RATIO at POS.
POS is used to read the rendered font via `font-at' when the buffer is
visible in a window.  Falls back to `frame-char-height' otherwise."
  (let* ((ratio (or ratio 1.5))
         (win (get-buffer-window (current-buffer) t))
         (height
          (or (when (window-live-p win)
                (condition-case nil
                    (let* ((font (font-at pos win))
                           (fi   (and font (font-info font))))
                      (when (and (vectorp fi)
                                 (> (length fi) 2)
                                 (aref fi 2))
                        (aref fi 2)))
                  (error nil)))
              (frame-char-height)))
         (px (max 0 (round (* ratio height)))))
    `(space :width 0 :height (,px))))

;;; Low-level text-property applier

(defun variable-spacing--put (ratio beg end)
  "Apply line-spacing for RATIO to the region BEG..END.
Sets `line-prefix' and `wrap-prefix' to a pixel-height spacer and marks
the range with `variable-spacing--prop' so it can be cleared precisely."
  (when (< beg end)
    (let ((spacer (variable-spacing--spacer ratio beg)))
      (put-text-property beg end 'line-prefix spacer)
      (put-text-property beg end 'wrap-prefix spacer)
      (put-text-property beg end variable-spacing--prop t))))

;;; Public API — apply / clear

;;;###autoload
(defun variable-spacing-clear (&optional beg end)
  "Remove paragraph line spacing previously applied by `variable-spacing-mode'.
If BEG..END is provided, clear only within that range.  When called
interactively, clears the active region when present, otherwise the
whole buffer."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (let* ((beg (or beg (point-min)))
         (end (or end (point-max)))
         (pos beg))
    (while (< pos end)
      (let ((next (or (next-single-property-change
                       pos variable-spacing--prop nil end)
                      end)))
        (when (get-text-property pos variable-spacing--prop)
          (remove-text-properties pos next
                                  (list variable-spacing--prop nil
                                        'line-prefix nil
                                        'wrap-prefix nil)))
        (setq pos next)))))

;;;###autoload
(defun variable-spacing-apply (&optional ratio beg end)
  "Apply paragraph-wise line spacing to bare Org paragraphs.
Uses RATIO (defaults to `variable-spacing-ratio') and operates on
BEG..END (defaults to the whole buffer).  Skips paragraphs inside any
element type listed in `variable-spacing--excluded-parents'.

When called interactively, operates on the active region when present,
otherwise the whole buffer."
  (interactive (list nil
                     (when (use-region-p) (region-beginning))
                     (when (use-region-p) (region-end))))
  (unless (derived-mode-p 'org-mode)
    (user-error "variable-spacing-apply: not in an Org buffer"))
  (let* ((ratio (or ratio variable-spacing-ratio 1.5))
         (region-specified (and beg end))
         (beg (or beg (point-min)))
         (end (or end (point-max)))
         (ast (if region-specified
                  (save-restriction
                    (narrow-to-region beg end)
                    (org-element-parse-buffer))
                (org-element-parse-buffer))))
    (variable-spacing-clear beg end)
    (org-element-map ast 'paragraph
      (lambda (p)
        (let ((pb (org-element-property :begin p))
              (pe (org-element-property :end p)))
          (when (and pb pe
                     (< pb end)
                     (> pe beg)
                     (save-excursion
                       (goto-char pb)
                       (not (org-element-lineage
                             (org-element-context)
                             variable-spacing--excluded-parents
                             t))))
            (variable-spacing--put ratio
                                   (max pb beg)
                                   (min pe end))))))))

;;; jit-lock integration

(defun variable-spacing--jit (beg end)
  "jit-lock fontification function; applies spacing over BEG..END."
  (when (and (derived-mode-p 'org-mode)
             variable-spacing-ratio
             (> variable-spacing-ratio 0))
    (variable-spacing-apply variable-spacing-ratio beg end)))

(defun variable-spacing--ensure-jit ()
  "Register `variable-spacing--jit' with jit-lock if not already done."
  (unless variable-spacing--jit-installed
    (jit-lock-register #'variable-spacing--jit)
    (setq variable-spacing--jit-installed t)))

(defun variable-spacing--disable-jit ()
  "Unregister `variable-spacing--jit' from jit-lock."
  (when variable-spacing--jit-installed
    (jit-lock-unregister #'variable-spacing--jit)
    (setq variable-spacing--jit-installed nil)))

(defun variable-spacing--refresh-visible ()
  "Apply spacing to the currently visible portions of this buffer."
  (dolist (win (get-buffer-window-list (current-buffer) nil t))
    (let ((vb (window-start win))
          (ve (or (window-end win t) (point-max))))
      (variable-spacing--jit vb ve))))

;;; text-scale-mode advice

(defun variable-spacing--text-scale-refresh (&rest _)
  "Recompute paragraph-spacing pixel heights after a text-scale change.
Advises `text-scale-mode'; stale spacers (sized for the old font) are
cleared, then jit is applied explicitly to the visible range since
merely clearing properties does not itself trigger jit-lock
refontification."
  (when (and (derived-mode-p 'org-mode)
             variable-spacing-ratio)
    (variable-spacing-clear)
    (variable-spacing--refresh-visible)))

;;; Minor mode

;;;###autoload
(define-minor-mode variable-spacing-mode
  "Apply proportional line spacing to Org paragraphs.
Spacing is determined by `variable-spacing-ratio' (set that buffer-locally
before enabling the mode).  Structured elements (code blocks, drawers,
tables, etc.) are left at their natural line height."
  :lighter " VSpac"
  (if variable-spacing-mode
      (progn
        (when (fboundp 'jit-lock-mode) (jit-lock-mode 1))
        (variable-spacing--ensure-jit)
        ;; Defer the initial visible-range refresh so it runs after the
        ;; current hook/command completes and window geometry has settled.
        ;; Calling --refresh-visible synchronously during org-mode-hook
        ;; can produce an unsettled window-end that misses the paragraph
        ;; at point; jit-lock then never re-visits it.
        (let ((buf (current-buffer)))
          (run-with-idle-timer
           0 nil (lambda ()
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (variable-spacing--refresh-visible))))))
        (advice-add 'text-scale-mode :after
                    #'variable-spacing--text-scale-refresh))
    (variable-spacing--disable-jit)
    (variable-spacing-clear)
    (advice-remove 'text-scale-mode
                   #'variable-spacing--text-scale-refresh)))

(provide 'variable-spacing)
;;; variable-spacing.el ends here
