;;; org-filetags-config.el --- Personal org-sty configuration -*- lexical-binding: t; -*-
;;
;; Author: Brad Stewart <brad@bradstewart.ca>
;; Created: September 10, 2026
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; Personal configuration for org-sty, variable-spacing-mode, and
;; related minor modes.  Kept in the org-sty repo so it can be updated
;; alongside library changes.
;;
;; Face attributes are declared via the `:faces' key so they are
;; buffer-local and cleaned up automatically on re-apply.  Computed
;; values (e.g. background colours derived from the current theme) use
;; `org-sty-remap' from within `:eval'.
;;
;; The default style :eval handles only mode toggles; the wp-style :eval
;; handles only mode enables and the text-body spacing ratio.

;;; Code:

;; ---------------------------------------------------------------------------
;; Default style (applies to all Org buffers as a base layer)
;; ---------------------------------------------------------------------------
;; `org-sty-default' is always applied first; tag-specific styles stack on
;; top.  It is not a fallback for untagged buffers only.
;;
;; Note on heading heights: the float values (2.4, 2.2 …) are relative to
;; each face's effective parent at display time.  In WP buffers where
;; variable-spacing-mode is active, org-level faces inherit text-body via a
;; buffer-local remap; the interaction between that inherited height and the
;; float multiplier here may need tuning.  Verify heading sizes interactively.
;;
;; Note on org-quote/org-verse: :slant italic is set here as a default.  In
;; WP buffers the (:inherit text-body) remap may bring in :slant normal from
;; the default chain and override it.  If that happens, add an explicit
;; :slant override in the wp-style :faces below.

(setq org-sty-default
      `(:font "Iosevka Aile"
        :faces
        (;; Headings: weight and scale only.  Font family is handled by
         ;; `--apply-font' via heading-remap-cookies so that tag-specific
         ;; :font overrides (e.g. "Times New Roman" for WP buffers) are
         ;; respected.  Never specify :family/:font here.
         (org-level-1         . (:weight bold :height 1.4))
         (org-level-2         . (:weight bold :height 1.3))
         (org-level-3         . (:weight bold :height 1.2))
         (org-level-4         . (:weight bold :height 1.1))
         (org-level-5         . (:weight bold :height 1.0))
         (org-level-6         . (:weight bold :height 1.0))
         (org-level-7         . (:weight bold :height 1.0))
         (org-level-8         . (:weight bold :height 1.0))
         (org-document-title  . (:weight bold :height 1.6))
         ;; Structural / metadata: fixed-pitch at floor size.
         (org-drawer          . (:inherit fixed-pitch :height 1.0))
         (org-property-value  . (:inherit fixed-pitch :height 60))
         (org-special-keyword . (:inherit fixed-pitch :height 60))
         ;; Code / data: fixed-pitch.
         (org-table           . (:inherit fixed-pitch))
         (org-formula         . (:inherit fixed-pitch))
         (org-code            . (:inherit (shadow fixed-pitch)))
         (org-verbatim        . (:inherit (shadow fixed-pitch)))
         ;; Prose blocks: italic.  Background is theme-relative so it is
         ;; set via `org-sty-remap' in :eval below.
         (org-quote           . (:slant italic ))
         (org-verse           . (:slant italic )))
        :eval
        ((org-sty-remap
          'org-block
          :inherit 'fixed-pitch
          :background (color-darken-name (face-background 'default) 15)
          :extend t)
         (org-sty-remap
          'org-quote
          :background (color-darken-name (face-background 'default) 5)
          :extend t)
         (org-sty-remap
          'org-verse
          :background (color-darken-name (face-background 'default) 5)
          :extend t)
         (hl-line-mode -1))))

;; ---------------------------------------------------------------------------
;; Tag-specific styles
;; ---------------------------------------------------------------------------
;; All WP document tags share the same base style.  Define it once and map
;; it over the tag list.

(let* ((wp-eval '(progn
                   (put 'text-body 'variable-spacing-ratio 1.6)
                   (hl-line-mode 0)
                   ;(lsp-ltex-plus-mode 1)
                   (org-block-appear-mode 1)
                   (variable-spacing-mode 1)
                   (org-title-fold-mode 1)
                   ;; Style heading numbers to match their heading level face.
                   (setq-local org-num-format-function
                               (lambda (numbering)
                                 (propertize
                                  (concat (mapconcat #'number-to-string numbering ".") " ")
                                  'face (intern (format "org-level-%d"
                                                        (min (length numbering) 8))))))
                   (when (bound-and-true-p org-num-mode)
                     (org-num-mode -1)
                     (org-num-mode 1))))
       (wp-style `(:font "Times New Roman"
                   :num-level 3 :indent nil :olivetti-width 68
                   :eval ,wp-eval)))
  (setq org-sty-alist
        (mapcar (lambda (tag) (cons tag wp-style))
                '("thesis" "book" "article" "sermon" "test" "chapter"))))

(provide 'org-filetags-config)
;;; org-filetags-config.el ends here
