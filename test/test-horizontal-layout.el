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
  "compose-prefix with no existing prefix returns a pixel-width-only spec."
  (should (equal '(space :width (40))
                 (horizontal-layout--compose-prefix 40 nil))))

(ert-deftest hl/compose-prefix/with-height ()
  "compose-prefix preserves the :height from an existing pass-1 spacer."
  (let ((existing '(space :width 0 :height (30))))
    (should (equal '(space :width (40) :height (30))
                   (horizontal-layout--compose-prefix 40 existing)))))

(ert-deftest hl/compose-prefix/zero-width-returns-nil ()
  "compose-prefix returns nil when width is 0."
  (should (null (horizontal-layout--compose-prefix 0 nil)))
  (should (null (horizontal-layout--compose-prefix 0 '(space :width 0 :height (30))))))

(ert-deftest hl/compose-prefix/non-space-existing ()
  "compose-prefix handles a non-space existing prefix gracefully (no height)."
  ;; If existing is something unexpected, treat as no height.
  (should (equal '(space :width (20))
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
;;; horizontal-layout--apply-margin-left
;;; -----------------------------------------------------------------------

(ert-deftest hl/apply-margin-left/sets-line-prefix ()
  "apply-margin-left sets line-prefix and wrap-prefix on the span."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 40)))
    (should (equal '(space :width (40)) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width (40)) (hl-test--wrap-prefix-at 1)))))

(ert-deftest hl/apply-margin-left/sets-sentinel ()
  "apply-margin-left stamps the sentinel property on applied spans."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 40)))
    (should (hl-test--sentinel-at 1))
    ;; Outside span: no sentinel.
    (should (null (hl-test--sentinel-at 7)))))

(ert-deftest hl/apply-margin-left/composes-with-height ()
  "apply-margin-left preserves :height from a pre-existing pass-1 spacer."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    ;; Simulate pass-1 having already set a height spacer.
    (put-text-property 1 6 'line-prefix  '(space :width 0 :height (30)))
    (put-text-property 1 6 'wrap-prefix  '(space :width 0 :height (30)))
    (horizontal-layout--apply-margin-left '((1 6 40)))
    (should (equal '(space :width (40) :height (30))
                   (hl-test--line-prefix-at 1)))
    (should (equal '(space :width (40) :height (30))
                   (hl-test--wrap-prefix-at 1)))))

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
    ;; mode is off (never enabled in this buffer)
    (horizontal-layout--apply-margin-left '((1 6 40)))
    (should (null (hl-test--line-prefix-at 1)))))

(ert-deftest hl/apply-margin-left/multiple-spans ()
  "apply-margin-left handles multiple disjoint spans correctly."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 4 20) (6 11 40)))
    (should (equal '(space :width (20)) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width (40)) (hl-test--line-prefix-at 6)))
    ;; Gap between spans: no prefix.
    (should (null (hl-test--line-prefix-at 5)))))

(ert-deftest hl/apply-margin-left/clears-stale-before-reapply ()
  "apply-margin-left clears stale margin before re-applying a new value."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    ;; First application.
    (horizontal-layout--apply-margin-left '((1 6 40)))
    (should (equal '(space :width (40)) (hl-test--line-prefix-at 1)))
    ;; Second application with different value over same span.
    (horizontal-layout--apply-margin-left '((1 6 20)))
    (should (equal '(space :width (20)) (hl-test--line-prefix-at 1)))))

(ert-deftest hl/apply-margin-left/varies-by-lp-boundary ()
  "apply-margin-left composes correctly across varying pass-1 heights."
  (hl-test--with-buffer
    (insert "aaaaabbbbb")  ; positions 1-5 and 6-10
    (horizontal-layout-mode 1)
    ;; Two different pass-1 heights in the same margin span.
    (put-text-property 1  6  'line-prefix '(space :width 0 :height (20)))
    (put-text-property 6  11 'line-prefix '(space :width 0 :height (30)))
    (horizontal-layout--apply-margin-left '((1 11 50)))
    (should (equal '(space :width (50) :height (20)) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width (50) :height (30)) (hl-test--line-prefix-at 6)))))


;;; -----------------------------------------------------------------------
;;; horizontal-layout-clear
;;; -----------------------------------------------------------------------

(ert-deftest hl/clear/removes-line-prefix ()
  "horizontal-layout-clear removes line-prefix and wrap-prefix."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 40)))
    (horizontal-layout-clear 1 6)
    (should (null (hl-test--line-prefix-at 1)))
    (should (null (hl-test--wrap-prefix-at 1)))))

(ert-deftest hl/clear/removes-sentinel ()
  "horizontal-layout-clear removes the sentinel property."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 6 40)))
    (horizontal-layout-clear 1 6)
    (should (null (hl-test--sentinel-at 1)))))

(ert-deftest hl/clear/restores-height-only-prefix ()
  "horizontal-layout-clear restores the pass-1 height-only spacer."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    ;; Pre-set pass-1 spacer, then apply margin on top.
    (put-text-property 1 6 'line-prefix  '(space :width 0 :height (30)))
    (put-text-property 1 6 'wrap-prefix  '(space :width 0 :height (30)))
    (horizontal-layout--apply-margin-left '((1 6 40)))
    ;; Sanity: composed spec is present.
    (should (equal '(space :width (40) :height (30)) (hl-test--line-prefix-at 1)))
    ;; Now clear: should restore height-only spec.
    (horizontal-layout-clear 1 6)
    (should (equal '(space :width 0 :height (30)) (hl-test--line-prefix-at 1)))
    (should (equal '(space :width 0 :height (30)) (hl-test--wrap-prefix-at 1)))))

(ert-deftest hl/clear/leaves-outside-span-intact ()
  "horizontal-layout-clear does not touch text outside the cleared range."
  (hl-test--with-buffer
    (insert "hello world")
    (horizontal-layout-mode 1)
    (horizontal-layout--apply-margin-left '((1 12 40)))
    ;; Clear only the first half.
    (horizontal-layout-clear 1 6)
    (should (null (hl-test--line-prefix-at 1)))
    ;; Second half should still have the margin.
    (should (equal '(space :width (40)) (hl-test--line-prefix-at 7)))))

(ert-deftest hl/clear/no-op-on-unmarked-text ()
  "horizontal-layout-clear is a no-op on text with no sentinel."
  (hl-test--with-buffer
    (insert "hello world")
    ;; Set an unrelated line-prefix and verify clear doesn't disturb it.
    (put-text-property 1 6 'line-prefix '(space :width 0 :height (30)))
    (horizontal-layout-clear 1 6)
    ;; Not marked with sentinel, so clear should not remove it.
    (should (equal '(space :width 0 :height (30)) (hl-test--line-prefix-at 1)))))

(provide 'test-horizontal-layout)
;;; test-horizontal-layout.el ends here
