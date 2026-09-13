;;; org-sty.el --- Per-filetag visual styling for Org buffers -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: org, convenience
;; Version: 1.0-beta

;;; Commentary:

;; Applies a visual "profile" to an Org buffer based on its #+FILETAGS.
;; Define styles per tag in `org-sty-alist', and this library applies the
;; matching style(s) whenever an Org file with those tags is opened.
;;
;; Quick start:
;;
;;   (add-hook 'org-mode-hook #'org-sty-mode)
;;
;;   (setq org-sty-default
;;         '(:font "Iosevka Aile" :eval (...)))
;;
;;   (setq org-sty-alist
;;         '(("thesis" . (:font "Times New Roman" :font-size 12
;;                        :num-level 3 :indent nil :olivetti-width 68
;;                        :eval (progn
;;                                (variable-spacing-mode 1)
;;                                (org-title-fold-mode 1))))))
;;
;; If a buffer has several matching tags, their styles are merged in
;; the order they appear in `org-sty-alist' (later entries win on
;; conflicting keys).  `org-sty-default' supplies a baseline applied
;; to every Org buffer before any tag-specific style is layered on top.
;;
;; Since filetags can change after the buffer is opened (e.g. via
;; `org-set-tags-command' or hand-editing #+FILETAGS), call
;; `org-sty-refresh' (bound to whatever key you like) to re-apply.
;; It is also wired in automatically after `org-set-tags-command'.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'face-remap)
(require 'variable-spacing)

(defgroup org-sty nil
  "Apply visual styles to Org buffers based on filetags."
  :group 'org)

(defcustom org-sty-alist nil
  "Alist mapping a filetag (string) to a style plist.

Recognized plist keys:

  :font            Font family name, e.g. \"Times New Roman\".
  :font-size       Point size, e.g. 12. Combined with :font via
                    `buffer-face-mode'; either can be given alone.
  :num-level       Heading depth for `org-num-mode' numbering
                    (sets `org-num-max-level' and enables the mode).
                    Use `off' or nil-with-explicit key absence to
                    leave org-num-mode alone; use 0 to disable it.
  :indent          t to enable `org-indent-mode', nil to disable it.
  :olivetti-width  Integer for `olivetti-body-width' (enables
                    `olivetti-mode' if it is installed).
  :faces           An alist of (FACE . ATTRS-PLIST) pairs installed as
                    buffer-local face remaps via `face-remap-add-relative'.
                    The special pseudo-attribute `:variable-spacing-ratio'
                    is routed to `variable-spacing-face-remap-add-extra'
                    rather than the remap (requires `variable-spacing').
                    All remaps are tracked and removed on re-apply, so
                    re-applying a style is idempotent.  To perform face
                    remaps with runtime values, call `org-sty-remap'
                    from `:eval' instead.
  :eval            A single form, or list of forms, run via `eval'
                    after the other keys are applied.  Use this for mode
                    toggles and runtime logic; use `:faces' for face
                    attribute overrides.  Bare `set-face-attribute' calls
                    in `:eval' are an anti-pattern -- they are global and
                    not cleaned up on re-apply.

Any key may be omitted; omitted keys are simply not touched for
that tag (they neither turn a setting on nor off)."
  :type '(alist :key-type string :value-type plist)
  :group 'org-sty)

(defcustom org-sty-default nil
  "Baseline style plist applied to every Org buffer, before tag styles.

Same keys as the values in `org-sty-alist'.  Tag-specific styles are
layered on top of this and win on overlapping keys."
  :type 'plist
  :group 'org-sty)

;;; Internal state

(defun org-sty--merge (base override)
  "Merge plist OVERRIDE onto plist BASE, OVERRIDE winning on conflicts."
  (let ((result (copy-sequence base)))
    (cl-loop for (k v) on override by #'cddr
             do (setq result (plist-put result k v)))
    result))

(defun org-sty--current-tags ()
  "Return the current buffer's filetags as a list of strings."
  (when (derived-mode-p 'org-mode)
    ;; `org-file-tags' is populated from #+FILETAGS by the time
    ;; `org-mode-hook' runs, and stays current if the buffer is
    ;; re-scanned (e.g. `org-set-regexps-and-options').
    org-file-tags))

(defun org-sty--effective-style ()
  "Compute the merged style plist for the current buffer's filetags."
  (let ((style org-sty-default))
    (dolist (tag (org-sty--current-tags) style)
      (let ((tag-style (cdr (assoc tag org-sty-alist))))
        (when tag-style
          (setq style (org-sty--merge style tag-style)))))))

(defconst org-sty--heading-faces
  '(org-level-1 org-level-2 org-level-3 org-level-4 org-level-5 org-level-6
    org-level-7 org-level-8 org-document-title)
  "Faces whose :family should follow the buffer's :font style.

These are handled separately from `default' because Org heading
faces (and things like `org-document-title') commonly get their own
explicit :family set globally -- e.g. by a default style's :eval
block that also sets per-level :height/:weight.  Remapping `default'
alone doesn't reach them, so a tag's :font override would otherwise
apply to body text but not headings.")

(defvar-local org-sty--heading-remap-cookies nil
  "Cookies from remapping `org-sty--heading-faces', for cleanup.")

(defun org-sty--clear-heading-remaps ()
  "Remove all heading face remaps tracked in `org-sty--heading-remap-cookies'."
  (dolist (cookie org-sty--heading-remap-cookies)
    (face-remap-remove-relative cookie))
  (setq org-sty--heading-remap-cookies nil))

(defvar-local org-sty--face-remap-cookies nil
  "Tagged cookies for remaps installed by `:faces' or `org-sty-remap'.

Each element is a cons cell whose car is either:
  `remap' — cdr is a cookie from `face-remap-add-relative',
             removed via `face-remap-remove-relative'.
  `extra'  — cdr is a cookie from
             `variable-spacing-face-remap-add-extra', removed via
             `variable-spacing-face-remap-remove-extra'.

The list is cleared and rebuilt on each call to `org-sty-apply'.")

(defun org-sty--clear-face-remaps ()
  "Remove all face remaps tracked in `org-sty--face-remap-cookies'."
  (dolist (tagged org-sty--face-remap-cookies)
    (pcase (car tagged)
      ('remap (face-remap-remove-relative (cdr tagged)))
      ('extra (when (fboundp 'variable-spacing-face-remap-remove-extra)
                (variable-spacing-face-remap-remove-extra (cdr tagged))))))
  (setq org-sty--face-remap-cookies nil))

(defvar-local org-sty--eval-activated-modes nil
  "Minor modes newly activated by the last `:eval' run.
Recorded so `org-sty--disable' can turn them off cleanly.")

(defconst org-sty--known-eval-modes
  '(variable-spacing-mode org-title-fold-mode org-block-appear-mode org-num-mode)
  "Minor modes that `:eval' commonly activates; tracked for teardown.")

;;; Apply helpers

;;;###autoload
(defun org-sty-remap (face &rest attrs)
  "Install a buffer-local face remap for FACE using ATTRS, tracking the cookie.

ATTRS is a plist of face attributes and values, as accepted by
`face-remap-add-relative'.  The special pseudo-attribute
`:variable-spacing-ratio' is handled separately: it is stripped from
ATTRS and routed to `variable-spacing-face-remap-add-extra' (if
`variable-spacing' is loaded), so that spacing ratios are stored as
symbol properties and cleaned up correctly on re-apply.

All cookies are pushed onto `org-sty--face-remap-cookies' and are
removed automatically on the next `org-sty-apply' call, making
re-application idempotent.

This function may also be called directly from an `:eval' block for
cases requiring runtime values or conditional logic:

  (org-sty-remap \\='org-quote
                 :slant \\='italic
                 :variable-spacing-ratio 1.0)"
  (let ((ratio (plist-get attrs :variable-spacing-ratio))
        (rest  (cl-loop for (k v) on attrs by #'cddr
                        unless (eq k :variable-spacing-ratio)
                        append (list k v))))
    (when rest
      (push (cons 'remap (apply #'face-remap-add-relative face rest))
            org-sty--face-remap-cookies))
    (when (and ratio (fboundp 'variable-spacing-face-remap-add-extra))
      (push (cons 'extra
                  (variable-spacing-face-remap-add-extra
                   face 'variable-spacing-ratio ratio))
            org-sty--face-remap-cookies))))

(defun org-sty--apply-faces (plist)
  "Apply the `:faces' alist from PLIST via `org-sty-remap'."
  (dolist (entry (plist-get plist :faces))
    (apply #'org-sty-remap (car entry) (cdr entry))))

(defun org-sty--apply-font (plist)
  "Apply :font / :font-size from PLIST by owning the `default' remap,
and buffer-locally override the family on `org-sty--heading-faces'.

This deliberately does NOT use `face-remap-add-relative' for
`default', because relative remaps compose/stack: if anything else
on `org-mode-hook' (or elsewhere) also remaps `default' -- e.g. a
hand-rolled variable-pitch-font hook -- whichever remap was added
later wins, and that's not something we can reliably control by
ordering alone.  Instead this strips any existing `default' entry
from `face-remapping-alist' and installs ours as the sole remap for
that face, so the result doesn't depend on hook execution order.

Heading faces are handled with a plain relative :family-only remap
instead, since nothing else in this library touches them and we
want to preserve whatever :height/:weight is already set on them."
  (let ((family (plist-get plist :font))
        (size (plist-get plist :font-size))
        (others (assq-delete-all 'default (copy-tree face-remapping-alist))))
    (if (not (or family size))
        (setq-local face-remapping-alist others)
      (let (face-spec)
        (when family (setq face-spec (plist-put face-spec :family family)))
        (when size (setq face-spec (plist-put face-spec :height (* size 10))))
        (setq-local face-remapping-alist (cons (list 'default face-spec) others))))
    (org-sty--clear-heading-remaps)
    (when family
      (dolist (face org-sty--heading-faces)
        (push (face-remap-add-relative face (list :family family))
              org-sty--heading-remap-cookies)))))

(defun org-sty--apply-num (plist)
  "Apply :num-level from PLIST."
  (when (plist-member plist :num-level)
    (let ((level (plist-get plist :num-level)))
      (if (and level (> level 0))
          (progn
            (setq-local org-num-max-level level)
            (when (fboundp 'org-num-mode) (org-num-mode 1)))
        (when (and (fboundp 'org-num-mode) (bound-and-true-p org-num-mode))
          (org-num-mode -1))))))

(defun org-sty--apply-indent (plist)
  "Apply :indent from PLIST."
  (when (plist-member plist :indent)
    (if (plist-get plist :indent)
        (org-indent-mode 1)
      (org-indent-mode -1))))

(defun org-sty--apply-olivetti (plist)
  "Apply :olivetti-width from PLIST."
  (let ((width (plist-get plist :olivetti-width)))
    (when (and width (fboundp 'olivetti-mode))
      (setq-local olivetti-body-width width)
      (olivetti-mode 1))))

(defun org-sty--apply-eval (plist)
  "Run the `:eval' form(s) from PLIST, tracking newly-activated modes."
  (let ((forms (plist-get plist :eval)))
    (when forms
      (let ((before (seq-filter (lambda (m) (and (boundp m) (symbol-value m)))
                                org-sty--known-eval-modes)))
        (dolist (form (if (and (consp forms) (listp (car forms)))
                          forms
                        (list forms)))
          (eval form t))
        (setq org-sty--eval-activated-modes
              (seq-filter (lambda (m)
                            (and (boundp m) (symbol-value m)
                                 (not (memq m before))))
                          org-sty--known-eval-modes))))))

;;; Public API

;;;###autoload
(defun org-sty-apply ()
  "Apply the style matching this buffer's filetags.
Intended for use via `org-sty-mode'; safe to call directly to refresh."
  (when (derived-mode-p 'org-mode)
    ;; Force a fresh parse of #+FILETAGS rather than trusting that
    ;; `org-file-tags' is already populated at hook time -- cheap,
    ;; and removes any dependency on hook ordering.
    (org-set-regexps-and-options)
    (let ((style (org-sty--effective-style)))
      ;; Clear tracked face remaps first so re-apply is idempotent.
      (org-sty--clear-face-remaps)
      ;; Order matters: org-num-mode / org-indent-mode / olivetti-mode
      ;; are toggled here, and at least Olivetti can apply its own font
      ;; styling via `buffer-face-mode' when it turns on (depending on
      ;; `olivetti-style'). Apply ours last so it wins.
      (org-sty--apply-num style)
      (org-sty--apply-indent style)
      (org-sty--apply-olivetti style)
      (org-sty--apply-font style)
      ;; :eval runs before :faces so that mode toggles (e.g.
      ;; variable-spacing-mode) install their remaps first.  :faces
      ;; remaps are prepended last and therefore have the highest
      ;; priority, ensuring declared face attributes win over whatever
      ;; the enabled modes install.
      (org-sty--apply-eval style)
      (org-sty--apply-faces style))))

(defun org-sty--disable ()
  "Reverse all styling applied by `org-sty-mode' in this buffer."
  ;; Remove tracked face remaps and symbol-property effects.
  (org-sty--clear-face-remaps)
  (org-sty--clear-heading-remaps)
  ;; Remove the `default' face remap that --apply-font owns.
  (setq-local face-remapping-alist
              (assq-delete-all 'default face-remapping-alist))
  ;; Disable minor modes that were activated by `:eval'.
  (dolist (mode org-sty--eval-activated-modes)
    (when (and (fboundp mode) (boundp mode) (symbol-value mode))
      (funcall mode -1)))
  (setq org-sty--eval-activated-modes nil))

;;;###autoload
(defun org-sty-debug ()
  "Print detected filetags and the resulting merged style to *Messages*.
Use this to sanity-check why a style isn't (or is) being applied."
  (interactive)
  (if (not (derived-mode-p 'org-mode))
      (message "org-sty-debug: not in an Org buffer")
    (org-set-regexps-and-options)
    (let* ((tags (org-sty--current-tags))
           (style (org-sty--effective-style)))
      (message "org-sty: tags=%S style=%S" tags style))))

;;;###autoload
(defun org-sty-refresh ()
  "Re-scan filetags and re-apply the matching style.
Use this after editing #+FILETAGS by hand or via
`org-set-tags-command', since those don't automatically re-run
`org-mode-hook'."
  (interactive)
  (org-set-regexps-and-options)
  (org-sty-apply))

;;; Minor mode

;;;###autoload
(define-minor-mode org-sty-mode
  "Apply tag-driven visual styles to this Org buffer.

Reads #+FILETAGS, merges matching entries from `org-sty-alist' with
`org-sty-default', and applies the resulting style.  Disabling the
mode reverses all face remaps and turns off any minor modes that
were activated by the style's `:eval' form.

To enable for all Org buffers add to your init file:

  (add-hook \\='org-mode-hook #\\='org-sty-mode)"
  :lighter " Sty"
  :group 'org-sty
  (if org-sty-mode
      (when (derived-mode-p 'org-mode)
        (org-sty-apply))
    (org-sty--disable)))

;;;###autoload
(defalias 'org-style-mode 'org-sty-mode
  "Alias for `org-sty-mode'.  The file is org-sty.el; pronounced \"org-style\".")

;;; Hooks

(advice-add 'org-set-tags-command :after
            (lambda (&rest _) (org-sty-refresh)))

(provide 'org-sty)
;;; org-sty.el ends here
