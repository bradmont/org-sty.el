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
(require 'face-remap)

;;;; ----------------------------------------------------------------
;;;; User options
;;;; ----------------------------------------------------------------

(defgroup variable-spacing nil
  "Variable line spacing via pluggable backends."
  :group 'display)

(defface text-body
  '((t :inherit default :height 120))
  "Face for word-processor body text in `variable-spacing-mode' buffers.

Two mechanisms make this the sizing root for body content:

  1. `variable-spacing--put' stamps it as a `face' property over every
     region that receives a line-spacing ratio (typically paragraphs).

  2. On mode enable, `variable-spacing--install-body-remaps' adds a
     buffer-local `face-remap-add-relative' entry injecting
     `(:inherit text-body)' for each face in
     `variable-spacing-body-faces' (curated Org content faces).

Meanwhile `default' is remapped buffer-locally to the small floor
height (`variable-spacing-floor-height'), so structural/metadata
elements such as drawers and keywords naturally render small without
any per-face configuration.

Set the body height globally once:

  (set-face-attribute \\='text-body nil :height 110)

The `defface' defaults to `:height 120' (12 pt at standard DPI), which
can be overridden via `set-face-attribute' or Customize."
  :group 'variable-spacing)

(defcustom variable-spacing-floor-height 60
  "Buffer-local floor `:height' applied to `default' in `variable-spacing-mode'.

In Emacs face-height units (1/10 of a point), so 60 = 6 pt.  When
`variable-spacing-mode' is enabled this value is installed via
`face-remap-add-relative' on `default', making it the minimum rendered
size for any face that does not inherit from `text-body' or carry its
own explicit `:height'.  This naturally shrinks structural/metadata
elements (drawers, property values, keywords, meta-lines) without
requiring per-face configuration.

The remap is strictly buffer-local and is removed on mode disable."
  :type 'integer
  :group 'variable-spacing)

(defcustom variable-spacing-body-faces
  '(org-block
    org-block-begin-line
    org-block-end-line
    org-table
    org-formula
    org-code
    org-verbatim
    org-link
    org-footnote
    org-list-dt
    org-quote
    org-verse)
  "Faces that should render at body-text size in `variable-spacing-mode' buffers.

When the mode is enabled, each face in this list receives a
buffer-local remap via `face-remap-add-relative' that injects
`(:inherit text-body)' into its effective attribute chain.  This
overrides the floor height installed on `default', so these faces
render at whatever `:height' `text-body' carries.

Only faces that are already loaded (per `facep') at mode-enable time
are remapped; faces loaded later are not affected until the mode is
toggled.  Structural/metadata faces (drawers, property values, keywords,
meta-lines) are intentionally absent — they fall through to the floor."
  :type '(repeat face)
  :group 'variable-spacing)

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

(defvar-local variable-spacing--body-remap-cookies nil
  "List of cookies from `face-remap-add-relative' for `text-body' injection.
Installed on `variable-spacing-mode' enable; removed on disable.")

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

(defun variable-spacing--org-find-ruled-ancestor (el rules)
  "Return the nearest ancestor of EL whose type is present in RULES, or nil.

Enforces parent-wins semantics when jit-lock starts a fontification
pass mid-block: `org-element-at-point' returns the innermost element
rather than the enclosing block, and without this check the child's
ratio would be applied instead of the block's.

Walks the `:parent' chain from EL upward; returns the first ancestor
element whose type is a key in RULES, or nil if none is found.  The
`:parent' property is populated by the org-element cache (Org 9.5+);
when it is nil the function safely returns nil and the walker falls
back to its normal behaviour."
  (let ((parent (org-element-property :parent el)))
    (while (and parent
                (not (plist-member rules (org-element-type parent))))
      (setq parent (org-element-property :parent parent)))
    (and parent
         (plist-member rules (org-element-type parent))
         parent)))

(defconst variable-spacing-org-backend
  (list :element-at-point    #'variable-spacing--org-element-at-point
        :element-type         #'variable-spacing--org-element-type
        :element-begin        #'variable-spacing--org-element-begin
        :element-end          #'variable-spacing--org-element-end
        :contents-begin       #'variable-spacing--org-contents-begin
        :container-p          #'variable-spacing--org-container-p
        :find-ruled-ancestor  #'variable-spacing--org-find-ruled-ancestor)
  "Variable-spacing backend for Org buffers.
Uses `org-element-at-point' (cache-backed) for element detection.
Registered for `org-mode' in `variable-spacing-mode-backends'.")

;;;; ----------------------------------------------------------------
;;;; Pixel-height spacer
;;;; ----------------------------------------------------------------

(defun variable-spacing--spacer (ratio _pos)
  "Return a `space' display spec for RATIO.
Measures the rendered height of `text-body' via `face-font' rather
than `font-at', so the result is independent of whatever `face' text
properties may (or may not) be set at _POS."
  (let* ((ratio (or ratio 1.5))
         (win (get-buffer-window (current-buffer) t))
         (height
          (or (when (window-live-p win)
                (condition-case nil
                    (let* ((font (face-font 'text-body (window-frame win)))
                           (fi   (and font (font-info font))))
                      (when (and (vectorp fi) (> (length fi) 2) (aref fi 2))
                        (aref fi 2)))
                  (error nil)))
              (frame-char-height)))
         (px (max 0 (round (* ratio height)))))
    `(space :width 0 :height (,px))))

(defun variable-spacing--add-body-face (beg end)
  "Add `text-body' as a low-priority `face' property over BEG..END.
Uses `add-face-text-property' with APPEND=t so that any face already
present at a position (e.g. `org-footnote', `org-cite') remains as the
higher-priority entry and its own appearance is preserved."
  (add-face-text-property beg end 'text-body t))

(defun variable-spacing--remove-body-face (beg end)
  "Remove only `text-body' from the `face' property in BEG..END.
Handles both a singleton symbol and a list, leaving any other faces
(e.g. `org-footnote') intact."
  (let ((pos beg))
    (while (< pos end)
      (let* ((next (or (next-single-property-change pos 'face nil end) end))
             (f    (get-text-property pos 'face)))
        (cond
         ((eq f 'text-body)
          (remove-text-properties pos next '(face nil)))
         ((and (listp f) (memq 'text-body f))
          (let ((trimmed (remq 'text-body f)))
            (if trimmed
                (put-text-property pos next 'face trimmed)
              (remove-text-properties pos next '(face nil))))))
        (setq pos next)))))

(defun variable-spacing--put (ratio beg end)
  "Apply line-spacing for RATIO to BEG..END via text properties.
Adds `text-body' as a low-priority face alongside any face already
present (e.g. `org-footnote', `org-cite') rather than replacing it."
  (when (< beg end)
    (let ((spacer (variable-spacing--spacer ratio beg)))
      (put-text-property beg end 'line-prefix spacer)
      (put-text-property beg end 'wrap-prefix spacer)
      (variable-spacing--add-body-face beg end)
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
                                        'wrap-prefix nil))
          (variable-spacing--remove-body-face pos next))
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
         (fn-at-point     (variable-spacing--backend-get backend :element-at-point))
         (fn-type         (variable-spacing--backend-get backend :element-type))
         (fn-begin        (variable-spacing--backend-get backend :element-begin))
         (fn-end          (variable-spacing--backend-get backend :element-end))
         (fn-contents     (variable-spacing--backend-get backend :contents-begin))
         (fn-container-p  (variable-spacing--backend-get backend :container-p))
         ;; Optional: backends may supply this to enforce parent-wins
         ;; when jit-lock starts mid-block (returns the nearest ancestor
         ;; element whose type is in RULES, or nil).
         (fn-find-ancestor (variable-spacing--backend-get backend :find-ruled-ancestor)))
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
              (let* ((ratio    (plist-get rules type))
                     (ancestor (and fn-find-ancestor
                                    (funcall fn-find-ancestor el rules))))
                (if ancestor
                    ;; A containing block already governs this region
                    ;; (jit-lock started mid-block).  Jump past the
                    ;; ancestor's end without applying the child's ratio.
                    (goto-char (or (funcall fn-end ancestor) (1+ (point))))
                  (when (and (numberp ratio) (> ratio 0))
                    (variable-spacing--put ratio
                                           (max el-beg beg)
                                           (min el-end end)))
                  (goto-char (or el-end (1+ (point)))))))
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
;;;; Buffer-local text-body face injection
;;;; ----------------------------------------------------------------

(defun variable-spacing--install-body-remaps ()
  "Install buffer-local face remaps for the `text-body' floor/body model.

Two things happen:

  1. `default' is remapped with a floor `:height' of
     `variable-spacing-floor-height', so structural/metadata elements
     (drawers, property values, keywords, etc.) render small without
     per-face configuration.

  2. Each face in `variable-spacing-body-faces' that is already loaded
     receives a `(:inherit text-body)' remap, overriding the floor and
     making those faces track `text-body' for sizing.

All remaps are buffer-local; cookies are stored in
`variable-spacing--body-remap-cookies' for clean removal."
  (setq variable-spacing--body-remap-cookies nil)
  ;; 1. Floor on default.
  (push (face-remap-add-relative 'default :height variable-spacing-floor-height)
        variable-spacing--body-remap-cookies)
  ;; 2. Body-size injection for curated content faces.
  (dolist (face variable-spacing-body-faces)
    (when (facep face)
      (push (face-remap-add-relative face :inherit 'text-body)
            variable-spacing--body-remap-cookies))))

(defun variable-spacing--remove-body-remaps ()
  "Remove all buffer-local face remaps installed on `variable-spacing-mode' enable."
  (dolist (cookie variable-spacing--body-remap-cookies)
    (face-remap-remove-relative cookie))
  (setq variable-spacing--body-remap-cookies nil))

;;;; ----------------------------------------------------------------
;;;; Unfontify advice — preserve face stamps through font-lock cycles
;;;; ----------------------------------------------------------------

(defun variable-spacing--around-unfontify (orig beg end)
  "Advise `font-lock-unfontify-region' to preserve `face' `text-body' stamps.

Calls ORIG (the real unfontify function) over BEG..END, then
re-stamps `face' `text-body' on any span marked by our sentinel
property `variable-spacing--prop'.

This is more robust than racing for last place in the jit-lock
function queue: the sentinel is never in any managed-props list, so it
survives unfontify intact and serves as a stable record of what we
own.  The advice runs only in buffers where `variable-spacing-mode' is
active."
  (funcall orig beg end)
  (when (bound-and-true-p variable-spacing-mode)
    (let ((pos beg))
      (while (< pos end)
        (let ((next (or (next-single-property-change
                         pos variable-spacing--prop nil end)
                        end)))
          (when (get-text-property pos variable-spacing--prop)
            (variable-spacing--add-body-face pos next))
          (setq pos next))))))

(defun variable-spacing--enable-unfontify-advice ()
  "Add `variable-spacing--around-unfontify' to `font-lock-unfontify-region'.
Safe to call multiple times; `advice-add' is idempotent for a given
function symbol."
  (advice-add 'font-lock-unfontify-region :around
              #'variable-spacing--around-unfontify))

(defun variable-spacing--disable-unfontify-advice ()
  "Remove the unfontify advice if no other buffer still has the mode on."
  (unless (cl-some (lambda (buf)
                     (and (not (eq buf (current-buffer)))
                          (buffer-local-value 'variable-spacing-mode buf)))
                   (buffer-list))
    (advice-remove 'font-lock-unfontify-region
                   #'variable-spacing--around-unfontify)))

;;;; ----------------------------------------------------------------
;;;; text-scale-mode advice / text-body face-change hook
;;;; ----------------------------------------------------------------

(defun variable-spacing--text-scale-refresh (&rest _)
  "Recompute spacing pixel heights after a text-scale change.
Advises `text-scale-mode'; clears stale spacers then re-applies to the
visible range, since clearing properties alone does not trigger
jit-lock refontification."
  (when (variable-spacing--any-positive-p variable-spacing-rules)
    (variable-spacing-clear)
    (variable-spacing--refresh-visible)))

(defun variable-spacing--text-body-face-refresh (face &rest _)
  "Recompute spacers in `variable-spacing-mode' buffers when FACE is `text-body'.

Advises `set-face-attribute'.  Spacers are pixel values baked in at
fontification time; changing `text-body' height later leaves them
stale unless we clear and re-apply."
  (when (eq face 'text-body)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (bound-and-true-p variable-spacing-mode)
          (variable-spacing-clear)
          (variable-spacing--refresh-visible))))))

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
        (variable-spacing--install-body-remaps)
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
                    #'variable-spacing--text-scale-refresh)
        (advice-add 'set-face-attribute :after
                    #'variable-spacing--text-body-face-refresh)
        (variable-spacing--enable-unfontify-advice))
    (variable-spacing--remove-body-remaps)
    (variable-spacing--disable-jit)
    (variable-spacing-clear)
    (advice-remove 'text-scale-mode
                   #'variable-spacing--text-scale-refresh)
    (advice-remove 'set-face-attribute
                   #'variable-spacing--text-body-face-refresh)
    (variable-spacing--disable-unfontify-advice)))

(provide 'variable-spacing)
;;; variable-spacing.el ends here
