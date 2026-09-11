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
;; face naturally render small.  Faces in `variable-spacing-content-faces'
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

Faces in `variable-spacing-content-faces' receive a buffer-local
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

(defcustom variable-spacing-content-faces
  '(;; Heading faces — sized at body scale.  Their own relative :height
    ;; multipliers compose on top of text-body, preserving hierarchy.
    ;; org-document-title is the face for the rendered title VALUE
    ;; (the text following #+TITLE:).  It is content, not metadata.
    ;; The #+TITLE: keyword tag itself gets org-document-info-keyword,
    ;; which belongs in `variable-spacing-metadata-faces'.
    org-level-1
    org-level-2
    org-level-3
    org-level-4
    org-level-5
    org-level-6
    org-level-7
    org-level-8
    org-document-title
    ;; Block-content faces.  Block delimiter lines (#+begin_/#+end_)
    ;; are metadata and belong in `variable-spacing-metadata-faces'.
    org-block
    org-table
    org-formula
    org-list-dt
    org-quote
    org-verse)
  "Document-content faces that track body-text size in `variable-spacing-mode'.

The content/metadata distinction is functional: content faces cover the
substance of the document (headings, body text, blocks, tables, quotes);
metadata faces cover structural annotations (drawers, keyword tags,
block delimiters).  See `variable-spacing-metadata-faces'.

When the mode is enabled, each face in this list receives a buffer-local
remap via `face-remap-add-relative' that injects `(:inherit text-body)'
into its effective attribute chain, lifting it above the floor height on
`default'.

Inline faces (bold, italic, org-code, org-link, org-cite, org-footnote,
etc.) are intentionally absent: they can appear as the leading face in a
list alongside a structural face (e.g. `(italic org-level-2)'), and a
remap would make body height dominate in that context.  Instead, the
after-fontify pass stamps `text-body' directly on runs that carry no
content or metadata face.

This variable can be set buffer-locally (via `setq-local' in
file-local or dir-local variables) to customise the face treatment for
individual documents — the intended hook for the document portability
feature."
  :type '(repeat face)
  :group 'variable-spacing)

(defcustom variable-spacing-metadata-faces
  '(;; Drawer structure.
    org-drawer
    org-special-keyword
    org-property-value
    ;; Block delimiter lines (#+begin_X / #+end_X).  These are
    ;; structural markers, not block content.
    org-block-begin-line
    org-block-end-line
    ;; File-level keyword lines and their values.
    ;; org-document-info-keyword is the face for keyword tags such as
    ;; #+TITLE: — it is metadata.  org-document-title (the rendered
    ;; title value) is content and belongs in
    ;; `variable-spacing-content-faces'.
    org-meta-line
    org-keyword
    org-document-info-keyword
    org-document-info)
  "Metadata faces exempt from text-body stamping in `variable-spacing-mode'.

Metadata faces cover structural annotations that are not part of the
readable document content: drawers, property blocks, block delimiter
lines, and file-level keyword lines (#+OPTIONS:, #+TITLE: tag, etc.).
They are distinct from content faces (`variable-spacing-content-faces')
which cover headings, blocks, tables, and quotes.

Faces in this list do NOT receive a `(:inherit text-body)' remap.  They
are also excluded from the text-body stamp applied by the after-fontify
pass, so they inherit floor size from the `default' remap regardless of
whether they arrive as `font-lock-face' or `face' text properties.

Like `variable-spacing-content-faces', this variable can be set
buffer-locally for per-document customisation."
  :type '(repeat face)
  :group 'variable-spacing)

;;;; ----------------------------------------------------------------
;;;; Internal state
;;;; ----------------------------------------------------------------

(defconst variable-spacing--prop
  'variable-spacing--spacing
  "Text property sentinel marking spans styled by `variable-spacing-mode'.
Scoped so only our own properties are cleared without affecting others.")

(defun variable-spacing--has-explicit-face-p (face)
  "Return non-nil if FACE contains at least one content or metadata face.
FACE may be a symbol, an anonymous attribute plist such as
`(:strike-through t)', or a list thereof, as stored in the `face' text
property.

A face is explicit if it appears in `variable-spacing-content-faces'
(document content: headings, blocks, tables — receive a text-body remap)
or `variable-spacing-metadata-faces' (document metadata: drawers,
keyword tags, block delimiters — floor-sized, exempt from stamping).

Anonymous plists (cons whose car is a keyword) are never explicit: they
carry only inline display attributes such as `:strike-through' and
contribute no sizing context.

The after-fontify pass stamps `text-body' on characters where this
returns nil and no `font-lock-face' is present.  The blacklist design
means arbitrary faces from Org or font-lock that belong to neither list
— e.g. `font-lock-function-name-face' on footnote labels — are treated
as non-explicit and do not block the stamp."
  (cond
   ((null face) nil)
   ;; Anonymous plist — never explicit.
   ((and (consp face) (keywordp (car face))) nil)
   ((symbolp face)
    (or (memq face variable-spacing-content-faces)
        (memq face variable-spacing-metadata-faces)))
   ((listp face)
    (cl-some (lambda (f)
               (and (symbolp f)
                    (or (memq f variable-spacing-content-faces)
                        (memq f variable-spacing-metadata-faces))))
             face))
   (t nil)))

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
;;;; Symbol-property face remapping (face-remap-extra API)
;;;; ----------------------------------------------------------------

;;;###autoload
(defun variable-spacing-face-remap-add-extra (face property value)
  "Set symbol PROPERTY on FACE to VALUE, returning a cookie for later removal.

Mirrors the `face-remap-add-relative' / `face-remap-remove-relative'
contract for symbol properties (such as `variable-spacing-ratio') that
are not face attributes and cannot be passed to `face-remap-add-relative'.

The returned cookie is an opaque list `(FACE PROPERTY OLD-VALUE)' where
OLD-VALUE is the property's value before this call.  Pass the cookie to
`variable-spacing-face-remap-remove-extra' to restore the previous value
precisely — including restoring nil if the property was previously unset.

Example:

  (let ((cookie (variable-spacing-face-remap-add-extra
                  \\='org-quote \\='variable-spacing-ratio 1.0)))
    ;; … later …
    (variable-spacing-face-remap-remove-extra cookie))"
  (let ((old (get face property)))
    (put face property value)
    (list face property old)))

;;;###autoload
(defun variable-spacing-face-remap-remove-extra (cookie)
  "Restore the symbol property saved by `variable-spacing-face-remap-add-extra'.

COOKIE must be a value previously returned by
`variable-spacing-face-remap-add-extra'.  The property is restored to
the value it held before that call, including nil if it was unset."
  (put (nth 0 cookie) (nth 1 cookie) (nth 2 cookie)))

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

  2. Each face in `variable-spacing-content-faces' receives a
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
  ;; 2. Body-size injection for content faces.
  (dolist (face variable-spacing-content-faces)
    (push (face-remap-add-relative face :inherit 'text-body)
          variable-spacing--body-remap-cookies))
  ;; 3. Anchor metadata faces to `default'.  Some metadata faces
  ;;    (e.g. org-block-begin-line) globally inherit from a content
  ;;    face (org-block) that now has a text-body remap.  Emacs follows
  ;;    buffer-local remaps through inheritance chains, so without an
  ;;    explicit anchor those faces would inherit body size.  Using
  ;;    `(:inherit default)' makes them track `default' semantically —
  ;;    when the floor remap on `default' is in effect they are
  ;;    floor-sized, and they follow `default' if it ever changes.
  (dolist (face variable-spacing-metadata-faces)
    (push (face-remap-add-relative face :inherit 'default)
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
            (when (and (null (get-text-property pos 'font-lock-face))
                       (not (variable-spacing--has-explicit-face-p
                             (get-text-property pos 'face))))
              ;; No font-lock-face and no structural face in the `face'
              ;; property: stamp text-body on non-newline runs.  This
              ;; covers plain paragraph text (face nil), inline emphasis
              ;; (italic, bold, underline), inline Org markup (org-code,
              ;; org-link, org-footnote, org-cite, …), anonymous inline
              ;; attributes ((:strike-through t)), and arbitrary
              ;; font-lock faces applied by Org for syntax colouring
              ;; (e.g. font-lock-function-name-face on footnote labels).
              ;; Characters with a structural face in their list (e.g.
              ;; `(italic org-level-2)') are skipped so the heading face
              ;; supplies the height.
              (save-excursion
                (goto-char pos)
                (while (< (point) next)
                  (let ((run-start (point)))
                    (skip-chars-forward "^\n" next)
                    (when (> (point) run-start)
                      (add-face-text-property run-start (point) 'text-body t))
                    (when (and (< (point) next) (= (char-after) ?\n))
                      (forward-char 1)))))) ; end save-excursion / when no structural face
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
