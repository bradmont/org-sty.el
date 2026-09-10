;;; org-filetags-config.el --- Personal org-filetag-style configuration -*- lexical-binding: t; -*-
;;
;; Author: Brad Stewart <brad@bradstewart.ca>
;; Created: September 10, 2026
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; Personal configuration for org-filetag-style, variable-spacing-mode,
;; and related minor modes.  Kept in the org-filetag-style repo so it
;; can be updated alongside library changes.
;;
;; Tag-specific :eval blocks are responsible for:
;;   - setting the text-body spacing ratio via `put'
;;   - enabling variable-spacing-mode
;;
;; The default style :eval sets up face attributes globally for all
;; Org buffers.  It uses the multi-form syntax understood by
;; `org-filetag-style--apply-eval': a bare list of top-level forms,
;; each evaluated separately.

;;; Code:

;; ---------------------------------------------------------------------------
;; Tag-specific styles
;; ---------------------------------------------------------------------------
;; All WP document tags share the same base style.  Define it once and map
;; it over the tag list.
;;
;; Note: :font-size here is currently masked in WP buffers — the
;; variable-spacing-mode floor remap takes priority over the :height that
;; --apply-font installs on `default'.  Body text size is controlled by
;; `text-body' instead.  Keeping :font-size for non-WP fallback and future
;; use when --apply-font is updated to also set `text-body' height.

(let* ((wp-eval '(progn
                   (put 'text-body 'variable-spacing-ratio 1.6)
                   (hl-line-mode 0)
                   (lsp-ltex-plus-mode 1)
                   (org-block-appear-mode 1)
                   (variable-spacing-mode 1)
                   (org-title-fold-mode 1)))
       (wp-style `(:font "Times New Roman" :font-size 12
                   :num-level 3 :indent nil :olivetti-width 68
                   :eval ,wp-eval)))
  (setq org-filetag-style-alist
        (mapcar (lambda (tag) (cons tag wp-style))
                '("thesis" "book" "article" "sermon" "test" "chapter"))))

;; ---------------------------------------------------------------------------
;; Default style (applies to all Org buffers)
;; ---------------------------------------------------------------------------
;; Uses the multi-form :eval syntax: a bare list of forms evaluated in order.
;;
;; Note on heading heights in WP buffers: the float heights here (2.4, 2.2 …)
;; are relative to each face's effective parent at display time.  In WP buffers
;; where variable-spacing-mode is active, org-level faces inherit text-body via
;; a buffer-local remap; the interaction between that remap's inherited height
;; and the global float may need tuning — verify heading sizes when testing.
;;
;; Note on org-quote/org-verse slant: these faces have :slant italic set here
;; globally.  In WP buffers the (:inherit text-body) remap may bring in
;; :slant normal from the default chain and override it.  Check italic
;; rendering in WP buffers and add an explicit :slant override to the
;; tag-specific :eval if needed.

(setq org-filetag-style-default
      '(:font "Iosevka Aile"
        :eval
        ((dolist (spec '((org-level-1 . 2.4) (org-level-2 . 2.2) (org-level-3 . 2.0)
                         (org-level-4 . 2.0) (org-level-5 . 2.0) (org-level-6 . 2.0)
                         (org-level-7 . 2.0) (org-level-8 . 2.0)))
           (set-face-attribute (car spec) nil
                               :font "Iosevka Aile" :weight 'bold :height (cdr spec)))

         (set-face-attribute 'org-document-title nil
                             :font "Iosevka Aile" :weight 'bold :height 2.6)

         ;; Structural / metadata: fixed-pitch at floor size.
         (set-face-attribute 'org-drawer nil :inherit 'fixed-pitch :height 1.0)
         (set-face-attribute 'org-property-value nil :inherit 'fixed-pitch :height 1.0)
         (set-face-attribute 'org-special-keyword nil :inherit 'fixed-pitch :height 1.0)
         (set-face-attribute 'org-block-begin-line nil :inherit 'fixed-pitch :height 1.0)
         (set-face-attribute 'org-block-end-line nil :inherit 'fixed-pitch :height 1.0)

         ;; Code / data: fixed-pitch in a dark box.
         (set-face-attribute 'org-block nil
                             :inherit 'fixed-pitch
                             :background (color-darken-name (face-background 'default) 15)
                             :extend t)
         (set-face-attribute 'org-table nil :inherit 'fixed-pitch)
         (set-face-attribute 'org-formula nil :inherit 'fixed-pitch)
         (set-face-attribute 'org-code nil :inherit '(shadow fixed-pitch))
         (set-face-attribute 'org-verbatim nil :inherit '(shadow fixed-pitch))

         ;; Prose blocks: body font, slightly inset background, italic.
         (set-face-attribute 'org-quote nil
                             :inherit nil
                             :background (color-darken-name (face-background 'default) 5)
                             :extend t :height 2.0 :slant 'italic)
         (set-face-attribute 'org-verse nil
                             :inherit nil
                             :background (color-darken-name (face-background 'default) 5)
                             :extend t :height 2.0 :slant 'italic)

         (hl-line-mode -1))))

(provide 'org-filetags-config)
;;; org-filetags-config.el ends here
