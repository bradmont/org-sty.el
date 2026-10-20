;;; org-footnote-extra.el --- Enhanced footnote placement and rendering -*- lexical-binding: t -*-

;; Author: Brad
;; Version: 0.1.0

;;; Commentary:

;; Extends Org's footnote machinery with a third definition-placement
;; strategy — "right after the paragraph" — alongside Org's built-in
;; document-section and chapter-section modes.
;;
;; PLACEMENT STRATEGY
;; ------------------
;; Org's `org-footnote-section' controls where new definitions go:
;;
;;   "Footnotes"    — collected under a dedicated heading (Org default)
;;   nil            — end of current outline section (before next heading)
;;   "*paragraph*"  — immediately after the paragraph containing the
;;                    reference (this library's extension)
;;
;; Set `org-footnote-section' to "*paragraph*" to activate paragraph
;; placement.  All other values are passed through to Org unchanged.
;;
;; When "*paragraph*" is active, an :around advice on
;; `org-footnote-create-definition' intercepts the call, temporarily
;; binds `org-footnote-section' to nil (so Org's cond takes the local
;; branch), and shadows `org-footnote--goto-local-insertion-point' with
;; `org-footnote-extra--paragraph-insertion-point' via `cl-letf'.  The
;; rest of `org-footnote-create-definition' (blank-line logic, label
;; insertion, return value) runs unmodified.
;;
;; RENDERING  (forthcoming)
;; ------------------------
;; `org-footnote-extra-mode' will eventually also:
;;   - [fn:N] references in body text are rendered as raised, small-caps
;;     markers (hiding the [fn: and ] delimiters) via font-lock display
;;     properties and the `org-footnote-extra-reference' face.
;;   - Apply a dedicated `org-footnote-extra-body' face to definition
;;     paragraphs so they render at a smaller size with single spacing
;;     and justified alignment, distinct from body text.

;;; Code:

(require 'cl-lib)
(require 'org-footnote)
(require 'face-extra)
(require 'variable-spacing)

;;;; ----------------------------------------------------------------
;;;; Group and faces
;;;; ----------------------------------------------------------------

(defgroup org-footnote-extra nil
  "Enhanced footnote placement and rendering for Org mode."
  :group 'org-footnote)

(defface org-footnote-extra-body
  '((t :inherit default))
  "Face for footnote definition paragraphs in `org-footnote-extra-mode'.

Intended to be styled smaller than body text — e.g. 10 pt with single
spacing and justified alignment — so footnote definitions are visually
distinct from main paragraph content.  The default simply inherits
`default' as a neutral starting point; customise to taste."
  :group 'org-footnote-extra)

(defface org-footnote-extra-reference
  '((t :height 1.2))
  "Face for footnote reference markers in body text.

Applied to the label portion of `[fn:N]' references after the `[fn:'
prefix and `]' suffix are hidden via display properties.  Sets the label to 1.2× the inherited (floor) size — the `org-footnote'
remap chains through `text-body', so the effective size is relative to
the floor face, not body text.  Raise 0.5 lifts it to roughly cap-height.  The vertical raise is applied separately as
a `display' \\='(raise 0.7) property.  (`:raise' is not a valid face
attribute; see AGENTS.md for planned face-extra support.)
Inherits color, weight, and family from `org-footnote'."
  :group 'org-footnote-extra)

;;;; ----------------------------------------------------------------
;;;; Paragraph insertion point helpers
;;;; ----------------------------------------------------------------

(defun org-footnote-extra--para-beg (pos)
  "Return the start of the paragraph containing POS.
A paragraph begins on the line following the nearest preceding blank
line, or at `point-min' if none exists."
  (save-excursion
    (goto-char pos)
    (if (re-search-backward "^[ \t]*$" nil t)
        (progn (forward-line 1) (point))
      (point-min))))

(defun org-footnote-extra--prev-ref-label (ref-pos para-beg)
  "Return the label of the footnote reference just before REF-POS.
Searches backward within the paragraph bounded by PARA-BEG.  Returns
nil when REF-POS is the first reference in the paragraph.

Only matches named references `[fn:LABEL]'; anonymous `[fn::]' inline
footnotes are ignored, as are definitions at the start of a line.

When called from `org-footnote-create-definition', REF-POS is the
position just after the newly inserted reference's closing `]', so the
first backward search finds the new reference itself (`match-end' ==
REF-POS).  In that case we search once more to find the actual
preceding reference."
  (save-excursion
    (goto-char ref-pos)
    (when (re-search-backward "\\[fn:\\([-_[:word:]]+\\)\\]" para-beg t)
      (if (= (match-end 0) ref-pos)
          ;; Found the newly inserted reference itself; search again.
          (when (re-search-backward "\\[fn:\\([-_[:word:]]+\\)\\]" para-beg t)
            (match-string 1))
        (match-string 1)))))

(defun org-footnote-extra--goto-para-end ()
  "Move point to the insertion position at the end of the current paragraph.
Stops at the first blank line OR the first heading (`^\\*'), whichever
comes first.  For a blank line, advances one line past it so that
`org-back-over-empty-lines' sees count=1 (no extra \\n inserted).  For
a heading, positions at its start so that `org-back-over-empty-lines'
sees count=0 and inserts the required separator \\n automatically."
  (if (re-search-forward "^[ \t]*$\\|^\\*" nil t)
      (if (eq (char-after (match-beginning 0)) ?*)
          (goto-char (match-beginning 0))   ; heading: sit before it
        (forward-line 1))                   ; blank line: advance past it
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))))

(defun org-footnote-extra--para-end (pos)
  "Return the buffer position of the start of the definitions block for POS.
This is the first line after the paragraph's trailing blank line, or
the heading that immediately follows the paragraph if there is no
blank line.  Used to anchor forward searches for existing definitions."
  (save-excursion
    (goto-char pos)
    (if (re-search-forward "^[ \t]*$\\|^\\*" nil t)
        (if (eq (char-after (match-beginning 0)) ?*)
            (match-beginning 0)
          (progn (forward-line 1) (point)))
      (point-max))))

(defun org-footnote-extra--after-def (label search-from)
  "Return the buffer position just after the definition of LABEL.
Searches forward from SEARCH-FROM for `^[fn:LABEL]', then advances to
the blank line or next definition that ends it, and returns the position
one line past that so that `org-back-over-empty-lines' sees count=1.
Returns nil if the definition is not found."
  (save-excursion
    (goto-char search-from)
    (when (re-search-forward
           (concat "^\\[fn:" (regexp-quote label) "\\]") nil t)
      (if (re-search-forward "^[ \t]*$\\|^\\[fn:" nil t)
          (goto-char (match-beginning 0))
        (goto-char (point-max)))
      (skip-chars-backward " \r\t\n")
      (forward-line 2)  ;; one line to blank, one past it → count=1 on back-over
      (point))))

;;;; ----------------------------------------------------------------
;;;; Paragraph insertion point
;;;; ----------------------------------------------------------------

(defun org-footnote-extra--paragraph-insertion-point ()
  "Position point for a new footnote definition in document order.

Called as a replacement for `org-footnote--goto-local-insertion-point'
inside `org-footnote-create-definition' (which runs inside
`org-with-wide-buffer', so point is at the reference location).

Strategy:
  1. If there is a footnote reference immediately before the new one in
     the same paragraph, insert the new definition right after that
     reference's existing definition — preserving document order even
     when footnotes are added between existing ones.
  2. Otherwise (first reference in the paragraph), insert before any
     existing definitions by positioning at the paragraph's blank line.

In both cases the position is chosen so that `org-back-over-empty-lines'
returns 1 (one blank line seen), suppressing the extra separator `\\n'
that `org-footnote-create-definition' would otherwise prepend."
  (let* ((ref-pos   (point))
         (para-beg  (org-footnote-extra--para-beg ref-pos))
         (prev-label (org-footnote-extra--prev-ref-label ref-pos para-beg)))
    (if prev-label
        ;; Case 1: preceding reference exists — insert after its definition.
        (let* ((para-end (org-footnote-extra--para-end ref-pos))
               (after-def (org-footnote-extra--after-def prev-label para-end)))
          (if after-def
              (goto-char after-def)
            ;; Preceding definition not in buffer yet: fall back to para end.
            (goto-char para-end)))
      ;; Case 2: first reference in paragraph — go to start of definitions block.
      (goto-char ref-pos)
      (org-footnote-extra--goto-para-end))))

;;;; ----------------------------------------------------------------
;;;; Advice on org-footnote-create-definition
;;;; ----------------------------------------------------------------

(defun org-footnote-extra--around-create-definition (orig-fn label)
  "Intercept `org-footnote-create-definition' for the \"*paragraph*\" strategy.

When `org-footnote-section' is \"*paragraph*\", binds it to nil so
Org's internal dispatch takes the local-insertion branch, and shadows
`org-footnote--goto-local-insertion-point' with
`org-footnote-extra--paragraph-insertion-point' for the duration of
the call via `cl-letf'.  All other values of `org-footnote-section'
are passed through to ORIG-FN without modification."
  (if (equal org-footnote-section "*paragraph*")
      (let ((org-footnote-section nil))
        (cl-letf (((symbol-function 'org-footnote--goto-local-insertion-point)
                   #'org-footnote-extra--paragraph-insertion-point))
          (funcall orig-fn label)))
    (funcall orig-fn label)))

;;;; ----------------------------------------------------------------
;;;; Styling — font-lock, spacing, alignment
;;;; ----------------------------------------------------------------

(defvar-local org-footnote-extra--remap-cookie nil
  "Cookie from `face-remap-add-relative' for the `org-footnote' body remap.
Installed by `org-footnote-extra--install-styling' when
`variable-spacing-mode' is already active; removed on mode disable.")

(defvar-local org-footnote-extra--face-extra-cookies nil
  "List of cookies from `face-extra-add-relative' for footnote properties.
Installed by `org-footnote-extra--install-styling'; removed on disable.")

;;;; ----------------------------------------------------------------
;;;; Reference superscript rendering
;;;; ----------------------------------------------------------------

(defconst org-footnote-extra--ref-re
  "\\(\\[fn:\\)\\([-_[:word:]]+\\)\\(\\]\\)"
  "Regexp matching a named footnote reference (not a definition or inline).
Group 1: `[fn:'  — hidden via `display' \"\".
Group 2: the label — displayed with `org-footnote-extra-reference' face.
Group 3: `]'     — hidden via `display' \"\".")

(defconst org-footnote-extra--ref-prop 'org-footnote-extra--ref
  "Marker text-property set on reference spans for cleanup.")

(defun org-footnote-extra--fontify-references (limit)
  "Font-lock matcher: apply superscript display to footnote references.
Searches forward to LIMIT for `org-footnote-extra--ref-re', skipping
any match whose `[' is at the beginning of a line (those are definitions,
not references).  For each reference found, hides the `[fn:' prefix and
`]' suffix via `display' \"\" properties and applies
`org-footnote-extra-reference' face to the label.

Returns t if a match was found (font-lock protocol), nil otherwise.
The match data is left pointing at the full match so the caller can
use `(0 nil)' as a no-op highlighter — all actual highlighting is done
here as a side effect."
  (catch 'found
    (while (re-search-forward org-footnote-extra--ref-re limit t)
      (let ((mbeg (match-beginning 0))
            (pfx-beg  (match-beginning 1)) (pfx-end  (match-end 1))
            (lbl-beg  (match-beginning 2)) (lbl-end  (match-end 2))
            (sfx-beg  (match-beginning 3)) (sfx-end  (match-end 3)))
        ;; Skip definition lines: `[' at column 0 is a definition.
        (unless (= mbeg (line-beginning-position))
          ;; Hide [fn:
          (put-text-property pfx-beg pfx-end 'display "")
          (put-text-property pfx-beg pfx-end org-footnote-extra--ref-prop t)
          ;; Style the label as a superscript.  Use add-face-text-property
          ;; so our face appends to the list rather than replacing it
          ;; (Org's own org-activate-footnote-links also uses add-face-text-property).
          (add-face-text-property lbl-beg lbl-end 'org-footnote-extra-reference)
          ;; `:raise' is not a face attribute — apply it as a display spec.
          (put-text-property lbl-beg lbl-end 'display '(raise 0.3))
          (put-text-property lbl-beg lbl-end org-footnote-extra--ref-prop t)
          ;; Hide ]
          (put-text-property sfx-beg sfx-end 'display "")
          (put-text-property sfx-beg sfx-end org-footnote-extra--ref-prop t)
          ;; Mark multiline just in case a reference ever spans a line.
          (put-text-property mbeg sfx-end 'font-lock-multiline t)
          (throw 'found t))))
    nil))

(defun org-footnote-extra--clear-reference-display (beg end)
  "Remove superscript display properties from reference spans in BEG..END.
Only touches positions marked with `org-footnote-extra--ref-prop' to
avoid disturbing `display' properties set by other packages.
Does not remove `face' properties; those belong to font-lock and will
be cleaned up naturally on the next refontification."
  (with-silent-modifications
    (let ((pos beg))
      (while (< pos end)
        (let ((next (next-single-property-change pos org-footnote-extra--ref-prop
                                                 nil end)))
          (when (get-text-property pos org-footnote-extra--ref-prop)
            (remove-text-properties pos next
                                    (list 'display nil
                                          org-footnote-extra--ref-prop nil
                                          'font-lock-multiline nil)))
          (setq pos (or next end)))))))

(defconst org-footnote-extra--ref-font-lock-keywords
  ;; The matcher function does all the work (display, face, marker properties).
  ;; The highlighter `(0 (progn ... nil))' returns nil so font-lock sets no
  ;; face on the match — the face was already applied inside the matcher.
  `((org-footnote-extra--fontify-references (0 (progn nil))))
  "Font-lock keyword invoking `org-footnote-extra--fontify-references'.
The matcher function applies all display and face properties as side
effects; the `(0 (progn nil))' highlighter is a no-op (returns nil,
so font-lock leaves the face property untouched).")

;;;; ----------------------------------------------------------------
;;;; Definition label styling
;;;; ----------------------------------------------------------------

(defun org-footnote-extra--fontify-definitions (limit)
  "Font-lock matcher: hide `[fn:' and `]' delimiters on definition labels.
Searches forward to LIMIT for `org-footnote-extra--ref-re', firing only
when the match is at the beginning of a line.  Hides the `[fn:' prefix
and `]' suffix via `display' \"\"; the label itself is left unstyled
(inherits `org-footnote' from the definition-body keyword below)."
  (catch 'found
    (while (re-search-forward org-footnote-extra--ref-re limit t)
      (let ((mbeg (match-beginning 0))
            (pfx-beg (match-beginning 1)) (pfx-end (match-end 1))
            (lbl-beg (match-beginning 2)) (lbl-end (match-end 2))
            (sfx-beg (match-beginning 3)) (sfx-end (match-end 3)))
        (when (= mbeg (line-beginning-position))
          (put-text-property pfx-beg pfx-end 'display "")
          (put-text-property pfx-beg pfx-end org-footnote-extra--ref-prop t)
          (put-text-property lbl-beg lbl-end org-footnote-extra--ref-prop t)
          (put-text-property sfx-beg sfx-end 'display ".")
          (put-text-property sfx-beg sfx-end org-footnote-extra--ref-prop t)
          (throw 'found t))))
    nil))

(defconst org-footnote-extra--def-font-lock-keywords
  `((org-footnote-extra--fontify-definitions (0 (progn nil))))
  "Font-lock keyword hiding `[fn:' and `]' delimiters on definition labels.")

;;;; ----------------------------------------------------------------
;;;; Definition body font-lock keyword
;;;; ----------------------------------------------------------------

(defconst org-footnote-extra--font-lock-keywords
  `((,(concat org-footnote-definition-re ".*")
     (0 'org-footnote prepend)))
  "Font-lock keywords stamping `org-footnote' on footnote definition lines.
Matches the label `[fn:N]' plus the rest of the first line.  Uses
`prepend' so `org-footnote' is added to the front of any existing face
list (e.g. `italic' from emphasis markup inside the definition), ensuring
`has-explicit-face-p' always finds it and the stamp pass never overwrites
definition text with `text-body'.")

(defun org-footnote-extra--install-styling ()
  "Install font-lock keywords, face remap, and face-extra properties."
  ;; 1a. Superscript display on reference markers.
  (font-lock-add-keywords nil org-footnote-extra--ref-font-lock-keywords t)
  ;; 1b. Hide [fn: and ] delimiters on definition labels.
  (font-lock-add-keywords nil org-footnote-extra--def-font-lock-keywords t)
  ;; 1c. Stamp org-footnote across entire definition lines.
  (font-lock-add-keywords nil org-footnote-extra--font-lock-keywords t)
  ;; 2. Register org-footnote as a content face buffer-locally so
  ;;    `variable-spacing--has-explicit-face-p' returns t for it and
  ;;    text-body is not stamped over definition text.
  (setq-local variable-spacing-content-faces
              (cons 'org-footnote variable-spacing-content-faces))
  ;; 3. `variable-spacing-mode' installs content-face remaps at enable
  ;;    time, before this mode exists.  Install the (:inherit text-body)
  ;;    remap for org-footnote now so it scales with body text.
  (when (bound-and-true-p variable-spacing-mode)
    (setq org-footnote-extra--remap-cookie
          (face-remap-add-relative 'org-footnote :inherit 'text-body)))
  ;; 4. Single-space definition lines (ratio 1.0) and justify them.
  (setq org-footnote-extra--face-extra-cookies
        (list (face-extra-add-relative 'org-footnote
                                       'variable-spacing-ratio 1.0)
              (face-extra-add-relative 'org-footnote
                                       'text-align 'justify)))
  (font-lock-flush))

(defun org-footnote-extra--uninstall-styling ()
  "Remove font-lock keywords, face remap, and face-extra properties."
  (font-lock-remove-keywords nil org-footnote-extra--ref-font-lock-keywords)
  (font-lock-remove-keywords nil org-footnote-extra--def-font-lock-keywords)
  (org-footnote-extra--clear-reference-display (point-min) (point-max))
  (font-lock-remove-keywords nil org-footnote-extra--font-lock-keywords)
  (setq-local variable-spacing-content-faces
              (delq 'org-footnote variable-spacing-content-faces))
  (when org-footnote-extra--remap-cookie
    (face-remap-remove-relative org-footnote-extra--remap-cookie)
    (setq org-footnote-extra--remap-cookie nil))
  (dolist (cookie org-footnote-extra--face-extra-cookies)
    (face-extra-remove cookie))
  (setq org-footnote-extra--face-extra-cookies nil)
  (font-lock-flush))

;;;; ----------------------------------------------------------------
;;;; Minor mode
;;;; ----------------------------------------------------------------

;;;###autoload
(define-minor-mode org-footnote-extra-mode
  "Enhanced footnote placement and rendering for Org buffers.

When enabled:

PLACEMENT — advises `org-footnote-create-definition' to support the
\"*paragraph*\" placement strategy: set `org-footnote-section' to the
string \"*paragraph*\" and new footnote definitions will be placed
immediately after the paragraph containing their reference, rather than
at the end of the section or under a document-level heading.  The other
two standard strategies (nil and \"Footnotes\") continue to work as
usual.

REFERENCE RENDERING — `[fn:N]' references in body text are displayed
as raised, small superscript markers by hiding the `[fn:' and `]'
delimiters and applying `org-footnote-extra-reference' face to the
label.  The underlying text is unchanged."
  :lighter " FnX"
  (if org-footnote-extra-mode
      (progn
        (advice-add 'org-footnote-create-definition :around
                    #'org-footnote-extra--around-create-definition)
        (org-footnote-extra--install-styling))
    (advice-remove 'org-footnote-create-definition
                   #'org-footnote-extra--around-create-definition)
    (org-footnote-extra--uninstall-styling)))

;;;; ----------------------------------------------------------------
;;;; Sort and migration
;;;; ----------------------------------------------------------------

(defun org-footnote-extra--sort-insertion-point (scan-from insert-before)
  "Position point for a definition insertion.
SCAN-FROM is the first line after the paragraph's blank line: where to
look for any definitions already inserted in this sort pass.
INSERT-BEFORE is where to place the definition when none have been
inserted yet — typically the blank line's own `\\n' so the definition
lands before the trailing blank line rather than after it.

Walks forward from SCAN-FROM over `[fn:]' definition lines only
(blank lines stop the walk — they mark the end of the block) and
positions after the last one found, or at INSERT-BEFORE if none."
  (let ((prev-def-end
         (save-excursion
           (goto-char scan-from)
           (let (last-end)
             (while (looking-at "\\[fn:[-_[:word:]]+\\]")
               (setq last-end (line-beginning-position 2))
               (forward-line 1))
             last-end))))
    (goto-char (or prev-def-end insert-before))))

;;;###autoload
(defun org-footnote-extra--delete-section (name)
  "Delete the outline section with heading NAME and its content.
Unlike `org-footnote--clear-footnote-section', does not recreate the
section afterward.  Does nothing if no heading named NAME exists."
  (org-with-wide-buffer
   (goto-char (point-min))
   (when (re-search-forward
          (format "^\\*+[ \t]+%s[ \t]*$" (regexp-quote name))
          nil t)
     (let ((beg (match-beginning 0)))
       (org-end-of-subtree t t)
       (delete-region beg (point))))))

(defun org-footnote-extra-sort ()
  "Move all footnote definitions to just after their reference paragraphs.

Collects all non-inline definitions in document order, deletes them,
cleans up any now-empty footnote-section heading, and reinserts each
definition immediately after the paragraph containing its reference —
maintaining the order of references within each paragraph.

This is the paragraph-placement equivalent of `org-footnote-sort'.
For a full inline-to-paragraph migration, use `org-footnote-extra-migrate'."
  (interactive)
  (org-preserve-local-variables
   (let* ((references  (org-footnote--collect-references))
          (definitions (org-footnote--collect-definitions 'delete))
          (total        (length (cl-remove-if (lambda (c) (nth 3 c)) references)))
          (count        0))
     ;; Remove any leftover footnote-section heading (empty after deletion).
     ;; When org-footnote-section is "*paragraph*", definitions may have
     ;; come from a "Footnotes" section created by org-footnote-normalize
     ;; during a migrate call — clean that up too.
     (let ((section (cond
                     ((equal org-footnote-section "*paragraph*") "Footnotes")
                     ((and org-footnote-section
                           (not (equal org-footnote-section "*paragraph*")))
                      org-footnote-section))))
       (when section
         (org-footnote-extra--delete-section section)))
     (org-with-wide-buffer
      (let (inserted)
        (dolist (cell references)
          (let ((label  (car cell))
                (refpos (marker-position (nth 1 cell)))
                (inline (nth 3 cell)))
            (unless (or (member label inserted) inline)
              (push label inserted)
              (cl-incf count)
              (message "org-footnote-extra: placing [fn:%s] (%d/%d)…"
                       label count total)
              (goto-char refpos)
              (let* ((scan-from (org-footnote-extra--para-end refpos))
                     ;; Insert before the trailing blank line, not after it.
                     ;; Blank-line case: scan-from follows \n\n (para-end \n
                     ;; + blank \n), so (1- scan-from) is the blank \n.
                     ;; Heading / EOB case: only one \n before scan-from —
                     ;; insert at scan-from (before the heading or at EOB).
                     (insert-before
                      (if (and (> scan-from 1)
                               (eq (char-before scan-from) ?\n)
                               (> (1- scan-from) 0)
                               (eq (char-after (- scan-from 2)) ?\n))
                          (1- scan-from)
                        scan-from)))
                (org-footnote-extra--sort-insertion-point scan-from insert-before)
                (insert (or (cdr (assoc label definitions))
                            (format "[fn:%s] DEFINITION NOT FOUND." label))
                        "\n"))))))))))

;;;###autoload
(defun org-footnote-extra-migrate ()
  "Convert all inline footnotes to numbered paragraph-local definitions.

Runs `org-footnote-normalize' with standard \"Footnotes\" section
placement to assign sequential [fn:N] labels and extract all inline
`[fn::...]' and `[fn:LABEL:...]' definitions, then runs
`org-footnote-extra-sort' to move each definition to immediately after
the paragraph containing its reference."
  (interactive)
  (message "org-footnote-extra: normalizing footnotes…")
  ;; Normalize into a temporary Footnotes section regardless of the
  ;; current org-footnote-section setting (which may be "*paragraph*").
  (let ((org-footnote-section "Footnotes"))
    (org-footnote-normalize))
  (org-footnote-extra-sort)
  (message "org-footnote-extra: done."))

(provide 'org-footnote-extra)
;;; org-footnote-extra.el ends here
