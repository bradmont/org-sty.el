;;; variable-spacing.el --- Variable line spacing for Org elements -*- lexical-binding: t -*-

;; Author: Brad
;; Version: 0.2.0

;;; Commentary:

;; `variable-spacing-mode' applies proportional line spacing to Org
;; elements on a per-type basis, controlled by `variable-spacing-rules'.
;;
;; `variable-spacing-rules' is a buffer-local plist mapping Org element
;; type symbols to numeric ratios (or nil to explicitly exclude):
;;
;;   (setq-local variable-spacing-rules
;;               '(paragraph   1.6
;;                 item        1.2
;;                 quote-block 1.3
;;                 src-block   nil))
;;   (variable-spacing-mode 1)
;;
;; An element type absent from the plist is treated as nil: no spacing
;; applied to it directly.  Whether its children are visited depends on
;; whether it is a "greater element" (one that can contain other
;; elements): greater elements not in the plist are entered
;; transparently; non-greater elements are jumped past entirely (they
;; cannot contain paragraphs or other spaced types anyway).
;;
;; Parent wins: once a type is present in the plist (even with nil),
;; the walker jumps past the whole element and never visits its
;; children.  A nil-ratio entry is therefore an explicit "exclude this
;; and everything inside it."
;;
;; Spacing is applied lazily via jit-lock.  Spacers are pixel-height
;; `line-prefix'/`wrap-prefix' display properties computed from the
;; live rendered font via `font-at', so they respond correctly to
;; `text-scale-mode'.  The initial visible-range refresh is deferred
;; with `run-with-idle-timer' so window geometry has settled before the
;; first sizing calculation.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'jit-lock)

;;; User option

(defcustom variable-spacing-rules '(paragraph 1.5)
  "Plist mapping Org element type symbols to line-spacing ratios.

Each key is an Org element type symbol (e.g. `paragraph', `item',
`quote-block', `src-block').  Each value is either a positive number
(the ratio to apply to that element type) or nil (explicitly exclude
that type and prevent the walker from visiting its children).

Types absent from this plist are also not spaced directly.  Whether
their children are visited depends on whether the type is a greater
element (see `org-element-greater-elements'): greater elements not in
the plist are entered transparently; non-greater elements (which cannot
contain paragraphs) are jumped past.

Parent wins: any type present in the plist (even with nil) causes the
walker to jump past the whole element, so children never receive rules
from enclosing scopes.

Example:
  \\='(paragraph   1.6
    item        1.2
    quote-block 1.3
    src-block   nil)"
  :type '(plist :key-type symbol :value-type (choice number (const nil)))
  :group 'variable-spacing)
(make-variable-buffer-local 'variable-spacing-rules)

;;; Internal constants

(defconst variable-spacing--prop
  'variable-spacing--paragraph-spacing
  "Text property sentinel marking ranges that received spacing from
`variable-spacing-mode'.  Used to clear only our own properties without
clobbering those set by other packages.")

;;; Internal state

(defvar-local variable-spacing--jit-installed nil
  "Non-nil when `variable-spacing--jit' is registered with jit-lock
in the current buffer.")

;;; Private helpers

(defun variable-spacing--any-positive-p (rules)
  "Return non-nil if RULES contains at least one positive numeric ratio."
  (cl-loop for tail on rules by #'cddr
           thereis (let ((v (cadr tail)))
                     (and (numberp v) (> v 0)))))

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
  "Remove line spacing previously applied by `variable-spacing-mode'.
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
(defun variable-spacing-apply (&optional rules beg end)
  "Apply per-type line spacing to Org elements according to RULES.
RULES defaults to `variable-spacing-rules'.  Operates on BEG..END
\(defaults to the whole buffer).

Walks the buffer using `org-element-at-point' (cache-backed; does not
reparse).  For each element:

  - In RULES with a positive ratio: apply that ratio to the element's
    span then jump past it.
  - In RULES with nil: jump past it without applying spacing; its
    children are never visited (explicit exclude).
  - Not in RULES, a greater element: enter it transparently.
  - Not in RULES, not a greater element: jump past it (leaf-like;
    cannot contain paragraphs or other spaced types).

Widens internally so element boundaries are correct even when called
from jit-lock inside a narrowed buffer.

When called interactively, operates on the active region when present,
otherwise the whole buffer."
  (interactive (list nil
                     (when (use-region-p) (region-beginning))
                     (when (use-region-p) (region-end))))
  (unless (derived-mode-p 'org-mode)
    (user-error "variable-spacing-apply: not in an Org buffer"))
  (let* ((rules (or rules variable-spacing-rules))
         (beg (or beg (point-min)))
         (end (or end (point-max))))
    (variable-spacing-clear beg end)
    (org-with-wide-buffer
     (goto-char beg)
     (while (< (point) end)
       (let* ((el      (org-element-at-point))
              (type    (org-element-type el))
              (el-beg  (org-element-property :begin el))
              (el-end  (org-element-property :end   el)))
         (cond
          ;; Type has an explicit plist entry: apply its ratio if
          ;; positive, then always jump past the whole element.
          ;; Children are never visited (parent wins).
          ((plist-member rules type)
           (let ((ratio (plist-get rules type)))
             (when (and (numberp ratio) (> ratio 0))
               (variable-spacing--put ratio
                                      (max el-beg beg)
                                      (min el-end end))))
           (goto-char (or el-end (1+ (point)))))
          ;; Not in plist, is a greater element: enter it by advancing
          ;; to its contents.  The (max … (1+ (point))) guard ensures
          ;; forward progress if :contents-begin would send us backward.
          ((memq type org-element-greater-elements)
           (goto-char (max (or (org-element-property :contents-begin el)
                               el-end
                               (1+ (point)))
                           (1+ (point)))))
          ;; Not in plist, not a greater element: jump past it.
          ;; These elements cannot contain paragraphs or other spaced
          ;; types, so there is nothing to visit inside them.
          (t
           (goto-char (or el-end (1+ (point)))))))))))

;;; jit-lock integration

(defun variable-spacing--jit (beg end)
  "jit-lock fontification function; applies spacing over BEG..END."
  (when (and (derived-mode-p 'org-mode)
             (variable-spacing--any-positive-p variable-spacing-rules))
    (variable-spacing-apply variable-spacing-rules beg end)))

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
  "Recompute spacing pixel heights after a text-scale change.
Advises `text-scale-mode'; stale spacers (sized for the old font) are
cleared, then jit is applied explicitly to the visible range since
merely clearing properties does not itself trigger jit-lock
refontification."
  (when (and (derived-mode-p 'org-mode)
             (variable-spacing--any-positive-p variable-spacing-rules))
    (variable-spacing-clear)
    (variable-spacing--refresh-visible)))

;;; Minor mode

;;;###autoload
(define-minor-mode variable-spacing-mode
  "Apply per-type proportional line spacing to Org elements.
Spacing rules are defined in `variable-spacing-rules' (set that
buffer-locally before enabling the mode).  See that variable's
docstring for the plist format and parent-wins semantics."
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
