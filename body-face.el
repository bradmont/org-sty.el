;;; body-face.el --- Body-face hierarchy for WP buffers -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: faces, org
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (cl-lib "0.5") (face-extra "0.1.0"))
;; URL: https://github.com/braddelong/org-sty

;;; Commentary:

;; `body-face-mode' installs the semantic body-face hierarchy in a buffer:
;; content faces receive `(:inherit body)' remaps, metadata faces receive
;; `(:inherit default)' anchors, and the pass-0 bare-text stamper is
;; activated via face-extra dispatch.
;;
;; The `body' face is a neutral semantic identity face; its visual size in
;; WP buffers is controlled by the `variable-spacing-ratio' property on
;; `body' (set via `face-extra-add-relative') combined with
;; `variable-spacing-mode''s floor remap on `default'.
;;
;; Register a backend for a major mode:
;;
;;   (body-face-register-backend 'my-mode
;;     :content-faces  '(my-content-face ...)
;;     :metadata-faces '(my-metadata-face ...)
;;     :stamp-body-text #'my-stamp-fn)
;;
;; Then enable `body-face-mode' in that mode's hook or via a style `:eval'.

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'face-extra)


;;;; ================================================================
;;;; Section 1 — The body face
;;;; ================================================================

(defgroup body-face nil
  "Semantic body-face hierarchy for word-processor buffers."
  :group 'faces)

(defface body
  '((t :inherit default))
  "Semantic identity face for prose body text.

Any character that is prose body text — as opposed to structural or
metadata text — should carry this face.  Property packages
\(`variable-spacing-mode', `horizontal-layout-mode', `text-align-mode')
target `body' spans to apply spacing ratios, margins, and alignment.

The face is intentionally neutral (`(:inherit default)').  Visual sizing
is supplied by the `variable-spacing-ratio' synthetic property on `body',
set buffer-locally by `org-sty-config' via `face-extra-add-relative'."
  :group 'body-face)


;;;; ================================================================
;;;; Section 2 — Backend registry
;;;; ================================================================

(defvar body-face--backend-alist nil
  "Alist mapping major-mode symbol → body-face backend plist.

Each backend plist must supply:
  :content-faces   Faces that receive `(:inherit body)' remaps on enable.
  :metadata-faces  Faces that receive `(:inherit default)' anchors on enable.
  :stamp-body-text A function (beg end) for pass-0 body stamping.

Register via `body-face-register-backend'.")

(defun body-face-register-backend (major-mode-sym &rest plist)
  "Register PLIST as the body-face backend for MAJOR-MODE-SYM.

PLIST must contain :content-faces, :metadata-faces, and :stamp-body-text.
Called at load time (or by user config) before `body-face-mode' is enabled.
`body-face-mode' reads the plist when it enables in a buffer of MAJOR-MODE-SYM."
  (unless (plist-get plist :stamp-body-text)
    (error "body-face-register-backend: `%s' backend lacks :stamp-body-text"
           major-mode-sym))
  (unless (plist-get plist :content-faces)
    (error "body-face-register-backend: `%s' backend lacks :content-faces"
           major-mode-sym))
  (unless (plist-get plist :metadata-faces)
    (error "body-face-register-backend: `%s' backend lacks :metadata-faces"
           major-mode-sym))
  (setf (alist-get major-mode-sym body-face--backend-alist) plist))

(defun body-face-deregister-backend (major-mode-sym)
  "Remove the body-face backend registered for MAJOR-MODE-SYM."
  (setf (alist-get major-mode-sym body-face--backend-alist nil 'remove) nil))

(defun body-face--active-backend ()
  "Return the body-face backend plist for the current buffer's major mode, or nil."
  (alist-get major-mode body-face--backend-alist))


;;;; ================================================================
;;;; Section 3 — Remap helpers
;;;; ================================================================

(defun body-face--install-remaps (content-faces metadata-faces)
  "Install body-hierarchy face remaps for CONTENT-FACES and METADATA-FACES.

For each face in CONTENT-FACES installs a buffer-local `(:inherit body)'
remap so it tracks body-text size.  For each face in METADATA-FACES
installs a `(:inherit default)' remap to anchor it at floor size.

Returns the list of remap cookies.  Pass the returned list to
`body-face--remove-remaps' to undo."
  (let (cookies)
    (dolist (face content-faces)
      (push (face-remap-add-relative face :inherit 'body) cookies))
    (dolist (face metadata-faces)
      (push (face-remap-add-relative face :inherit 'default) cookies))
    cookies))

(defun body-face--remove-remaps (cookies)
  "Remove face remaps installed by `body-face--install-remaps'.
COOKIES is the list returned by that function."
  (dolist (cookie cookies)
    (face-remap-remove-relative cookie)))


;;;; ================================================================
;;;; Section 4 — Body-stamp utilities
;;;; ================================================================

(defun body-face-remove-body-face (beg end)
  "Remove only `body' from the `face' property in BEG..END.
Handles both a singleton symbol and a list, leaving any other faces
\(e.g. `org-footnote') intact."
  (let ((pos beg))
    (while (< pos end)
      (let* ((next (or (next-single-property-change pos 'face nil end) end))
             (f    (get-text-property pos 'face)))
        (cond
         ((eq f 'body)
          (remove-text-properties pos next '(face nil)))
         ((and (listp f) (memq 'body f))
          (let ((trimmed (remq 'body f)))
            (if trimmed
                (put-text-property pos next 'face trimmed)
              (remove-text-properties pos next '(face nil))))))
        (setq pos next)))))


;;;; ================================================================
;;;; Section 5 — body-face-mode
;;;; ================================================================

(defvar-local body-face--remap-cookies nil
  "List of remap cookies installed by `body-face-mode'.
Populated on enable; cleared on disable.")

;;;###autoload
(define-minor-mode body-face-mode
  "Minor mode that installs the body-face hierarchy for the current buffer.

On enable, looks up the backend registered for the current `major-mode'
via `body-face-register-backend', then:
  1. Installs `(:inherit body)' remaps on the backend's :content-faces.
  2. Installs `(:inherit default)' anchors on the backend's :metadata-faces.
  3. Calls `face-extra-mode-require' to activate face-extra dispatch in
     this buffer.
  4. Flushes font-lock so the new remaps take effect immediately.

On disable, reverses all of the above."
  :lighter nil
  (if body-face-mode
      (let ((backend (body-face--active-backend)))
        (unless backend
          (setq body-face-mode nil)
          (error "body-face-mode: no backend registered for `%s'" major-mode))
        (setq body-face--remap-cookies
              (body-face--install-remaps
               (plist-get backend :content-faces)
               (plist-get backend :metadata-faces)))
        (face-extra-mode-require)
        (font-lock-flush))
    (body-face--remove-remaps body-face--remap-cookies)
    (setq body-face--remap-cookies nil)
    (face-extra-mode-release)
    (body-face-remove-body-face (point-min) (point-max))
    (font-lock-flush)))


;;;; ================================================================
;;;; Section 6 — Org backend
;;;; ================================================================

(defcustom body-face-org-content-faces
  '(org-level-1 org-level-2 org-level-3 org-level-4
    org-level-5 org-level-6 org-level-7 org-level-8
    org-document-title
    org-block org-table org-formula org-list-dt org-quote org-verse)
  "Document-content faces that track body-text size in Org WP buffers.

Each face in this list receives a buffer-local `(:inherit body)' remap
when `body-face-mode' is enabled, lifting it above the floor height on
`default'.

Inline faces (bold, italic, org-code, org-link, org-cite, org-footnote,
etc.) are intentionally absent: they can appear alongside a structural
face in a list (e.g. `(italic org-level-2)') and a remap would cause
body height to dominate incorrectly.  The pass-0 stamp handles them by
marking bare-text runs with `body' directly.

Can be set buffer-locally for per-document customisation."
  :type '(repeat face)
  :group 'body-face)

(defcustom body-face-org-metadata-faces
  '(org-hide
    org-drawer org-special-keyword org-property-value
    variable-spacing--default
    org-block-begin-line org-block-end-line
    org-meta-line org-keyword
    org-document-info-keyword org-document-info)
  "Metadata faces exempt from `body' stamping in Org WP buffers.

Faces in this list do NOT receive a `(:inherit body)' remap and are
excluded from the pass-0 body stamp, so they inherit floor size from
the `default' remap.

Can be set buffer-locally for per-document customisation."
  :type '(repeat face)
  :group 'body-face)

(defun body-face--org-explicit-face-p (face)
  "Return non-nil if FACE contains at least one Org content or metadata face.
FACE may be a symbol, an anonymous attribute plist, or a list thereof.

The pass-0 stamp stamps `body' on characters where this returns nil and
no `font-lock-face' is present."
  (cond
   ((null face) nil)
   ((and (consp face) (keywordp (car face))) nil)
   ((symbolp face)
    (or (memq face body-face-org-content-faces)
        (memq face body-face-org-metadata-faces)))
   ((listp face)
    (cl-some (lambda (f)
               (and (symbolp f)
                    (or (memq f body-face-org-content-faces)
                        (memq f body-face-org-metadata-faces))))
             face))
   (t nil)))

(defun body-face--org-stamp-body-text (beg end)
  "Stamp `body' on characters in BEG..END that Org left unstyled.

Called during pass 0 of each dispatch cycle for `org-mode' buffers.
Mode guard enforced by dispatcher via :mode \\='body-face-mode."
  (with-silent-modifications
    (body-face-remove-body-face beg end)
    (let ((pos beg))
      (while (< pos end)
        (let* ((next-face    (next-single-property-change pos 'face nil end))
               (next-fl-face (next-single-property-change
                              pos 'font-lock-face nil end))
               (next         (min (or next-face end) (or next-fl-face end))))
          (when (and (null (get-text-property pos 'font-lock-face))
                     (not (body-face--org-explicit-face-p
                           (get-text-property pos 'face))))
            (let ((stamp-start pos))
              (when (and (eq (char-after pos) ?\n)
                         (> pos (point-min))
                         (not (eq (char-before pos) ?\n)))
                (let ((prev-face (or (get-text-property (1- pos) 'face)
                                     (get-text-property (1- pos)
                                                        'font-lock-face))))
                  (when prev-face
                    (add-face-text-property pos (1+ pos) prev-face t)
                    (setq stamp-start (1+ pos)))))
              (when (< stamp-start next)
                (add-face-text-property stamp-start next 'body t))))
          (setq pos next))))))

;; Register the Org backend at load time.
(body-face-register-backend 'org-mode
  :content-faces  body-face-org-content-faces
  :metadata-faces body-face-org-metadata-faces
  :stamp-body-text #'body-face--org-stamp-body-text)

;; Register the pass-0 body-stamp property at load time.
(face-extra-define-property 'body-stamp
  :pass 0
  :mode 'body-face-mode
  :apply #'body-face--org-stamp-body-text)


(provide 'body-face)
;;; body-face.el ends here
