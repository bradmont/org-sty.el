;;; test-horizontal-layout.el --- ERT tests for horizontal-layout.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   emacs --batch -L /path/to/org-sty.el -l ert \
;;         -l test/test-horizontal-layout.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'face-extra)
(require 'horizontal-layout)

;;; -----------------------------------------------------------------------
;;; Helpers
;;; -----------------------------------------------------------------------

(defmacro hl-test--with-buffer (&rest body)
  "Run BODY in a fresh buffer with clean face-extra state."
  (declare (indent 0))
  `(with-temp-buffer
     (setq face-extra--local-properties nil
           face-extra--face-cache nil)
     ,@body))

(defun hl-test--line-prefix-at (pos)
  "Return the `line-prefix' text property at POS."
  (get-text-property pos 'line-prefix))

(defun hl-test--wrap-prefix-at (pos)
  "Return the `wrap-prefix' text property at POS."
  (get-text-property pos 'wrap-prefix))

(defun hl-test--sentinel-at (pos)
  "Return the horizontal-layout sentinel property at POS."
  (get-text-property pos horizontal-layout--prop))


;;; -----------------------------------------------------------------------
;;; Registration
;;; -----------------------------------------------------------------------

(ert-deftest hl/margin-left-registered ()
  "horizontal-layout-margin-left is registered in face-extra--registry."
  (should (gethash 'horizontal-layout-margin-left face-extra--registry)))

(ert-deftest hl/margin-left-is-pass-2 ()
  "horizontal-layout-margin-left is registered at pass 2."
  (let ((entry (gethash 'horizontal-layout-margin-left face-extra--registry)))
    (should (eql 2 (plist-get entry :pass)))))


;;; -----------------------------------------------------------------------
;;; horizontal-layout--compose-prefix
;;; -----------------------------------------------------------------------

(ert-deftest hl/compose-prefix/nil-existing ()
  "compose-prefix with no existing prefix returns a char-width-only spec."
  (should (equal '(space :width 40)
                 (horizontal-layout--compose-prefix 40 nil))))

(ert-deftest hl/compose-prefix/with-height ()
  "compose-prefix preserves the :height from an existing pass-1 spacer."
  (let ((existing '(space :width 0 :height (30))))
    (should (equal '(space :width 40 :height (30))
                   (horizontal-layout--compose-prefix 40 existing)))))

(ert-deftest hl/compose-prefix/zero-width-returns-nil ()
  "compose-prefix returns nil when width is 0."
  (should (null (horizontal-layout--compose-prefix 0 nil)))
  (should (null (horizontal-layout--compose-prefix 0 '(space :width 0 :height (30))))))

(ert-deftest hl/compose-prefix/non-space-existing ()
  "compose-prefix handles a non-space existing prefix gracefully (no height)."
  (should (equal '(space :width 20)
                 (horizontal-layout--compose-prefix 20 'something-else))))


;;; -----------------------------------------------------------------------
;;; horizontal-layout--strip-width
;;; -----------------------------------------------------------------------

(ert-deftest hl/strip-width/restores-height-only ()
  "strip-width removes :width, returning a height-only pass-1 spacer."
  (should (equal '(space :width 0 :height (30))
                 (horizontal-layout--strip-width '(space :width 40 :height (30))))))

(ert-deftest hl/strip-width/no-height-returns-nil ()
  "strip-width returns nil when the spec has no :height (nothing to restore)."
  (should (null (horizontal-layout--strip-width '(space :width 40))))
  (should (null (horizontal-layout--strip-width nil))))

(ert-deftest hl/strip-width/non-space-returns-nil ()
  "strip-width returns nil for non-space values."
  (should (null (horizontal-layout--strip-width 'something))))


;;; -----------------------------------------------------------------------
;;; horizontal-layout--block-start-p
;;; -----------------------------------------------------------------------

(ert-deftest hl/block-start/detects-invisible-preceding-nl ()
  "block-start-p returns t when the char before beg is an invisible \\n."
  (hl-test--with-buffer
    (insert "\nHello")
    ;; Make the \n at position 1 invisible (simulating org-block-appear).
    (put-text-property 1 2 'invisible 'org-block-appear)
    ;; beg = 2 (the 'H'); char-before is invisible \n.
    (should (horizontal-layout--block-start-p 2))))

(ert-deftest hl/block-start/visible-nl-is-not-block-start ()
  "block-start-p returns nil when the preceding \\n is visible."
  (hl-test--with-buffer
    (insert "\nHello")
    ;; \n is present but NOT invisible.
    (should (null (horizontal-layout--block-start-p 2)))))

(ert-deftest hl/block-start/non-nl-preceding-char ()
  "block-start-p returns nil when the preceding char is not a \\n."
  (hl-test--with-buffer
    (insert "aHello")
    (put-text-property 1 2 'invisible 'org-block-appear)
    ;; Preceding char is 'a', not \n.
    (should (null (horizontal-layout--block-start-p 2)))))

(ert-deftest hl/block-start/at-point-min ()
  "block-start-p returns nil at point-min (no preceding character)."
  (hl-test--with-buffer
    (insert "Hello")
    (should (null (horizontal-layout--block-start-p 1)))))


;;; -----------------------------------------------------------------------
;;; horizontal-layout--apply-margin-left
;;; -----------------------------------------------------------------------

(ert-deftest hl/apply-margin-left/sets-line-prefix ()
  "apply-margin-left sets line-prefix and wrap-prefix on the span."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 4)))
    (should (equal '(space :width 4) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width 4) (hl-test--wrap-prefix-at 1)))))

(ert-deftest hl/apply-margin-left/sets-sentinel ()
  "apply-margin-left stamps the sentinel property on applied spans."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 4)))
    (should (hl-test--sentinel-at 1))
    (should (null (hl-test--sentinel-at 7)))))

(ert-deftest hl/apply-margin-left/composes-with-height ()
  "apply-margin-left preserves :height from a pre-existing pass-1 spacer."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (put-text-property 1 6 'line-prefix  '(space :width 0 :height (30)))
    (put-text-property 1 6 'wrap-prefix  '(space :width 0 :height (30)))
    (horizontal-layout--apply-margin-left '((1 6 4)))
    (should (equal '(space :width 4 :height (30)) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width 4 :height (30)) (hl-test--wrap-prefix-at 1)))))

(ert-deftest hl/apply-margin-left/skips-zero-width ()
  "apply-margin-left does nothing when value is 0."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 0)))
    (should (null (hl-test--line-prefix-at 1)))
    (should (null (hl-test--sentinel-at 1)))))

(ert-deftest hl/apply-margin-left/no-op-when-mode-off ()
  "apply-margin-left is a no-op when horizontal-layout-mode is off."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout--apply-margin-left '((1 6 4)))
    (should (null (hl-test--line-prefix-at 1)))))

(ert-deftest hl/apply-margin-left/multiple-spans ()
  "apply-margin-left handles multiple disjoint spans correctly."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 4 2) (6 11 4)))
    (should (equal '(space :width 2) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width 4) (hl-test--line-prefix-at 6)))
    (should (null (hl-test--line-prefix-at 5)))))

(ert-deftest hl/apply-margin-left/clears-stale-before-reapply ()
  "apply-margin-left clears stale margin before re-applying a new value."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 4)))
    (should (equal '(space :width 4) (hl-test--line-prefix-at 1)))
    (horizontal-layout--apply-margin-left '((1 6 2)))
    (should (equal '(space :width 2) (hl-test--line-prefix-at 1)))))

(ert-deftest hl/apply-margin-left/varies-by-lp-boundary ()
  "apply-margin-left composes correctly across varying pass-1 heights."
  (hl-test--with-buffer
    (insert "aaaaabbbbb")
    (horizontal-layout-mode 1)
    (put-text-property 1  6  'line-prefix '(space :width 0 :height (20)))
    (put-text-property 6  11 'line-prefix '(space :width 0 :height (30)))
    (horizontal-layout--apply-margin-left '((1 11 4)))
    (should (equal '(space :width 4 :height (20)) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width 4 :height (30)) (hl-test--line-prefix-at 6)))))

(ert-deftest hl/apply-margin-left/block-start-gets-overlay ()
  "apply-margin-left creates a before-string overlay on beg when beg-1 is invisible \\n."
  (hl-test--with-buffer
    ;; Simulate: invisible \n (pos 1) then content H (pos 2).
    (insert "\nHello")
    (horizontal-layout-mode 1)
    (put-text-property 1 2 'invisible 'org-block-appear)
    ;; Span starts at pos 2 (the 'H'); beg-1 is the invisible \n.
    (horizontal-layout--apply-margin-left '((2 7 4)))
    ;; beg (pos 2) should NOT have line-prefix (overlay handles it instead).
    (should (null (hl-test--line-prefix-at 2)))
    ;; beg should NOT have the sentinel text property.
    (should (null (hl-test--sentinel-at 2)))
    ;; An overlay with the sentinel property should exist at beg.
    (let ((ovs (cl-remove-if-not
                (lambda (ov) (overlay-get ov horizontal-layout--prop))
                (overlays-at 2))))
      (should (= 1 (length ovs)))
      (let ((bs (overlay-get (car ovs) 'before-string)))
        (should bs)
        (should (equal '(space :width 4)
                       (get-text-property 0 'display bs)))))
    ;; Characters after beg (pos 3+) should have line-prefix normally.
    (should (equal '(space :width 4) (hl-test--line-prefix-at 3)))))

(ert-deftest hl/apply-margin-left/does-not-skip-mid-block-nl ()
  "apply-margin-left does not skip \\n within a block.
A mid-block \\n is preceded by a visible \\n (the char before beg is not
invisible), so block-start-p returns nil and line-prefix is applied normally."
  (hl-test--with-buffer
    ;; Span starting at a visible character — beg-1 is not an invisible \n.
    (insert "ab\ncd")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 4)))
    ;; All characters including the \n at pos 3 get line-prefix.
    (should (equal '(space :width 4) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width 4) (hl-test--line-prefix-at 3)))))


;;; -----------------------------------------------------------------------
;;; horizontal-layout-clear
;;; -----------------------------------------------------------------------

(ert-deftest hl/clear/removes-line-prefix ()
  "horizontal-layout-clear removes line-prefix and wrap-prefix."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 4)))
    (horizontal-layout-clear 1 6)
    (should (null (hl-test--line-prefix-at 1)))
    (should (null (hl-test--wrap-prefix-at 1)))))

(ert-deftest hl/clear/removes-sentinel ()
  "horizontal-layout-clear removes the sentinel property."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 4)))
    (horizontal-layout-clear 1 6)
    (should (null (hl-test--sentinel-at 1)))))

(ert-deftest hl/clear/restores-height-only-prefix ()
  "horizontal-layout-clear restores the pass-1 height-only spacer."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (put-text-property 1 6 'line-prefix  '(space :width 0 :height (30)))
    (put-text-property 1 6 'wrap-prefix  '(space :width 0 :height (30)))
    (horizontal-layout--apply-margin-left '((1 6 4)))
    (should (equal '(space :width 4 :height (30)) (hl-test--line-prefix-at 1)))
    (horizontal-layout-clear 1 6)
    (should (equal '(space :width 0 :height (30)) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width 0 :height (30)) (hl-test--wrap-prefix-at 1)))))

(ert-deftest hl/clear/leaves-outside-span-intact ()
  "horizontal-layout-clear does not touch text outside the cleared range."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 12 4)))
    (horizontal-layout-clear 1 6)
    (should (null (hl-test--line-prefix-at 1)))
    (should (equal '(space :width 4) (hl-test--line-prefix-at 7)))))

(ert-deftest hl/clear/no-op-on-unmarked-text ()
  "horizontal-layout-clear is a no-op on text with no sentinel."
  (hl-test--with-buffer
    (insert "hello world")
    (put-text-property 1 6 'line-prefix '(space :width 0 :height (30)))
    (horizontal-layout-clear 1 6)
    (should (equal '(space :width 0 :height (30)) (hl-test--line-prefix-at 1)))))

(ert-deftest hl/clear/removes-block-start-overlay ()
  "horizontal-layout-clear removes the before-string overlay created for block starts."
  (hl-test--with-buffer
    (insert "\nHello world")
    (horizontal-layout-mode 1)
    (put-text-property 1 2 'invisible 'org-block-appear)
    (horizontal-layout--apply-margin-left '((2 13 4)))
    ;; Overlay exists before clear.
    (should (cl-some (lambda (ov) (overlay-get ov horizontal-layout--prop))
                     (overlays-at 2)))
    (horizontal-layout-clear 1 13)
    ;; Overlay should be gone after clear.
    (should (null (cl-some (lambda (ov) (overlay-get ov horizontal-layout--prop))
                           (overlays-at 2))))))

(provide 'test-horizontal-layout)
;;; test-horizontal-layout.el ends here
