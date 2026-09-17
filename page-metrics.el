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
;; `olivetti-body-width' is set as a *float* (fraction of window width).
;; Olivetti's float branch in `olivetti-normalize-width' multiplies the
;; window pixel width by the fraction directly, bypassing `olivetti-scale-width'
;; entirely.  This means the body's pixel width stays fixed at `text-area-px'
;; regardless of `text-scale-mode', which is the correct behaviour for a
;; fixed physical page: zooming changes how many characters fit per line, not
;; the physical width of the page.
;;
;; `olivetti-margin-width' is made buffer-local at load time so different
;; documents can have different physical margins without interfering.  It is
;; set to the average of the declared left and right margin column counts,
;; which positions the fringes correctly for centering the full page in the
;; window.  A buffer-local `page-metrics--margin-delta' holds the asymmetry
;; correction (left − right) / 2; this is applied by an :after advice on
;; `olivetti-set-window' once Olivetti has finished its symmetric layout.
;;
;; Narrow-window handling
;; ──────────────────────
;; When the window is narrower than the page, `olivetti-body-width' is
;; clamped to 1.0 (Olivetti fills the window).  `page-metrics-mode' detects
;; this and runs `page-metrics-width-change-functions' so the pagination
;; layer can revert to non-paginated view and alert the user.  Pagination is
;; automatically re-enabled when the window becomes wide enough again (e.g.
;; after the user decreases zoom or widens the frame).
;;
;; DPI accuracy
;; ────────────
;; `display-mm-width' is unreliable on X11 (almost always 96 dpi regardless
;; of the actual screen).  Set `page-metrics-dpi-override' to the real
;; pixels-per-mm for the monitor if physical accuracy matters.  For typical
;; use the proportional relationships between page elements are correct even
;; with wrong DPI; only the absolute on-screen physical size is affected.

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


;;;; ================================================================
;;;; Section 2 — Buffer-local page parameters
;;;; ================================================================

(defvar-local page-metrics-page-size 'a4
  "Page size for this buffer.
Either a symbol from `page-metrics-page-sizes' (e.g. \\='a4, \\='letter)
or a custom plist (:width MM :height MM).  Set by `org-sty-apply' from
the style plist; can also be set buffer-locally via file- or dir-local
variables.")

(defvar-local page-metrics-margin-top    25.0
  "Top margin in millimetres.")

(defvar-local page-metrics-margin-bottom 25.0
  "Bottom margin in millimetres.")

(defvar-local page-metrics-margin-left   30.0
  "Left margin in millimetres.")

(defvar-local page-metrics-margin-right  25.0
  "Right margin in millimetres.")


;;;; ================================================================
;;;; Section 3 — DPI
;;;; ================================================================

(defvar page-metrics-dpi-override nil
  "Override the automatic pixels-per-mm ratio.
Nil means derive from `display-pixel-width' / `display-mm-width'
(unreliable on X11, which typically reports 96 dpi regardless of the
actual screen).

Set to a float (pixels per mm, e.g. 3.78 for 96 dpi, 5.51 for 140 dpi)
for a single global override, or to an alist of (FRAME . FLOAT) for
per-frame overrides when multiple monitors with different densities are
in use.")

(defun page-metrics--px-per-mm (&optional frame)
  "Return pixels per millimetre for FRAME.
Consults `page-metrics-dpi-override' before falling back to the display
geometry reported by the system."
  (or (cond
       ((null page-metrics-dpi-override) nil)
       ((listp page-metrics-dpi-override)
        (cdr (assq (or frame (selected-frame))
                   page-metrics-dpi-override)))
       (t page-metrics-dpi-override))
      (/ (float (display-pixel-width  frame))
         (display-mm-width frame))))


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
  "Convert MM millimetres to pixels on FRAME."
  (* mm (page-metrics--px-per-mm frame)))

(defun page-metrics-page-width-px (&optional frame)
  "Full page width in pixels on FRAME."
  (page-metrics-mm-to-px (page-metrics-page-width-mm) frame))

(defun page-metrics-page-height-px (&optional frame)
  "Full page height in pixels on FRAME."
  (page-metrics-mm-to-px (page-metrics-page-height-mm) frame))

(defun page-metrics-text-area-width-px (&optional frame)
  "Text area width in pixels on FRAME (page width minus left and right margins)."
  (page-metrics-mm-to-px (- (page-metrics-page-width-mm)
                             page-metrics-margin-left
                             page-metrics-margin-right)
                          frame))

(defun page-metrics-text-area-height-px (&optional frame)
  "Text area height in pixels on FRAME (page height minus top and bottom margins)."
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

(defvar-local page-metrics--was-narrow nil
  "Non-nil if the window was last known to be narrower than the page.
Used to detect transitions and only fire `page-metrics-width-change-functions'
on changes, not on every resize event.")

(defun page-metrics--narrow-p (&optional frame)
  "Return non-nil if the current window is narrower than the declared page."
  (< (window-pixel-width)
     (page-metrics-page-width-px frame)))

(defun page-metrics-apply (&optional frame)
  "Compute and apply Olivetti parameters from the buffer-local page model.

Derives `olivetti-body-width' (as a pixel-precise float fraction of the
window width), `olivetti-margin-width' (average of left/right margin
column counts), and `page-metrics--margin-delta' (asymmetry correction).

Call this after the font face remap has been applied so `frame-char-width'
reflects the actual rendered character width, and whenever the window or
frame geometry changes.

Runs `page-metrics-width-change-functions' if the narrow-window state
has changed since the last call."
  (let* ((px/mm      (page-metrics--px-per-mm frame))
         (text-px    (page-metrics-text-area-width-px frame))
         (left-px    (* page-metrics-margin-left  px/mm))
         (right-px   (* page-metrics-margin-right px/mm))
         ;; Use the window displaying this buffer if one exists, otherwise
         ;; fall back to the selected window.
         (win        (or (get-buffer-window (current-buffer) frame)
                         (selected-window)))
         (win-px     (float (window-body-width win t)))
         ;; Float fraction: Olivetti's float branch does window-px × fraction
         ;; directly, bypassing olivetti-scale-width.  This keeps the body
         ;; pixel-width stable under text-scale-mode.  Clamped to 1.0 when
         ;; the window is narrower than the page.
         (body-frac  (min 1.0 (/ text-px win-px)))
         ;; Column widths in frame-char-width units — the same unit Olivetti
         ;; passes to set-window-margins.  No floor-pt needed; we use
         ;; frame-char-width directly (the frame default, unaffected by
         ;; buffer-local face remaps).
         (col-px     (float (frame-char-width frame)))
         (left-cols  (round (/ left-px  col-px)))
         (right-cols (round (/ right-px col-px)))
         (avg-cols   (max 1 (round (/ (+ left-cols right-cols) 2.0))))
         (now-narrow (< win-px (page-metrics-page-width-px frame))))
    ;; Feed Olivetti.
    (setq olivetti-body-width   body-frac
          olivetti-margin-width avg-cols)
    ;; Store the asymmetry correction for the advice on olivetti-set-window.
    (setq page-metrics--margin-delta
          (round (/ (float (- left-cols right-cols)) 2)))
    ;; Notify listeners if the narrow-window state has changed.
    (unless (eq now-narrow page-metrics--was-narrow)
      (setq page-metrics--was-narrow now-narrow)
      (run-hook-with-args 'page-metrics-width-change-functions now-narrow))
    ;; Ask Olivetti to recompute and redisplay.
    (when (bound-and-true-p olivetti-mode)
      (olivetti-set-buffer-windows))))


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

The pagination layer hooks here to revert to / restore paginated view.")

(defun page-metrics--on-size-change (frame)
  "Recompute page metrics when a window on FRAME changes size."
  (when (and (bound-and-true-p page-metrics-mode)
             (get-buffer-window (current-buffer) frame))
    (page-metrics-apply frame)))

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
    (kill-local-variable 'page-metrics--was-narrow)
    (kill-local-variable 'olivetti-margin-width)))


(provide 'page-metrics)
;;; page-metrics.el ends here
