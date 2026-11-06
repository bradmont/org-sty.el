;;; variable-spacing.el --- Variable line spacing via pluggable backends -*- lexical-binding: t -*-

;; Author: Brad
;; Keywords: faces, display, wp
;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1") (cl-lib "0.5") (org "9.5") (body-face "0.1.0"))
;; URL: https://github.com/braddelong/org-sty

;;; Commentary:

;; `variable-spacing-mode' applies proportional line spacing to faces
;; in a buffer.  Spacing is configured by attaching a ratio to any face
;; via the `variable-spacing-ratio' symbol property:
;;
;;   (put 'body 'variable-spacing-ratio 1.5)
;;   (put 'org-quote 'variable-spacing-ratio 1.0)
;;
;; Or using the extended `set-face-attribute' syntax this library
;; provides (the advice strips the key before passing to Emacs):
;;
;;   (set-face-attribute 'body nil :variable-spacing-ratio 1.5)
;;
;; After each font-lock fontification cycle two passes run in order:
;;
;;   1. Add-face pass (`variable-spacing--after-fontify'): adds the
;;      `body' face to characters that Org left completely unstyled
;;      (plain paragraph text), so they participate in spacing.
;;
;;   2. Spacing pass (`variable-spacing--spacing-pass'): walks the
;;      fontified region, reads the active face at each span, looks up
;;      `variable-spacing-ratio' on that face, and applies pixel-height
;;      `line-prefix'/`wrap-prefix' spacers accordingly.
;;
;; Both passes advise `font-lock-fontify-keywords-region' with :after,
;; so they see the fully-extended fontification bounds and run after
;; all Org face assignments are complete.
;;
;; The `default' face is remapped buffer-locally to a small floor height
;; (`variable-spacing-floor-height') so that structural/metadata
;; elements (drawers, keywords, property values) that carry no explicit
;; face naturally render small.  Content and metadata face remaps
;; (`(:inherit body)' and `(:inherit default)') are managed by
;; `body-face-mode', which `variable-spacing-mode' enables as a
;; dependency.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'face-remap)
(require 'body-face)

;;;; ----------------------------------------------------------------
;;;; User options
;;;; ----------------------------------------------------------------

(defgroup variable-spacing nil
  "Variable line spacing via pluggable backends."
  :group 'display)

;; `body' face is defined in face-extra.el (Section 4b).

(defface variable-spacing--default
  '((t :inherit default))
  "Internal face for unstyled gaps left by Org's font-lock keywords.

Org's property-line keyword covers only the :KEY: and VALUE subgroups
of `org-property-re', leaving the whitespace between them — and any
trailing whitespace after the value — with no face at all.  Without
this face those characters would have `body' added by the pass-0
fontifier and rendered at body-text height.

This face inherits `default' so it is floor-sized in
`variable-spacing-mode' and otherwise invisible.  It may be reused
wherever Org leaves other structural whitespace unstyled."
  :group 'variable-spacing)

(defcustom variable-spacing-floor-height 60
  "Buffer-local floor `:height' applied to `default' in `variable-spacing-mode'.

In Emacs face-height units (1/10 of a point), so 60 = 6 pt.  When
`variable-spacing-mode' is enabled this value is installed via
`face-remap-add-relative' on `default', making it the minimum rendered
size for any face that does not inherit from `body' or carry its
own explicit `:height'.  This naturally shrinks structural/metadata
elements (drawers, property values, keywords, meta-lines) without
requiring per-face configuration.

The remap is strictly buffer-local and is removed on mode disable."
  :type 'integer
  :group 'variable-spacing)

;; `body-face-org-content-faces', `body-face-org-metadata-faces', and
;; `body-face--org-explicit-face-p' are defined in body-face.el.

;;;; ----------------------------------------------------------------
;;;; Internal state
;;;; ----------------------------------------------------------------

(defconst variable-spacing--prop
  'variable-spacing--spacing
  "Text property sentinel marking spans styled by `variable-spacing-mode'.
Scoped so only our own properties are cleared without affecting others.")

(defvar-local variable-spacing--body-remap-cookies nil
  "List of cookies from `face-remap-add-relative' for body-remap injection.
Installed on `variable-spacing-mode' enable; removed on disable.")

;;;; ----------------------------------------------------------------
;;;; Pixel-height spacer
;;;; ----------------------------------------------------------------

(defun variable-spacing--spacer (ratio face)
  "Return a `space' display spec for RATIO.
Measures the rendered height of FACE in the current buffer via
`face-font' and `font-info'.  This correctly respects the buffer-local
`face-remapping-alist' (e.g. the variable-spacing floor remap on
`default') and works for off-screen content where no live window
exists.  `frame-char-height' is intentionally not used: in WP buffers
it reflects the floor-remapped `default' rather than the body text
height, and would return incorrect results for off-screen content."
  (let* ((ratio  (or ratio 1.5))
         (win    (get-buffer-window (current-buffer) t))
         (f      (if (window-live-p win) (window-frame win) (selected-frame)))
         (font   (face-font face f))
         (fi     (and font (font-info font)))
         (height (if (and (vectorp fi) (> (length fi) 2) (aref fi 2))
                     (aref fi 2)
                   (error "variable-spacing--spacer: \
could not measure font height for face `%s'" face)))
         (px     (max 0 (round (* ratio height)))))
    `(space :width 0 :height (,px))))

;; `body-face-remove-body-face' is in body-face.el.

;;;; ----------------------------------------------------------------
;;;; Public API — clear
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

;; Body remaps, stamp function, and Org backend are in body-face.el.

;;;; ----------------------------------------------------------------
;;;; text-scale-mode advice / body face-change hook
;;;; ----------------------------------------------------------------

(defun variable-spacing--text-scale-refresh (&rest _)
  "Recompute spacing after a text-scale change.
Advises `text-scale-mode'.  Clears stale pixel spacers, invalidates the
face-extra cache (which also runs `face-extra-invalidate-cache-functions'
to clear secondary caches such as the justify char-width cache and ring),
and flushes font-lock so face-extra dispatch recomputes everything at the
new scale."
  (when (bound-and-true-p variable-spacing-mode)
    (variable-spacing-clear)
    (face-extra--invalidate-cache)
    (font-lock-flush)))

(defun variable-spacing--body-face-refresh (face &rest _)
  "Flush spacing in `variable-spacing-mode' buffers when FACE is `body'.
Advises `set-face-attribute' with :after.
Spacers are pixel values baked at fontification time; changing `body'
height leaves them stale unless we flush."
  (when (eq face 'body)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (bound-and-true-p variable-spacing-mode)
          (variable-spacing-clear)
          (font-lock-flush))))))

;;;; ----------------------------------------------------------------
;;;; Minor mode
;;;; ----------------------------------------------------------------

;;;###autoload
(define-minor-mode variable-spacing-mode
  "Apply proportional line spacing to faces in this buffer.

Spacing ratios are configured via the `variable-spacing-ratio' synthetic
face property, set with `face-extra-add-relative' (buffer-local) or
`face-extra-add' (global):

  (face-extra-add \\='body \\='variable-spacing-ratio 1.5)
  (face-extra-add-relative \\='org-quote \\='variable-spacing-ratio 1.0)

After each font-lock cycle `face-extra--dispatch' runs: the Org backend
adds the `body' face to unstyled characters (pass 0), then the spacing
pass (pass 1) applies pixel spacers to all characters whose active face
carries a `variable-spacing-ratio'."
  :lighter " VSpac"
  (if variable-spacing-mode
      (progn
        ;; Floor remap on `default' (spacing concern — stays here).
        ;; Body/metadata face remaps are managed by body-face-mode.
        (setq variable-spacing--body-remap-cookies
              (list (face-remap-add-relative
                     'default :height variable-spacing-floor-height)))
        ;; Enable body-face-mode as a dependency so content/metadata remaps
        ;; and pass-0 body face addition are active.
        (body-face-mode 1)
        ;; Invalidate the face cache so the new buffer-local remaps
        ;; are picked up immediately.
        (face-extra--invalidate-cache)
        (advice-add 'text-scale-mode :after
                    #'variable-spacing--text-scale-refresh)
        (advice-add 'set-face-attribute :after
                    #'variable-spacing--body-face-refresh)
        ;; Cover whitespace gaps that Org's property-line font-lock keyword
        ;; leaves unstyled: the [ \t]+ between :KEY: and VALUE, and any
        ;; trailing [ \t]+ after VALUE.  Without this the pass-0 fontifier
        ;; treats them as bare body text.  `keep' is character-by-character
        ;; so we never clobber anything Org already fontified.
        (font-lock-add-keywords nil
          '(("^[ \t]*:[^:\n]+:\\([ \t]+\\)[^\n]*\\([ \t]+\\)$"
             (1 'variable-spacing--default keep)
             (2 'variable-spacing--default keep))
            ("^[ \t]*:[^:\n]+:\\([ \t]+\\)\\S-"
             (1 'variable-spacing--default keep)))
          t)
        ;; Flush to trigger dispatch on already-fontified text.
        (font-lock-flush))
    (dolist (c variable-spacing--body-remap-cookies)
      (face-remap-remove-relative c))
    (setq variable-spacing--body-remap-cookies nil)
    (variable-spacing-clear)
    (body-face-mode -1)
    (font-lock-remove-keywords nil
      '(("^[ \t]*:[^:\n]+:\\([ \t]+\\)[^\n]*\\([ \t]+\\)$"
         (1 'variable-spacing--default keep)
         (2 'variable-spacing--default keep))
        ("^[ \t]*:[^:\n]+:\\([ \t]+\\)\\S-"
         (1 'variable-spacing--default keep))))
    (advice-remove 'text-scale-mode
                   #'variable-spacing--text-scale-refresh)
    (advice-remove 'set-face-attribute
                   #'variable-spacing--body-face-refresh)))

;;;; ----------------------------------------------------------------
;;;; face-extra registration and apply function
;;;; ----------------------------------------------------------------

(defun variable-spacing--apply-ratio (spans)
  "Apply line-spacing pixel spacers for all SPANS collected by face-extra.

SPANS is a list of (beg end value) triples where VALUE is the
`variable-spacing-ratio' for the face covering BEG..END.  Called
once per dispatch cycle with all collected triples; applies
`line-prefix', `wrap-prefix', and the sentinel
`variable-spacing--prop' text properties.

Stale spacing from a previous cycle is cleared before application.
Only active in buffers where `variable-spacing-mode' is on.

Spacer height measurement uses two paths:

  Explicit ratio — the face at BEG has `variable-spacing-ratio' set
  directly on it (buffer-local via `face-extra-add-relative', level 1;
  or global symbol property via `face-extra-add', level 2).  In this
  case the spacer is measured from that face's own rendered height, so
  a deliberately smaller face (e.g. `org-footnote' at 0.67× body size)
  gets a spacer proportional to its actual glyph height rather than to
  body-text height.

  Inherited ratio — the ratio arrives via the (:inherit body)
  remap chain (headings, inline markup, etc.).  In this case the spacer
  is measured from `body' so that visual rhythm stays consistent
  across all body-sized elements regardless of heading scale.

The cache key is (ratio . measure-face) so the same ratio value at
different face sizes produces distinct spacers."
  ;; Mode guard enforced by dispatcher via :mode 'variable-spacing-mode.
  (with-silent-modifications
      ;; Clear stale spacers for every span first.
      (dolist (span spans)
        (variable-spacing-clear (nth 0 span) (nth 1 span)))
      ;; Apply new spacers.  Cache keyed by (ratio . measure-face).
      (let ((cache nil))
        (dolist (span spans)
          (let* ((beg   (nth 0 span))
                 (end   (nth 1 span))
                 (ratio (nth 2 span)))
            (when (and (numberp ratio) (> ratio 0))
              (let* (;; Primary face at BEG: font-lock-face takes priority
                     ;; (set by Org regexp keywords); fall back to face.
                     (f    (or (get-text-property beg 'font-lock-face)
                               (get-text-property beg 'face)))
                     (face (cond ((symbolp f) f)
                                 ((listp f)   (cl-find-if #'symbolp f))
                                 (t           nil)))
                     ;; Explicit-p: ratio is set directly on this face
                     ;; (level 1 or 2), not only through inheritance.
                     (explicit-p
                      (and face
                           (or (and face-extra--local-properties
                                    (not (eq (gethash (cons face
                                                           'variable-spacing-ratio)
                                                      face-extra--local-properties
                                                      :face-extra-unset)
                                             :face-extra-unset)))
                               (get face 'variable-spacing-ratio))))
                     (measure-face (if explicit-p face 'body))
                     (cache-key    (cons ratio measure-face))
                     (spacer (or (cdr (assoc cache-key cache))
                                 (let ((s (variable-spacing--spacer
                                           ratio measure-face)))
                                   (push (cons cache-key s) cache)
                                   s))))
                (put-text-property beg end 'line-prefix spacer)
                (put-text-property beg end 'wrap-prefix spacer)
                (put-text-property beg end variable-spacing--prop t))))))))

(defun variable-spacing--clear-ratio (_cookie)
  "No-op :clear function for `variable-spacing-ratio' registration.
Called by face-extra when a global (face-extra-add) cookie is removed.
The per-buffer spacer text properties are cleaned up by
`variable-spacing-clear' on mode disable or the next dispatch cycle."
  nil)

;; Register variable-spacing-ratio at load time.
;; Buffer-local lifecycle is managed by face-extra-mode-require/release.
(face-extra-define-property 'variable-spacing-ratio
  :pass  1
  :mode  'variable-spacing-mode
  :after nil
  :apply #'variable-spacing--apply-ratio
  :clear #'variable-spacing--clear-ratio)

;; The Org body-backend is registered at load time in body-face.el.
;; body-face-mode reads it on enable.

(provide 'variable-spacing)
;;; variable-spacing.el ends here
