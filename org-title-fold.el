;;; org-title-fold.el --- Fold #+KEYWORD: lines below #+TITLE: like a headline -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: org, convenience, outlines
;; Version: 0.1

;;; Commentary:

;; Org natively folds two kinds of things: drawers and #+begin_/#+end_
;; blocks. A run of #+KEYWORD: lines at the top of a file (#+TITLE:,
;; #+AUTHOR:, #+FILETAGS:, ...) gets neither -- there's no built-in way
;; to collapse them.
;;
;; This package treats #+TITLE: as a pseudo-headline: TAB on that line
;; folds every #+KEYWORD: line immediately below it (down to the first
;; blank line, heading, or block), the same way TAB on a real headline
;; folds its body. Anything *above* #+TITLE: is left alone, so it
;; doesn't need to be the first line in the file.
;;
;; It's built on `org-fold-core', the same folding engine Org itself
;; uses for headlines/drawers/blocks (since Org 9.6), so the fold
;; behaves like a native one: proper ellipsis, participates in
;; isearch, etc. -- not a simulated/overlay hack.
;;
;; Usage:
;;
;;   (require 'org-title-fold)
;;   (add-hook 'org-mode-hook #'org-title-fold-mode)
;;
;; Or enable it selectively, e.g. from another package's per-file
;; style logic:
;;
;;   (org-title-fold-mode 1)
;;
;; By default, enabling the mode immediately folds the metadata block
;; if #+TITLE: is present anywhere in the buffer (not just at point);
;; disabling it unfolds again. See `org-title-fold-fold-on-enable' to
;; change that.

;;; Code:

(require 'org)
(require 'org-fold-core)

(defgroup org-title-fold nil
  "Fold #+KEYWORD: lines below #+TITLE: like a headline."
  :group 'org)

(defcustom org-title-fold-fold-on-enable t
  "Whether enabling `org-title-fold-mode' immediately folds the
metadata block below #+TITLE:, regardless of where point is.
If nil, the mode only affects what TAB does; nothing folds until you
actually press TAB on the #+TITLE: line."
  :type 'boolean
  :group 'org-title-fold)

(defcustom org-title-fold-ellipsis " ..."
  "Ellipsis shown at the end of the #+TITLE: line when its metadata
is folded."
  :type 'string
  :group 'org-title-fold)

(defconst org-title-fold-spec 'org-title-fold
  "Folding spec registered with `org-fold-core' for the metadata body.
This covers the #+KEYWORD: lines below #+TITLE:.")

(defconst org-title-fold-tag-spec 'org-title-fold-tag
  "Folding spec registered with `org-fold-core' for the #+TITLE: tag prefix.
This covers the \"#+TITLE: \" text at the start of the title line,
hiding the tag while leaving the title value visible.")

(unless (org-fold-core-folding-spec-p org-title-fold-spec)
  (org-fold-core-add-folding-spec
   org-title-fold-spec
   `((:ellipsis . ,org-title-fold-ellipsis) (:isearch-open . t))))

(unless (org-fold-core-folding-spec-p org-title-fold-tag-spec)
  (org-fold-core-add-folding-spec
   org-title-fold-tag-spec
   '((:ellipsis . "") (:isearch-open . t))))

(defun org-title-fold--ensure-spec ()
  "Ensure both fold specs are registered in the CURRENT buffer.

`org-fold-core--specs' is buffer-local, so registering the specs once
at package-load time only makes them known in whichever buffer happened
to be current when the file was loaded (e.g. `*scratch*'), not in any
Org buffer opened afterward. This must run in each buffer that
actually wants to use the fold."
  (unless (org-fold-core-folding-spec-p org-title-fold-spec)
    (org-fold-core-add-folding-spec
     org-title-fold-spec
     `((:ellipsis . ,org-title-fold-ellipsis) (:isearch-open . t))))
  (unless (org-fold-core-folding-spec-p org-title-fold-tag-spec)
    (org-fold-core-add-folding-spec
     org-title-fold-tag-spec
     '((:ellipsis . "") (:isearch-open . t)))))

(defun org-title-fold--tag-region-from (pos)
  "If POS is on a #+TITLE: line, return (BEG . END) covering the tag prefix.
The region spans from the start of the line up to and including the
\"#+TITLE: \" prefix (colon and any following whitespace), so the
title value text itself remains visible. Returns nil if POS isn't on
a #+TITLE: line."
  (save-excursion
    (goto-char pos)
    (beginning-of-line)
    (when (looking-at "^\\([ \t]*#\\+title:[ \t]*\\)")
      (cons (match-beginning 1) (match-end 1)))))

(defun org-title-fold--region-from (pos)
  "If POS is on a #+TITLE: line, return (BEG . END) spanning the
contiguous #+KEYWORD: lines immediately following it -- the line's
\"body\", mirroring how a headline's body is everything below it up
to the next non-child line. Returns nil if POS isn't on that line, or
if there's nothing following it to fold.

BEG is the end-of-line position on the #+TITLE: line itself (i.e. at
the newline character), so the ellipsis appears at the end of that
line rather than on the line below -- matching the drawer-fold
convention."
  (save-excursion
    (goto-char pos)
    (beginning-of-line)
    (when (looking-at "^[ \t]*#\\+title:")
      (let ((beg (line-end-position)))
        (forward-line 1)
        (let ((body-start (point)))
          (while (looking-at "^[ \t]*#\\+[a-zA-Z_-]+:")
            (forward-line 1))
          (when (> (point) body-start)
            (cons beg (point))))))))

(defun org-title-fold--find-title-line ()
  "Search the whole buffer for a #+TITLE: line and return its start position.
Returns nil if no #+TITLE: line is found."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^[ \t]*#\\+title:" nil t)
      (line-beginning-position))))

(defun org-title-fold--find-title-region ()
  "Search the whole buffer for a #+TITLE: line and return its fold
region via `org-title-fold--region-from', or nil if there's no
#+TITLE: line or nothing below it to fold. Unlike
`org-title-fold--region-from', this doesn't require point to already
be on the line -- used when auto-folding on mode enable."
  (let ((line-pos (org-title-fold--find-title-line)))
    (when line-pos
      (org-title-fold--region-from line-pos))))

(defun org-title-fold--apply (folded line-pos body-region)
  "Apply fold state FOLDED to both the tag prefix and the body.
LINE-POS is the start of the #+TITLE: line.  BODY-REGION is (BEG . END)
for the metadata body below, as returned by `org-title-fold--region-from'.
The tag region is computed fresh from LINE-POS."
  (let ((tag-region (org-title-fold--tag-region-from line-pos)))
    (when tag-region
      (org-fold-core-region (car tag-region) (cdr tag-region)
                             folded org-title-fold-tag-spec))
    (org-fold-core-region (car body-region) (cdr body-region)
                           folded org-title-fold-spec)))

(defun org-title-fold-toggle ()
  "Fold/unfold the #+KEYWORD: lines below #+TITLE:, like TAB on a
headline folds its body.  Also folds/unfolds the #+TITLE: tag prefix
so only the title value remains visible when folded.

Meant for a buffer-local `org-tab-first-hook': returns non-nil (which
stops further `org-cycle' processing for this keypress) only when
point is actually on the #+TITLE: line and there's something below it
to fold; returns nil otherwise so normal TAB behavior proceeds."
  (let ((line-pos (save-excursion
                    (beginning-of-line)
                    (and (looking-at "^[ \t]*#\\+title:")
                         (point)))))
    (when line-pos
      (let ((region (org-title-fold--region-from line-pos)))
        (when region
          (let ((folded (org-fold-core-folded-p (car region) org-title-fold-spec)))
            (org-title-fold--apply (not folded) line-pos region))
          t)))))

(defun org-title-fold--fold-now ()
  "Fold the buffer's #+TITLE: tag prefix and metadata block, if present."
  (let ((line-pos (org-title-fold--find-title-line)))
    (when line-pos
      (let ((region (org-title-fold--region-from line-pos)))
        (when region
          (org-title-fold--apply t line-pos region))))))

(defun org-title-fold--unfold-now ()
  "Unfold the buffer's #+TITLE: tag prefix and metadata block, if present."
  (let ((line-pos (org-title-fold--find-title-line)))
    (when line-pos
      (let ((tag-region (org-title-fold--tag-region-from line-pos))
            (region (org-title-fold--region-from line-pos)))
        (when tag-region
          (org-fold-core-region (car tag-region) (cdr tag-region)
                                 nil org-title-fold-tag-spec))
        (when region
          (org-fold-core-region (car region) (cdr region)
                                 nil org-title-fold-spec))))))

;;;###autoload
(define-minor-mode org-title-fold-mode
  "Toggle folding #+KEYWORD: lines below #+TITLE: on TAB, like a headline.

When enabled, TAB on the #+TITLE: line folds/unfolds every
#+KEYWORD: line immediately below it. Also see
`org-title-fold-fold-on-enable', which controls whether enabling the
mode immediately folds the metadata (default: yes)."
  :lighter nil
  (if org-title-fold-mode
      (progn
        (org-title-fold--ensure-spec)
        (add-hook 'org-tab-first-hook #'org-title-fold-toggle nil t)
        (when org-title-fold-fold-on-enable
          (org-title-fold--fold-now)))
    (remove-hook 'org-tab-first-hook #'org-title-fold-toggle t)
    (org-title-fold--unfold-now)))

(provide 'org-title-fold)
;;; org-title-fold.el ends here
