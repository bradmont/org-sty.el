;;; page-metrics.el --- Physical page measurements for org-sty -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: wp, text
;; Version: 0.1.0

;;; Commentary:

;; `page-metrics' translates a physical page model (page size in mm, margin
;; widths in mm) into the concrete Emacs parameters that `olivetti-mode'
;; needs to render a fixed-width page in the window.
;;
;; Scope
;; ─────
;; This package knows about: page dimensions, margin widths, frame DPI, and
;; how to derive pixel measurements from these.  It does NOT know about font
;; sizes, floor heights, line spacing, or Org element structure.  Those belong
;; to `variable-spacing' and `org-sty'.
;;
;; Olivetti integration
;; ────────────────────
;; Olivetti is used as-is; we configure it rather than modifying it.
;;
;; `olivetti-body-width' is set as an *integer* column count — the text-area
;; width in units of the default face character width.  Integer mode is
;; stable under `text-scale-mode': zooming changes how many characters fit
;; per line, not the declared column count that defines the page boundary.
;; When the window is narrower than the requested body width, Olivetti
;; degrades gracefully on its own; no special handling is needed here.
;;
;; `olivetti-margin-width' is made buffer-local so different documents with
;; different physical margins don't interfere.  It is set to the average of
;; the left and right margin column counts to centre the page in the window.
;; A buffer-local `page-metrics--margin-delta' holds (left − right) / 2;
;; this is applied by an :after advice on `olivetti-set-window' to correct
;; Olivetti's symmetric layout for asymmetric page margins.
;;
;; Column width derivation (no screen DPI)
;; ────────────────────────────────────────
;; All measurements start in mm, are converted to typographic points
;; (1 pt = 25.4/72 mm — a pure constant), then to pixels via the ratio of
;; frame-char-height (px) to the default face :height (1/10-pt units).
;; Because frame-char-height and frame-char-width live in the same Emacs
;; pixel coordinate space, their ratio to each other is inherently correct
;; regardless of monitor DPI, HiDPI scaling, or Wayland reporting quirks.
;; Screen DPI is never consulted.

;;; Code:

(require 'cl-lib)

;; Olivetti is a required dependency at runtime but we soft-require it here
;; so byte-compilation does not hard-fail when olivetti is not in the path.
;; The minor mode body guards with (featurep 'olivetti).
(require 'olivetti nil t)

;; Forward declarations for olivetti symbols used in this file.
(defvar olivetti-body-width)
(defvar olivetti-margin-width)
(defvar olivetti-minimum-body-width)
(declare-function olivetti-mode             "olivetti" (&optional arg))
(declare-function olivetti-set-buffer-windows "olivetti" ())


;;;; ================================================================
;;;; Section 1 — Page size library
;;;; ================================================================

(defconst page-metrics-page-sizes
  '((a4     . (:width 210.0  :height 297.0))
    (letter . (:width 215.9  :height 279.4))
    (legal  . (:width 215.9  :height 355.6))
    (a5     . (:width 148.0  :height 210.0)))
  "Standard page sizes in mm.
Keys are symbols; values are plists with :width and :height in millimetres.")

(defconst page-metrics-size-margins
  ;; letter/legal: 1 inch (25.4 mm) all around — Word 2007+ default.
  ;; a4/a5:        20 mm all around — LibreOffice/OpenOffice default.
  '((letter . (:top 25.4 :bottom 25.4 :left 25.4 :right 25.4))
    (a4     . (:top 20.0 :bottom 20.0 :left 20.0 :right 20.0))
    (legal  . (:top 25.4 :bottom 25.4 :left 25.4 :right 25.4))
    (a5     . (:top 20.0 :bottom 20.0 :left 20.0 :right 20.0)))
  "Default margins in mm for each standard page size.
Values are sourced from widely-used word processor defaults:
letter/legal use Word 2007+ (1 inch = 25.4 mm all around);
a4/a5 use LibreOffice Writer (20 mm all around).
These are the starting point used by `page-metrics-set-page'; override
individual margin vars afterwards for non-standard margins.")


;;;; ================================================================
;;;; Section 2 — Buffer-local page parameters
;;;; ================================================================

(defvar-local page-metrics-page-size 'letter
  "Page size for this buffer.
Either a symbol from `page-metrics-page-sizes' (e.g. \\='a4, \\='letter)
or a custom plist (:width MM :height MM).

Do not set this directly when also changing margins; use
`page-metrics-set-page' instead, which sets the size and resets all
four margin vars from `page-metrics-size-margins' in one step.
Intended to be called from an org-sty style plist `:eval' block.")

;; Margin defaults match the letter entry in `page-metrics-size-margins'
;; (Word 2007+ standard: 1 inch = 25.4 mm all around).
(defvar-local page-metrics-margin-top    25.4
  "Top margin in millimetres.")

(defvar-local page-metrics-margin-bottom 25.4
  "Bottom margin in millimetres.")

(defvar-local page-metrics-margin-left   25.4
  "Left margin in millimetres.")

(defvar-local page-metrics-margin-right  25.4
  "Right margin in millimetres.")

(defun page-metrics-set-page (size)
  "Set page SIZE and reset margins from `page-metrics-size-margins'.
SIZE is a symbol from `page-metrics-page-sizes' (e.g. \\='letter, \\='a4).
The four margin buffer-locals are overwritten with the values from
`page-metrics-size-margins'; call this before any per-document margin
overrides.  Intended for use in an org-sty style plist `:eval' block:

  (page-metrics-set-page \\='letter)

After the call, individual margins can be further adjusted:

  (setq-local page-metrics-margin-left 31.75)"
  (unless (assq size page-metrics-page-sizes)
    (error "page-metrics-set-page: unknown page size `%s'" size))
  (setq-local page-metrics-page-size size)
  (let ((m (cdr (assq size page-metrics-size-margins))))
    (when m
      (setq-local page-metrics-margin-top    (plist-get m :top))
      (setq-local page-metrics-margin-bottom (plist-get m :bottom))
      (setq-local page-metrics-margin-left   (plist-get m :left))
      (setq-local page-metrics-margin-right  (plist-get m :right)))))


;;;; ================================================================
;;;; Section 3 — Unit conversion
;;;; ================================================================

;; Screen DPI is not used anywhere in this module.  Physical page
;; dimensions (mm) are first converted to typographic points — a purely
;; typographic constant (1 pt = 25.4/72 mm) with no screen involvement.
;; Points are then converted to Emacs pixels via the ratio of the
;; typographic em (ascent+descent from `font-info', in pixels) to the
;; default face :height (in 1/10-pt units).  `frame-char-height' is NOT
;; used: it returns the cell height (em + line-gap/leading), which inflates
;; the px/pt ratio by ~1.3–1.5× and produces incorrect column counts.
;;
;; All metrics must be read at the frame level.  `face-font' (even called
;; with a frame argument) consults `face-remapping-alist' in the current
;; buffer, so in a `variable-spacing-mode' buffer it returns the 6pt floor
;; font rather than the frame default, mixing two different faces' metrics
;; and producing a wrong px/pt.  `frame-parameter' \\='font bypasses face
;; resolution entirely and is the correct source for font-px.
;; `face-attribute' \\='default :height FRAME correctly reads the frame-level
;; height (unaffected by buffer-local remaps).  `frame-char-width' is also
;; frame-level and is the right column unit because it is exactly what
;; Olivetti uses when it interprets an integer `olivetti-body-width'.

(defconst page-metrics--pt-per-mm (/ 72.0 25.4)
  "Typographic points per millimetre.  1 pt = 25.4/72 mm ≈ 0.353 mm.")

(defun page-metrics--mm-to-pts (mm)
  "Convert MM millimetres to typographic points.
This is a pure typographic constant; no screen metrics are involved."
  (* mm page-metrics--pt-per-mm))

(defun page-metrics--font-px (&optional frame)
  "Return the rendered pixel size of the frame default font.

Uses `frame-parameter' \\='font and `font-info' index 2 (pixel-size).
This is the size the font was requested at (e.g. 15px for an 11.3pt
font at 96 dpi) and is the correct numerator for the px/pt ratio.

font-info indices 8+9 (ascent+descent) are NOT used: they measure the
typographic bounding box, which for fonts with generous metrics (e.g.
Hack, where ascent+descent = cell height = 18 for a 15px font) exceeds
the nominal pixel size and inflates the px/pt ratio.  index 3 (cell
height) has the same problem for the same reason.

`face-font' (even with a frame argument) consults `face-remapping-alist'
and can return a buffer-local remapped font.  `frame-parameter' \\='font
bypasses all face resolution and always returns the true frame font."
  (let* ((f    (or frame (selected-frame)))
         (font (frame-parameter f 'font))
         (fi   (and font (font-info font))))
    (when (and fi (> (aref fi 2) 0))
      (aref fi 2))))   ; ascent + descent

(defun page-metrics--pts-to-px (pts &optional frame)
  "Convert PTS typographic points to Emacs pixels using frame font metrics.

Derivation (no screen DPI):
  face-h   = (face-attribute \\='default :height frame) — 1/10-pt, e.g. 113
  font-px  = page-metrics--font-px FRAME  — font-info index 2 (pixel-size),
                                            the size the font was requested at
  px/pt    = font-px × 10 / face-h
  result   = pts × px/pt

Both face-h and font-px are read at the frame level, bypassing any
buffer-local face remaps (e.g. the variable-spacing floor remap on
`default').  `frame-char-height' and font-info ascent+descent are NOT
used: for fonts like Hack, both equal the cell height (18px for a 15px
font), inflating px/pt and producing column counts that are too high.
font-info index 2 (pixel-size = 15px) is the correct numerator."
  (let* ((f       (or frame (selected-frame)))
         (face-h  (face-attribute 'default :height f))
         (font-px (page-metrics--font-px f)))
    (when (and (integerp face-h) (> face-h 0) font-px)
      (/ (* pts font-px 10.0) face-h))))


;;;; ================================================================
;;;; Section 4 — Derived pixel measurements
;;;; ================================================================

(defun page-metrics--size-plist ()
  "Return the (:width :height) plist for `page-metrics-page-size'.
Signals an error for unknown page-size symbols."
  (if (symbolp page-metrics-page-size)
      (or (cdr (assq page-metrics-page-size page-metrics-page-sizes))
          (error "page-metrics: unknown page size `%s'; \
add it to `page-metrics-page-sizes' or use a (:width MM :height MM) plist"
                 page-metrics-page-size))
    page-metrics-page-size))

(defun page-metrics-page-width-mm ()
  "Declared page width in mm for the current buffer."
  (plist-get (page-metrics--size-plist) :width))

(defun page-metrics-page-height-mm ()
  "Declared page height in mm for the current buffer."
  (plist-get (page-metrics--size-plist) :height))

(defun page-metrics-mm-to-px (mm &optional frame)
  "Convert MM millimetres to Emacs pixels using frame font metrics."
  (page-metrics--pts-to-px (page-metrics--mm-to-pts mm) frame))

(defun page-metrics-page-width-px (&optional frame)
  "Full page width in pixels."
  (page-metrics-mm-to-px (page-metrics-page-width-mm) frame))

(defun page-metrics-page-height-px (&optional frame)
  "Full page height in pixels."
  (page-metrics-mm-to-px (page-metrics-page-height-mm) frame))

(defun page-metrics-text-area-width-px (&optional frame)
  "Text area width in pixels (page width minus left and right margins)."
  (page-metrics-mm-to-px (- (page-metrics-page-width-mm)
                             page-metrics-margin-left
                             page-metrics-margin-right)
                          frame))

(defun page-metrics-text-area-height-px (&optional frame)
  "Text area height in pixels (page height minus top and bottom margins)."
  (page-metrics-mm-to-px (- (page-metrics-page-height-mm)
                             page-metrics-margin-top
                             page-metrics-margin-bottom)
                          frame))


;;;; ================================================================
;;;; Section 5 — Olivetti integration
;;;; ================================================================

;; Allow each buffer to have its own olivetti-margin-width so different
;; documents with different physical page geometries don't interfere.
(make-variable-buffer-local 'olivetti-margin-width)

(defvar-local page-metrics--margin-delta 0
  "Asymmetry correction in frame-char-width columns.
Added to the left window margin and subtracted from the right after
Olivetti sets its symmetric margins.  Positive when the left page margin
is wider than the right.  Computed by `page-metrics-apply'.")

(defun page-metrics--mm-to-cols (mm &optional frame)
  "Convert MM millimetres to a column count in the default face character width.

Derivation (no screen DPI):
  px  = page-metrics-mm-to-px MM FRAME   — pts × px/pt via frame font metrics
  col = frame-char-width FRAME            — px per column, frame default face
  result = round (px / col)

`frame-char-width' is the frame-level default face character width,
unaffected by buffer-local face remaps.  Because both px values are in
the same Emacs pixel coordinate space their ratio is DPI-independent."
  (let* ((f   (or frame (selected-frame)))
         (px  (page-metrics-mm-to-px mm f))
         (col (float (frame-char-width f))))
    (and px (> col 0) (round (/ px col)))))

(defun page-metrics-apply (&optional frame)
  "Compute and apply Olivetti parameters from the buffer-local page model.

Sets `olivetti-body-width' to the text-area width in character columns
(an integer), `olivetti-margin-width' to the average of the left and
right margin column counts, and `page-metrics--margin-delta' to the
asymmetry correction (left − right) / 2.

Olivetti accepts an integer `olivetti-body-width' as an absolute column
count, which is stable under `text-scale-mode' — zooming changes how
many characters fit per line, not the declared column width.  When the
window is narrower than the requested body width Olivetti degrades
gracefully without any special handling here.

Call this after the font face remap has been applied so `frame-char-width'
reflects the actual rendered character width."
  (let* ((f           (or frame (selected-frame)))
         (body-cols   (page-metrics--mm-to-cols
                       (- (page-metrics-page-width-mm)
                          page-metrics-margin-left
                          page-metrics-margin-right)
                       f))
         (left-cols   (page-metrics--mm-to-cols page-metrics-margin-left  f))
         (right-cols  (page-metrics--mm-to-cols page-metrics-margin-right f))
         (avg-cols    (max 1 (round (/ (+ (or left-cols 0)
                                          (or right-cols 0))
                                       2.0)))))
    (when body-cols
      ;; Feed Olivetti integer column widths.
      (setq olivetti-body-width   body-cols
            olivetti-margin-width avg-cols)
      ;; Store the asymmetry correction for the advice on olivetti-set-window.
      (setq page-metrics--margin-delta
            (round (/ (float (- (or left-cols 0) (or right-cols 0))) 2)))
      ;; Ask Olivetti to recompute and redisplay.
      (when (bound-and-true-p olivetti-mode)
        (olivetti-set-buffer-windows)))))


;;;; ================================================================
;;;; Section 6 — Olivetti asymmetry advice
;;;; ================================================================

(defun page-metrics--olivetti-adjust (window-or-frame)
  "Shift Olivetti's symmetric margins to match asymmetric page margins.
Applied as :after advice on `olivetti-set-window'.  Is a no-op in
buffers where `page-metrics-mode' is not active or where left and right
margins are already equal."
  (when (and (bound-and-true-p page-metrics-mode)
             (not (zerop page-metrics--margin-delta)))
    (let ((delta   page-metrics--margin-delta)
          (windows (if (framep window-or-frame)
                       (get-buffer-window-list nil nil window-or-frame)
                     (list window-or-frame))))
      (dolist (w windows)
        (when (and (window-live-p w)
                   (eq (window-buffer w) (current-buffer)))
          (let* ((m     (window-margins w))
                 (left  (max 0 (+ (or (car m) 0) delta)))
                 (right (max 0 (- (or (cdr m) 0) delta))))
            (set-window-margins w left right)))))))

;; Install the advice once at load time.  The guard inside the function
;; makes it a no-op everywhere except page-metrics-mode buffers.
(advice-add 'olivetti-set-window :after #'page-metrics--olivetti-adjust)


;;;; ================================================================
;;;; Section 7 — Minor mode
;;;; ================================================================

(defvar page-metrics-width-change-functions nil
  "Abnormal hook run when the window width crosses the page-width threshold.
Each function receives one argument: non-nil if the window is now too
narrow for the page, nil if it has become wide enough again.

Reserved for the future pagination layer.  Not triggered by
`page-metrics-apply' in the current implementation; Olivetti already
degrades gracefully when the window is narrower than `olivetti-body-width'.")

(defun page-metrics--on-size-change (window-or-frame)
  "Recompute page metrics when a window or frame changes size.
`window-size-change-functions' passes a window on some Emacs versions
and a frame on others; handle both, as Olivetti does."
  (when (bound-and-true-p page-metrics-mode)
    (let ((frame (if (framep window-or-frame)
                     window-or-frame
                   (window-frame window-or-frame))))
      (when (get-buffer-window (current-buffer) frame)
        (page-metrics-apply frame)))))

;;;###autoload
(define-minor-mode page-metrics-mode
  "Apply physical page measurements to Olivetti in this buffer.

Reads the buffer-local `page-metrics-page-size' and `page-metrics-margin-*'
variables, derives Olivetti parameters from them, and keeps them updated
as the window or frame changes size.

Intended to be enabled by `org-sty-apply' after the font face remap has
been applied (so `frame-char-width' reflects the actual rendered font).
Can also be enabled interactively for testing."
  :lighter " PgM"
  (if page-metrics-mode
      (progn
        (unless (featurep 'olivetti)
          (user-error "page-metrics-mode requires olivetti to be loaded"))
        (add-hook 'window-size-change-functions
                  #'page-metrics--on-size-change nil t)
        (unless (bound-and-true-p olivetti-mode)
          (olivetti-mode 1))
        (page-metrics-apply))
    (remove-hook 'window-size-change-functions
                 #'page-metrics--on-size-change t)
    (kill-local-variable 'page-metrics--margin-delta)
    (kill-local-variable 'olivetti-margin-width)))


(provide 'page-metrics)
;;; page-metrics.el ends here
