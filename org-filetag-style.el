;;; org-filetag-style.el --- Per-filetag visual styling for Org buffers -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: org, convenience
;; Version: 0.1

;;; Commentary:

;; Applies a visual "profile" to an Org buffer based on its #+FILETAGS.
;; Define styles per tag (font, line-spacing, heading numbering depth,
;; org-indent-mode, olivetti width, or arbitrary code) in
;; `org-filetag-style-alist', and this library applies the matching
;; style(s) whenever an Org file with those tags is opened.
;;
;; Example config:
;;
;; (setq org-filetag-style-alist
;;       '(("thesis"  . (:font "Times New Roman" :font-size 12
;;                       :line-spacing 0.6 :num-level 3
;;                       :indent nil :olivetti-width 64))
;;         ("book"    . (:font "Times New Roman" :font-size 12
;;                       :line-spacing 0.6 :num-level 3
;;                       :indent nil :olivetti-width 64))
;;         ("article" . (:font "Georgia" :font-size 11
;;                       :line-spacing 0.4 :num-level 1
;;                       :indent nil :olivetti-width 72))
;;         ("chapter" . (:font "Times New Roman" :font-size 12
;;                       :line-spacing 0.6 :num-level 3
;;                       :indent nil :olivetti-width 64))))
;;
;; (add-hook 'org-mode-hook #'org-filetag-style-apply)
;;
;; If a buffer has several matching tags, their styles are merged in
;; the order they appear in `org-filetag-style-alist' (later entries
;; win on conflicting keys). `org-filetag-style-default' supplies
;; fallback values / a baseline applied to every Org buffer before
;; any tag-specific style is layered on top.
;;
;; Since filetags can change after the buffer is opened (e.g. via
;; `org-set-tags-command' or hand-editing #+FILETAGS), call
;; `org-filetag-style-refresh' (bound to whatever key you like) to
;; re-apply. It is also wired in automatically after
;; `org-set-tags-command'.

;;; Code:

(require 'cl-lib)
(require 'org)

(defgroup org-filetag-style nil
  "Apply visual styles to Org buffers based on filetags."
  :group 'org)

(defcustom org-filetag-style-alist nil
  "Alist mapping a filetag (string) to a style plist.

Recognized plist keys:

  :font            Font family name, e.g. \"Times New Roman\".
  :font-size       Point size, e.g. 12. Combined with :font via
                    `buffer-face-mode'; either can be given alone.
  :line-spacing    Value for the buffer-local `line-spacing' variable.
  :num-level       Heading depth for `org-num-mode' numbering
                    (sets `org-num-max-level' and enables the mode).
                    Use `off' or nil-with-explicit key absence to
                    leave org-num-mode alone; use 0 to disable it.
  :indent          t to enable `org-indent-mode', nil to disable it.
  :olivetti-width  Integer for `olivetti-body-width' (enables
                    `olivetti-mode' if it is installed).
  :eval            A single form, or list of forms, run via `eval'
                    after the other keys are applied -- an escape
                    hatch for anything not covered above.

Any key may be omitted; omitted keys are simply not touched for
that tag (they neither turn a setting on nor off)."
  :type '(alist :key-type string :value-type plist)
  :group 'org-filetag-style)

(defcustom org-filetag-style-default nil
  "Baseline style plist applied to every Org buffer, before tag styles.

Same keys as the values in `org-filetag-style-alist'. Tag-specific
styles are layered on top of this and win on overlapping keys."
  :type 'plist
  :group 'org-filetag-style)

(defun org-filetag-style--merge (base override)
  "Merge plist OVERRIDE onto plist BASE, OVERRIDE winning on conflicts."
  (let ((result (copy-sequence base)))
    (cl-loop for (k v) on override by #'cddr
             do (setq result (plist-put result k v)))
    result))

(defun org-filetag-style--current-tags ()
  "Return the current buffer's filetags as a list of strings."
  (when (derived-mode-p 'org-mode)
    ;; `org-file-tags' is populated from #+FILETAGS by the time
    ;; `org-mode-hook' runs, and stays current if the buffer is
    ;; re-scanned (e.g. `org-set-regexps-and-options').
    org-file-tags))

(defun org-filetag-style--effective-style ()
  "Compute the merged style plist for the current buffer's filetags."
  (let ((style org-filetag-style-default))
    (dolist (tag (org-filetag-style--current-tags) style)
      (let ((tag-style (cdr (assoc tag org-filetag-style-alist))))
        (when tag-style
          (setq style (org-filetag-style--merge style tag-style)))))))

(defvar org-filetag-style--block-delim-indent-installed nil
  "Whether `org-filetag-style-indent-block-delimiters' has already
registered its font-lock keyword. Guards against piling up duplicate
keywords if it's called from every buffer's style application.")

;;;###autoload
(defun org-filetag-style-indent-block-delimiters (&optional width)
  "Visually indent #+begin_/#+end_ lines by WIDTH tabs (default 1).

This doesn't touch the buffer's actual text -- it attaches a
`line-prefix' display property to the first character of each
delimiter line, purely cosmetic and safe to call from :eval in a
style plist. Registers its font-lock keyword once, globally for
`org-mode', the first time it's called."
  (unless org-filetag-style--block-delim-indent-installed
    (let ((prefix (make-string (or width 1) ?\t)))
      (font-lock-add-keywords
       'org-mode
       `(("^[ \t]*#\\+\\(?:begin\\|end\\)_[a-zA-Z_-]+.*$"
          (0 (progn
               (put-text-property (match-beginning 0) (1+ (match-beginning 0))
                                   'line-prefix ,prefix)
               nil))))
       'append))
    (setq org-filetag-style--block-delim-indent-installed t)))

(defvar org-filetag-style--block-end-hide-installed nil
  "Whether `org-filetag-style-hide-block-end-lines' has already
registered its font-lock keyword. Guards against piling up duplicate
keywords if it's called from every buffer's style application.")

;;;###autoload
(defface org-filetag-style-block-end-marker
  '((t :inherit shadow))
  "Face for the compact end-of-block marker drawn by
`org-filetag-style-hide-block-end-lines' in place of the full
#+end_ line."
  :group 'org-filetag-style)

(defvar org-filetag-style--block-end-hide-installed nil
  "Whether `org-filetag-style-hide-block-end-lines' has already
registered its font-lock keyword. Guards against piling up duplicate
keywords if it's called from every buffer's style application.")

;;;###autoload
(defun org-filetag-style-hide-block-end-lines (&optional marker)
  "Replace #+end_ lines with a compact MARKER (default \"#\"), appended
to the end of the block's last content line instead of shown on its
own row."
  (unless org-filetag-style--block-end-hide-installed
    (let ((marker-str (propertize (or marker "#") 'face 'org-filetag-style-block-end-marker)))
      (font-lock-add-keywords
       'org-mode
       `(("\n[ \t]*#\\+end_[a-zA-Z_-]+.*"
          (0 (progn
               (put-text-property (match-beginning 0) (match-end 0)
                                   'display ,marker-str)
               (put-text-property (match-beginning 0) (match-end 0)
                                   'font-lock-multiline t)
               nil))))
       'append))
    (setq org-filetag-style--block-end-hide-installed t)))

(defconst org-filetag-style--heading-faces
  '(org-level-1 org-level-2 org-level-3 org-level-4 org-level-5 org-level-6
    org-level-7 org-level-8 org-document-title)
  "Faces whose :family should follow the buffer's :font style.

These are handled separately from `default' because Org heading
faces (and things like `org-document-title') commonly get their own
explicit :family set globally -- e.g. by a default style's :eval
block that also sets per-level :height/:weight. Remapping `default'
alone doesn't reach them, so a tag's :font override would otherwise
apply to body text but not headings.")

(defvar-local org-filetag-style--heading-remap-cookies nil
  "Cookies from remapping `org-filetag-style--heading-faces', for cleanup.")

(defun org-filetag-style--clear-heading-remaps ()
  (dolist (cookie org-filetag-style--heading-remap-cookies)
    (face-remap-remove-relative cookie))
  (setq org-filetag-style--heading-remap-cookies nil))

(defun org-filetag-style--apply-font (plist)
  "Apply :font / :font-size from PLIST by owning the `default' remap,
and buffer-locally override the family on `org-filetag-style--heading-faces'.

This deliberately does NOT use `face-remap-add-relative' for
`default', because relative remaps compose/stack: if anything else
on `org-mode-hook' (or elsewhere) also remaps `default' -- e.g. a
hand-rolled variable-pitch-font hook -- whichever remap was added
later wins, and that's not something we can reliably control by
ordering alone. Instead this strips any existing `default' entry
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
    (org-filetag-style--clear-heading-remaps)
    (when family
      (dolist (face org-filetag-style--heading-faces)
        (push (face-remap-add-relative face (list :family family))
              org-filetag-style--heading-remap-cookies)))))

(defun org-filetag-style--apply-line-spacing (plist)
  (let ((spacing (plist-get plist :line-spacing)))
    (when spacing
      (setq-local line-spacing spacing))))

(defun org-filetag-style--apply-num (plist)
  (when (plist-member plist :num-level)
    (let ((level (plist-get plist :num-level)))
      (if (and level (> level 0))
          (progn
            (setq-local org-num-max-level level)
            (when (fboundp 'org-num-mode) (org-num-mode 1)))
        (when (and (fboundp 'org-num-mode) (bound-and-true-p org-num-mode))
          (org-num-mode -1))))))

(defun org-filetag-style--apply-indent (plist)
  (when (plist-member plist :indent)
    (if (plist-get plist :indent)
        (org-indent-mode 1)
      (org-indent-mode -1))))

(defun org-filetag-style--apply-olivetti (plist)
  (let ((width (plist-get plist :olivetti-width)))
    (when (and width (fboundp 'olivetti-mode))
      (setq-local olivetti-body-width width)
      (olivetti-mode 1))))

(defun org-filetag-style--apply-eval (plist)
  (let ((forms (plist-get plist :eval)))
    (when forms
      (dolist (form (if (and (consp forms) (listp (car forms)))
                         forms
                       (list forms)))
        (eval form t)))))

;;;###autoload
(defun org-filetag-style-apply ()
  "Apply the style matching this buffer's filetags.
Intended for `org-mode-hook'; safe to call again any time to refresh."
  (when (derived-mode-p 'org-mode)
    ;; Force a fresh parse of #+FILETAGS rather than trusting that
    ;; `org-file-tags' is already populated at hook time -- cheap,
    ;; and removes any dependency on hook ordering.
    (org-set-regexps-and-options)
    (let ((style (org-filetag-style--effective-style)))
      ;; Order matters: org-num-mode / org-indent-mode / olivetti-mode
      ;; are toggled here, and at least Olivetti can apply its own font
      ;; styling via `buffer-face-mode' when it turns on (depending on
      ;; `olivetti-style'). Apply ours last so it wins.
      (org-filetag-style--apply-line-spacing style)
      (org-filetag-style--apply-num style)
      (org-filetag-style--apply-indent style)
      (org-filetag-style--apply-olivetti style)
      (org-filetag-style--apply-font style)
      (org-filetag-style--apply-eval style))))

;;;###autoload
(defun org-filetag-style-debug ()
  "Print detected filetags and the resulting merged style to *Messages*.
Use this to sanity-check why a style isn't (or is) being applied."
  (interactive)
  (if (not (derived-mode-p 'org-mode))
      (message "org-filetag-style-debug: not in an Org buffer")
    (org-set-regexps-and-options)
    (let* ((tags (org-filetag-style--current-tags))
           (style (org-filetag-style--effective-style)))
      (message "org-filetag-style: tags=%S style=%S" tags style))))

;;;###autoload
(defun org-filetag-style-refresh ()
  "Re-scan filetags and re-apply the matching style.
Use this after editing #+FILETAGS by hand or via
`org-set-tags-command', since those don't automatically re-run
`org-mode-hook'."
  (interactive)
  (org-set-regexps-and-options)
  (org-filetag-style-apply))

(advice-add 'org-set-tags-command :after
            (lambda (&rest _) (org-filetag-style-refresh)))

(provide 'org-filetag-style)
;;; org-filetag-style.el ends here
