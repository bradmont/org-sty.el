;;; variable-spacing.el --- Variable line spacing via pluggable backends -*- lexical-binding: t -*-

;; Author: Brad
;; Version: 0.3.0

;;; Commentary:

;; `variable-spacing-mode' applies proportional line spacing to faces
;; in a buffer.  Spacing is configured by attaching a ratio to any face
;; via the `variable-spacing-ratio' symbol property:
;;
;;   (put 'text-body 'variable-spacing-ratio 1.5)
;;   (put 'org-quote 'variable-spacing-ratio 1.0)
;;
;; Or using the extended `set-face-attribute' syntax this library
;; provides (the advice strips the key before passing to Emacs):
;;
;;   (set-face-attribute 'text-body nil :variable-spacing-ratio 1.5)
;;
;; After each font-lock fontification cycle two passes run in order:
;;
;;   1. Face-stamp pass (`variable-spacing--after-fontify'): stamps
;;      the `text-body' face onto characters that Org left completely
;;      unstyled (plain paragraph text), so they participate in spacing.
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
;; face naturally render small.  Faces in `variable-spacing-body-faces'
;; receive a buffer-local `(:inherit text-body)' remap so they track
;; the body-text size.

;;; Code:

(require 'cl-lib)
(require 'org)
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

Faces in `variable-spacing-body-faces' receive a buffer-local
`(:inherit text-body)' remap so they track this face's height.

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
  '(;; Heading faces — sized at body scale so they remain visible.
    ;; Their own relative :height multipliers still apply on top of
    ;; text-body, so hierarchy is preserved.
    org-level-1
    org-level-2
    org-level-3
    org-level-4
    org-level-5
    org-level-6
    org-level-7
    org-level-8
    ;; Primitive Emacs emphasis faces — Org's anchor functions apply
    ;; these directly (from org-emphasis-alist), so they need a remap
    ;; rather than a text-property stamp to reach body size.
    bold
    italic
    underline
    ;; Content block faces — quote/verse/code blocks, tables, inline
    ;; markup, links, footnotes, and list terms should all render at
    ;; body size.  org-quote is intentionally included: quote blocks
    ;; default to body size; users who want them smaller can remap
    ;; the face independently.
    org-block
    org-block-begin-line
    org-block-end-line
    org-table
    org-formula
    org-code
    org-verbatim
    org-link
    org-link-id
    org-cite
    org-cite-key
    org-footnote
    org-list-dt
    org-quote
    org-verse)
  "Faces that should render at body-text size in `variable-spacing-mode' buffers.

When the mode is enabled, each face in this list receives a buffer-local
remap via `face-remap-add-relative' that injects `(:inherit text-body)'
into its effective attribute chain.  This overrides the floor height
installed on `default', so these faces render at whatever `:height'
`text-body' carries.

Three populations are covered:

  Heading faces (org-level-1…org-level-8): applied by Org's regexp
  font-lock keywords as `font-lock-face'.  The after-fontify pass skips
  them, so the remap is the only way to lift them above the floor.  Their
  intrinsic relative `:height' multipliers still compose on top of
  text-body, preserving heading hierarchy.

  Primitive emphasis faces (bold, italic, underline): applied directly by
  `org-do-emphasis-faces' as a `face' text property.  The after-fontify
  pass skips them because they are styled.  Without a remap they would
  inherit from `default' and render at floor size.

  Content block / inline markup faces (org-quote, org-block, …): applied
  by Org's anchor functions as a `face' property.  The after-fontify pass
  skips them too.  The remap makes them track text-body by default.
  Each face that Org stamps directly as a text property must be listed
  explicitly — face remapping is not transitive through inheritance, so
  remapping a parent face does not affect faces that merely inherit from
  it in their global definition.

Structural/metadata faces (drawers, property values, keywords, meta-lines)
are intentionally absent — they fall through to the floor.

Only faces that are already loaded (per `facep') at mode-enable time are
remapped; faces loaded later are not affected until the mode is toggled."
  :type '(repeat face)
  :group 'variable-spacing)

;;;; ----------------------------------------------------------------
;;;; Internal state
;;;; ----------------------------------------------------------------

(defconst variable-spacing--prop
  'variable-spacing--spacing
  "Text property sentinel marking spans styled by `variable-spacing-mode'.
Scoped so only our own properties are cleared without affecting others.")

(defvar-local variable-spacing--body-remap-cookies nil
  "List of cookies from `face-remap-add-relative' for `text-body' injection.
Installed on `variable-spacing-mode' enable; removed on disable.")

;;;; ----------------------------------------------------------------
;;;; Pixel-height spacer
;;;; ----------------------------------------------------------------

(defun variable-spacing--spacer (ratio face)
  "Return a `space' display spec for RATIO.
Measures the rendered height of FACE via `face-font' rather than
`font-at', so the result is independent of whatever `face' text
properties may (or may not) be set elsewhere."
  (let* ((ratio (or ratio 1.5))
         (win (get-buffer-window (current-buffer) t))
         (height
          (or (when (window-live-p win)
                (condition-case nil
                    (let* ((font (face-font face (window-frame win)))
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

  2. Each face in `variable-spacing-body-faces' receives a
     `(:inherit text-body)' remap so it tracks `text-body' for sizing.
     The `facep' guard is omitted: faces not yet defined at enable time
     (e.g. `org-cite' from oc.el, which loads lazily) still get a remap
     entry that takes effect when the face is first used for display.

All remaps are buffer-local; cookies are stored in
`variable-spacing--body-remap-cookies' for clean removal."
  (setq variable-spacing--body-remap-cookies nil)
  ;; 1. Floor on default.
  (push (face-remap-add-relative 'default :height variable-spacing-floor-height)
        variable-spacing--body-remap-cookies)
  ;; 2. Body-size injection for curated content faces.
  (dolist (face variable-spacing-body-faces)
    (push (face-remap-add-relative face :inherit 'text-body)
          variable-spacing--body-remap-cookies)))

(defun variable-spacing--remove-body-remaps ()
  "Remove all buffer-local face remaps installed on `variable-spacing-mode' enable."
  (dolist (cookie variable-spacing--body-remap-cookies)
    (face-remap-remove-relative cookie))
  (setq variable-spacing--body-remap-cookies nil))

;;;; ----------------------------------------------------------------
;;;; After-fontify pass — stamp text-body on Org-unstyled characters
;;;; ----------------------------------------------------------------

(defun variable-spacing--after-fontify (beg end &optional _loudly)
  "Stamp `text-body' on characters in BEG..END that Org left unstyled.
Advises `font-lock-fontify-keywords-region' with :after.  Runs only
in buffers where `variable-spacing-mode' is active.

After Org's full keyword list runs for a jit-lock chunk two categories
of characters exist:

  Styled   — Org set a `face' text property (anchor functions: blocks,
              emphasis, links) or a `font-lock-face' property (regexp
              keywords: headlines, tables, TODO keywords).

  Unstyled — neither property is set.  This is plain paragraph text
              that Org intentionally leaves bare.

This function stamps `text-body' on the unstyled characters so they
render at body-text size rather than falling through to the floor
height of `default'.

Bare newlines are excluded: a \\n with `text-body' would inflate the
line height for blank lines and for small structural lines that contain
only a newline.  Each unstyled span is walked with
`skip-chars-forward' to stamp only non-newline runs.

Stale stamps from a previous fontification cycle are cleared first,
so that spans which have since acquired an Org face (e.g. a quote
block that was just typed) do not retain a stale `text-body' stamp
alongside their Org face."
  (when (bound-and-true-p variable-spacing-mode)
    (with-silent-modifications
      ;; 1. Clear stale text-body stamps so newly Org-styled text is clean.
      (variable-spacing--remove-body-face beg end)
      ;; 2. Re-stamp on truly unstyled, non-newline runs.
      (let ((pos beg))
        (while (< pos end)
          (let* ((next-face    (next-single-property-change
                                pos 'face nil end))
                 (next-fl-face (next-single-property-change
                                pos 'font-lock-face nil end))
                 ;; Advance to whichever face boundary comes first.
                 (next         (min (or next-face end)
                                    (or next-fl-face end))))
            (when (and (null (get-text-property pos 'face))
                       (null (get-text-property pos 'font-lock-face)))
              ;; Unstyled span: stamp text-body on non-newline runs only.
              (save-excursion
                (goto-char pos)
                (while (< (point) next)
                  (let ((run-start (point)))
                    (skip-chars-forward "^\n" next)
                    (when (> (point) run-start)
                      (add-face-text-property run-start (point) 'text-body t))
                    (when (and (< (point) next) (= (char-after) ?\n))
                      (forward-char 1)))))) ; end save-excursion / when unstyled
            (setq pos next)))))))           ; end let* / while / let

(defun variable-spacing--enable-after-fontify-advice ()
  "Add `variable-spacing--after-fontify' as :after advice on fontification.
Advises `font-lock-fontify-keywords-region', which is called by
`font-lock-default-fontify-region' with the already-extended
\[fstart, fend] bounds — the same range jit-lock marks as clean.
Advising this inner function rather than `font-lock-fontify-region'
ensures our stamp pass covers exactly the text that was fontified,
including any region extended by `font-lock-extend-region-functions'.
Safe to call multiple times; `advice-add' is idempotent."
  (advice-add 'font-lock-fontify-keywords-region :after
              #'variable-spacing--after-fontify))

(defun variable-spacing--disable-after-fontify-advice ()
  "Remove the after-fontify advice when no other buffer still has the mode on."
  (unless (cl-some (lambda (buf)
                     (and (not (eq buf (current-buffer)))
                          (buffer-local-value 'variable-spacing-mode buf)))
                   (buffer-list))
    (advice-remove 'font-lock-fontify-keywords-region
                   #'variable-spacing--after-fontify)))

;;;; ----------------------------------------------------------------
;;;; Face-derived spacing pass
;;;; ----------------------------------------------------------------

(defun variable-spacing--face-with-ratio (face)
  "Return the first face in FACE that has a `variable-spacing-ratio' property.
FACE may be a symbol or a list of face symbols as stored in the `face'
or `font-lock-face' text property.  Returns the face symbol whose
`variable-spacing-ratio' symbol property is non-nil, or nil if none."
  (cond
   ((null face) nil)
   ((symbolp face)
    (and (get face 'variable-spacing-ratio) face))
   ((listp face)
    (cl-some (lambda (f)
               (and (symbolp f) (get f 'variable-spacing-ratio) f))
             face))
   (t nil)))

(defun variable-spacing--spacing-pass (beg end &optional _loudly)
  "Apply face-derived line spacing over BEG..END after fontification.
Advises `font-lock-fontify-keywords-region' with :after.  Runs only
in buffers where `variable-spacing-mode' is active.

Walks BEG..END span-by-span (using the minimum of the next `face' and
`font-lock-face' property change boundaries).  For each span, looks up
`variable-spacing-ratio' on the active face via
`variable-spacing--face-with-ratio'.  If a ratio is found, applies
`line-prefix', `wrap-prefix', and the sentinel `variable-spacing--prop'
text properties.  Stale spacing from a previous cycle is cleared first."
  (when (bound-and-true-p variable-spacing-mode)
    (with-silent-modifications
      (variable-spacing-clear beg end)
      (let ((pos beg))
        (while (< pos end)
          (let* ((next-face    (next-single-property-change pos 'face nil end))
                 (next-fl-face (next-single-property-change
                                pos 'font-lock-face nil end))
                 (next         (min (or next-face end) (or next-fl-face end)))
                 (f            (or (get-text-property pos 'face)
                                   (get-text-property pos 'font-lock-face)))
                 (ratio-face   (variable-spacing--face-with-ratio f))
                 (ratio        (and ratio-face
                                    (get ratio-face 'variable-spacing-ratio))))
            (when (and ratio (numberp ratio) (> ratio 0))
              (let ((spacer (variable-spacing--spacer ratio ratio-face)))
                (put-text-property pos next 'line-prefix spacer)
                (put-text-property pos next 'wrap-prefix spacer)
                (put-text-property pos next variable-spacing--prop t)))
            (setq pos next)))))))

(defun variable-spacing--enable-spacing-advice ()
  "Add `variable-spacing--spacing-pass' as :after advice on fontification.
Advises `font-lock-fontify-keywords-region'.  Must be added after
`variable-spacing--enable-after-fontify-advice' so that face stamps
are in place when the spacing pass runs.  Idempotent."
  (advice-add 'font-lock-fontify-keywords-region :after
              #'variable-spacing--spacing-pass))

(defun variable-spacing--disable-spacing-advice ()
  "Remove the spacing-pass advice when no other buffer still has the mode on."
  (unless (cl-some (lambda (buf)
                     (and (not (eq buf (current-buffer)))
                          (buffer-local-value 'variable-spacing-mode buf)))
                   (buffer-list))
    (advice-remove 'font-lock-fontify-keywords-region
                   #'variable-spacing--spacing-pass)))

;;;; ----------------------------------------------------------------
;;;; set-face-attribute advice — :variable-spacing-ratio interception
;;;; ----------------------------------------------------------------

(defun variable-spacing--set-face-attribute-advice (orig face frame &rest args)
  "Intercept `set-face-attribute' calls that include `:variable-spacing-ratio'.
Stores the ratio via `put' and triggers a full spacing refresh in every
buffer where `variable-spacing-mode' is active, then calls ORIG with
the remaining standard face attributes (`:variable-spacing-ratio'
stripped out, since `set-face-attribute' would error on an unknown key)."
  (let ((ratio (plist-get args :variable-spacing-ratio))
        (rest  (cl-loop for (k v) on args by #'cddr
                        unless (eq k :variable-spacing-ratio)
                        append (list k v))))
    (when ratio
      (put face 'variable-spacing-ratio ratio)
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (bound-and-true-p variable-spacing-mode)
            (variable-spacing-clear)
            (font-lock-flush)))))
    (apply orig face frame rest)))

(defun variable-spacing--enable-face-attr-advice ()
  "Add `:variable-spacing-ratio' interception to `set-face-attribute'.
Idempotent."
  (advice-add 'set-face-attribute :around
              #'variable-spacing--set-face-attribute-advice))

(defun variable-spacing--disable-face-attr-advice ()
  "Remove the `set-face-attribute' advice when no buffer has the mode on."
  (unless (cl-some (lambda (buf)
                     (and (not (eq buf (current-buffer)))
                          (buffer-local-value 'variable-spacing-mode buf)))
                   (buffer-list))
    (advice-remove 'set-face-attribute
                   #'variable-spacing--set-face-attribute-advice)))

;;;; ----------------------------------------------------------------
;;;; text-scale-mode advice / text-body face-change hook
;;;; ----------------------------------------------------------------

(defun variable-spacing--text-scale-refresh (&rest _)
  "Recompute spacing after a text-scale change.
Advises `text-scale-mode'.  Clears stale pixel spacers and flushes
font-lock so the spacing pass recomputes them at the new scale."
  (when (bound-and-true-p variable-spacing-mode)
    (variable-spacing-clear)
    (font-lock-flush)))

(defun variable-spacing--text-body-face-refresh (face &rest _)
  "Flush spacing in `variable-spacing-mode' buffers when FACE is `text-body'.
Advises `set-face-attribute' with :after (fires after the :around advice).
Spacers are pixel values baked at fontification time; changing `text-body'
height leaves them stale unless we flush."
  (when (eq face 'text-body)
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

Spacing ratios are configured via the `variable-spacing-ratio' symbol
property on any face:

  (put \\='text-body \\='variable-spacing-ratio 1.5)

Or via the extended `set-face-attribute' syntax:

  (set-face-attribute \\='text-body nil :variable-spacing-ratio 1.5)

After each font-lock cycle two passes run: a face-stamp pass stamps
`text-body' on unstyled characters, and a spacing pass applies pixel
spacers to all characters whose active face carries a ratio."
  :lighter " VSpac"
  (if variable-spacing-mode
      (progn
        (variable-spacing--install-body-remaps)
        ;; Face-stamping pass must be added first so spacing pass
        ;; (added second) sees the stamped faces.
        (variable-spacing--enable-after-fontify-advice)
        (variable-spacing--enable-spacing-advice)
        (variable-spacing--enable-face-attr-advice)
        (advice-add 'text-scale-mode :after
                    #'variable-spacing--text-scale-refresh)
        (advice-add 'set-face-attribute :after
                    #'variable-spacing--text-body-face-refresh)
        ;; Flush to trigger both passes on already-fontified text.
        (font-lock-flush))
    (variable-spacing--remove-body-remaps)
    (variable-spacing-clear)
    (variable-spacing--remove-body-face (point-min) (point-max))
    (advice-remove 'text-scale-mode
                   #'variable-spacing--text-scale-refresh)
    (advice-remove 'set-face-attribute
                   #'variable-spacing--text-body-face-refresh)
    (variable-spacing--disable-after-fontify-advice)
    (variable-spacing--disable-spacing-advice)
    (variable-spacing--disable-face-attr-advice)))

(provide 'variable-spacing)
;;; variable-spacing.el ends here
