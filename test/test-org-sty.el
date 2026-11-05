;;; test-org-sty.el --- ERT tests for org-sty.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   emacs --batch -L /path/to/org-sty.el -l ert \
;;         -l test/test-org-sty.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'face-extra)
(require 'variable-spacing)
(require 'org-sty)

;;; -----------------------------------------------------------------------
;;; Helpers
;;; -----------------------------------------------------------------------

(defmacro os-test--with-buffer (&rest body)
  "Run BODY in a fresh temp buffer with clean org-sty and face-extra state."
  (declare (indent 0))
  `(with-temp-buffer
     (setq face-extra--local-properties nil
           face-extra--face-cache       nil
           org-sty--face-remap-cookies  nil)
     ,@body))

(defface os-test-face-a '((t)) "Scratch face A for org-sty tests.")
(defface os-test-face-b '((t)) "Scratch face B for org-sty tests.")

;;; -----------------------------------------------------------------------
;;; org-sty-remap — routing
;;; -----------------------------------------------------------------------

(ert-deftest os/remap/standard-attr-produces-remap-cookie ()
  "A standard face attribute (e.g. :slant) produces a 'remap cookie."
  (os-test--with-buffer
    (org-sty-remap 'os-test-face-a :slant 'italic)
    (should (= 1 (length org-sty--face-remap-cookies)))
    (should (eq 'remap (caar org-sty--face-remap-cookies)))
    ;; Clean up.
    (org-sty--clear-face-remaps)))

(ert-deftest os/remap/standard-attrs-plist-order-correct ()
  "Standard face attributes must be passed to face-remap-add-relative in
correct plist order (k v k v ...), not reversed (v k v k ...).

Regression test for: org-level-1 got remap spec (bold :weight 1.4 :height)
instead of (:weight bold :height 1.4), causing headings to display at
floor height with no theme colours."
  (os-test--with-buffer
    ;; Remap with TWO standard attributes.
    (org-sty-remap 'os-test-face-a :weight 'bold :height 1.4)
    (should (= 1 (length org-sty--face-remap-cookies)))
    ;; Inspect the face-remapping-alist entry for os-test-face-a.
    (let* ((entry    (assq 'os-test-face-a face-remapping-alist))
           ;; The remap list has the form (FACE SPEC ... ORIG-FACE).
           ;; Our spec is the first entry after the face symbol.
           (spec     (cadr entry)))
      ;; The spec must be a plist starting with a keyword, not a symbol.
      (should (keywordp (car spec)))
      ;; :weight must map to the symbol bold, not a number.
      (should (eq 'bold (plist-get spec :weight)))
      ;; :height must be the float 1.4.
      (should (eql 1.4 (plist-get spec :height))))
    (org-sty--clear-face-remaps)))

(ert-deftest os/remap/registered-property-produces-extra-cookie ()
  "A registered face-extra property (:variable-spacing-ratio) produces an 'extra cookie."
  (os-test--with-buffer
    (org-sty-remap 'os-test-face-a :variable-spacing-ratio 1.5)
    (should (= 1 (length org-sty--face-remap-cookies)))
    (should (eq 'extra (caar org-sty--face-remap-cookies)))
    ;; The value should be stored in local-properties.
    (should (equal 1.5 (face-extra--resolve-property
                        'os-test-face-a 'variable-spacing-ratio)))
    ;; Clean up.
    (org-sty--clear-face-remaps)
    ;; After cleanup the value must be gone.
    (should (null (face-extra--resolve-property
                   'os-test-face-a 'variable-spacing-ratio)))))

(ert-deftest os/remap/suppressor-zero-produces-extra-cookie ()
  "A suppressor value of 0 for a registered property produces an 'extra cookie."
  (os-test--with-buffer
    (org-sty-remap 'os-test-face-a :variable-spacing-ratio 0)
    (should (= 1 (length org-sty--face-remap-cookies)))
    (should (eq 'extra (caar org-sty--face-remap-cookies)))
    ;; Value 0 means suppressed — resolver returns nil.
    (should (null (face-extra--resolve-property
                   'os-test-face-a 'variable-spacing-ratio)))
    (org-sty--clear-face-remaps)))

(ert-deftest os/remap/mixed-attrs-produce-both-cookie-types ()
  "Mixed attrs (:slant + :variable-spacing-ratio) produce both cookie types."
  (os-test--with-buffer
    (org-sty-remap 'os-test-face-a :slant 'italic :variable-spacing-ratio 1.2)
    (should (= 2 (length org-sty--face-remap-cookies)))
    (let ((types (mapcar #'car org-sty--face-remap-cookies)))
      (should (memq 'remap types))
      (should (memq 'extra types)))
    (org-sty--clear-face-remaps)))

(ert-deftest os/remap/unknown-key-warns-and-skips ()
  "An unrecognised key is warned about and does not produce a cookie."
  (os-test--with-buffer
    ;; :not-a-real-key is neither a face-extra property nor a face attribute
    ;; that face-remap-add-relative will accept (actually face-remap-add-relative
    ;; would pass it through; the warning fires from org-sty-remap when the key
    ;; is not a keyword — but we only warn for non-keyword keys).
    ;; For this test we verify that the call completes without error.
    ;; Unknown non-keyword symbols should not produce remap cookies.
    (should-not (condition-case err
                    (progn
                      (org-sty-remap 'os-test-face-a 'not-a-keyword "value")
                      nil)
                  (error err)))
    ;; Non-keyword keys get a warning and no cookie.
    (should (null org-sty--face-remap-cookies))))

;;; -----------------------------------------------------------------------
;;; org-sty--clear-face-remaps
;;; -----------------------------------------------------------------------

(ert-deftest os/clear/removes-remap-cookies ()
  "clear-face-remaps removes face-remap-add-relative cookies."
  (os-test--with-buffer
    (org-sty-remap 'os-test-face-a :weight 'bold)
    (let ((n-before (length face-remapping-alist)))
      (org-sty--clear-face-remaps)
      ;; face-remapping-alist should have shrunk back.
      (should (< (length face-remapping-alist) n-before))
      (should (null org-sty--face-remap-cookies)))))

(ert-deftest os/clear/removes-extra-cookies ()
  "clear-face-remaps removes face-extra-add-relative cookies."
  (os-test--with-buffer
    (org-sty-remap 'os-test-face-a :variable-spacing-ratio 1.3)
    (should (face-extra--resolve-property 'os-test-face-a 'variable-spacing-ratio))
    (org-sty--clear-face-remaps)
    (should (null org-sty--face-remap-cookies))
    (should (null (face-extra--resolve-property 'os-test-face-a 'variable-spacing-ratio)))))

(ert-deftest os/clear/list-becomes-nil ()
  "After clear-face-remaps, org-sty--face-remap-cookies is nil."
  (os-test--with-buffer
    (org-sty-remap 'os-test-face-a :slant 'italic)
    (org-sty-remap 'os-test-face-b :variable-spacing-ratio 1.1)
    (should (= 2 (length org-sty--face-remap-cookies)))
    (org-sty--clear-face-remaps)
    (should (null org-sty--face-remap-cookies))))

;;; -----------------------------------------------------------------------
;;; org-sty--apply-faces
;;; -----------------------------------------------------------------------

(ert-deftest os/apply-faces/iterates-alist ()
  "apply-faces processes each (FACE . ATTRS) entry via org-sty-remap."
  (os-test--with-buffer
    (org-sty--apply-faces
     `(:faces ((os-test-face-a . (:weight bold))
               (os-test-face-b . (:variable-spacing-ratio 0.8)))))
    ;; Expect 2 cookies: one remap, one extra.
    (should (= 2 (length org-sty--face-remap-cookies)))
    (should (memq 'remap (mapcar #'car org-sty--face-remap-cookies)))
    (should (memq 'extra (mapcar #'car org-sty--face-remap-cookies)))
    ;; The extra value must be visible via the resolver.
    (should (equal 0.8 (face-extra--resolve-property
                        'os-test-face-b 'variable-spacing-ratio)))
    (org-sty--clear-face-remaps)))

(ert-deftest os/apply-faces/suppressor-zero-stored ()
  "apply-faces correctly stores a suppressor value of 0 for a face."
  (os-test--with-buffer
    (org-sty--apply-faces
     `(:faces ((os-test-face-a . (:variable-spacing-ratio 0)))))
    ;; Suppressor stored → resolver returns nil.
    (should (null (face-extra--resolve-property
                   'os-test-face-a 'variable-spacing-ratio)))
    ;; But the cookie IS in the list (so it gets cleaned up on re-apply).
    (should (= 1 (length org-sty--face-remap-cookies)))
    (should (eq 'extra (caar org-sty--face-remap-cookies)))
    (org-sty--clear-face-remaps)))

;;; -----------------------------------------------------------------------
;;; Idempotency
;;; -----------------------------------------------------------------------

(ert-deftest os/idempotency/second-apply-faces-leaves-one-set ()
  "Calling apply-faces twice (with clear in between) leaves exactly one set of cookies."
  (os-test--with-buffer
    (let ((faces-plist `(:faces ((os-test-face-a . (:variable-spacing-ratio 1.0))))))
      ;; First apply.
      (org-sty--apply-faces faces-plist)
      (let ((cookies-1 (length org-sty--face-remap-cookies))
            (val-1 (face-extra--resolve-property
                    'os-test-face-a 'variable-spacing-ratio)))
        (should (= 1 cookies-1))
        (should (equal 1.0 val-1))
        ;; Clear + re-apply (mimics what org-sty-apply does).
        (org-sty--clear-face-remaps)
        (org-sty--apply-faces faces-plist)
        (let ((cookies-2 (length org-sty--face-remap-cookies))
              (val-2 (face-extra--resolve-property
                      'os-test-face-a 'variable-spacing-ratio)))
          (should (= 1 cookies-2))
          (should (equal 1.0 val-2))))
      (org-sty--clear-face-remaps))))

(ert-deftest os/idempotency/clear-removes-all-from-second-apply ()
  "After two apply+clear cycles, the resolver returns nil."
  (os-test--with-buffer
    (let ((faces-plist `(:faces ((os-test-face-b . (:variable-spacing-ratio 2.0))))))
      (org-sty--apply-faces faces-plist)
      (org-sty--clear-face-remaps)
      (org-sty--apply-faces faces-plist)
      (org-sty--clear-face-remaps)
      (should (null (face-extra--resolve-property
                     'os-test-face-b 'variable-spacing-ratio))))))

;;; -----------------------------------------------------------------------
;;; The key parity test: org-sty-apply correctly stores suppressors
;;; before fontification could run
;;; -----------------------------------------------------------------------

(ert-deftest os/parity/apply-faces-stores-suppressor-before-dispatch ()
  "After org-sty--apply-faces, collect-spans returns no ratio span for
a suppressed face — even when a global body ratio is set.

This is the core parity test: it verifies that the suppressor installed
via :faces is visible to the dispatch system."
  (os-test--with-buffer
    (insert "some quoted content")
    (put-text-property 1 20 'face 'org-quote)
    (unwind-protect
        (progn
          ;; Set global body ratio (as wp-eval does).
          (put 'body 'variable-spacing-ratio 1.6)
          ;; Apply the suppressor via apply-faces (as org-sty--apply-faces does).
          (org-sty--apply-faces
           `(:faces ((org-quote . (:variable-spacing-ratio 0)))))
          ;; Now collect spans as the dispatch would.
          (let ((spans-table (face-extra--collect-spans 1 20)))
            (let ((ratio-spans (gethash 'variable-spacing-ratio spans-table)))
              ;; org-quote is suppressed → no span covering positions 1..20.
              (should-not
               (cl-some (lambda (s)
                          (and (>= (nth 0 s) 1) (<= (nth 1 s) 20)
                               (nth 2 s) (> (nth 2 s) 0)))
                        ratio-spans))))
          (org-sty--clear-face-remaps))
      (setplist 'body
                (cl-loop for (k v) on (symbol-plist 'body) by #'cddr
                         unless (eq k 'variable-spacing-ratio)
                         append (list k v))))))

;;; -----------------------------------------------------------------------
;;; Run
;;; -----------------------------------------------------------------------

(provide 'test-org-sty)
;;; test-org-sty.el ends here
