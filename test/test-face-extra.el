;;; test-face-extra.el --- ERT tests for face-extra.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   emacs --batch -L /path/to/org-sty.el -l ert \
;;         -l test/test-face-extra.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'face-extra)

;;; -----------------------------------------------------------------------
;;; Helpers
;;; -----------------------------------------------------------------------

;; A scratch face for tests that need a real (but unimportant) face symbol.
(defface fe-test-face-a '((t)) "Scratch face A for face-extra tests.")
(defface fe-test-face-b '((t)) "Scratch face B for face-extra tests.")
(defface fe-test-face-c '((t)) "Scratch face C for face-extra tests.")

;; A scratch property that we register fresh in each registry test.
;; We define a function to (re)register it so it can be called in setup.
(defvar fe-test--apply-calls nil
  "Accumulates (spans) lists received by the test :apply function.")
(defun fe-test--apply (spans)
  (push spans fe-test--apply-calls))
(defun fe-test--clear (_cookie) nil)

(defun fe-test--register-prop (sym pass)
  "Register SYM as a test property at PASS, clobbering any prior entry."
  (puthash sym (list :pass pass :after nil
                     :apply #'fe-test--apply
                     :clear #'fe-test--clear)
           face-extra--registry)
  (face-extra--sort-pass pass)
  (face-extra--invalidate-all-caches))

(defmacro with-clean-registry (&rest body)
  "Run BODY with a fresh face-extra registry and pass-order tables.
Restores original values on exit."
  (declare (indent 0))
  `(let ((face-extra--registry  (make-hash-table :test #'eq))
         (face-extra--pass-order (make-hash-table :test #'eql)))
     ,@body))

(defmacro with-test-buffer (&rest body)
  "Run BODY in a fresh temporary buffer with clean face-extra buffer-locals."
  (declare (indent 0))
  `(with-temp-buffer
     (setq face-extra--local-properties nil
           face-extra--face-cache       nil)
     ,@body))

;;; -----------------------------------------------------------------------
;;; Section 3: Public install API
;;; -----------------------------------------------------------------------

(ert-deftest fe-add-relative/stores-and-resolves ()
  "face-extra-add-relative stores the value; resolve-property finds it."
  (with-test-buffer
    (let ((cookie (face-extra-add-relative 'fe-test-face-a 'fe-test-prop 42)))
      (should (equal 42 (face-extra--resolve-property 'fe-test-face-a 'fe-test-prop)))
      ;; Sanity: another face does not see it.
      (should (null (face-extra--resolve-property 'fe-test-face-b 'fe-test-prop)))
      ;; Clean up.
      (face-extra-remove cookie)
      (should (null (face-extra--resolve-property 'fe-test-face-a 'fe-test-prop))))))

(ert-deftest fe-add-relative/removes-restores-old ()
  "Remove restores the prior local value, including :face-extra-unset."
  (with-test-buffer
    ;; Set an initial value, then override, then remove — should return to initial.
    (let ((c1 (face-extra-add-relative 'fe-test-face-a 'fe-test-prop 10)))
      (let ((c2 (face-extra-add-relative 'fe-test-face-a 'fe-test-prop 20)))
        (should (equal 20 (face-extra--resolve-property 'fe-test-face-a 'fe-test-prop)))
        (face-extra-remove c2))
      (should (equal 10 (face-extra--resolve-property 'fe-test-face-a 'fe-test-prop)))
      (face-extra-remove c1)
      ;; Now unset.
      (should (null (face-extra--resolve-property 'fe-test-face-a 'fe-test-prop))))))

(ert-deftest fe-add-relative/is-buffer-local ()
  "face-extra-add-relative does not affect other buffers."
  (let (cookie)
    (with-test-buffer
      (setq cookie (face-extra-add-relative 'fe-test-face-a 'fe-test-prop 99))
      (should (equal 99 (face-extra--resolve-property 'fe-test-face-a 'fe-test-prop))))
    ;; Different buffer — should not see the value.
    (with-test-buffer
      (should (null (face-extra--resolve-property 'fe-test-face-a 'fe-test-prop))))
    ;; Remove from the original buffer's cookie (buffer is gone but buffer-live-p
    ;; will be nil, so remove is a no-op; just ensure no error).
    (face-extra-remove cookie)))

(ert-deftest fe-add-global/stores-globally ()
  "face-extra-add sets the symbol property globally and resolves in any buffer."
  ;; Ensure no prior value.
  (let ((old (get 'fe-test-face-a 'fe-test-global-prop)))
    (unwind-protect
        (progn
          (let ((cookie (face-extra-add 'fe-test-face-a 'fe-test-global-prop 77)))
            (should (equal 77 (get 'fe-test-face-a 'fe-test-global-prop)))
            (with-test-buffer
              (should (equal 77 (face-extra--resolve-property
                                 'fe-test-face-a 'fe-test-global-prop))))
            (face-extra-remove cookie)
            (should (null (get 'fe-test-face-a 'fe-test-global-prop)))))
      ;; Restore whatever was there before (probably nil).
      (if old
          (put 'fe-test-face-a 'fe-test-global-prop old)
        (setplist 'fe-test-face-a
                  (cl-loop for (k v) on (symbol-plist 'fe-test-face-a) by #'cddr
                           unless (eq k 'fe-test-global-prop)
                           append (list k v)))))))

;;; -----------------------------------------------------------------------
;;; Suppression with value 0
;;; -----------------------------------------------------------------------

(ert-deftest fe-suppression/local-zero-returns-nil ()
  "A local value of 0 suppresses and returns nil."
  (with-test-buffer
    (let ((c (face-extra-add-relative 'fe-test-face-a 'fe-test-prop 0)))
      (should (null (face-extra--resolve-property 'fe-test-face-a 'fe-test-prop)))
      (face-extra-remove c))))

(ert-deftest fe-suppression/global-zero-returns-nil ()
  "A global symbol property of 0 suppresses and returns nil."
  (unwind-protect
      (progn
        (put 'fe-test-face-a 'fe-test-supp-prop 0)
        (with-test-buffer
          (should (null (face-extra--resolve-property 'fe-test-face-a 'fe-test-supp-prop)))))
    (setplist 'fe-test-face-a
              (cl-loop for (k v) on (symbol-plist 'fe-test-face-a) by #'cddr
                       unless (eq k 'fe-test-supp-prop)
                       append (list k v)))))

(ert-deftest fe-suppression/local-zero-overrides-global ()
  "Local 0 suppresses even when there is a positive global value."
  (unwind-protect
      (progn
        (put 'fe-test-face-a 'fe-test-supp2-prop 1.5)
        (with-test-buffer
          (let ((c (face-extra-add-relative 'fe-test-face-a 'fe-test-supp2-prop 0)))
            (should (null (face-extra--resolve-property
                           'fe-test-face-a 'fe-test-supp2-prop)))
            (face-extra-remove c)
            ;; After removing the suppressor the global value should be visible.
            (should (equal 1.5 (face-extra--resolve-property
                                'fe-test-face-a 'fe-test-supp2-prop))))))
    (setplist 'fe-test-face-a
              (cl-loop for (k v) on (symbol-plist 'fe-test-face-a) by #'cddr
                       unless (eq k 'fe-test-supp2-prop)
                       append (list k v)))))

;;; -----------------------------------------------------------------------
;;; Section 5: resolver — inheritance
;;; -----------------------------------------------------------------------

(ert-deftest fe-resolve/finds-global-symbol-property ()
  "Resolver finds a value set via (put face property value)."
  (unwind-protect
      (progn
        (put 'fe-test-face-a 'fe-test-inh-prop 2.5)
        (with-test-buffer
          (should (equal 2.5 (face-extra--resolve-property
                              'fe-test-face-a 'fe-test-inh-prop)))))
    (setplist 'fe-test-face-a
              (cl-loop for (k v) on (symbol-plist 'fe-test-face-a) by #'cddr
                       unless (eq k 'fe-test-inh-prop) append (list k v)))))

(ert-deftest fe-resolve/local-shadows-global ()
  "A buffer-local value shadows a global symbol property."
  (unwind-protect
      (progn
        (put 'fe-test-face-a 'fe-test-shadow-prop 1.0)
        (with-test-buffer
          (let ((c (face-extra-add-relative 'fe-test-face-a 'fe-test-shadow-prop 3.0)))
            (should (equal 3.0 (face-extra--resolve-property
                                'fe-test-face-a 'fe-test-shadow-prop)))
            (face-extra-remove c))))
    (setplist 'fe-test-face-a
              (cl-loop for (k v) on (symbol-plist 'fe-test-face-a) by #'cddr
                       unless (eq k 'fe-test-shadow-prop) append (list k v)))))

(ert-deftest fe-resolve/remap-inherit-chain ()
  "Resolver walks face-remapping-alist :inherit entries."
  (unwind-protect
      (progn
        (put 'fe-test-face-b 'fe-test-remap-prop 1.6)
        (with-test-buffer
          ;; Set up a buffer-local remap: face-a inherits face-b via remapping.
          (let ((cookie (face-remap-add-relative 'fe-test-face-a :inherit 'fe-test-face-b)))
            (unwind-protect
                ;; face-a has no direct value; should resolve via face-b's global property.
                (should (equal 1.6 (face-extra--resolve-property
                                    'fe-test-face-a 'fe-test-remap-prop)))
              (face-remap-remove-relative cookie)))))
    (setplist 'fe-test-face-b
              (cl-loop for (k v) on (symbol-plist 'fe-test-face-b) by #'cddr
                       unless (eq k 'fe-test-remap-prop) append (list k v)))))

(ert-deftest fe-resolve/global-inherit-chain ()
  "Resolver walks the global face :inherit attribute."
  (unwind-protect
      (progn
        (put 'fe-test-face-c 'fe-test-ginh-prop 0.8)
        ;; Make face-b globally inherit face-c.
        (let ((orig-inherit (face-attribute 'fe-test-face-b :inherit t)))
          (set-face-attribute 'fe-test-face-b nil :inherit 'fe-test-face-c)
          (unwind-protect
              (with-test-buffer
                (should (equal 0.8 (face-extra--resolve-property
                                    'fe-test-face-b 'fe-test-ginh-prop))))
            (set-face-attribute 'fe-test-face-b nil
                                :inherit (if (eq orig-inherit 'unspecified)
                                             'unspecified
                                           orig-inherit)))))
    (setplist 'fe-test-face-c
              (cl-loop for (k v) on (symbol-plist 'fe-test-face-c) by #'cddr
                       unless (eq k 'fe-test-ginh-prop) append (list k v)))))

(ert-deftest fe-resolve/cycle-guard ()
  "Resolver does not loop on cyclic :inherit."
  ;; Create a cycle: face-a inherits face-b, face-b inherits face-a (via global).
  (let ((orig-a (face-attribute 'fe-test-face-a :inherit t))
        (orig-b (face-attribute 'fe-test-face-b :inherit t)))
    (set-face-attribute 'fe-test-face-a nil :inherit 'fe-test-face-b)
    (set-face-attribute 'fe-test-face-b nil :inherit 'fe-test-face-a)
    (unwind-protect
        (with-test-buffer
          ;; Should return nil without looping.
          (should (null (face-extra--resolve-property 'fe-test-face-a 'fe-test-cycle-prop))))
      (set-face-attribute 'fe-test-face-a nil
                          :inherit (if (eq orig-a 'unspecified) 'unspecified orig-a))
      (set-face-attribute 'fe-test-face-b nil
                          :inherit (if (eq orig-b 'unspecified) 'unspecified orig-b)))))

;;; -----------------------------------------------------------------------
;;; Section 1: Registry
;;; -----------------------------------------------------------------------

(ert-deftest fe-registry/define-property-basic ()
  "face-extra-define-property registers the entry correctly."
  (with-clean-registry
    (face-extra-define-property 'test-prop :pass 1
                                :apply #'fe-test--apply
                                :clear #'fe-test--clear)
    (let ((entry (gethash 'test-prop face-extra--registry)))
      (should entry)
      (should (eql 1 (plist-get entry :pass)))
      (should (eq #'fe-test--apply (plist-get entry :apply))))))

(ert-deftest fe-registry/invalid-pass-errors ()
  "face-extra-define-property signals on invalid :pass."
  (with-clean-registry
    (should-error
     (face-extra-define-property 'test-bad :pass 4
                                 :apply #'fe-test--apply
                                 :clear #'fe-test--clear))))

(ert-deftest fe-registry/cross-pass-after-rejected ()
  "face-extra-define-property rejects :after referencing a different pass."
  (with-clean-registry
    ;; Register prop-a at pass 1.
    (face-extra-define-property 'test-prop-a :pass 1
                                :apply #'fe-test--apply :clear #'fe-test--clear)
    ;; prop-b at pass 2 with :after test-prop-a (pass 1) — must error.
    (should-error
     (face-extra-define-property 'test-prop-b :pass 2
                                 :after '(test-prop-a)
                                 :apply #'fe-test--apply :clear #'fe-test--clear))))

(ert-deftest fe-registry/topo-sort-respects-after ()
  "Pass order after registration respects :after constraints."
  (with-clean-registry
    ;; prop-b must run after prop-a (both pass 1).
    (face-extra-define-property 'prop-a :pass 1
                                :apply #'fe-test--apply :clear #'fe-test--clear)
    (face-extra-define-property 'prop-b :pass 1 :after '(prop-a)
                                :apply #'fe-test--apply :clear #'fe-test--clear)
    (let ((order (gethash 1 face-extra--pass-order)))
      (should (< (cl-position 'prop-a order)
                 (cl-position 'prop-b order))))))

;;; -----------------------------------------------------------------------
;;; Section 2: Cache
;;; -----------------------------------------------------------------------

(ert-deftest fe-cache/miss-builds-entry ()
  "Cache miss calls build-cache-entry; second lookup hits cache."
  (with-clean-registry
    (fe-test--register-prop 'cache-prop 1)
    (unwind-protect
        (progn
          (put 'fe-test-face-a 'cache-prop 1.0))
      (with-test-buffer
        (should (null face-extra--face-cache))
        (face-extra--get-cache-entry 'fe-test-face-a)
        (should face-extra--face-cache)
        (should (gethash 'fe-test-face-a face-extra--face-cache))
        ;; Second call must reuse cache (entry still present).
        (face-extra--get-cache-entry 'fe-test-face-a)
        (should (gethash 'fe-test-face-a face-extra--face-cache)))
      (setplist 'fe-test-face-a
                (cl-loop for (k v) on (symbol-plist 'fe-test-face-a) by #'cddr
                         unless (eq k 'cache-prop) append (list k v))))))

(ert-deftest fe-cache/invalidate-face-clears-one-entry ()
  "face-extra--invalidate-face removes only the target face."
  (with-clean-registry
    (fe-test--register-prop 'inv-prop 1)
    (unwind-protect
        (progn
          (put 'fe-test-face-a 'inv-prop 1.0)
          (put 'fe-test-face-b 'inv-prop 2.0))
      (with-test-buffer
        (face-extra--get-cache-entry 'fe-test-face-a)
        (face-extra--get-cache-entry 'fe-test-face-b)
        (should (gethash 'fe-test-face-a face-extra--face-cache))
        (should (gethash 'fe-test-face-b face-extra--face-cache))
        (face-extra--invalidate-face 'fe-test-face-a)
        (should (null (gethash 'fe-test-face-a face-extra--face-cache)))
        (should (gethash 'fe-test-face-b face-extra--face-cache)))
      (setplist 'fe-test-face-a
                (cl-loop for (k v) on (symbol-plist 'fe-test-face-a) by #'cddr
                         unless (eq k 'inv-prop) append (list k v)))
      (setplist 'fe-test-face-b
                (cl-loop for (k v) on (symbol-plist 'fe-test-face-b) by #'cddr
                         unless (eq k 'inv-prop) append (list k v))))))

;;; -----------------------------------------------------------------------
;;; Dispatch: collect-spans
;;; -----------------------------------------------------------------------

(ert-deftest fe-dispatch/collect-spans-basic ()
  "collect-spans returns triples for faces that carry a registered property."
  (with-clean-registry
    (fe-test--register-prop 'span-prop 1)
    (unwind-protect
        (progn
          (put 'fe-test-face-a 'span-prop 1.5))
      (with-test-buffer
        (insert "hello world")
        ;; Stamp font-lock-face over positions 1-6 ("hello ").
        (put-text-property 1 6 'font-lock-face 'fe-test-face-a)
        (let ((spans-table (face-extra--collect-spans 1 (point-max))))
          (let ((spans (gethash 'span-prop spans-table)))
            (should spans)
            ;; Should have at least one triple covering [1,6).
            (should (cl-some (lambda (s) (and (= (nth 0 s) 1) (= (nth 1 s) 6)))
                             spans)))))
      (setplist 'fe-test-face-a
                (cl-loop for (k v) on (symbol-plist 'fe-test-face-a) by #'cddr
                         unless (eq k 'span-prop) append (list k v))))))

(ert-deftest fe-dispatch/collect-spans-no-face-no-entry ()
  "collect-spans produces no entry for positions with no face."
  (with-clean-registry
    (fe-test--register-prop 'nospan-prop 1)
    (with-test-buffer
      (insert "plain text")
      ;; No face properties set.
      (let ((spans-table (face-extra--collect-spans 1 (point-max))))
        (should (null (gethash 'nospan-prop spans-table)))))))

;;; -----------------------------------------------------------------------
;;; Dispatch guard
;;; -----------------------------------------------------------------------

(ert-deftest fe-dispatch/guard-no-local-no-backend ()
  "face-extra--dispatch is a no-op when local-properties is nil and no backend."
  (with-clean-registry
    (fe-test--register-prop 'guard-prop 1)
    (with-test-buffer
      (let ((face-extra--backend-alist nil)
            (fe-test--apply-calls nil))
        (put-text-property 1 1 'font-lock-face 'fe-test-face-a) ; noop on empty buf
        (face-extra--dispatch 1 1)
        ;; apply should not have been called.
        (should (null fe-test--apply-calls))))))

(ert-deftest fe-dispatch/guard-runs-with-local-properties ()
  "face-extra--dispatch runs when face-extra--local-properties is non-nil."
  (with-clean-registry
    (fe-test--register-prop 'run-prop 1)
    (unwind-protect
        (progn
          (put 'fe-test-face-a 'run-prop 1.0))
      (with-test-buffer
        (let ((face-extra--backend-alist nil)
              (fe-test--apply-calls nil))
          (setq face-extra--local-properties (make-hash-table :test #'equal))
          (insert "hi")
          (put-text-property 1 3 'font-lock-face 'fe-test-face-a)
          (face-extra--dispatch 1 3)
          ;; apply was called (even if with empty spans for faces not in local-props,
          ;; it should have been invoked if there are spans).
          ;; Verify dispatch ran by checking apply-calls accumulated something.
          (should (not (null fe-test--apply-calls)))))
      (setplist 'fe-test-face-a
                (cl-loop for (k v) on (symbol-plist 'fe-test-face-a) by #'cddr
                         unless (eq k 'run-prop) append (list k v))))))

;;; -----------------------------------------------------------------------
;;; Run
;;; -----------------------------------------------------------------------

(provide 'test-face-extra)
;;; test-face-extra.el ends here
