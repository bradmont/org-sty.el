;;; horizontal-layout.el --- Synthetic face properties for horizontal text layout -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: faces, display
;; Version: 0.1.0

;;; Commentary:

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
        (delete-overlay ov))))))


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
                                            end)))
                         (existing (get-text-property pos 'line-prefix))
                         (prefix   (horizontal-layout--compose-prefix
                                    width existing)))
                    (when prefix
                      (put-text-property pos next 'line-prefix  prefix)
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
                   (combined (and (consp existing)
                                  (eq (car existing) 'space)
                                  (plist-get (cdr existing) :width)))
                   (height   (and (consp existing)
                                  (eq (car existing) 'space)
                                  (plist-get (cdr existing) :height)))
                   (left     (max 0 (- (or combined 0) right))))
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
                                          'face nil)))
          (setq pos next))))))

(defun text-align--stamp (lbeg lend value)
  "Stamp a margin-aware alignment prefix for the visual line LBEG..LEND.

VALUE is `center' or `right'; the offset accounts for any left/right
margins on the face at LBEG (see NEXT.md for derivation):
  center — left_px + (avail - left_px - right_px - text_px) / 2
  right  — avail - right_px - text_px

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
             (zone     (- avail left-px right-px))
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
        (when (> zone text-px)
          (let* ((offset (pcase value
                           ('center (+ left-px (/ (- zone text-px) 2)))
                           ('right  (- avail right-px text-px))))
                 (prefix (if height
                             `(space :align-to (,offset) :height ,height)
                           `(space :align-to (,offset)))))
            (put-text-property lbeg (1+ lbeg) prefix-prop prefix)
            (put-text-property lbeg (1+ lbeg) text-align--prop t)))))))

(defun text-align--apply (spans)
  "Apply text alignment for SPANS from `face-extra--dispatch-pass3'.

SPANS is a list of (lbeg lend value) triples, one per visual line.
Apply functions must NOT call `vertical-motion'.

Dispatches on value:
  `center'      — stamps a centering `line-prefix'/`wrap-prefix' at lbeg.
  `right'       — stamps a right-align prefix at lbeg.
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
  :pass  3
  :after '(horizontal-layout-margin-right)
  :apply  #'text-align--apply
  :clear  #'text-align--clear-marker)

(provide 'horizontal-layout)
;;; horizontal-layout.el ends here
