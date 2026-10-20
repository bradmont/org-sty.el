;;; horizontal-layout.el --- Synthetic face properties for horizontal text layout -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: faces, display
;; Version: 0.1.0

;;; Commentary:

;; !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
;; NEVER USE `string-pixel-width' IN THIS FILE.
;;
;; `string-pixel-width' opens a temp buffer and measures using the GLOBAL
;; default face — it does NOT see the buffer-local face-remapping-alist.
;; In WP buffers, variable-spacing-mode remaps faces so body text renders
;; in a completely different font (e.g. Times New Roman) than the global
;; default (e.g. Iosevka Aile).  Any measurement via `string-pixel-width'
;; will be silently wrong, producing inflated or deflated pixel values
;; that corrupt justification, margin, and alignment calculations.
;;
;; ALWAYS measure from a live buffer position using:
;;   (window-text-pixel-size win pos (1+ pos) large-x-limit)
;; or for a range:
;;   (window-text-pixel-size win beg end large-x-limit)
;;
;; These see the actual face-remapping-alist in the current buffer and
;; return the true rendered pixel widths.
;; !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

;; `horizontal-layout' provides synthetic face properties for horizontal
;; text placement, implemented as a face-extra pass-2 plugin.
;;
;; Currently supported properties:
;;
;;   `horizontal-layout-margin-left'
;;     Left indent in pixels.  Applied as `line-prefix'/`wrap-prefix'
;;     display specs on every character of matching spans.
;;
;; Properties are attached to faces via the face-extra API:
;;
;;   ;; Buffer-local (per-document, typical case):
;;   (face-extra-add-relative 'org-quote 'horizontal-layout-margin-left 40)
;;
;;   ;; Global (all buffers):
;;   (face-extra-add 'org-quote 'horizontal-layout-margin-left 40)
;;
;; Or declared in an org-sty style plist under :faces:
;;
;;   :faces ((org-quote . (:horizontal-layout-margin-left 40)))
;;
;; Enable the minor mode to ensure dispatch is active:
;;
;;   (horizontal-layout-mode 1)
;;
;; Or wire it in via org-sty's :eval key.
;;
;; Pass-1/pass-2 composition
;; ─────────────────────────
;; `variable-spacing--apply-ratio' (pass 1) writes `line-prefix' as
;; `(space :width 0 :height (Npx))'.  `horizontal-layout--apply-margin-left'
;; (pass 2) runs after pass 1 is complete (guaranteed by face-extra's pass
;; ordering), reads the existing `:height' from `line-prefix', and writes a
;; composed spec `(space :width Mpx :height (Npx))' that preserves vertical
;; rhythm while adding the horizontal offset.  `horizontal-layout-clear' is
;; the inverse: it strips `:width' and restores the height-only spec, or
;; removes the property entirely if no height component was present.
;;
;; Right margin
;; ────────────
;; Right margin (controlling where word-wrap occurs) requires window-level
;; intervention — Emacs has no `line-suffix' text property.  Per-face right
;; margin via text properties is not feasible; right-side control belongs at
;; the window/frame level (e.g. `olivetti-mode').  Only left margin is
;; implemented here.

;;; Code:

(require 'cl-lib)
(require 'face-extra)


;;;; ================================================================
;;;; Section 1 — Sentinel and internal helpers
;;;; ================================================================

(defconst horizontal-layout--prop 'horizontal-layout--margin
  "Sentinel text property marking spans styled by `horizontal-layout-mode'.
Used by `horizontal-layout-clear' to remove exactly this package's
display properties without disturbing Org's or other packages' uses of
`line-prefix'/`wrap-prefix'.")

(defconst horizontal-layout-suppress-line-prefix 'horizontal-layout-suppress-line-prefix
  "Text property that suppresses `line-prefix' stamping by `margin-left'.
When set at a buffer position, `horizontal-layout--apply-margin-left'
skips the `line-prefix' put for that position while still stamping
`wrap-prefix'.  Set by callers that need the left-margin indent to apply
only to wrapped continuations, not to the first visual line — e.g. the
label line of a footnote definition, where the label glyph sits at
column zero and the body text hangs via the wrap-prefix.")

(defconst horizontal-layout--right-prop 'horizontal-layout--right
  "Overlay property key for right-margin after-string overlays.
Set on overlays created by `horizontal-layout--apply-margin-right-pass3'.
Used by `horizontal-layout-clear' to find and remove these overlays.")

(defun horizontal-layout--compose-prefix (width existing-prefix)
  "Return a display spec combining WIDTH with EXISTING-PREFIX's :height.

WIDTH is the left margin in canonical character widths — a number N
means N times the width of a space character in the current font.  This
unit scales naturally with `text-scale-mode'.

EXISTING-PREFIX is the current `line-prefix' text-property value at a
position — expected to be a `(space ...)' spec written by
`variable-spacing--apply-ratio' in pass 1, or nil if pass 1 did not
run at this position.

If EXISTING-PREFIX carries a `:height' component it is preserved in the
returned spec so that vertical rhythm is not disturbed.  If WIDTH is
0 or nil, returns nil (no prefix needed).

This implements the pass-1/pass-2 composition contract:
  pass 1 writes  (space :width 0  :height (Npx))
  pass 2 returns (space :width W  :height (Npx))  ; height unchanged"
  (when (and (numberp width) (> width 0))
    (let ((height (and (consp existing-prefix)
                       (eq (car existing-prefix) 'space)
                       (plist-get (cdr existing-prefix) :height))))
      (if height
          `(space :width ,width :height ,height)
        `(space :width ,width)))))

(defun horizontal-layout--block-start-p (beg)
  "Return non-nil if BEG is the first content character of a hidden block.

`org-block-appear-mode' hides the #+begin_ delimiter line including its
trailing \\n.  That \\n belongs to the `org-block-begin-line' face span,
not to the content face span, so the content span starts at the first
real content character (BEG).

When that \\n is invisible the screen line technically starts at the
hidden `#' of #+begin_, not at BEG.  BEG is not the screen-line-start
character even though it is the first visible character on the line, so
`line-prefix' on BEG does not fire.  An overlay `before-string' on BEG
fires unconditionally and appears as the leading visible content on that
screen line, providing the desired indent.

Detection: the character immediately before BEG is an invisible \\n."
  (and (> beg (point-min))
       (eq (char-before beg) ?\n)
       (get-text-property (1- beg) 'invisible)))

(defun horizontal-layout--strip-width (prefix)
  "Return PREFIX with the `:width' component zeroed, or nil.

Used by `horizontal-layout-clear' to restore the pass-1 height-only
spacer after removing the horizontal offset.  Returns nil if PREFIX
carries no `:height' (meaning there was no pass-1 spacer to restore)."
  (and (consp prefix)
       (eq (car prefix) 'space)
       (let ((height (plist-get (cdr prefix) :height)))
         (and height `(space :width 0 :height ,height)))))


;;;; ================================================================
;;;; Section 2 — Public clear API
;;;; ================================================================

;;;###autoload
(defun horizontal-layout-clear (&optional beg end)
  "Remove horizontal-layout margin display properties from BEG..END.
Defaults to the whole buffer.  Restores any pass-1 height-only
`line-prefix'/`wrap-prefix' spacer that was present before the margin
was applied; removes the property entirely if no height component was
present."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (let* ((beg (or beg (point-min)))
         (end (or end (point-max)))
         (pos beg))
    (with-silent-modifications
      (while (< pos end)
        (let ((next (or (next-single-property-change
                         pos horizontal-layout--prop nil end)
                        end)))
          (when (get-text-property pos horizontal-layout--prop)
            (let* ((lp       (get-text-property pos 'line-prefix))
                   (restored (horizontal-layout--strip-width lp)))
              (if restored
                  (progn
                    (put-text-property pos next 'line-prefix  restored)
                    (put-text-property pos next 'wrap-prefix  restored))
                (remove-text-properties pos next '(line-prefix nil
                                                   wrap-prefix nil))))
            (remove-text-properties pos next
                                    (list horizontal-layout--prop nil)))
          (setq pos next)))
    ;; Remove block-start indent overlays in the range.
    (dolist (ov (overlays-in beg end))
      (when (overlay-get ov horizontal-layout--prop)
        (delete-overlay ov)))
    ;; Remove right-margin after-string overlays.
    (dolist (ov (overlays-in beg end))
      (when (overlay-get ov horizontal-layout--right-prop)
        (delete-overlay ov))))
  ;; Clear hanging-wrap stamps (separate marker, separate pass).
  (horizontal-layout--clear-hang-region beg end)))


;;;; ================================================================
;;;; Section 3 — Apply and clear callbacks for face-extra
;;;; ================================================================

(defun horizontal-layout--apply-margin-left (spans)
  "Apply left-margin character-width spacers for SPANS collected by face-extra.

SPANS is a list of (beg end value) triples where VALUE is the left
margin width in canonical character widths (N = N × space-char width,
scales with `text-scale-mode').  Called once per dispatch cycle.

Stale margins are cleared before re-application.  For each character
position in a span, the existing `line-prefix' (from pass 1) is read
and its `:height' preserved in the composed spec.  See
`horizontal-layout--compose-prefix'.

Block-start detection: when the character immediately before the span's
BEG is an invisible \\n (hidden by `org-block-appear-mode'), BEG is not
at a screen-line start when the block is hidden, so `line-prefix' on BEG
would not fire.  An overlay `before-string' is used instead: it fires
unconditionally and appears as the leading visible content on the screen
line.  BEG is excluded from the `line-prefix' loop to avoid double-indent
when the block is revealed.  All other characters — including \\n
characters that separate paragraphs within the block — receive
`line-prefix' normally.

Only runs when `horizontal-layout-mode' is active in the current buffer."
  (when (bound-and-true-p horizontal-layout-mode)
    (with-silent-modifications
      ;; Clear stale margins before re-applying.
      (dolist (span spans)
        (horizontal-layout-clear (nth 0 span) (nth 1 span)))
      ;; Apply, composing with any pass-1 line-prefix at each position.
      (dolist (span spans)
        (let ((beg   (nth 0 span))
              (end   (nth 1 span))
              (width (nth 2 span)))
          (when (and (numberp width) (> width 0))
            ;; Detect block-start: the char immediately before beg is an
            ;; invisible \n (hidden by org-block-appear).  In that case beg
            ;; is not at a screen-line start when the block is hidden, so
            ;; line-prefix on beg would not fire.  Use an overlay
            ;; before-string instead: it fires unconditionally and appears
            ;; as the leading visible content on the screen line.  When the
            ;; block is revealed the before-string still fires correctly, so
            ;; we do NOT also set line-prefix on beg (that would
            ;; double-indent when revealed).
            (let ((block-start-p (horizontal-layout--block-start-p beg)))
              (when (and block-start-p (< beg end))
                (let ((ov (make-overlay beg (1+ beg))))
                  (overlay-put ov horizontal-layout--prop t)
                  (overlay-put ov 'before-string
                               (propertize " " 'display
                                           `(space :width ,width)))))
              ;; Walk from beg+1 (block-start) or beg (regular span).
              (let ((pos (if block-start-p (1+ beg) beg)))
                (while (< pos end)
                  (let* ((next     (min end
                                        (or (next-single-property-change
                                             pos 'line-prefix nil end)
                                            end)
                                        ;; Also break at suppress-property
                                        ;; boundaries so the suppress on the
                                        ;; label-line `[' only skips line-prefix
                                        ;; for that one char; subsequent BOLs
                                        ;; (continuation lines) are processed
                                        ;; separately and receive line-prefix.
                                        (or (next-single-property-change
                                             pos
                                             horizontal-layout-suppress-line-prefix
                                             nil end)
                                            end)))
                         (existing (get-text-property pos 'line-prefix))
                         (prefix   (horizontal-layout--compose-prefix
                                    width existing)))
                    (when prefix
                      (unless (get-text-property pos
                                                 horizontal-layout-suppress-line-prefix)
                        (put-text-property pos next 'line-prefix prefix))
                      (put-text-property pos next 'wrap-prefix  prefix)
                      (put-text-property pos next
                                         horizontal-layout--prop t))
                    (setq pos next)))))))))))

(defun horizontal-layout--clear-margin-left (_cookie)
  "No-op `:clear' callback for `horizontal-layout-margin-left'.
Per-buffer text properties are cleaned up by `horizontal-layout-clear'
on mode disable or the next dispatch cycle."
  nil)


;;;; ================================================================
;;;; Section 3a-ii — Hanging wrap (pass 2)
;;;; ================================================================
;;
;; `horizontal-layout-hanging-wrap' sets ONLY `wrap-prefix' (never
;; `line-prefix'), adding the hang width on top of whatever width
;; `margin-left' has already placed in `wrap-prefix'.  The result is:
;;
;;   line-prefix  = (space :width left        :height H)  ; first-line
;;   wrap-prefix  = (space :width left + hang :height H)  ; continuations
;;
;; This produces a hanging indent: the first line of a paragraph starts
;; at `left', while wrapped continuation lines are indented by an
;; additional `hang' character-widths.
;;
;; Typical use — footnote definitions, where the superscript label sits
;; in the `hang' gutter and continuation lines align with the body text:
;;
;;   ¹ First sentence of the footnote, which might
;;     wrap onto this continuation line.
;;
;; The `:clear' callback is a no-op; `horizontal-layout-clear' cleans
;; up via a separate pass over `horizontal-layout--hang-prop' markers.

(defconst horizontal-layout--hang-prop 'horizontal-layout--hang
  "Marker text-property set on positions where a hanging wrap was stamped.
Used by `horizontal-layout-clear' to find and restore those positions.")

(defun horizontal-layout--apply-hanging-wrap (spans)
  "Apply hanging-wrap to SPANS: widen wrap-prefix by VALUE, leave line-prefix.
SPANS is a list of (beg end value) triples where VALUE is the extra
indent width for continuation lines, in canonical character widths.
Runs after `horizontal-layout-margin-left' (pass 2), so `wrap-prefix'
already carries the left-margin width; this adds VALUE on top of it."
  (when (bound-and-true-p horizontal-layout-mode)
    (with-silent-modifications
      ;; Clear stale hang stamps before re-applying.
      (dolist (span spans)
        (horizontal-layout--clear-hang-region (nth 0 span) (nth 1 span)))
      (dolist (span spans)
        (let ((beg   (nth 0 span))
              (end   (nth 1 span))
              (hang  (nth 2 span)))
          (when (and (numberp hang) (> hang 0))
            (let ((pos beg))
              (while (< pos end)
                (let* ((next     (min end (or (next-single-property-change
                                               pos 'wrap-prefix nil end)
                                              end)))
                       (existing (get-text-property pos 'wrap-prefix))
                       (cur-w    (or (and (consp existing)
                                          (eq (car existing) 'space)
                                          (plist-get (cdr existing) :width))
                                     0))
                       (height   (and (consp existing)
                                      (eq (car existing) 'space)
                                      (plist-get (cdr existing) :height)))
                       (new-w    (+ cur-w hang))
                       (prefix   (if height
                                     `(space :width ,new-w :height ,height)
                                   `(space :width ,new-w))))
                  (put-text-property pos next 'wrap-prefix prefix)
                  (put-text-property pos next horizontal-layout--hang-prop t)
                  (setq pos next))))))))))



(defun horizontal-layout--clear-hang-region (beg end)
  "Remove hanging-wrap stamps from wrap-prefix in BEG..END.
Restores wrap-prefix to match line-prefix (removing the hang addition),
or removes it if line-prefix is absent."
  (with-silent-modifications
    (let ((pos beg))
      (while (< pos end)
        (let ((next (or (next-single-property-change
                         pos horizontal-layout--hang-prop nil end)
                        end)))
          (when (get-text-property pos horizontal-layout--hang-prop)
            (let ((lp (get-text-property pos 'line-prefix)))
              (if lp
                  (put-text-property pos next 'wrap-prefix lp)
                (remove-text-properties pos next '(wrap-prefix nil))))
            (remove-text-properties pos next
                                    (list horizontal-layout--hang-prop nil)))
          (setq pos next))))))

(defun horizontal-layout--clear-hanging-wrap (_cookie)
  "No-op `:clear' callback for `horizontal-layout-hanging-wrap'."
  nil)


;;;; ================================================================
;;;; Section 3b — Right margin (pass 2 + pass 3)
;;;; ================================================================
;;
;; `horizontal-layout-margin-right' is registered at BOTH pass 2 and
;; pass 3 under separate `(property . pass)' registry keys, sharing the
;; same user-facing property name.
;;
;; Pass 2 (:after horizontal-layout-margin-left):
;;   Reads the existing `line-prefix' (which at this point carries
;;   `(space :width left :height H)' from margin-left) and replaces
;;   `:width' with `left + right'.  This narrows the display text area
;;   so word-wrap fires at `avail - left - right'.
;;
;; Pass 3 (:after nil, before text-align via :after constraint there):
;;   Walks visual-line spans (one triple per line) and atomically:
;;   1. Reads the combined width from line-prefix and restores it to
;;      left-only by subtracting VALUE.
;;   2. Stamps a display property on the final char `(1- lend)' that
;;      renders it as itself followed by a VALUE-wide trailing space.
;;
;;   Trailing stamp is skipped when:
;;     (a) `(char-after (1- lend))' is `\n' — last line of a paragraph.
;;     (b) The face at lbeg has a non-nil `text-align' — alignment takes
;;         ownership of the right boundary (see NEXT.md for geometry).

(defun horizontal-layout--apply-margin-right-pass2 (spans)
  "Narrow text area for right margin — pass-2 apply for margin-right.

SPANS is a list of (beg end value) triples where VALUE is the right
margin in canonical character widths.  Runs after margin-left (:after
constraint) so the left-margin `line-prefix' is already stamped.
Reads `(space :width left :height H)' and replaces `:width' with
`left+right', narrowing the display text area so word-wrap fires at
`avail - left - right'.

Only runs when `horizontal-layout-mode' is active."
  (when (bound-and-true-p horizontal-layout-mode)
    (with-silent-modifications
      (dolist (span spans)
        (let ((beg   (nth 0 span))
              (end   (nth 1 span))
              (right (nth 2 span)))
          (when (and (numberp right) (> right 0))
            ;; Skip beg when org-block-appear has hidden the block
            ;; delimiter: beg is not at a screen-line start, but the
            ;; block-start overlay (from margin-left) already provides
            ;; the indent via before-string.  Stamping line-prefix on
            ;; beg as well would double the indent.
            (let ((pos (if (horizontal-layout--block-start-p beg)
                           (1+ beg)
                         beg)))
              (while (< pos end)
                (let* ((next     (min end
                                      (or (next-single-property-change
                                           pos 'line-prefix nil end)
                                          end)))
                       (existing (get-text-property pos 'line-prefix))
                       (left     (and (consp existing)
                                      (eq (car existing) 'space)
                                      (plist-get (cdr existing) :width)))
                       (height   (and (consp existing)
                                      (eq (car existing) 'space)
                                      (plist-get (cdr existing) :height)))
                       (combined (+ (or left 0) right))
                       (prefix   (if height
                                     `(space :width ,combined :height ,height)
                                   `(space :width ,combined))))
                  (put-text-property pos next 'line-prefix  prefix)
                  (put-text-property pos next 'wrap-prefix  prefix)
                  (put-text-property pos next horizontal-layout--prop t)
                  (setq pos next))))))))))

(defun horizontal-layout--clear-margin-right (_cookie)
  "No-op `:clear' callback for `horizontal-layout-margin-right'.
Per-buffer stamps are cleaned up by `horizontal-layout-clear'."
  nil)

(defun horizontal-layout--apply-margin-right-pass3 (spans)
  "Atomic right-margin expansion — pass-3 apply for margin-right.

SPANS is a list of (lbeg lend value) triples, one per visual line
(from `face-extra--dispatch-pass3').  VALUE is the right margin in
canonical character widths.  Must NOT call `vertical-motion'.

For each visual line, within `with-silent-modifications':
  1. Reads `line-prefix' width (left+right from pass 2) and restores
     it to left-only: `(space :width left :height H)'.
  2. Stamps a display property on `(1- lend)' rendering the character
     as itself followed by a VALUE-wide trailing space, unless:
       (a) `(char-after (1- lend))' is `\\n' — last line of paragraph.
       (b) The face at lbeg has a non-nil `text-align' — alignment
           takes ownership of the right boundary.

Only runs when `horizontal-layout-mode' is active."
  (when (bound-and-true-p horizontal-layout-mode)
    (with-silent-modifications
      (dolist (span spans)
        (let* ((lbeg  (nth 0 span))
               (lend  (nth 1 span))
               (right (nth 2 span)))
          (when (and (numberp right) (> right 0) (< lbeg lend))
            (let* ((existing (get-text-property lbeg 'line-prefix))
                   (height   (and (consp existing)
                                  (eq (car existing) 'space)
                                  (plist-get (cdr existing) :height)))
                   ;; Resolve the configured left-margin value directly from
                   ;; the face cache rather than deriving it from `combined -
                   ;; right'.  The derived approach double-subtracts when
                   ;; pass-3 has already run and restored line-prefix to
                   ;; left-only: the second run sees left as combined and
                   ;; subtracts right again, collapsing the margin to 0.
                   (f        (or (get-text-property lbeg 'font-lock-face)
                                 (get-text-property lbeg 'face)))
                   (face     (cond ((symbolp f) f)
                                   ((listp f)   (cl-find-if #'symbolp f))
                                   (t           nil)))
                   (left     (* (frame-char-width)
                                (or (and face
                                         (face-extra--resolve-property
                                          face 'horizontal-layout-margin-left))
                                    0))))
              ;; Step 1: restore the firing prefix to left-only.
              ;; line-prefix fires at logical BOL; wrap-prefix fires at
              ;; continuation visual-line starts.  Restore whichever
              ;; one actually fires for this visual line.
              (let* ((logical-bol-p (= lbeg (save-excursion
                                              (goto-char lbeg)
                                              (line-beginning-position))))
                     (prefix-prop   (if logical-bol-p
                                        'line-prefix
                                      'wrap-prefix))
                     (restored      (if height
                                        `(space :width ,left :height ,height)
                                      `(space :width ,left))))
                (put-text-property lbeg (1+ lbeg) prefix-prop restored))
              ;; Clear any stale right-margin overlay for this visual line.
              (dolist (ov (overlays-in lbeg lend))
                (when (overlay-get ov horizontal-layout--right-prop)
                  (delete-overlay ov)))
              ;; Step 2: right-margin after-string (unless skipped).
              (let* ((trail-pos (1- lend))
                     (trail-ch  (and (>= trail-pos lbeg)
                                     (char-after trail-pos)))
                     (f         (or (get-text-property lbeg 'font-lock-face)
                                    (get-text-property lbeg 'face)))
                     (face      (cond ((symbolp f) f)
                                      ((listp f)   (cl-find-if #'symbolp f))
                                      (t           nil)))
                     (has-align (and face
                                     (face-extra--resolve-property
                                      face 'text-align))))
                (unless (or (null trail-ch)
                            (eq trail-ch ?\n)
                            has-align)
                  ;; Add a right-margin space via an overlay after-string.
                  ;; An after-string's display property is processed as a
                  ;; top-level display element (not nested), so
                  ;; `(space :width N)' correctly uses N × face-char-width.
                  ;; A display property inside a display string is ignored
                  ;; by Emacs, which is why a text-property approach fails.
                  (let* ((tf         (or (get-text-property trail-pos
                                                            'font-lock-face)
                                         (get-text-property trail-pos 'face)))
                         (trail-face (cond ((symbolp tf) tf)
                                           ((listp tf)   (cl-find-if
                                                          #'symbolp tf))
                                           (t            nil)))
                         (ov         (make-overlay trail-pos lend)))
                    (overlay-put ov 'after-string
                                 (propertize " "
                                             'face trail-face
                                             'display `(space :width ,right)))
                    (overlay-put ov horizontal-layout--right-prop t)))))))))))

(defun horizontal-layout--pre-clear-right-margin (beg end)
  "Remove right-margin after-string overlays in BEG..END.
Called as a `:pre-clear' callback before `face-extra--dispatch-pass3'
starts its `vertical-motion' walk.  Stale right-margin overlays from a
previous pass-3 run add visual width via their after-strings, causing
`vertical-motion' to compute wrong visual-line boundaries (lend too
early, potentially mid-word).  Clearing them here ensures the walk sees
the clean display state."
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov horizontal-layout--right-prop)
      (delete-overlay ov))))

(defun horizontal-layout--clear-margin-right-pass3 (_cookie)
  "No-op `:clear' callback for `horizontal-layout-margin-right' pass 3.
Per-buffer stamps are cleaned up by `horizontal-layout-clear'."
  nil)


;;;; ================================================================
;;;; Section 4 — Minor mode
;;;; ================================================================

;;;###autoload
(define-minor-mode horizontal-layout-mode
  "Apply synthetic horizontal layout properties to faces in this buffer.

Margin values are configured via `face-extra-add-relative' (buffer-local)
or `face-extra-add' (global):

  (face-extra-add-relative \\='org-quote \\='horizontal-layout-margin-left 4)
  (face-extra-add-relative \\='org-quote \\='horizontal-layout-margin-right 4)

`face-extra--dispatch' owns passes 1-2; `face-extra--dispatch-pass3'
owns pass 3 (right-margin expansion).  Both are managed here."
  :lighter " HLay"
  (if horizontal-layout-mode
      (progn
        (face-extra--enable-dispatch)
        (face-extra--enable-dispatch-pass3)
        (face-extra--invalidate-cache)
        (font-lock-flush))
    (horizontal-layout-clear)
    (face-extra--disable-dispatch-pass3)
    (face-extra--disable-dispatch)))


;;;; ================================================================
;;;; Section 5 — face-extra registration (load time)
;;;; ================================================================

(face-extra-define-property 'horizontal-layout-margin-left
  :pass  2
  :after nil
  :apply  #'horizontal-layout--apply-margin-left
  :clear  #'horizontal-layout--clear-margin-left)

(face-extra-define-property 'horizontal-layout-margin-right
  :pass  2
  :after '(horizontal-layout-margin-left)
  :apply  #'horizontal-layout--apply-margin-right-pass2
  :clear  #'horizontal-layout--clear-margin-right)

(face-extra-define-property 'horizontal-layout-hanging-wrap
  :pass  2
  :after '(horizontal-layout-margin-left)
  :apply  #'horizontal-layout--apply-hanging-wrap
  :clear  #'horizontal-layout--clear-hanging-wrap)

(face-extra-define-property 'horizontal-layout-margin-right
  :pass       3
  :after      nil
  :pre-clear  #'horizontal-layout--pre-clear-right-margin
  :apply      #'horizontal-layout--apply-margin-right-pass3
  :clear      #'horizontal-layout--clear-margin-right-pass3)


;;;; ================================================================
;;;; Section 6 — text-align: pass-3 line-break-dependent alignment
;;;; ================================================================
;;
;; `text-align' is a synthetic face property (pass 3) that controls
;; text alignment per face.  SPANS received by the :apply function are
;; one (lbeg lend value) triple per visual line, as built by the
;; linewise walk in `face-extra--dispatch-pass3'.  Apply functions must
;; NOT call `vertical-motion' themselves.
;;
;; Supported values:
;;   `center'      — real centering via line-prefix align-to offset
;;   `test-marker' — dev stub: highlights char at character-midpoint

(defconst text-align--prop 'text-align--marker
  "Sentinel text property marking spans styled by `text-align-mode'.
Used by `text-align-clear' to remove exactly this package's properties.")

(defconst text-align--justify-prop 'text-align--justify-space
  "Sentinel text property on space characters stamped by justify.
Set alongside the `display' property so the pre-clear pass can find and
remove stale stamps before `window-text-pixel-size' measures the line.
Without this, stale display widths on spaces inflate the measured
text-px and cause the distributed slack to be too small.")

(defvar-local horizontal-layout--last-avail nil
  "Last known pixel width of the text area in this buffer's window.
Used by `horizontal-layout--window-size-change' to detect genuine
width changes (which require a pass-3 re-stamp) and ignore pure
height changes (minibuffer growth, vertico popup) which do not affect
justification geometry.")

(defvar-local text-align--char-width-cache nil
  "Hash table: (face . char-code) → natural pixel width.
Populated lazily on first encounter of each (face, char) pair via a
single `window-text-pixel-size' call on that character's buffer position.
Cleared on font or scale changes via `face-extra-invalidate-cache-functions'.")

(defvar-local text-align--line-natural-px nil
  "Running sum of natural character widths on point's current visual line.
Initialised by `text-align--stamp' after each pass-3 flush; incremented
in `text-align--post-command-ring-walk' on each self-insert keystroke.
Nil means the state is stale — the next flush will rebuild it.")

(defvar-local text-align--line-zone-px nil
  "Zone width (avail − margins) at last pass-3 stamp of point's visual line.
Paired with `text-align--line-natural-px' and `text-align--space-ring'.")

(defvar-local text-align--space-ring nil
  "List of (MARKER . EXTRA-PX) for the justified spaces on point's visual line.
MARKER points to a space character; EXTRA-PX is the pixels above natural
width currently stamped on it.  Invariant while valid:
  sum(extra-px) = text-align--line-zone-px - text-align--line-natural-px
Built by `text-align--stamp'; consumed by `text-align--post-command-ring-walk'.
Nil when stale — flush will rebuild.")

(defvar-local text-align--ring-lbeg nil
  "Visual BOL for which `text-align--space-ring' was built.
`text-align--post-command-ring-walk' checks this against
`face-extra--vline-beg' to detect when point has moved to a different line.")

(defvar-local text-align--ring-cursor-idx nil
  "Index into `text-align--space-ring' of the next space to reduce.
Initialised to the last long-space (remainder − 1) when the ring is built.
Advances backward by 1 for each pixel removed; wraps from 0 to (1- n).")

(defun text-align--natural-space-px (win pos avail)
  "Return the natural pixel width of the space character at POS in WIN.
Uses `text-align--char-width-cache' keyed by (face . ?\\s); on a miss,
measures via `window-text-pixel-size' and caches the result."
  (let* ((face  (or (get-text-property pos 'font-lock-face)
                    (get-text-property pos 'face)))
         (key   (cons face ?\s))
         (cache (or text-align--char-width-cache
                    (setq text-align--char-width-cache
                          (make-hash-table :test #'equal)))))
    (or (gethash key cache)
        (let ((w (car (window-text-pixel-size win pos (1+ pos) (* 2 avail)))))
          (puthash key w cache)
          w))))

(defconst text-align--line-hash-prop 'text-align--line-hash
  "Text property on visual-line BOL storing `buffer-hash' at last justify.
Used to skip re-justifying lines whose content has not changed since the
last flush, making the flush cost O(changed-lines) instead of O(all-lines).
Stored at (point lbeg) by `text-align--apply' after each successful stamp.
Cleared by `text-align--justify-clear' on mode disable so stale hashes
do not survive a font or scale change.")

(defconst text-align--debug-lend-prop 'text-align--debug-lend
  "Sentinel text property on the lend-1 character when
`text-align-justify-debug-mode' is active.  Used to paint a green
background on the last character of each justified visual line so the
lend boundary is visible during debugging.")

(defun text-align--clear-char-width-cache ()
  "Clear `text-align--char-width-cache' and invalidate ring state.
Registered on `face-extra-invalidate-cache-functions' alongside
`text-align--clear-space-width-cache'.  Any font or scale change makes
cached character widths and the derived ring state stale."
  (setq text-align--char-width-cache  nil
        text-align--line-natural-px   nil
        text-align--space-ring        nil
        text-align--ring-cursor-idx   nil))

(defun text-align--justify-clear (beg end)
  "Remove stale justify display stamps from space characters in BEG..END.
Called as `:pre-clear' before the pass-3 `vertical-motion' walk so that
`window-text-pixel-size' measures natural (unstamped) character widths.
Does NOT clear `text-align--space-width-cache': that cache maps face to
natural-space-px and is stable across keystrokes.  It is cleared by
`text-align--clear-space-width-cache' via
`face-extra-invalidate-cache-functions' when font metrics actually change."
  (with-silent-modifications
    (let ((pos beg))
      (while (< pos end)
        (let ((next (or (next-single-property-change
                         pos text-align--justify-prop nil end)
                        end)))
          (when (get-text-property pos text-align--justify-prop)
            (remove-text-properties pos next
                                    (list 'display                 nil
                                          text-align--justify-prop nil)))
          (setq pos next))))
    ;; Clear line-hash stamps so re-justify runs fresh after a clear.
    ;; This ensures font/scale changes are picked up: when the mode is
    ;; re-applied after text-scale-mode, this runs and invalidates hashes.
    (remove-text-properties beg end (list text-align--line-hash-prop nil))
    ;; Also clear debug lend markers.
    (let ((pos beg))
      (while (< pos end)
        (let ((next (or (next-single-property-change
                         pos text-align--debug-lend-prop nil end)
                        end)))
          (when (get-text-property pos text-align--debug-lend-prop)
            (remove-text-properties pos next
                                    (list 'face                    nil
                                          text-align--debug-lend-prop nil)))
          (setq pos next))))))

;;;###autoload
(defun text-align-clear (&optional beg end)
  "Remove text-align display properties from BEG..END.
Defaults to the whole buffer.

For centering stamps, restores `line-prefix' to the height-only pass-1
spacer form `(space :width 0 :height H)' rather than removing it
entirely, preserving vertical rhythm.  For test-marker stamps, which do
not modify `line-prefix', this restoration is a no-op."
  (interactive (if (use-region-p)
                   (list (region-beginning) (region-end))
                 (list nil nil)))
  (let* ((beg (or beg (point-min)))
         (end (or end (point-max)))
         (pos beg))
    (with-silent-modifications
      (while (< pos end)
        (let ((next (or (next-single-property-change
                         pos text-align--prop nil end)
                        end)))
          (when (get-text-property pos text-align--prop)
            ;; Restore line-prefix or wrap-prefix if we modified it.
            ;; Logical BOL positions have a centering line-prefix;
            ;; continuation positions have a centering wrap-prefix.
            ;; Check both: exactly one will have :align-to.
            (dolist (prop '(line-prefix wrap-prefix))
              (let* ((val    (get-text-property pos prop))
                     (height (and (consp val)
                                  (eq (car val) 'space)
                                  (plist-get (cdr val) :height))))
                (when (and (consp val) (plist-get (cdr val) :align-to))
                  (if height
                      (put-text-property pos next prop
                                         `(space :width 0 :height ,height))
                    (remove-text-properties pos next (list prop nil))))))
            (remove-text-properties pos next
                                    (list text-align--prop nil
                                          'face            nil)))
          ;; Also sweep justify stamps in this range (they use a separate
          ;; sentinel so they're not caught by text-align--prop above).
          (text-align--justify-clear pos next)
          (setq pos next))))
    ;; Full clear also invalidates the char-width cache: mode disable or
    ;; explicit text-align-clear means a clean slate on next enable/flush.
    (setq text-align--char-width-cache nil)))

(defun text-align--stamp (lbeg lend value)
  "Stamp a margin-aware alignment prefix for the visual line LBEG..LEND.

VALUE is `center', `right', or `justify'.  The offset or distribution
accounts for any left/right margins on the face at LBEG:
  center  — left_px + (zone - text_px) / 2             [line-prefix]
  right   — avail - right_px - text_px                 [line-prefix]
  justify — slack distributed across interword spaces  [display props]
where zone = avail - left_px - right_px.

margin-left and margin-right are resolved from the face cache and
converted to pixels via `frame-char-width' (approximate but sufficient;
`frame-char-width' is horizontal and unaffected by the floor-height
remap that makes `frame-char-height' unreliable in WP buffers).

`center', `right', and `justify' are all values of the same `text-align'
property, so each visual line produces exactly one measurement regardless
of which value is active.

Measures actual rendered text width via `window-text-pixel-size' in the
current window — no temp buffer, no `string-pixel-width'.  Measuring
from the live window is essential because `face-remapping-alist' entries
from `variable-spacing-mode' affect character widths for proportional
fonts and are absent in a temp buffer.

`line-prefix' fires at the start of the first visual line of a logical
line; `wrap-prefix' fires at the start of each continuation visual line.
Both are looked up from the character at each visual-line start, so
each carries a unique offset computed for that specific visual line.

Preserves the `:height' component written by pass 1 so vertical rhythm
is not disturbed.  Any prior alignment stamp not overwritten by pass 1
is explicitly neutralised before measuring to keep measurements clean."
  ;; Paragraph-final guard — bail out before any measurement.
  ;; For justify, the last line of a paragraph has \n immediately before
  ;; lend; stretching it would look wrong.  Returning early skips the
  ;; window-text-pixel-size call and stamp neutralisation entirely, which
  ;; matters for the narrow (point's-line-only) keystroke path where this
  ;; function would otherwise fire on every keystroke for no effect.
  (unless (and (eq value 'justify)
               (eq (char-after (1- lend)) ?\n))
  (let* ((win   (get-buffer-window (current-buffer)))
         (avail (and win (window-body-width win t))))
    (when avail
      (let* (;; Margin values for the face at lbeg.
             (f        (or (get-text-property lbeg 'font-lock-face)
                           (get-text-property lbeg 'face)))
             (face     (cond ((symbolp f) f)
                             ((listp f)   (cl-find-if #'symbolp f))
                             (t           nil)))
             (char-w   (frame-char-width))
             (left-px  (* char-w (or (and face (face-extra--resolve-property
                                               face 'horizontal-layout-margin-left))
                                     0)))
             (right-px (* char-w (or (and face (face-extra--resolve-property
                                               face 'horizontal-layout-margin-right))
                                     0)))
             ;; For justify, word-wrap already constrains body text to
             ;; avail - margin via line-prefix/wrap-prefix; zone must be
             ;; `avail' so slack = avail - text-px is the leftover space
             ;; relative to the full window (≈ margin_px, always positive).
             ;; Using zone = avail - margin gives slack ≈ 0 because
             ;; body_px ≈ avail - margin — nothing to distribute.
             ;; For center/right the exact zone is needed to compute the
             ;; correct alignment offset.
             (zone     (if (eq value 'justify)
                           avail
                         (- avail left-px right-px)))
             ;; line-prefix fires at logical BOL; wrap-prefix fires at
             ;; continuation visual-line starts.
             (logical-bol-p (= lbeg (save-excursion
                                      (goto-char lbeg)
                                      (line-beginning-position))))
             (prefix-prop   (if logical-bol-p 'line-prefix 'wrap-prefix))
             (existing      (get-text-property lbeg prefix-prop))
             (height        (and (consp existing)
                                 (eq (car existing) 'space)
                                 (plist-get (cdr existing) :height)))
             ;; Neutralise any prior alignment stamp before measuring.
             (_ (when (get-text-property lbeg text-align--prop)
                  (if height
                      (put-text-property lbeg (1+ lbeg) prefix-prop
                                         `(space :width 0 :height ,height))
                    (remove-text-properties lbeg (1+ lbeg)
                                            (list prefix-prop nil)))))
             (text-px (car (window-text-pixel-size
                            win lbeg lend (* 2 avail)))))
        (cond
         ;; ── center / right ─────────────────────────────────────────
         ((memq value '(center right))
          (when (> zone text-px)
            (let* ((offset (pcase value
                             ('center (+ left-px (/ (- zone text-px) 2)))
                             ('right  (- avail right-px text-px))))
                   (prefix (if height
                               `(space :align-to (,offset) :height ,height)
                             `(space :align-to (,offset)))))
              (put-text-property lbeg (1+ lbeg) prefix-prop prefix)
              (put-text-property lbeg (1+ lbeg) text-align--prop t))))

         ;; ── justify ────────────────────────────────────────────────
         ;; Skip the last line of a paragraph (ends with \n) — it should
         ;; be left-aligned, not stretched.  Also skip when slack ≤ 0
         ;; (line already fills or overflows the zone).
         ((eq value 'justify)
          ;; Debug: paint lend-1 green so the wrap boundary is visible.
          (when (bound-and-true-p text-align-justify-debug-mode)
            (put-text-property (1- lend) lend
                               'face '(:background "#00aa44" :foreground "white"))
            (put-text-property (1- lend) lend text-align--debug-lend-prop t))
          (unless (eq (char-after (1- lend)) ?\n)
          ;; Skip visual lines that start immediately after a display
          ;; overlay (e.g. a wrapped org-cite-appear citation).  On such
          ;; lines lbeg = overlay-end, so window-text-pixel-size misses
          ;; the overlay's contribution to this visual line (the second
          ;; half of its display string), making text-px far too small
          ;; and slack far too large — widening spaces until a word
          ;; overflows onto a third line.  Skipping is the safe first
          ;; step; a follow-up pass will compute the correct slack from
          ;; cached overlay word widths.
          (unless (and (> lbeg (point-min))
                       (cl-some (lambda (ov) (overlay-get ov 'display))
                                (overlays-at (1- lbeg))))
            (let ((slack (- zone text-px)))
              (when (> slack 0)
                ;; Collect interword space positions in the visual line,
                ;; excluding the wrap character at (1- lend).
                ;; Skip spaces that lie inside an overlay whose `display'
                ;; property replaces the whole span (e.g. org-cite-appear
                ;; overlays).  Those spaces are not rendered; stamping
                ;; extra width on them consumes slack without widening
                ;; anything visible, leaving the line short of the margin.
                (let ((spaces nil)
                      (pos    lbeg))
                  (while (< pos (1- lend))
                    (when (and (= (char-after pos) ?\s)
                               (not (get-text-property pos 'display))
                               (not (cl-some
                                     (lambda (ov) (overlay-get ov 'display))
                                     (overlays-at pos))))
                      (push pos spaces))
                    (setq pos (1+ pos)))
                  ;; Trim any trailing spaces that are not followed by a
                  ;; non-space character before (1- lend).  These are
                  ;; gaps after the last word on the line and should not
                  ;; be widened.
                  (let ((ordered (nreverse spaces)))
                    (while (and ordered
                                (let ((p (1+ (car (last ordered)))))
                                  (while (and (< p (1- lend))
                                              (eq (char-syntax (char-after p)) ?\ ))
                                    (setq p (1+ p)))
                                  (>= p (1- lend))))
                      (setq ordered (butlast ordered)))
                    (let ((n (length ordered)))
                      (when (> n 0)
                        ;; Measure natural space width from an actual space
                        ;; in the line, not from `string-pixel-width'.
                        ;; `string-pixel-width' opens a temp buffer and
                        ;; uses the global default face — in a WP buffer
                        ;; where variable-spacing remaps default to a floor
                        ;; font (e.g. Iosevka Aile) but body text renders
                        ;; in a different font (e.g. Times New Roman via
                        ;; buffer-local face remapping), the two space
                        ;; widths diverge.  Stamping with the wrong
                        ;; natural-px inflates the line beyond zone.
                        ;; `window-text-pixel-size' on a buffer position
                        ;; sees the full face-remapping-alist in context.
                        (let* ((natural-px   (text-align--natural-space-px
                                                   win (car ordered) avail))
                               (base-extra   (/ slack n))
                               (remainder    (% slack n))
                               (i            0)
                               ;; Ring entries collected only for point's line.
                               (on-point-line (and (>= (point) lbeg)
                                                   (< (point) lend)))
                               (ring-entries nil))
                          ;; Distribute: first `remainder' spaces get
                          ;; base-extra+1 px, the rest get base-extra
                          ;; (Bresenham — every slack pixel is used).
                          (dolist (sp ordered)
                            (let* ((extra  (+ base-extra
                                              (if (< i remainder) 1 0)))
                                   (new-px (+ natural-px extra)))
                              (when (> extra 0)
                                (put-text-property sp (1+ sp)
                                                   'display
                                                   `(space :width (,new-px)))
                                (put-text-property sp (1+ sp)
                                                   text-align--justify-prop t))
                              ;; Collect ring entry for every space; extra=0
                              ;; entries are included so the invariant holds.
                              (when on-point-line
                                (push (cons (copy-marker sp t) extra)
                                      ring-entries)))
                            (setq i (1+ i)))
                          ;; Store ring and line state for point's line only.
                          (when on-point-line
                            (setq text-align--space-ring      (nreverse ring-entries)
                                  text-align--line-natural-px (float text-px)
                                  text-align--line-zone-px    (float zone)
                                  text-align--ring-lbeg       lbeg
                                  ;; Cursor starts at the last long space
                                  ;; (index remainder-1), where remainder
                                  ;; is the number of +1 spaces.
                                  text-align--ring-cursor-idx (max 0 (1- (max remainder 1)))))))))))))))))))))  ; closes unless

;;;; ================================================================
;;;; Section 6b — justify debug mode
;;;; ================================================================

(defun text-align--justify-debug-echo ()
  "Echo justification metrics for the visual line at point.
Active via `post-command-hook' when `text-align-justify-debug-mode' is on.
Fires only when point is at visual-line beginning position."
  (when (and (bound-and-true-p text-align-justify-debug-mode)
             (= (point) (save-excursion (beginning-of-visual-line) (point))))
    (let* ((win   (get-buffer-window (current-buffer)))
           (avail (and win (window-body-width win t))))
      (when avail
        (let* ((lbeg (point))
               (lend (save-excursion (vertical-motion 1)
                                     (min (point-max) (point))))
               ;; Debug echoes justify metrics; use zone = avail so slack
               ;; matches what text-align--stamp computes for justify.
               (zone     avail)
               (text-px  (car (window-text-pixel-size win lbeg lend (* 2 avail))))
               (slack    (- zone text-px)))
          ;; Collect and trim spaces the same way the stamp function does.
          ;; Skip spaces inside display overlays (mirrors the guard in
          ;; `text-align--stamp').
          (let ((spaces nil)
                (pos    lbeg))
            (while (< pos (1- lend))
              (when (and (= (char-after pos) ?\s)
                         (not (cl-some
                               (lambda (ov) (overlay-get ov 'display))
                               (overlays-at pos))))
                (push pos spaces))
              (setq pos (1+ pos)))
            (let ((ordered (nreverse spaces)))
              (while (and ordered
                          (let ((p (1+ (car (last ordered)))))
                            (while (and (< p (1- lend))
                                        (eq (char-syntax (char-after p)) ?\ ))
                              (setq p (1+ p)))
                            (>= p (1- lend))))
                (setq ordered (butlast ordered)))
              (let* ((n          (length ordered))
                     (natural-px (if (> n 0)
                                    (text-align--natural-space-px
                                     win (car ordered) avail)
                                  0))
                     (base-extra (if (> n 0) (/ slack n) 0))
                     (remainder  (if (> n 0) (% slack n) 0))
                     (widths     (cl-loop for i from 0 below n
                                          collect (+ natural-px base-extra
                                                     (if (< i remainder) 1 0)))))
                (message "line=%dpx  zone=%dpx  slack=%dpx  n=%d  extra=%dpx  widths=%S"
                         text-px zone slack n
                         (- (apply #'+ widths) (* n natural-px))
                         widths))))))))  )

;;;###autoload
(define-minor-mode text-align-justify-debug-mode
  "Show justification metrics in the echo area at visual-line BOL.

When active:
  - Moving point to visual-line BOL echoes: measured line width, zone,
    slack, space count, sum of distributed widths, per-space width list.
  - The lend-1 character of each justified visual line is painted with a
    green background so the wrap boundary is visible."
  :lighter " JDbg"
  (if text-align-justify-debug-mode
      (add-hook 'post-command-hook #'text-align--justify-debug-echo nil t)
    (remove-hook 'post-command-hook #'text-align--justify-debug-echo t)
    ;; Clear any lingering lend markers.
    (text-align--justify-clear (point-min) (point-max))))

(defun text-align--apply (spans)
  "Apply text alignment for SPANS from `face-extra--dispatch-pass3'.

SPANS is a list of (lbeg lend value) triples, one per visual line.
Apply functions must NOT call `vertical-motion'.

Dispatches on value:
  `center'      — stamps a centering `line-prefix'/`wrap-prefix' at lbeg.
  `right'       — stamps a right-align prefix at lbeg.
  `justify'     — distributes slack across interword spaces; skips last
                  line of paragraph.
  `test-marker' — dev stub: highlights the character-position midpoint
                  in hot pink; use `face-extra-add-relative' with value
                  `test-marker' to activate."
  (when (bound-and-true-p text-align-mode)
    (with-silent-modifications
      (dolist (span spans)
        (let ((lbeg  (nth 0 span))
              (lend  (nth 1 span))
              (value (nth 2 span)))
          (pcase value
            ((or 'center 'right)
             (text-align--stamp lbeg lend value))
            ('justify
             ;; Paragraph-final guard: last line of paragraph is left-aligned.
             ;; text-align--stamp has the same guard internally, but checking
             ;; here avoids the function call overhead on every final line.
             (unless (eq (char-after (1- lend)) ?\n)
               (text-align--stamp lbeg lend 'justify)))
            ('test-marker
             (let ((mid (/ (+ lbeg lend) 2)))
               (when (and (> lend lbeg)
                          (< mid lend)
                          (not (eq (char-after mid) ?\n)))
                 (put-text-property mid (1+ mid)
                                    'face '( :background "#ff0066"
                                             :foreground "white"
                                             :weight bold))
                 (put-text-property mid (1+ mid) text-align--prop t))))))))))

(defun text-align--clear-marker (_cookie)
  "No-op `:clear' callback for `text-align' registration.
Per-buffer text properties are cleaned up by `text-align-clear'
on mode disable or the next dispatch cycle."
  nil)

(defun text-align--ring-walk (char-px natural-px)
  "Reduce `text-align--space-ring' by CHAR-PX pixels, updating display stamps.
NATURAL-PX is the natural (unstamped) width of one space on this line.

Removes 1 pixel per step, advancing `text-align--ring-cursor-idx' backward
by 1 on each step (wrapping from 0 to n-1).  Starting from the last long
space (remainder-1) and working backward, this matches the Bresenham
stamp direction: the last long space loses its extra pixel first, then
the one before it, etc., producing the same distribution as a full reflow."
  (let* ((ring text-align--space-ring)
         (n    (length ring))
         (idx  (or text-align--ring-cursor-idx (1- n))))
    (dotimes (_ char-px)
      (let* ((cell  (nth idx ring))
             (extra (cdr cell)))
        (when (> extra 0)
          (setcdr cell (1- extra))
          (let ((pos (marker-position (car cell))))
            (when pos
              (with-silent-modifications
                (if (> (cdr cell) 0)
                    (put-text-property pos (1+ pos)
                                       'display
                                       `(space :width (,(+ natural-px (cdr cell)))))
                  (remove-text-properties pos (1+ pos)
                                          (list 'display             nil
                                                text-align--justify-prop nil)))))))
        ;; Advance cursor backward on every step, wrapping at 0.
        (setq idx (if (> idx 0) (1- idx) (1- n)))))
    (setq text-align--ring-cursor-idx idx)))

(defun text-align--post-command-reflow ()
  "One-shot post-command hook: reflow the paragraph at point after overflow.
Removes itself on first run, then performs a full-paragraph pass-3 walk
so the cascade from a line overflow is corrected before redisplay."
  (remove-hook 'post-command-hook #'text-align--post-command-reflow t)
  (let ((para (face-extra--paragraph-bounds (point) (point))))
    (setq face-extra--pass3-force-full t)
    (face-extra--dispatch-pass3 (car para) (cdr para))))

(defun text-align--post-command-ring-walk ()
  "One-shot post-command: update justify stamps after a self-insert.
Removes itself, then looks up the just-typed character's pixel width
(caching on miss), increments `text-align--line-natural-px', and either:
- walks `text-align--space-ring' to redistribute slack if the line still fits,
- or triggers overflow handling (clear next line + full reflow) if it does not."
  (remove-hook 'post-command-hook #'text-align--post-command-ring-walk t)
  (when (and text-align--line-natural-px
             text-align--line-zone-px
             text-align--space-ring
             text-align--ring-lbeg
             face-extra--vline-beg
             (= text-align--ring-lbeg face-extra--vline-beg))
    (let* ((pos       (1- (point)))
           (win       (get-buffer-window (current-buffer)))
           (avail     (and win (window-body-width win t))))
      (when (and (>= pos 0) avail)
        (let* ((face     (or (get-text-property pos 'font-lock-face)
                             (get-text-property pos 'face)))
               (char-code (char-after pos))
               (cache    (or text-align--char-width-cache
                             (setq text-align--char-width-cache
                                   (make-hash-table :test #'equal))))
               (key      (cons face char-code))
               (char-px  (or (gethash key cache)
                             (let ((w (car (window-text-pixel-size
                                            win pos (1+ pos) (* 2 avail)))))
                               (puthash key w cache)
                               w)))
               (new-natural (+ text-align--line-natural-px char-px)))
          (if (> new-natural text-align--line-zone-px)
              ;; Overflow: invalidate ring, clear next line, schedule reflow.
              (progn
                (setq text-align--line-natural-px  nil
                      text-align--space-ring        nil
                      text-align--ring-cursor-idx   nil)
                (let ((next-end (save-excursion
                                  (goto-char face-extra--vline-end)
                                  (let ((fontification-functions nil))
                                    (vertical-motion 1))
                                  (point))))
                  (text-align--justify-clear face-extra--vline-end next-end))
                ;; Call reflow directly — we are already in post-command-hook,
                ;; so adding it as another hook would defer it one cycle.
                (text-align--post-command-reflow))
            ;; Fits: update natural-px and walk ring to reclaim char-px of slack.
            (setq text-align--line-natural-px new-natural)
            (let ((natural-space-px
                   (when (and text-align--space-ring text-align--char-width-cache)
                     (let* ((sp  (marker-position (caar text-align--space-ring)))
                            (f   (and sp (or (get-text-property sp 'font-lock-face)
                                             (get-text-property sp 'face)))))
                       (and f (gethash (cons f ?\s) text-align--char-width-cache))))))
              (when natural-space-px
                (text-align--ring-walk char-px natural-space-px)))))))))

(defun text-align--pre-command-justify (vbeg vend)
  "Pre-command callback for justify: clear stamps and schedule ring walk.
VBEG and VEND are the visual-line bounds supplied by `face-extra--pre-command'.

When the ring is warm, skips clearing so the line stays justified
throughout; the ring-walk redistributes slack in post-command.
When the ring is stale, clears stamps as a fallback.

For self-inserting commands:
- If ring state is valid for this line, schedules
  `text-align--post-command-ring-walk' for exact overflow detection and
  ring redistribution.
- Otherwise falls back to an avg-char-px heuristic for overflow detection."
  (when (memq this-command '(self-insert-command org-self-insert-command))
    (let* ((ring-warm (and text-align--line-natural-px
                           text-align--line-zone-px
                           text-align--space-ring
                           text-align--ring-lbeg
                           (= text-align--ring-lbeg vbeg)))
           ;; When ring is warm, look up the about-to-be-typed character in
           ;; the cache.  On a hit we can detect overflow before insertion.
           ;; On a miss use ?W width if cached, else 1.5× space-width as a
           ;; conservative bound; the ring-walk will do the exact check in
           ;; post-command regardless.
           (char-px  (and ring-warm
                          text-align--char-width-cache
                          (characterp last-command-event)
                          (let* ((face (or (get-text-property (point) 'font-lock-face)
                                           (get-text-property (point) 'face)))
                                 (cache text-align--char-width-cache)
                                 (exact (gethash (cons face last-command-event) cache)))
                            (or exact
                                (gethash (cons face ?W) cache)
                                (let ((sp (gethash (cons face ?\s) cache)))
                                  (and sp (* 1.5 sp)))))))
           (overflow (and char-px
                          (> (+ text-align--line-natural-px char-px)
                             text-align--line-zone-px))))
      (cond
       ;; Cache hit + overflow: clear next line before insertion so the
       ;; wrapping word doesn't land on expanded spaces.  Schedule reflow.
       (overflow
        (let ((next-end (save-excursion
                          (goto-char vend)
                          (let ((fontification-functions nil))
                            (vertical-motion 1))
                          (point))))
          (text-align--justify-clear vend next-end))
        (add-hook 'post-command-hook #'text-align--post-command-reflow nil t))
       ;; Cache hit, no overflow, or cache miss with warm ring.
       ;; Space character: the ring doesn't include the new gap, so
       ;; invalidate and do a full reflow to rebuild with the new space count.
       ;; Non-space: ring-walk redistributes slack in post-command.
       (ring-warm
        (if (eq last-command-event ?\s)
            (progn
              (setq text-align--space-ring       nil
                    text-align--ring-cursor-idx  nil
                    text-align--line-natural-px  nil)
              (add-hook 'post-command-hook #'text-align--post-command-reflow nil t))
          (add-hook 'post-command-hook #'text-align--post-command-ring-walk nil t)))
       ;; Ring stale: avg-based overflow fallback until flush rebuilds ring.
       ;; 1.5× avg approximates max char width; replaced by ring once warm.
       ((and text-align--line-natural-px text-align--line-zone-px)
        (text-align--justify-clear vbeg vend)
        (let* ((avg-char-px (/ text-align--line-natural-px
                               (max 1.0 (- (float vend) vbeg 1))))
               (slack (- text-align--line-zone-px text-align--line-natural-px)))
          (when (< slack (* 1.5 avg-char-px))
            (let ((next-end (save-excursion
                              (goto-char vend)
                              (let ((fontification-functions nil))
                                (vertical-motion 1))
                              (point))))
              (text-align--justify-clear vend next-end))
            (add-hook 'post-command-hook
                      #'text-align--post-command-reflow nil t))))))))


;;;; ================================================================
;;;; Section 7 — text-align-mode minor mode
;;;; ================================================================

;;;###autoload
(define-minor-mode text-align-mode
  "Apply pass-3 text alignment to faces in this buffer.

Alignment values are configured via `face-extra-add-relative' (buffer-local)
or `face-extra-add' (global):

  (face-extra-add-relative \\='text-body \\='text-align \\='center)

`face-extra--dispatch-pass3' owns the apply loop; this mode ensures it
is registered and handles cleanup on disable."
  :lighter " TAlign"
  (if text-align-mode
      (progn
        (face-extra--enable-dispatch)
        (face-extra--enable-dispatch-pass3)
        (face-extra--invalidate-cache)
        (font-lock-flush))
    (text-align-clear)
    (face-extra--disable-dispatch-pass3)
    (face-extra--disable-dispatch)))


;;;; ================================================================
;;;; Section 8 — face-extra registration (load time)
;;;; ================================================================

(face-extra-define-property 'text-align
  :pass       3
  :after      '(horizontal-layout-margin-right)
  ;; :pre-clear removes stale justify space stamps from the walk region
  ;; before the visual-line walk begins, so `window-text-pixel-size'
  ;; always measures natural (unstamped) text widths.
  ;; `text-align--space-width-cache' is NOT cleared here — it is stable
  ;; across keystrokes and is only invalidated on genuine metric changes
  ;; (font-family or text-scale) via `face-extra-invalidate-cache-functions'.
  :pre-clear   #'text-align--justify-clear
  ;; :pre-command strips justify space stamps from point's visual line
  ;; before the keystroke is processed and rendered.  This prevents a
  ;; justified line from overflowing when a character is inserted into
  ;; fully-expanded spaces — the display engine sees natural widths for
  ;; the render that shows the new character, and the idle flush
  ;; re-justifies correctly afterward.
  :pre-command #'text-align--pre-command-justify
  :apply       #'text-align--apply
  :clear       #'text-align--clear-marker)

;; Clear the natural-space-width cache whenever face metrics change.
;; `face-extra--invalidate-cache' is called after org-sty-apply (font-family
;; changes) and whenever face-remapping-alist is updated — which includes
;; text-scale-mode, since variable-spacing-mode advises it and calls
;; face-extra--invalidate-cache via font-lock-flush → face-extra--dispatch.
(add-hook 'face-extra-invalidate-cache-functions
          #'text-align--clear-char-width-cache)

;; ---- Window resize: flush stale justify stamps when window width changes ----
;;
;; Pass-3 justify stamps encode `avail' (window pixel width) at stamp time.
;; After a resize all stamps are stale: the slack distribution was computed
;; for the old width.  `font-lock-flush' marks the buffer dirty so jit-lock
;; re-fontifies the visible region; the `:pre-clear' pass removes stale stamps
;; and the visual-line walk re-stamps with the new `avail'.
;; Deduplicates buffers shown in multiple windows on the same frame.

(defun horizontal-layout--window-size-change (frame)
  "Schedule a pass-3 flush when a window on FRAME changes pixel width.

Ignores pure height changes (minibuffer growth, vertico popup) which
do not affect justification geometry — only the available pixel WIDTH
matters for text-align stamps.  Avoids `font-lock-flush' entirely:
passes 1–2 stamps are in character units and don't depend on window
width, so no re-fontification is needed.  The flush's own `:pre-clear'
handles stale stamp removal atomically before re-stamping."
  (let ((seen nil))
    (dolist (win (window-list frame 'no-minibuffer))
      (let ((buf (window-buffer win)))
        (when (and (buffer-live-p buf) (not (memq buf seen)))
          (push buf seen)
          (with-current-buffer buf
            (when (or (bound-and-true-p horizontal-layout-mode)
                      (bound-and-true-p text-align-mode))
              (let ((avail (window-body-width win t)))
                (when (not (equal avail horizontal-layout--last-avail))
                  (setq horizontal-layout--last-avail avail)
                  (face-extra--schedule-pass3-flush
                   buf
                   (window-start win)
                   (window-end win t)))))))))))

(add-hook 'window-size-change-functions
          #'horizontal-layout--window-size-change)

;; ---- Text scale: invalidate metric caches and reflow after text-scale-set ----
;;
;; `text-scale-set' changes face `:height' via `face-remapping-alist', which
;; alters rendered character widths.  The space-width cache (face →
;; natural-space-px) is stale after scaling; `face-extra--invalidate-cache'
;; clears it via `face-extra-invalidate-cache-functions', and `font-lock-flush'
;; triggers a full reflow so stamps are recomputed with correct metrics.

(defun horizontal-layout--after-text-scale (&rest _)
  "Invalidate caches and reflow after `text-scale-set'."
  (when (or (bound-and-true-p horizontal-layout-mode)
            (bound-and-true-p text-align-mode))
    (setq horizontal-layout--last-avail nil)
    (face-extra--invalidate-cache)
    (font-lock-flush)))

(advice-add 'text-scale-set :after #'horizontal-layout--after-text-scale)

;; ---- org-appear: clear justify stamps on the visual line at point ----
;;
;; org-appear--show-with-lock calls font-lock-ensure BEFORE show-invisible,
;; so pass-3 runs and re-stamps with narrow (markers-hidden) geometry; then
;; show-invisible makes the markers visible, widening the line.  Redisplay
;; sees narrow stamps on a now-wider line → last word overflows → cascade.
;;
;; Fix for show: advise :after org-appear--show-invisible.  Markers are now
;; visible; clear stamps on the visual line at point and schedule a scoped
;; pass-3 flush for that line so the next redisplay sees natural spacing
;; rather than an overflowed line.
;;
;; Fix for hide: advise :before org-appear--hide-invisible.  Clear stamps on
;; the visual line before markers disappear; org-appear's own font-lock-flush/
;; ensure then drives a clean pass-3 reflow at the new narrower width.
;;
;; Visual line bounds are computed with vertical-motion — safe in post-command
;; (outside the pass-3 walk) and correctly scoped to one wrapped line.
;; fontification-functions is bound to nil to prevent jit-lock re-entry.
;;
;; Advice is installed once when org-appear loads, not per-buffer.

(defun horizontal-layout--org-appear-restamp (&rest _)
  "Synchronously re-stamp the visual line at point after org-appear toggle.

Called :after both `org-appear--show-invisible' and
`org-appear--hide-invisible' so that justify stamps are recomputed at
the correct geometry — wide with markers visible, narrow with markers
hidden — before the next redisplay cycle.

`face-extra--dispatch-pass3' is called directly rather than scheduling
an idle flush.  We are in post-command (outside any pass-3 walk), so
`face-extra--pass3-geometry-unsettled' is nil and `vertical-motion' is
safe.  Pass-3's own :pre-clear removes stale stamps before
re-measuring, so no separate clear step is needed.

The visual line bounds passed here are consumed by pass-3's non-idle
narrowing logic, which also computes them via `vertical-motion' — the
two calls are redundant but cheap and make the intent explicit."
  (when (bound-and-true-p text-align-mode)
    (when-let ((vline (horizontal-layout--org-appear-vline)))
      (face-extra--dispatch-pass3 (car vline) (cdr vline)))))

(defun horizontal-layout--org-appear-vline ()
  "Return (beg . end) of the visual line at point, or nil if no window."
  (when (get-buffer-window (current-buffer) t)
    (save-excursion
      (let ((fontification-functions nil))
        (vertical-motion 0)
        (let ((vbeg (point)))
          (vertical-motion 1)
          (cons vbeg (point)))))))

(with-eval-after-load 'org-appear
  (advice-add 'org-appear--show-invisible :after
              #'horizontal-layout--org-appear-restamp)
  (advice-add 'org-appear--hide-invisible :after
              #'horizontal-layout--org-appear-restamp))

(provide 'horizontal-layout)
;;; horizontal-layout.el ends here
