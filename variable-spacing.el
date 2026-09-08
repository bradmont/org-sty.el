;;; variable-spacing.el --- Variable line spacing via pluggable backends -*- lexical-binding: t -*-

;; Author: Brad
;; Version: 0.3.0

;;; Commentary:

;; `variable-spacing-mode' applies proportional line spacing to
;; elements in a buffer on a per-type basis, using a pluggable backend
;; that supplies element detection and classification.
;;
;; RULES
;;
;; `variable-spacing-rules' is a buffer-local plist mapping element
;; type symbols to numeric ratios (or nil to explicitly exclude):
;;
;;   (setq-local variable-spacing-rules
;;               '(paragraph   1.6
;;                 item        1.2
;;                 quote-block 1.3
;;                 src-block   nil))
;;   (variable-spacing-mode 1)
;;
;; An element type absent from the plist is not spaced directly.
;; Whether its children are visited depends on the backend's
;; :container-p predicate: container types not in the plist are entered
;; transparently; non-container types are jumped past (they cannot hold
;; spaced children).  Any type present in the plist -- even with nil --
;; causes the walker to jump past the whole element without visiting
;; children (parent wins / explicit exclude).
;;
;; BACKENDS
;;
;; A backend is a plist with these keys, each a function:
;;
;;   :element-at-point  ()         -> element (opaque to the caller)
;;   :element-type      (el)       -> type symbol
;;   :element-begin     (el)       -> buffer position
;;   :element-end       (el)       -> buffer position
;;   :contents-begin    (el)       -> buffer position or nil
;;   :container-p       (type)     -> boolean
;;
;; A backend may also carry a :parent key naming another backend plist.
;; `variable-spacing--backend-get' walks the chain; the text backend is
;; the final fallback for any key not found in the chain.
;;
;; Two backends are bundled:
;;
;;   `variable-spacing-text-backend' -- treats each physical line as a
;;     `line' element with no container concept.  Works in any buffer.
;;
;;   `variable-spacing-org-backend'  -- uses the org-element cache to
;;     identify element types.  Active automatically in org-mode buffers.
;;
;; The mode auto-detects the backend from `variable-spacing-mode-backends'
;; using `derived-mode-p', falling back to the text backend.
;;
;; CUSTOM BACKENDS
;;
;; Register a new backend by adding an entry to
;; `variable-spacing-mode-backends' and defining a backend plist.  Use
;; :parent to inherit from an existing backend and override only what
;; differs:
;;
;;   (defconst my-backend
;;     (list :parent variable-spacing-org-backend
;;           :element-type #'my-element-type-fn))
;;
;;   (add-to-list 'variable-spacing-mode-backends
;;                '(my-mode . my-backend))
;;
;; SPACING MECHANISM
;;
;; Spacers are pixel-height `line-prefix'/`wrap-prefix' display
;; properties computed from the live rendered font via `font-at', so
;; they respond correctly to `text-scale-mode'.  Work is done lazily
;; via jit-lock; the initial visible refresh is deferred via
;; `run-with-idle-timer' so window geometry has settled.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'jit-lock)

;;;; ----------------------------------------------------------------
;;;; User options
;;;; ----------------------------------------------------------------

(defgroup variable-spacing nil
  "Variable line spacing via pluggable backends."
  :group 'display)

(defcustom variable-spacing-rules '(paragraph 1.5)
  "Plist mapping element type symbols to line-spacing ratios.

Each key is a type symbol returned by the active backend's
:element-type function.  Each value is a positive number (the ratio to
apply) or nil (explicitly exclude that type and skip its children).

Types absent from the plist are not spaced directly.  The backend's
:container-p predicate determines whether their children are visited."
  :type '(plist :key-type symbol :value-type (choice number (const nil)))
  :group 'variable-spacing)
(make-variable-buffer-local 'variable-spacing-rules)

(defcustom variable-spacing-mode-backends
  '((org-mode . variable-spacing-org-backend))
  "Alist mapping major mode symbols to backend variable names.

When `variable-spacing-mode' is enabled, this list is walked in order
using `derived-mode-p'.  The first matching entry's backend is used.
If no entry matches, `variable-spacing-text-backend' is the fallback.

Values are variable names (symbols) so the backend can be updated
without modifying this alist."
  :type '(alist :key-type symbol :value-type symbol)
  :group 'variable-spacing)

;;;; ----------------------------------------------------------------
;;;; Internal state
;;;; ----------------------------------------------------------------

(defconst variable-spacing--prop
  'variable-spacing--spacing
  "Text property sentinel marking spans styled by `variable-spacing-mode'.
Scoped so only our own properties are cleared without affecting others.")

(defvar-local variable-spacing--jit-installed nil
  "Non-nil when `variable-spacing--jit' is registered with jit-lock.")

(defvar-local variable-spacing-backend nil
  "The active backend plist for this buffer.
Set automatically by `variable-spacing-mode' via
`variable-spacing--detect-backend'.  Can be overridden manually after
enabling the mode.")

;;;; ----------------------------------------------------------------
;;;; Private helpers
;;;; ----------------------------------------------------------------

(defun variable-spacing--any-positive-p (rules)
  "Return non-nil if RULES contains at least one positive numeric ratio."
  (cl-loop for tail on rules by #'cddr
           thereis (let ((v (cadr tail)))
                     (and (numberp v) (> v 0)))))

(defun variable-spacing--backend-get (backend key)
  "Look up KEY in BACKEND, walking the :parent chain.
Falls back to `variable-spacing-text-backend' if the key is not found
anywhere in the chain."
  (or (plist-get backend key)
      (when-let ((parent (plist-get backend :parent)))
        (variable-spacing--backend-get parent key))
      (plist-get variable-spacing-text-backend key)))

(defun variable-spacing--detect-backend ()
  "Return the appropriate backend for the current buffer's major mode.
Walks `variable-spacing-mode-backends' using `derived-mode-p'; falls
back to `variable-spacing-text-backend' if nothing matches."
  (or (cl-loop for entry in variable-spacing-mode-backends
               when (derived-mode-p (car entry))
               return (let ((sym (cdr entry)))
                        (and (boundp sym) (symbol-value sym))))
      variable-spacing-text-backend))

;;;; ----------------------------------------------------------------
;;;; Text backend
;;;; ----------------------------------------------------------------
;;
;; Elements are conses (BEGIN . END) covering exactly one line.
;; There is only one type, `line', and no container concept.

(defun variable-spacing--text-element-at-point ()
  (cons (line-beginning-position)
        (min (line-beginning-position 2) (point-max))))

(defun variable-spacing--text-element-type (_el)   'line)
(defun variable-spacing--text-element-begin (el)   (car el))
(defun variable-spacing--text-element-end (el)     (cdr el))
(defun variable-spacing--text-contents-begin (_el) nil)
(defun variable-spacing--text-container-p (_type)  nil)

(defconst variable-spacing-text-backend
  (list :element-at-point #'variable-spacing--text-element-at-point
        :element-type      #'variable-spacing--text-element-type
        :element-begin     #'variable-spacing--text-element-begin
        :element-end       #'variable-spacing--text-element-end
        :contents-begin    #'variable-spacing--text-contents-begin
        :container-p       #'variable-spacing--text-container-p)
  "Variable-spacing backend that treats each line as a `line' element.
Works in any buffer.  Rules like \\='(line 1.5) apply spacing to every
line.  This is the ultimate fallback when no mode-specific backend
matches, and the end of every backend's :parent chain.")

;;;; ----------------------------------------------------------------
;;;; Org backend
;;;; ----------------------------------------------------------------
;;
;; Uses the org-element cache; does not reparse the buffer.

(defun variable-spacing--org-element-at-point ()
  (org-element-at-point))

(defun variable-spacing--org-element-type (el)
  (org-element-type el))

(defun variable-spacing--org-element-begin (el)
  (org-element-property :begin el))

(defun variable-spacing--org-element-end (el)
  (org-element-property :end el))

(defun variable-spacing--org-contents-begin (el)
  (org-element-property :contents-begin el))

(defconst variable-spacing--org-structural-containers
  '(org-data headline section plain-list item footnote-definition inlinetask)
  "Org element types treated as transparent structural containers by the walker.

These are greater elements that exist purely to wrap other content;
entering them is always correct.  Content and metadata blocks
\(quote-block, center-block, drawer, table, etc.) are intentionally
excluded: they are jumped past by default, and the user opts them in by
adding entries to `variable-spacing-rules'.")

(defun variable-spacing--org-container-p (type)
  (memq type variable-spacing--org-structural-containers))

(defconst variable-spacing-org-backend
  (list :element-at-point #'variable-spacing--org-element-at-point
        :element-type      #'variable-spacing--org-element-type
        :element-begin     #'variable-spacing--org-element-begin
        :element-end       #'variable-spacing--org-element-end
        :contents-begin    #'variable-spacing--org-contents-begin
        :container-p       #'variable-spacing--org-container-p)
  "Variable-spacing backend for Org buffers.
Uses `org-element-at-point' (cache-backed) for element detection.
Registered for `org-mode' in `variable-spacing-mode-backends'.")

;;;; ----------------------------------------------------------------
;;;; Pixel-height spacer
;;;; ----------------------------------------------------------------

(defun variable-spacing--spacer (ratio pos)
  "Return a `space' display spec for RATIO at POS.
Reads the rendered font via `font-at' when the buffer is visible;
falls back to `frame-char-height' otherwise."
  (let* ((ratio (or ratio 1.5))
         (win (get-buffer-window (current-buffer) t))
         (height
          (or (when (window-live-p win)
                (condition-case nil
                    (let* ((font (font-at pos win))
                           (fi   (and font (font-info font))))
                      (when (and (vectorp fi) (> (length fi) 2) (aref fi 2))
                        (aref fi 2)))
                  (error nil)))
              (frame-char-height)))
         (px (max 0 (round (* ratio height)))))
    `(space :width 0 :height (,px))))

(defun variable-spacing--put (ratio beg end)
  "Apply line-spacing for RATIO to BEG..END via text properties."
  (when (< beg end)
    (let ((spacer (variable-spacing--spacer ratio beg)))
      (put-text-property beg end 'line-prefix spacer)
      (put-text-property beg end 'wrap-prefix spacer)
      (put-text-property beg end variable-spacing--prop t))))

;;;; ----------------------------------------------------------------
;;;; Public API — apply / clear
;;;; ----------------------------------------------------------------

;;;###autoload
(defun variable-spacing-clear (&optional beg end)
  "Remove spacing previously applied by `variable-spacing-mode'.
Clears BEG..END (defaults to the whole buffer), or the active region
when called interactively."
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
  "Apply per-type line spacing to buffer elements according to RULES.
RULES defaults to `variable-spacing-rules'; BEG..END defaults to the
whole buffer.

Walks forward using the active backend's :element-at-point function:

  - Type in RULES with positive ratio: apply ratio, jump past element.
  - Type in RULES with nil: jump past element (explicit exclude;
    children are never visited).
  - Type not in RULES, is a container: enter via :contents-begin.
  - Type not in RULES, not a container: jump past.

Widens internally so element boundaries are correct even when called
from jit-lock inside a narrowed buffer.

When called interactively, operates on the active region when present,
otherwise the whole buffer."
  (interactive (list nil
                     (when (use-region-p) (region-beginning))
                     (when (use-region-p) (region-end))))
  (let* ((rules   (or rules variable-spacing-rules))
         (backend variable-spacing-backend)
         (beg     (or beg (point-min)))
         (end     (or end (point-max)))
         ;; Resolve backend functions once up front.
         (fn-at-point    (variable-spacing--backend-get backend :element-at-point))
         (fn-type        (variable-spacing--backend-get backend :element-type))
         (fn-begin       (variable-spacing--backend-get backend :element-begin))
         (fn-end         (variable-spacing--backend-get backend :element-end))
         (fn-contents    (variable-spacing--backend-get backend :contents-begin))
         (fn-container-p (variable-spacing--backend-get backend :container-p)))
    (variable-spacing-clear beg end)
    (save-restriction
      (widen)
      (save-excursion
        (goto-char beg)
        (while (< (point) end)
          (let* ((el     (funcall fn-at-point))
                 (type   (funcall fn-type el))
                 (el-beg (funcall fn-begin el))
                 (el-end (funcall fn-end el)))
            (cond
             ;; Explicit plist entry: apply ratio if positive, always
             ;; jump past (parent wins / explicit exclude).
             ((plist-member rules type)
              (let ((ratio (plist-get rules type)))
                (when (and (numberp ratio) (> ratio 0))
                  (variable-spacing--put ratio
                                         (max el-beg beg)
                                         (min el-end end))))
              (goto-char (or el-end (1+ (point)))))
             ;; Not in plist, is a container: enter transparently.
             ((funcall fn-container-p type)
              (goto-char (max (or (funcall fn-contents el)
                                  el-end
                                  (1+ (point)))
                              (1+ (point)))))
             ;; Not in plist, not a container: jump past.
             (t
              (goto-char (or el-end (1+ (point))))))))))))

;;;; ----------------------------------------------------------------
;;;; jit-lock integration
;;;; ----------------------------------------------------------------

(defun variable-spacing--jit (beg end)
  "jit-lock fontification function; applies spacing over BEG..END."
  (when (variable-spacing--any-positive-p variable-spacing-rules)
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

;;;; ----------------------------------------------------------------
;;;; text-scale-mode advice
;;;; ----------------------------------------------------------------

(defun variable-spacing--text-scale-refresh (&rest _)
  "Recompute spacing pixel heights after a text-scale change.
Advises `text-scale-mode'; clears stale spacers then re-applies to the
visible range, since clearing properties alone does not trigger
jit-lock refontification."
  (when (variable-spacing--any-positive-p variable-spacing-rules)
    (variable-spacing-clear)
    (variable-spacing--refresh-visible)))

;;;; ----------------------------------------------------------------
;;;; Minor mode
;;;; ----------------------------------------------------------------

;;;###autoload
(define-minor-mode variable-spacing-mode
  "Apply per-type proportional line spacing to buffer elements.

The backend is chosen automatically from `variable-spacing-mode-backends'
based on the current major mode; it can be overridden by setting
`variable-spacing-backend' after enabling.

Spacing rules are defined in `variable-spacing-rules' (set that
buffer-locally before enabling).  See its docstring for the plist
format and parent-wins semantics."
  :lighter " VSpac"
  (if variable-spacing-mode
      (progn
        (setq-local variable-spacing-backend
                    (variable-spacing--detect-backend))
        (when (fboundp 'jit-lock-mode) (jit-lock-mode 1))
        (variable-spacing--ensure-jit)
        ;; Defer the initial visible-range refresh so it runs after the
        ;; current hook/command completes and window geometry has settled.
        ;; Calling --refresh-visible synchronously during a mode hook can
        ;; produce an unsettled window-end that misses the element at
        ;; point; jit-lock then never re-visits it.
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
