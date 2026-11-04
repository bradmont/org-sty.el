;;; org-sty-config.el --- Personal org-sty configuration -*- lexical-binding: t; -*-
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

(require 'page-metrics)
(require 'org-footnote-extra)
(require 'variable-spacing)

;; Tracks the currently installed inline-quote font-lock keyword so that
;; re-applying the style (e.g. after a theme change) can remove the old
;; keyword before installing a fresh one with the updated background colour.
(defvar-local org-sty-config--inline-quote-keyword nil)

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
         ;; :text-align 0 suppresses justify/center/right inherited from
         ;; text-body through the face-extra resolver.  Headings must
         ;; never be justified.
         (org-level-1         . (:weight bold :height 1.4 :text-align 0))
         (org-level-2         . (:weight bold :height 1.3 :text-align 0))
         (org-level-3         . (:weight bold :height 1.2 :text-align 0))
         (org-level-4         . (:weight bold :height 1.1 :text-align 0))
         (org-level-5         . (:weight bold :height 1.0 :text-align 0))
         (org-level-6         . (:weight bold :height 1.0 :text-align 0))
         (org-level-7         . (:weight bold :height 1.0 :text-align 0))
         (org-level-8         . (:weight bold :height 1.0 :text-align 0))
         ;; org-document-title: no :text-align suppressor here.  WP styles
         ;; add 'center via their own :faces layer (runs after :eval, so it
         ;; wins over the face-extra-add-relative calls in :eval).  Non-WP
         ;; buffers get no text-align at all, which is correct.
         (org-document-title  . (:weight bold :height 1.6))
         ;; Structural / metadata: fixed-pitch.  Floor-size entries
         ;; (:height 60) only make sense in WP buffers where
         ;; variable-spacing-mode shrinks `default' to 6pt; they live in
         ;; wp-faces below, not here.
         (org-drawer          . (:inherit fixed-pitch :height 1.0))
         (org-property-value  . (:inherit fixed-pitch))
         (org-special-keyword . (:inherit fixed-pitch))
         ;; Code / data: fixed-pitch.
         (org-table           . (:inherit fixed-pitch))
         (org-formula         . (:inherit fixed-pitch))
         (org-code            . (:inherit (shadow fixed-pitch)))
         (org-verbatim        . (:inherit (shadow fixed-pitch)))
         ;; Prose blocks: italic.  Background is theme-relative so it is
         ;; set via `org-sty-remap' in :eval below.
         (org-quote           . (:slant italic))
         (org-verse           . (:slant italic)))
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
         ;; Inline quoted spans — same background as org-quote blocks.
         ;; Covers guillemets «»,  typographic double "…", typographic single '…'.
         ;; Content group (1) excludes newlines so unmatched quotes don't run on.
         ;; `prepend' means Org's own faces (links, emphasis) win on foreground
         ;; while the background still shows through.
         (when org-sty-config--inline-quote-keyword
           (font-lock-remove-keywords nil org-sty-config--inline-quote-keyword))
         (let* ((bg (color-darken-name (face-background 'default) 5))
                (kw `(("[«\u201C\u2018]\\([^»\u201D\u2019\n]*\\)[»\u201D\u2019]"
                       (1 '(:background ,bg) prepend)))))
           (setq-local org-sty-config--inline-quote-keyword kw)
           (font-lock-add-keywords nil kw 'append)
           (font-lock-flush))
         (hl-line-mode -1))))

;; ---------------------------------------------------------------------------
;; Tag-specific styles
;; ---------------------------------------------------------------------------
;; All WP document tags share the same base style.  Define it once and map
;; it over the tag list.

(let* ((wp-eval '(progn
                   ;; ── Page geometry ───────────────────────────────────────
                   ;; Sets page-metrics-page-size and all four margin vars
                   ;; atomically from page-metrics-size-margins.  Must come
                   ;; before page-metrics-mode is enabled below.
                   (page-metrics-set-page 'letter)
                   ;; Fancy olivetti: fringes for the desktop area,
                   ;; margins for the in-page left/right gutter.
                   (setq-local olivetti-style 'fancy)
                   ;; ── Mode enables ────────────────────────────────────────
                   (hl-line-mode 0)
                   ;(lsp-ltex-plus-mode 1)
                   (org-block-appear-mode 1)
                   (org-cite-appear-mode 1)
                   (org-footnote-extra-mode 1)
                   ;; Suppress inherited text-body ratio on block/quote faces
                   ;; BEFORE variable-spacing-mode enables.  variable-spacing-mode
                   ;; installs (:inherit text-body) remaps and may trigger a
                   ;; fontification cycle; if the suppressors arrive later (via
                   ;; :faces) the cache is built without them and spacers are
                   ;; stamped on these faces before the suppressor can block it.
                   ;; Those stale spacers are never cleared by the span-only clear
                   ;; loop in variable-spacing--apply-ratio.
                   (org-sty-remap 'org-quote :variable-spacing-ratio 0)
                   (org-sty-remap 'org-verse :variable-spacing-ratio 0)
                   (org-sty-remap 'org-block :variable-spacing-ratio 0)
                   (variable-spacing-mode 1)

                   ;; superscripts & subscripts are set relative to 'default rather
                   ;; than 'text-body; make them 0.8x 'text-body
                   (setq-local org-script-display
                               '(((raise -0.3) (height 1.6))
                                 ((raise 0.3) (height 1.6))
                                 ((raise -0.5)) ((raise 0.5))))
                   
                   (horizontal-layout-mode 1)
                   ;; ── Pass 3 test: midpoint marker ─────────────────────────
                   ;; text-align-mode wires face-extra--dispatch-pass3 via
                   ;; jit-lock-register.  The test stub highlights the char at
                   ;; the midpoint of each visual line in hot pink to confirm
                   ;; the linewise pass fires.  Remove once centering is real.
                   (text-align-mode 1)
                   ;(face-extra-add-relative 'text-body 'text-align 'right)
                   (face-extra-add-relative 'text-body 'text-align 'justify)
                   ;; org-document-title centering is declared in :faces below
                   ;; so it runs in the :faces phase (after :eval) and wins
                   ;; cleanly over any base-style suppressor.
                   (org-title-fold-mode 1)
                   (auto-save-mode)
                   (guillemet-nbsp-mode 1)
                   ;; page-metrics-mode enables olivetti-mode and calls
                   ;; page-metrics-apply, which derives olivetti-body-width
                   ;; and olivetti-margin-width from the physical page model
                   ;; above.  Must come after variable-spacing-mode so the
                   ;; font remap is in place and frame-char-width is correct.
                   (page-metrics-mode 1)
                   ;; ── Frame width guard ───────────────────────────────────
                   ;; If the frame is narrower than the olivetti body width
                   ;; (plus a small margin for fringes/borders), widen it to
                   ;; 104 columns so the page is fully visible on first open.
                   (when (and (boundp 'olivetti-body-width)
                              olivetti-body-width
                              (< (frame-width) 100))
                     (set-frame-width (selected-frame) 104))
                   ;; ── Heading numbers ─────────────────────────────────────
                   (setq-local org-num-format-function
                               (lambda (numbering)
                                 (propertize
                                  (concat (mapconcat #'number-to-string numbering ".") " ")
                                  'face (intern (format "org-level-%d"
                                                        (min (length numbering) 8))))))
                   (when (bound-and-true-p org-num-mode)
                     (org-num-mode -1)
                     (org-num-mode 1))
                   (flyspell-mode 1)
                   (setq org-pretty-entities t)
                   (org-toggle-pretty-entities)
                   (setq-local org-footnote-section "*paragraph*")
                   (setq-local org-footnote-auto-adjust 'renumber))
               )
       (wp-faces '(;; ── Variable spacing ────────────────────────────────────
                   ;; text-body ratio and block suppressors live here, not in
                   ;; org-sty-default :faces, because the shallow plist merge
                   ;; in org-sty--merge replaces :faces wholesale — anything
                   ;; in org-sty-default :faces is clobbered by the WP :faces.
                   ;; Setting the ratio here also makes it buffer-local (via
                   ;; face-extra-add-relative) rather than global (put), so it
                   ;; is cleaned up correctly on re-apply or mode disable.
                   (text-body           . (:variable-spacing-ratio 1.6))
                   ;; Slant for quote/verse.  Each wp-faces entry must carry
                   ;; ALL standard-face attrs for that face because the shallow
                   ;; :faces merge means this entry replaces the org-sty-default
                   ;; entry entirely.  The :variable-spacing-ratio 0 suppressor
                   ;; is installed in :eval (before variable-spacing-mode) to
                   ;; avoid a premature-cache timing bug; it is not repeated here.
                   (org-quote           . (:slant italic))
                   (org-verse           . (:slant italic))
                   ;; ── Text alignment ──────────────────────────────────────
                   ;; :text-align left on headings suppresses justify/center/right
                   ;; inherited from text-body via the face-extra resolver.
                   ;; Must live here (after :eval) not in org-sty-default :faces,
                   ;; because horizontal-layout.el — which registers 'text-align
                   ;; with face-extra — is only loaded when text-align-mode is
                   ;; enabled in :eval above.  If placed in org-sty-default :faces,
                   ;; face-extra-registered-p('text-align) returns nil and
                   ;; org-sty-remap silently drops the key.
                   (org-level-1         . (:text-align left))
                   (org-level-2         . (:text-align left))
                   (org-level-3         . (:text-align left))
                   (org-level-4         . (:text-align left))
                   (org-level-5         . (:text-align left))
                   (org-level-6         . (:text-align left))
                   (org-level-7         . (:text-align left))
                   (org-level-8         . (:text-align left))
                   ;; Metadata faces at floor size — only correct in WP buffers
                   ;; where variable-spacing-mode remaps `default' to 6pt.
                   (org-property-value  . (:height 60))
                   (org-special-keyword . (:height 60))
                   ;; Footnote definitions: ~8pt (0.67 × 12pt body).
                   ;; The (:inherit text-body) remap is installed by
                   ;; org-footnote-extra-mode; this height sits on top of
                   ;; it as a relative multiplier.  :underline nil suppresses
                   ;; the link-style underline org-footnote carries by default.
                   (org-footnote        . (:height 0.67
                                           :variable-spacing-ratio 0
                                           :underline nil))
                   ;; Center the document title.  Declared here (in :faces)
                   ;; rather than via face-extra-add-relative in :eval so
                   ;; that it runs in the :faces phase — after :eval — and
                   ;; cannot be clobbered by a base-style suppressor.
                   (org-document-title . (:text-align center))
                   ;; Quote / verse blocks: left indent.  Must live here
                   ;; (after :eval) for the same reason as :text-align on
                   ;; headings — horizontal-layout.el registers
                   ;; horizontal-layout-margin-left with face-extra only
                   ;; when horizontal-layout-mode is enabled in :eval above.
                   ;; Placing this in org-sty-default :faces causes
                   ;; org-sty-remap to silently drop the key.
                   (org-quote . (:slant italic :horizontal-layout-margin-left 4 ;; :horizontal-layout-margin-right 4
                                        ))
                   (org-verse . (:horizontal-layout-margin-left 4 ;; :horizontal-layout-margin-right 4
                                                                ))
                   ;; Footnote definition indent: all continuation lines get a
                   ;; full left margin of 4 canonical char-widths.  The label
                   ;; line suppresses line-prefix via
                   ;; `horizontal-layout-suppress-line-prefix' (stamped by
                   ;; `org-footnote-extra--fontify-definitions') so the
                   ;; superscript label sits at column 0 while wrap-prefix
                   ;; still aligns any wrapped label-line text with the body.
                   (org-footnote . (:horizontal-layout-margin-left 4))))
       (wp-style `(:font "Times New Roman"
                   :num-level 3 :indent nil
                   :faces ,wp-faces
                   :eval ,wp-eval)))
  (setq org-sty-alist
        (mapcar (lambda (tag) (cons tag wp-style))
                '("thesis" "book" "article" "sermon" "test" "chapter"))))

(provide 'org-sty-config)
;;; org-sty-config.el ends here
