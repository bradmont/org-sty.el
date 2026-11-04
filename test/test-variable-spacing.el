;;; test-variable-spacing.el --- ERT tests for variable-spacing.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   emacs --batch -L /path/to/org-sty.el -l ert \
;;         -l test/test-variable-spacing.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'face-extra)
(require 'variable-spacing)

;;; -----------------------------------------------------------------------
;;; Helpers
;;; -----------------------------------------------------------------------

(defmacro vs-test--with-buffer (&rest body)
  "Run BODY in a fresh buffer with clean face-extra state."
  (declare (indent 0))
  `(with-temp-buffer
     (setq face-extra--local-properties nil
           face-extra--face-cache nil)
     ,@body))

(defun vs-test--has-spacer-p (pos)
  "Return non-nil if POS has a spacing text property applied."
  (get-text-property pos variable-spacing--prop))

(defun vs-test--line-prefix-at (pos)
  "Return the line-prefix at POS."
  (get-text-property pos 'line-prefix))

;;; -----------------------------------------------------------------------
;;; Registration checks
;;; -----------------------------------------------------------------------

(ert-deftest vs/ratio-registered-in-face-extra ()
  "variable-spacing-ratio is registered in face-extra--registry at load time."
  (should (gethash 'variable-spacing-ratio face-extra--registry)))

(ert-deftest vs/ratio-is-pass-1 ()
  "variable-spacing-ratio is registered at pass 1."
  (let ((entry (gethash 'variable-spacing-ratio face-extra--registry)))
    (should (eql 1 (plist-get entry :pass)))))

(ert-deftest vs/org-backend-registered ()
  "The org-mode backend is registered with face-extra after load."
  (should (alist-get 'org-mode face-extra--backend-alist))
  (should (plist-get (alist-get 'org-mode face-extra--backend-alist)
                     :stamp-body-text)))

;;; -----------------------------------------------------------------------
;;; variable-spacing--apply-ratio
;;; -----------------------------------------------------------------------

(ert-deftest vs/apply-ratio/applies-spacers ()
  "apply-ratio stamps line-prefix, wrap-prefix and sentinel on the spans."
  (vs-test--with-buffer
    (insert "hello world")
    (let ((variable-spacing-mode t))
      (variable-spacing--apply-ratio
       (list (list 1 6 1.5)    ; "hello" — ratio 1.5
             (list 7 12 1.0))) ; "world" — ratio 1.0
      ;; Sentinel present at start of each span.
      (should (vs-test--has-spacer-p 1))
      (should (vs-test--has-spacer-p 7))
      ;; line-prefix is a space display spec.
      (let ((pfx (vs-test--line-prefix-at 1)))
        (should pfx)
        (should (eq 'space (car pfx))))
      ;; Positions just outside spans have no spacer.
      (should-not (vs-test--has-spacer-p 6))  ; gap between spans
      (should-not (vs-test--has-spacer-p 12)))))

(ert-deftest vs/apply-ratio/uses-text-body-for-measurement ()
  "apply-ratio always measures spacer height from text-body, not the face
at the span position.  This ensures consistent visual rhythm regardless
of which face inherited the ratio.

Regression test for: org-cite got 24px spacer while text-body got 30px,
because the old code used the face at BEG (org-cite) to measure height."
  (vs-test--with-buffer
    ;; Two spans: one labelled with org-cite face, one with text-body.
    ;; Even though the faces differ, both spans with the same ratio
    ;; must produce the SAME line-prefix spec.
    (insert "cite textbody")
    (put-text-property 1 5 'face 'org-cite)
    (put-text-property 6 14 'face 'text-body)
    (let ((variable-spacing-mode t))
      (variable-spacing--apply-ratio
       (list (list 1 5 1.6)
             (list 6 14 1.6)))
      (let ((pfx-cite    (vs-test--line-prefix-at 1))
            (pfx-body    (vs-test--line-prefix-at 6)))
        (should pfx-cite)
        (should pfx-body)
        ;; Both specs are `(space :width 0 :height (N)) with the same N.
        (should (equal pfx-cite pfx-body))))))

(ert-deftest vs/apply-ratio/clears-stale-spacers ()
  "apply-ratio removes old spacers within given spans before re-applying.

The contract: apply-ratio clears the sentinel property for exactly the
spans it receives, then stamps new spacers.  Positions outside the
given spans are left untouched."
  (vs-test--with-buffer
    (insert "abcdef")
    (let ((variable-spacing-mode t))
      ;; Install spacers over the whole buffer (positions 1–6).
      (variable-spacing--apply-ratio (list (list 1 7 1.5)))
      (should (vs-test--has-spacer-p 1))
      (should (vs-test--has-spacer-p 4))
      ;; Now apply with only positions 3-5: apply-ratio clears 3-5 first,
      ;; then re-applies 3-5 at the new ratio.
      ;; Positions outside 3-5 (1-2, 6) are NOT touched by this call.
      (variable-spacing--apply-ratio (list (list 3 5 0.8)))
      ;; Positions 3-4 were cleared then re-applied — still have spacers.
      (should (vs-test--has-spacer-p 3))
      ;; Position 5 was the end of the clear range; apply-ratio cleared [3,5)
      ;; so position 5 was NOT cleared (end is exclusive in the clear call).
      ;; Position 1 was outside the new spans — still has the old spacer.
      (should (vs-test--has-spacer-p 1))
      ;; Position 5: not in the new span (list 3 5 ...) means [3,5), so 5 is outside.
      ;; Still has old spacer from the first call.
      (should (vs-test--has-spacer-p 5)))))

(ert-deftest vs/apply-ratio/zero-ratio-no-spacer ()
  "A ratio of 0 must not stamp a spacer (is filtered by > 0 check)."
  (vs-test--with-buffer
    (insert "test")
    (let ((variable-spacing-mode t))
      (variable-spacing--apply-ratio (list (list 1 5 0)))
      (should-not (vs-test--has-spacer-p 1)))))

(ert-deftest vs/apply-ratio/no-op-when-mode-off ()
  "apply-ratio is a no-op when variable-spacing-mode is nil."
  (vs-test--with-buffer
    (insert "test")
    (let ((variable-spacing-mode nil))
      (variable-spacing--apply-ratio (list (list 1 5 1.5)))
      (should-not (vs-test--has-spacer-p 1)))))

;;; -----------------------------------------------------------------------
;;; variable-spacing--stamp-body-text (Org backend, pass 0)
;;; -----------------------------------------------------------------------

(ert-deftest vs/stamp/unstyled-gets-text-body ()
  "Characters with no face/font-lock-face are stamped with text-body."
  (vs-test--with-buffer
    (insert "plain")
    ;; No face properties set.
    (variable-spacing--stamp-body-text 1 (point-max))
    ;; The stamp uses add-face-text-property with APPEND=t, so text-body
    ;; is the face or part of the face list.
    (let ((f (get-text-property 1 'face)))
      (should (or (eq f 'text-body)
                  (and (listp f) (memq 'text-body f)))))))

(ert-deftest vs/stamp/font-lock-face-blocks-stamp ()
  "Characters with font-lock-face set do NOT get text-body stamped."
  (vs-test--with-buffer
    (insert "heading")
    (put-text-property 1 8 'font-lock-face 'org-level-1)
    (variable-spacing--stamp-body-text 1 (point-max))
    (let ((f (get-text-property 1 'face)))
      (should-not (or (eq f 'text-body)
                      (and (listp f) (memq 'text-body f)))))))

(ert-deftest vs/stamp/content-face-blocks-stamp ()
  "Characters already carrying a content face do NOT get text-body."
  (vs-test--with-buffer
    (insert "quoted text")
    ;; org-quote is in variable-spacing-content-faces.
    (put-text-property 1 12 'face 'org-quote)
    (variable-spacing--stamp-body-text 1 (point-max))
    ;; text-body should NOT have been added.
    (let ((f (get-text-property 1 'face)))
      (should (or (eq f 'org-quote)
                  (and (listp f)
                       (memq 'org-quote f)
                       (not (memq 'text-body f))))))))

(ert-deftest vs/stamp/metadata-face-blocks-stamp ()
  "Characters carrying a metadata face do NOT get text-body."
  (vs-test--with-buffer
    (insert ":DRAWER:")
    (put-text-property 1 9 'face 'org-drawer)
    (variable-spacing--stamp-body-text 1 (point-max))
    (let ((f (get-text-property 1 'face)))
      (should-not (and (listp f) (memq 'text-body f)))
      (should-not (eq f 'text-body)))))

(ert-deftest vs/stamp/clears-stale-text-body ()
  "Stale text-body stamps are removed before re-stamping."
  (vs-test--with-buffer
    ;; Pre-load a stale text-body stamp on positions that now have org-quote.
    (insert "stale")
    (put-text-property 1 6 'face '(text-body org-quote))
    (variable-spacing--stamp-body-text 1 (point-max))
    ;; text-body must be gone; org-quote must remain.
    (let ((f (get-text-property 1 'face)))
      (should-not (and (listp f) (memq 'text-body f)))
      (should-not (eq f 'text-body))
      ;; org-quote should still be there.
      (should (or (eq f 'org-quote)
                  (and (listp f) (memq 'org-quote f)))))))

(ert-deftest vs/stamp/newline-mid-span-gets-text-body ()
  "A newline in the middle of an unstyled span is stamped text-body."
  (vs-test--with-buffer
    (insert "line1\nline2")
    ;; No face on any character.
    (variable-spacing--stamp-body-text 1 (point-max))
    ;; The \n at position 6 is mid-span (preceded by 'l', a non-\n char,
    ;; but the preceding char has no explicit face, so the span doesn't split).
    ;; \n should be stamped text-body.
    (let ((f (get-text-property 6 'face)))
      (should (or (eq f 'text-body)
                  (and (listp f) (memq 'text-body f)))))))

(ert-deftest vs/stamp/newline-after-heading-inherits-heading-face ()
  "A \\n that immediately follows a heading span inherits the heading face."
  (vs-test--with-buffer
    ;; Simulate: heading text (org-level-1 via font-lock-face) followed by \n,
    ;; then body text (no face).
    (insert "* Head\nbody")
    ;;         123456 7 8901
    ;; Positions 1-6 have font-lock-face org-level-1; position 7 is \n.
    (put-text-property 1 7 'font-lock-face 'org-level-1)
    (variable-spacing--stamp-body-text 1 (point-max))
    ;; Position 7 (\n) should have inherited the heading's face (not text-body),
    ;; since it's at the START of a body-context span and its preceding char
    ;; belongs to a non-body span.
    (let ((f7 (get-text-property 7 'face)))
      ;; Should carry org-level-1 (or a list containing it), not text-body.
      (should (or (eq f7 'org-level-1)
                  (and (listp f7) (memq 'org-level-1 f7)))))
    ;; Body text at position 8+ should be text-body.
    (let ((f8 (get-text-property 8 'face)))
      (should (or (eq f8 'text-body)
                  (and (listp f8) (memq 'text-body f8)))))))

;;; -----------------------------------------------------------------------
;;; Suppressor integration: org-quote with 0 via face-extra-add-relative
;;; -----------------------------------------------------------------------

(ert-deftest vs/suppressor/org-quote-no-spacer-when-suppressed ()
  "The key parity test: face=org-quote with local ratio=0 must produce no spacer.

This reproduces the bug where org-quote blocks were getting spacing
applied even though :variable-spacing-ratio 0 was set via :faces."
  (vs-test--with-buffer
    (insert "quoted text here")
    ;; Simulate exactly what org-sty-apply / variable-spacing-mode does:
    ;; 1. Store the text-body ratio globally (as wp-eval does).
    (unwind-protect
        (progn
          (put 'text-body 'variable-spacing-ratio 1.6)
          ;; 2. Set the suppressor for org-quote via face-extra-add-relative.
          (let ((cookie (face-extra-add-relative
                         'org-quote 'variable-spacing-ratio 0)))
            (unwind-protect
                (progn
                  ;; 3. Stamp org-quote on the text (as Org does for quote blocks).
                  (put-text-property 1 17 'face 'org-quote)
                  ;; 4. Run the stamp pass (backend pass 0).
                  (variable-spacing--stamp-body-text 1 17)
                  ;; 5. Collect spans as the dispatch would.
                  (let ((spans-table (face-extra--collect-spans 1 17)))
                    ;; No variable-spacing-ratio spans should be collected for
                    ;; the org-quote-covered region.
                    (let ((ratio-spans (gethash 'variable-spacing-ratio spans-table)))
                      (should-not
                       (cl-some (lambda (s)
                                  ;; Any span within 1..17 is a failure.
                                  (and (>= (nth 0 s) 1) (<= (nth 1 s) 17)))
                                ratio-spans)))))
              (face-extra-remove cookie))))
      (setplist 'text-body
                (cl-loop for (k v) on (symbol-plist 'text-body) by #'cddr
                         unless (eq k 'variable-spacing-ratio)
                         append (list k v))))))

(ert-deftest vs/suppressor/text-body-gets-spacer ()
  "Positions with face=text-body DO get a spacer when ratio is set globally."
  (vs-test--with-buffer
    (insert "body text")
    (unwind-protect
        (progn
          (put 'text-body 'variable-spacing-ratio 1.6)
          (put-text-property 1 10 'face 'text-body)
          (let ((spans-table (face-extra--collect-spans 1 10)))
            (let ((ratio-spans (gethash 'variable-spacing-ratio spans-table)))
              (should ratio-spans)
              (should (cl-some (lambda (s) (eql 1.6 (nth 2 s))) ratio-spans)))))
      (setplist 'text-body
                (cl-loop for (k v) on (symbol-plist 'text-body) by #'cddr
                         unless (eq k 'variable-spacing-ratio)
                         append (list k v))))))

(ert-deftest vs/suppressor/suppress-wins-over-inherited-ratio ()
  "When BOTH text-body and org-quote are in the face list, org-quote's 0
suppressor must prevent collect-spans from returning a span for that position.

This is the multi-face version of the org-quote spacing bug."
  (vs-test--with-buffer
    (insert "content")
    (unwind-protect
        (progn
          (put 'text-body 'variable-spacing-ratio 1.6)
          (let ((cookie (face-extra-add-relative
                         'org-quote 'variable-spacing-ratio 0)))
            (unwind-protect
                (progn
                  ;; Simulate a face list that has BOTH text-body (stale stamp)
                  ;; and org-quote (set by Org) at the same position.
                  (put-text-property 1 8 'face '(text-body org-quote))
                  (let ((spans-table (face-extra--collect-spans 1 8)))
                    (let ((ratio-spans (gethash 'variable-spacing-ratio spans-table)))
                      ;; Currently this test will FAIL with the existing code
                      ;; because collect-spans iterates all faces independently:
                      ;; text-body contributes 1.6 even though org-quote says 0.
                      ;; This is a known bug to be fixed.
                      ;;
                      ;; Expected (after fix): no spans, or only spans with nil value.
                      ;; For now, document what we expect the correct behaviour to be.
                      (should-not
                       (cl-some (lambda (s)
                                  (and (>= (nth 0 s) 1) (<= (nth 1 s) 8)
                                       (and (nth 2 s) (> (nth 2 s) 0))))
                                ratio-spans)))))
              (face-extra-remove cookie))))
      (setplist 'text-body
                (cl-loop for (k v) on (symbol-plist 'text-body) by #'cddr
                         unless (eq k 'variable-spacing-ratio)
                         append (list k v))))))

;;; -----------------------------------------------------------------------
;;; variable-spacing--install/remove-body-remaps
;;; -----------------------------------------------------------------------

(ert-deftest vs/remaps/floor-on-default-after-install ()
  "After install-body-remaps, default has a floor :height remap."
  (vs-test--with-buffer
    ;; We need face-remapping-alist to be buffer-local.
    (variable-spacing--install-body-remaps)
    (unwind-protect
        (let ((default-entry (assq 'default face-remapping-alist)))
          (should default-entry)
          ;; The remap spec must contain :height variable-spacing-floor-height.
          (let ((spec (cdr default-entry)))
            (should (cl-some (lambda (s)
                               (and (listp s)
                                    (equal (plist-get s :height)
                                           variable-spacing-floor-height)))
                             spec))))
      (variable-spacing--remove-body-remaps))))

(ert-deftest vs/remaps/content-face-gets-text-body-inherit ()
  "After install-body-remaps, content faces have a (:inherit text-body) remap."
  (vs-test--with-buffer
    (variable-spacing--install-body-remaps)
    (unwind-protect
        ;; Check a sample content face.
        (let ((entry (assq 'org-level-1 face-remapping-alist)))
          (should entry)
          (should (cl-some (lambda (s)
                             (and (listp s)
                                  (eq (plist-get s :inherit) 'text-body)))
                           (cdr entry))))
      (variable-spacing--remove-body-remaps))))

(ert-deftest vs/remaps/metadata-face-gets-default-inherit ()
  "After install-body-remaps, metadata faces have a (:inherit default) remap."
  (vs-test--with-buffer
    (variable-spacing--install-body-remaps)
    (unwind-protect
        (let ((entry (assq 'org-drawer face-remapping-alist)))
          (should entry)
          (should (cl-some (lambda (s)
                             (and (listp s)
                                  (eq (plist-get s :inherit) 'default)))
                           (cdr entry))))
      (variable-spacing--remove-body-remaps))))

(ert-deftest vs/remaps/clean-after-remove ()
  "After remove-body-remaps, the mode's remaps are gone."
  (vs-test--with-buffer
    (variable-spacing--install-body-remaps)
    (variable-spacing--remove-body-remaps)
    ;; The cookie list must be nil.
    (should (null variable-spacing--body-remap-cookies))
    ;; The floor remap on default must be gone.
    ;; (Other packages might add their own, so we just check ours is absent
    ;; by verifying no :height = floor-height remap remains.)
    (let ((default-entry (assq 'default face-remapping-alist)))
      (should-not
       (and default-entry
            (cl-some (lambda (s)
                       (and (listp s)
                            (equal (plist-get s :height)
                                   variable-spacing-floor-height)))
                     (cdr default-entry)))))))

;;; -----------------------------------------------------------------------
;;; Run
;;; -----------------------------------------------------------------------

(provide 'test-variable-spacing)
;;; test-variable-spacing.el ends here
