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
;;;; Section 4 — Minor mode
;;;; ================================================================

;;;###autoload
(define-minor-mode horizontal-layout-mode
  "Apply synthetic horizontal layout properties to faces in this buffer.

Margin values are configured via `face-extra-add-relative' (buffer-local)
or `face-extra-add' (global):

  (face-extra-add-relative \\='org-quote \\='horizontal-layout-margin-left 40)

`face-extra--dispatch' owns the apply loop; this mode ensures dispatch
is active and handles cleanup on disable."
  :lighter " HLay"
  (if horizontal-layout-mode
      (progn
        (face-extra--enable-dispatch)
        (face-extra--invalidate-cache)
        (font-lock-flush))
    (horizontal-layout-clear)
    (face-extra--disable-dispatch)))


;;;; ================================================================
;;;; Section 5 — face-extra registration (load time)
;;;; ================================================================

(face-extra-define-property 'horizontal-layout-margin-left
  :pass  2
  :after nil
  :apply  #'horizontal-layout--apply-margin-left
  :clear  #'horizontal-layout--clear-margin-left)

(provide 'horizontal-layout)
;;; horizontal-layout.el ends here
