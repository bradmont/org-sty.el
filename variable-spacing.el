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
(require 'face-extra)

;;;; ----------------------------------------------------------------
;;;; User options
;;;; ----------------------------------------------------------------

(defgroup variable-spacing nil
  "Variable line spacing via pluggable backends."
  :group 'display)

(defface text-body
  '((t :inherit default :height 2.0))
  "Face for word-processor body text in `variable-spacing-mode' buffers.

Faces in `variable-spacing-content-faces' receive a buffer-local
`(:inherit text-body)' remap so they track this face's height.

The `:height 2.0' is a float multiplier relative to `default'.  When
`variable-spacing-mode' is active, `default' is remapped to
`variable-spacing-floor-height' (default 60 = 6 pt), so body text
renders at 2.0 × 6 pt = 12 pt — the same size as the previous absolute
`:height 120'.  Expressing it as a float means `text-scale-mode' works:
its multiplier on `default' propagates through `text-body' to all
content faces.

To change the body size, adjust the ratio:

  (set-face-attribute \\='text-body nil :height 2.2)  ; ~13 pt at 6 pt floor"
  :group 'variable-spacing)

(defface variable-spacing--default
  '((t :inherit default))
  "Internal face for unstyled gaps left by Org's font-lock keywords.

Org's property-line keyword covers only the :KEY: and VALUE subgroups
of `org-property-re', leaving the whitespace between them — and any
trailing whitespace after the value — with no face at all.  Without
this face those characters are stamped `text-body' by the stamp pass
and rendered at body-text height.

This face inherits `default' so it is floor-sized in
`variable-spacing-mode' and otherwise invisible.  It may be reused
wherever Org leaves other structural whitespace unstyled."
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
  '(;; Heading stars — org-hide is applied as a `face' text property by Org.
    org-hide
    ;; Drawer structure.
    org-drawer
    org-special-keyword
    org-property-value
    ;; Internal gap face — whitespace in property lines left unstyled by Org.
    variable-spacing--default
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
;;;; Org backend for face-extra — stamp text-body on bare characters
;;;; ----------------------------------------------------------------

(defun variable-spacing--stamp-body-text (beg end)
  "Stamp `text-body' on characters in BEG..END that Org left unstyled.
This is the :stamp-body-text backend function registered with
`face-extra' for `org-mode'.  Called during pass 0 of each dispatch
cycle, before pass-1 property apply functions run.

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

Newlines are handled within the span pass.  A `\\n' in the middle of
a body-context span is stamped `text-body' along with the rest of that
span.  A `\\n' that opens a body-context span is stamped with the
preceding character's face so it renders at the height of the line it
terminates.

Stale stamps from a previous fontification cycle are cleared first."
  ;; Only stamp in buffers where variable-spacing-mode is active.
  ;; The backend is registered globally (so face-extra knows about it at
  ;; load time) but the stamp must not run in untagged / non-WP buffers:
  ;; without the buffer-local `default' floor remap, text-body's :height 2.0
  ;; multiplies against the normal default size and makes body text huge.
  (when (bound-and-true-p variable-spacing-mode)
  (with-silent-modifications
    ;; 1. Clear stale text-body stamps so newly Org-styled text is clean.
    (variable-spacing--remove-body-face beg end)
    ;; 2. Re-stamp on truly unstyled runs.
    (let ((pos beg))
      (while (< pos end)
        (let* ((next-face    (next-single-property-change pos 'face nil end))
               (next-fl-face (next-single-property-change
                              pos 'font-lock-face nil end))
               (next         (min (or next-face end) (or next-fl-face end))))
          (when (and (null (get-text-property pos 'font-lock-face))
                     (not (variable-spacing--has-explicit-face-p
                           (get-text-property pos 'face))))
            ;; Body-context span: stamp text-body on the whole region.
            ;; Newline at span start: stamp the preceding face on it so
            ;; it renders at the height of the line it terminates.
            ;; Blank lines (\n preceded by \n) are stamped text-body.
            (let ((stamp-start pos))
              (when (and (eq (char-after pos) ?\n)
                         (> pos (point-min))
                         (not (eq (char-before pos) ?\n)))
                (let ((prev-face (or (get-text-property (1- pos) 'face)
                                     (get-text-property (1- pos)
                                                        'font-lock-face))))
                  (when prev-face
                    (add-face-text-property pos (1+ pos) prev-face t)
                    (setq stamp-start (1+ pos)))))
              (when (< stamp-start next)
                (add-face-text-property stamp-start next 'text-body t))))
          (setq pos next)))))))

(defvar variable-spacing-org-backend
  (list :stamp-body-text #'variable-spacing--stamp-body-text)
  "face-extra backend plist for `org-mode'.

Supplies :stamp-body-text — the pass-0 bare-text stamper that marks
unstyled paragraph text with the `text-body' face so it participates
in variable spacing.")

;;;; ----------------------------------------------------------------
;;;; text-scale-mode advice / text-body face-change hook
;;;; ----------------------------------------------------------------

(defun variable-spacing--text-scale-refresh (&rest _)
  "Recompute spacing after a text-scale change.
Advises `text-scale-mode'.  Clears stale pixel spacers and flushes
font-lock so face-extra dispatch recomputes them at the new scale."
  (when (bound-and-true-p variable-spacing-mode)
    (variable-spacing-clear)
    (font-lock-flush)))

(defun variable-spacing--text-body-face-refresh (face &rest _)
  "Flush spacing in `variable-spacing-mode' buffers when FACE is `text-body'.
Advises `set-face-attribute' with :after.
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

Spacing ratios are configured via the `variable-spacing-ratio' synthetic
face property, set with `face-extra-add-relative' (buffer-local) or
`face-extra-add' (global):

  (face-extra-add \\='text-body \\='variable-spacing-ratio 1.5)
  (face-extra-add-relative \\='org-quote \\='variable-spacing-ratio 1.0)

After each font-lock cycle `face-extra--dispatch' runs: the Org backend
stamps `text-body' on unstyled characters (pass 0), then the spacing
pass (pass 1) applies pixel spacers to all characters whose active face
carries a `variable-spacing-ratio'."
  :lighter " VSpac"
  (if variable-spacing-mode
      (progn
        (variable-spacing--install-body-remaps)
        ;; face-extra owns the dispatch loop; just enable it.
        (face-extra--enable-dispatch)
        ;; Invalidate the face cache so the new buffer-local properties
        ;; (from install-body-remaps) are picked up immediately.
        (face-extra--invalidate-cache)
        (advice-add 'text-scale-mode :after
                    #'variable-spacing--text-scale-refresh)
        (advice-add 'set-face-attribute :after
                    #'variable-spacing--text-body-face-refresh)
        ;; Cover whitespace gaps that Org's property-line font-lock keyword
        ;; leaves unstyled: the [ \t]+ between :KEY: and VALUE, and any
        ;; trailing [ \t]+ after VALUE.  Without this the stamp pass treats
        ;; them as bare body text.  `keep' is character-by-character so we
        ;; never clobber anything Org already stamped.
        (font-lock-add-keywords nil
          '(("^[ \t]*:[^:\n]+:\\([ \t]+\\)[^\n]*\\([ \t]+\\)$"
             (1 'variable-spacing--default keep)
             (2 'variable-spacing--default keep))
            ("^[ \t]*:[^:\n]+:\\([ \t]+\\)\\S-"
             (1 'variable-spacing--default keep)))
          t)
        ;; Flush to trigger dispatch on already-fontified text.
        (font-lock-flush))
    (variable-spacing--remove-body-remaps)
    (variable-spacing-clear)
    (variable-spacing--remove-body-face (point-min) (point-max))
    (font-lock-remove-keywords nil
      '(("^[ \t]*:[^:\n]+:\\([ \t]+\\)[^\n]*\\([ \t]+\\)$"
         (1 'variable-spacing--default keep)
         (2 'variable-spacing--default keep))
        ("^[ \t]*:[^:\n]+:\\([ \t]+\\)\\S-"
         (1 'variable-spacing--default keep))))
    (advice-remove 'text-scale-mode
                   #'variable-spacing--text-scale-refresh)
    (advice-remove 'set-face-attribute
                   #'variable-spacing--text-body-face-refresh)
    ;; Remove dispatch advice only if no other buffer still needs it.
    (face-extra--disable-dispatch)))

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

The spacer pixel height is always measured from `text-body', not from
the face at each span position.  In the old spacing pass the ratio was
only ever set directly on `text-body', so measurement was always from
`text-body'.  In the new dispatch, content faces like `org-level-1'
and `org-cite' pick up the ratio via (:inherit text-body) remap
chains, but the spacer should still reflect the canonical body-text
line height so that visual rhythm is consistent across all elements."
  (when (bound-and-true-p variable-spacing-mode)
    (with-silent-modifications
      ;; Clear stale spacers for every span first.
      (dolist (span spans)
        (variable-spacing-clear (nth 0 span) (nth 1 span)))
      ;; Apply new spacers, always measuring height from `text-body'.
      ;; Cache the spacer per distinct ratio to avoid redundant font queries.
      (let ((cache nil))
        (dolist (span spans)
          (let ((beg   (nth 0 span))
                (end   (nth 1 span))
                (ratio (nth 2 span)))
            (when (and (numberp ratio) (> ratio 0))
              (let ((spacer (or (cdr (assoc ratio cache))
                                (let ((s (variable-spacing--spacer
                                          ratio 'text-body)))
                                  (push (cons ratio s) cache)
                                  s))))
                (put-text-property beg end 'line-prefix spacer)
                (put-text-property beg end 'wrap-prefix spacer)
                (put-text-property beg end variable-spacing--prop t)))))))))

(defun variable-spacing--clear-ratio (_cookie)
  "No-op :clear function for `variable-spacing-ratio' registration.
Called by face-extra when a global (face-extra-add) cookie is removed.
The per-buffer spacer text properties are cleaned up by
`variable-spacing-clear' on mode disable or the next dispatch cycle."
  nil)

(face-extra-define-property 'variable-spacing-ratio
  :pass  1
  :after nil
  :apply #'variable-spacing--apply-ratio
  :clear #'variable-spacing--clear-ratio)

;; Register the Org backend so face-extra's pass-0 bare-text stamper
;; activates in org-mode buffers where variable-spacing-mode is on.
(face-extra-register-backend 'org-mode variable-spacing-org-backend)

(provide 'variable-spacing)
;;; variable-spacing.el ends here
