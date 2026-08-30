;;; org-block-appear.el --- Hide Org block delimiters, reveal near point -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: org, convenience
;; Version: 0.1

;;; Commentary:

;; Hides #+begin_/#+end_ block delimiter lines in Org buffers, the way
;; `org-hide-emphasis-markers'/org-appear hide and reveal emphasis
;; markers -- except here the "markers" are whole lines, and "reveal"
;; means "point is somewhere inside this block", not "point is on the
;; marker character".
;;
;; Architecture
;; ------------
;;
;; HIDING rides on font-lock/jit-lock, the same way
;; `org-filetag-style-hide-block-end-lines' already hides #+end_ lines
;; elsewhere in this setup: a `font-lock-add-keywords' entry matches a
;; "^[ \t]*#+begin_...\n" / "^[ \t]*#+end_...\n" line (including its
;; trailing newline, so the whole line collapses to zero height) and
;; puts an `invisible' text property (symbol `org-block-appear') on it.
;; Because this is just a font-lock keyword, re-hiding after an edit is
;; free -- font-lock already re-fontifies (and therefore re-hides)
;; whatever region changed. No custom buffer-wide cache of block
;; positions is needed for this half.
;;
;; This is safe against false positives (e.g. a "#+begin_src" mentioned
;; literally inside an example block) because Org itself requires such
;; literal occurrences to be comma-escaped (",#+begin_src") -- an
;; unescaped "#+begin_/#+end_" line is always a real block delimiter.
;;
;; REVEALING is driven by `post-command-hook'. On each command, if
;; point is still within the range of the block we last revealed, we
;; do nothing -- a plain numeric comparison. Only once point has left
;; that range do we call `org-element-at-point', which is backed by
;; Org's own incremental `org-element-cache' rather than a full-buffer
;; reparse. If point has moved into a (possibly different, possibly no)
;; managed block, the previous block's delimiters are re-hidden and the
;; new one's are revealed.
;;
;; This mode supersedes `org-filetag-style-indent-block-delimiters':
;; drop that from your style plists' :eval once this is enabled.
;; Delimiter lines are invisible by default, and only get a one-tab
;; `line-prefix' (see `org-block-appear-indent-width') while revealed,
;; so the old always-on indent isn't needed alongside this.
;;
;; Known limitation: the `invisible' property is overwritten outright
;; rather than layered into a list, so a delimiter line that is *also*
;; inside a heading Org has folded (which uses `invisible' with value
;; `outline') could in principle collide with this mode's own value.
;; jit-lock mostly skips fontifying already-invisible regions, so this
;; should rarely bite in practice, but it isn't specifically handled.
;;
;; Usage:
;;
;;   (add-hook 'org-mode-hook #'org-block-appear-mode)
;;
;; or, from an `org-filetag-style-alist' entry's :eval:
;;
;;   (:eval (org-block-appear-mode 1))

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)

(defgroup org-block-appear nil
  "Hide Org block delimiter lines, revealing them near point."
  :group 'org)

(defcustom org-block-appear-indent-width 1
  "Number of tabs to indent a delimiter line by while it's revealed.
Set to 0 to disable indenting revealed delimiter lines."
  :type 'integer
  :group 'org-block-appear)

(defconst org-block-appear--element-types
  '(src-block example-block export-block quote-block verse-block
    center-block comment-block special-block)
  "Org element types whose #+begin_/#+end_ delimiters this mode manages.

Deliberately excludes `dynamic-block' (\"#+BEGIN: NAME ...\"/\"#+END:\"),
which uses a different, colon-terminated header syntax that the
regexps below don't match.")

(defconst org-block-appear--begin-re
  "^[ \t]*#\\+begin_[a-zA-Z_-]+.*\n"
  "Matches a #+begin_ delimiter line, including its trailing newline.")

(defconst org-block-appear--end-re
  "^[ \t]*#\\+end_[a-zA-Z_-]+.*\n?"
  "Matches a #+end_ delimiter line, including its trailing newline if any
\(the last line in the buffer may not have one\).")

(defconst org-block-appear--hidden-prop 'org-block-appear--hidden
  "Marks spans hidden by this mode, distinct from `invisible' itself so
we can find/clear exactly our own spans -- and only our own spans --
without assuming every `invisible' property in the buffer is ours.")

(defvar-local org-block-appear--revealed nil
  "Plist describing the currently revealed block, or nil. Keys:

  :range      (BEG . END), the block's own `org-element' :begin/:end --
              used for the cheap \"is point still inside\" check in
              `org-block-appear--post-command'.
  :begin-pos  Buffer position of the #+begin_ line's first character.
  :end-pos    Buffer position of the #+end_ line's first character, or
              nil if none was found in range (shouldn't normally
              happen for a well-formed block).")

;; ------------------------------------------------------------------
;; Hiding (font-lock side)
;; ------------------------------------------------------------------

(defun org-block-appear--install-font-lock ()
  (font-lock-add-keywords
   nil
   `((,org-block-appear--begin-re
      (0 (progn
           (put-text-property (match-beginning 0) (match-end 0)
                               'invisible 'org-block-appear)
           (put-text-property (match-beginning 0) (match-end 0)
                               org-block-appear--hidden-prop t)
           (put-text-property (match-beginning 0) (match-end 0)
                               'font-lock-multiline t)
           nil)))
     (,org-block-appear--end-re
      (0 (progn
           (put-text-property (match-beginning 0) (match-end 0)
                               'invisible 'org-block-appear)
           (put-text-property (match-beginning 0) (match-end 0)
                               org-block-appear--hidden-prop t)
           (put-text-property (match-beginning 0) (match-end 0)
                               'font-lock-multiline t)
           nil))))
   'append)
  (font-lock-flush))

(defun org-block-appear--remove-font-lock ()
  (font-lock-remove-keywords
   nil
   `((,org-block-appear--begin-re) (,org-block-appear--end-re)))
  (org-block-appear--clear (point-min) (point-max))
  (font-lock-flush))

(defun org-block-appear--clear (beg end)
  "Remove this mode's own invisible/marker properties from BEG..END,
without touching any unrelated use of the `invisible' property (e.g.
Org's own heading-folding, which uses that same property name with a
different value) -- scoped via `org-block-appear--hidden-prop', the
same pattern `org-filetag-style-clear-paragraph-line-spacing' uses."
  (with-silent-modifications
    (let ((pos beg))
      (while (< pos end)
        (let ((next (or (next-single-property-change
                          pos org-block-appear--hidden-prop nil end)
                         end)))
          (when (get-text-property pos org-block-appear--hidden-prop)
            (remove-text-properties
             pos next (list org-block-appear--hidden-prop nil 'invisible nil)))
          (setq pos next))))))

;; ------------------------------------------------------------------
;; Revealing (post-command-hook side)
;; ------------------------------------------------------------------

(defun org-block-appear--indent-line (beg)
  "Give the delimiter line starting at BEG a `line-prefix' tab.
No-op when `org-block-appear-indent-width' is 0."
  (when (> org-block-appear-indent-width 0)
    (put-text-property
     beg (1+ beg) 'line-prefix
     (make-string org-block-appear-indent-width ?\t))))

(defun org-block-appear--hide-line-at (pos)
  "Re-hide the delimiter line starting at POS, and drop its indent."
  (when pos
    (with-silent-modifications
      (save-excursion
        (goto-char pos)
        (when (or (looking-at org-block-appear--begin-re)
                  (looking-at org-block-appear--end-re))
          (put-text-property (match-beginning 0) (match-end 0)
                              'invisible 'org-block-appear)
          (put-text-property (match-beginning 0) (match-end 0)
                              org-block-appear--hidden-prop t))
        (remove-text-properties pos (1+ pos) '(line-prefix nil))))))

(defun org-block-appear--reveal-block (block)
  "Reveal BLOCK's own #+begin_/#+end_ lines.

Searches only within BLOCK's own :begin..:end span. This is safe
against nesting (e.g. a src-block inside a quote-block): the outer
block's own #+end_ line is always the textually *last* delimiter line
in that span, since nothing can follow it and still belong to this
block, so taking the last match here always finds the right one. Any
nested block reveals itself independently once point actually enters
it.

Returns (BEGIN-POS . END-POS), the two lines' starting positions --
END-POS may be nil if no #+end_ line was found, which shouldn't
normally happen for a well-formed block."
  (let* ((beg (org-element-property :begin block))
         (end (org-element-property :end block))
         (post-affiliated (or (org-element-property :post-affiliated block) beg))
         begin-pos end-pos)
    (with-silent-modifications
      (save-excursion
        (goto-char post-affiliated)
        (when (looking-at org-block-appear--begin-re)
          (setq begin-pos (match-beginning 0))
          (remove-text-properties begin-pos (match-end 0)
                                   (list 'invisible nil org-block-appear--hidden-prop nil))
          (org-block-appear--indent-line begin-pos))
        (goto-char beg)
        (let (last-beg last-end)
          (while (re-search-forward org-block-appear--end-re end t)
            (setq last-beg (match-beginning 0) last-end (match-end 0)))
          (when last-beg
            (setq end-pos last-beg)
            (remove-text-properties last-beg last-end
                                     (list 'invisible nil org-block-appear--hidden-prop nil))
            (org-block-appear--indent-line last-beg)))))
    (cons begin-pos end-pos)))

(defun org-block-appear--find-block-at-point ()
  "Return the innermost managed block element at point, or nil."
  (org-element-lineage (org-element-at-point)
                        org-block-appear--element-types t))

(defun org-block-appear--post-command ()
  (when (derived-mode-p 'org-mode)
    (let ((range (plist-get org-block-appear--revealed :range)))
      (unless (and range (>= (point) (car range)) (<= (point) (cdr range)))
        ;; Point left the cached block's range (or there wasn't one) --
        ;; only now do we pay for `org-element-at-point'.
        (let* ((block (org-block-appear--find-block-at-point))
               (new-range (when block
                            (cons (org-element-property :begin block)
                                  (org-element-property :end block)))))
          (unless (equal new-range range)
            (when org-block-appear--revealed
              (org-block-appear--hide-line-at
               (plist-get org-block-appear--revealed :begin-pos))
              (org-block-appear--hide-line-at
               (plist-get org-block-appear--revealed :end-pos)))
            (setq org-block-appear--revealed
                  (when block
                    (let ((positions (org-block-appear--reveal-block block)))
                      (list :range new-range
                            :begin-pos (car positions)
                            :end-pos (cdr positions)))))))))))

;; ------------------------------------------------------------------
;; Minor mode
;; ------------------------------------------------------------------

;;;###autoload
(define-minor-mode org-block-appear-mode
  "Hide #+begin_/#+end_ block delimiter lines, revealing them near point."
  :lighter " BlkA"
  (if org-block-appear-mode
      (progn
        (unless (derived-mode-p 'org-mode)
          (user-error "org-block-appear-mode is only for Org buffers"))
        (add-to-invisibility-spec 'org-block-appear)
        (org-block-appear--install-font-lock)
        (setq org-block-appear--revealed nil)
        (add-hook 'post-command-hook #'org-block-appear--post-command nil t))
    (remove-hook 'post-command-hook #'org-block-appear--post-command t)
    (when org-block-appear--revealed
      (org-block-appear--hide-line-at (plist-get org-block-appear--revealed :begin-pos))
      (org-block-appear--hide-line-at (plist-get org-block-appear--revealed :end-pos)))
    (remove-from-invisibility-spec 'org-block-appear)
    (org-block-appear--remove-font-lock)
    (setq org-block-appear--revealed nil)))

(provide 'org-block-appear)
;;; org-block-appear.el ends here
