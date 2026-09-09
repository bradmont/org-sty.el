;;; test-small-default.el --- Scratch test: global small default + per-buffer remap
;;
;; NOT part of the library. Load this in a live Emacs session to probe
;; whether the "invert default" architecture is stable before committing
;; to it. Fully reversible: call `test-small-default-revert' to undo
;; everything.
;;
;; Usage:
;;   M-x load-file RET <path-to-this-file> RET
;;
;;   Run all steps at once:
;;     M-x test-small-default-apply
;;
;;   Or step through manually in order:
;;     M-x test-small-default-step-save             ; snapshot current frame height
;;     M-x test-small-default-step-shrink-frame     ; set frame default to 6pt
;;     M-x test-small-default-step-remap-buffers    ; remap all existing buffers up
;;     M-x test-small-default-step-install-hook     ; hook future buffers
;;     M-x test-small-default-step-compensate-chrome ; fix header-line + minibuffer
;;
;;   Then when done:
;;     M-x test-small-default-revert                ; restore everything
;;
;; What to look for:
;;   - Do header-line and minibuffer recover after step 5?
;;   - Are there other chrome elements that step 5 misses?
;;   - Does `org-filetag-style-apply' correctly override the remap in WP buffers?
;;   - Does `text-scale-mode' (C-x C-=, C-x C--) still work correctly?
;;   - Are there buffers the hook visibly missed (opened after step 4)?
;;   - Does opening a new buffer during minibuffer use look correct?

;;; Tunables:

(defconst test-small-default-frame-height 60
  "Height to set on the frame `default' face, in 1/10pt units.
60 = 6pt.  This is the new global floor -- the minimum usable size for
word processing, and a useful stress-test of the inversion model.")

(defconst test-small-default-chrome-faces
  '(header-line
    mode-line
    mode-line-inactive
    tab-bar
    tab-line
    menu)
  "Chrome faces that resolve :height at the frame level, bypassing any
buffer's `face-remapping-alist'.  Each face in this list gets an explicit
:height pinned to the pre-test default in `test-small-default-step-compensate-chrome',
and restored to its original value by `test-small-default-revert'.

Add faces here if testing reveals other chrome elements still shrinking.")

;; The compensation height for ordinary buffers is NOT hardcoded here.
;; It is captured from the live frame state during `test-small-default-step-save',
;; so it reflects whatever size Emacs was actually running at before the test.

;;; State (do not edit):

(defvar test-small-default--saved-frame-height nil
  "Frame `default' :height before the test, in 1/10pt units.
Also used as the target height when remapping ordinary buffers back up --
\"normal\" means whatever we were running at before we started.")

(defvar test-small-default--saved-chrome-heights nil
  "Alist of (face . height) for each face in `test-small-default-chrome-faces',
captured before the test modified them.  Heights may be the symbol
`unspecified' if a face had no explicit :height set.")

(defvar test-small-default--remap-cookies nil
  "Alist of (buffer . cookie) for remaps installed by this test.")

;;; Internal:

(defun test-small-default--install-remap ()
  "Add the compensation remap to the current buffer, recording the cookie.
Uses `test-small-default--saved-frame-height' as the target height, so
the saved state must exist before this is called."
  (when test-small-default--saved-frame-height
    (let ((cookie (face-remap-add-relative
                   'default :height test-small-default--saved-frame-height)))
      (push (cons (current-buffer) cookie)
            test-small-default--remap-cookies))))

(defun test-small-default--minibuffer-remap ()
  "Remap `default' up to the pre-test height in the active minibuffer.
Installed on `minibuffer-setup-hook' by `test-small-default-step-compensate-chrome'.
The minibuffer buffer does not reliably receive `after-change-major-mode-hook',
and `face-remapping-alist' in the minibuffer buffer may not affect its
rendered text, so a dedicated setup hook is the reliable path."
  (when test-small-default--saved-frame-height
    (face-remap-add-relative 'default
                              :height test-small-default--saved-frame-height)))

;;; Step functions -- safe to call individually, in the order listed:

;;;###autoload
(defun test-small-default-step-save ()
  "Step 1: snapshot live frame state needed for compensation and revert.
Captures the current frame `default' height (used both as the buffer
compensation target and as the revert value) and the current
`header-line' face height.  Safe to call multiple times -- will not
overwrite an existing snapshot."
  (interactive)
  (if test-small-default--saved-frame-height
      (message "test-small-default: snapshot already held (%dpt) -- skipping."
               (/ test-small-default--saved-frame-height 10))
    (setq test-small-default--saved-frame-height
          (face-attribute 'default :height nil t))
    (setq test-small-default--saved-chrome-heights
          (mapcar (lambda (face)
                    (cons face (face-attribute face :height nil t)))
                  test-small-default-chrome-faces))
    (message "test-small-default: saved default=%dpt; chrome faces: %s."
             (/ test-small-default--saved-frame-height 10)
             (mapconcat (lambda (entry)
                          (format "%s=%S" (car entry) (cdr entry)))
                        test-small-default--saved-chrome-heights ", "))))

;;;###autoload
(defun test-small-default-step-shrink-frame ()
  "Step 2: set the frame `default' face to `test-small-default-frame-height'.
This is the visually disruptive step -- everything unstyled shrinks to 6pt.
Call `test-small-default-step-save' first if you want a clean revert."
  (interactive)
  (set-face-attribute 'default nil :height test-small-default-frame-height)
  (message "test-small-default: frame default is now %dpt."
           (/ test-small-default-frame-height 10)))

;;;###autoload
(defun test-small-default-step-remap-buffers ()
  "Step 3: remap `default' back up in every currently existing buffer.
Uses the height captured by `test-small-default-step-save' as the target.
Buffers created after this point are handled by the hook; see step 4."
  (interactive)
  (unless test-small-default--saved-frame-height
    (user-error "Run `test-small-default-step-save' first"))
  (let ((count 0))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (test-small-default--install-remap)
        (cl-incf count)))
    (message "test-small-default: remapped %d existing buffer(s) to %dpt."
             count (/ test-small-default--saved-frame-height 10))))

;;;###autoload
(defun test-small-default-step-install-hook ()
  "Step 4: install `after-change-major-mode-hook' so buffers created
from this point forward automatically receive the compensation remap."
  (interactive)
  (add-hook 'after-change-major-mode-hook #'test-small-default--install-remap)
  (message "test-small-default: hook installed for future buffers."))

;;;###autoload
(defun test-small-default-step-compensate-chrome ()
  "Step 5: explicitly compensate chrome elements that ignore `face-remapping-alist'.

`header-line' and the minibuffer resolve face attributes at the frame
level, bypassing each buffer's remap alist.  This step handles them:

  - `header-line' face: set :height explicitly to the pre-test size,
    so it is immune to whatever `default' is set to.

  - Minibuffer: install `minibuffer-setup-hook' so each minibuffer
    activation remaps `default' up in that buffer's own remap alist.
    (The minibuffer IS a real buffer; the hook fires in it reliably.)"
  (interactive)
  (unless test-small-default--saved-frame-height
    (user-error "Run `test-small-default-step-save' first"))
  ;; Chrome faces: pin :height on each so they no longer fall through to
  ;; `default'.  Works for any face in `test-small-default-chrome-faces'.
  (dolist (face test-small-default-chrome-faces)
    (set-face-attribute face nil :height test-small-default--saved-frame-height))
  ;; Minibuffer: a setup hook is the reliable path -- fires inside the
  ;; minibuffer buffer on each activation, regardless of when it was created.
  (add-hook 'minibuffer-setup-hook #'test-small-default--minibuffer-remap)
  (message "test-small-default: pinned %d chrome face(s) to %dpt; minibuffer-setup-hook installed."
           (length test-small-default-chrome-faces)
           (/ test-small-default--saved-frame-height 10)))

;;; Composite apply / revert:

;;;###autoload
(defun test-small-default-apply ()
  "Run all five steps in order.
To observe each step individually, call the `test-small-default-step-*'
functions one at a time instead."
  (interactive)
  (when test-small-default--saved-frame-height
    (user-error "Test already applied -- call `test-small-default-revert' first"))
  (test-small-default-step-save)
  (test-small-default-step-shrink-frame)
  (test-small-default-step-remap-buffers)
  (test-small-default-step-install-hook)
  (test-small-default-step-compensate-chrome)
  (message "test-small-default: fully applied. Call `test-small-default-revert' to undo."))

;;;###autoload
(defun test-small-default-revert ()
  "Undo everything applied by `test-small-default-apply' or the step functions."
  (interactive)
  (unless test-small-default--saved-frame-height
    (user-error "No saved state -- was `test-small-default-step-save' called?"))
  ;; Remove hooks.
  (remove-hook 'after-change-major-mode-hook #'test-small-default--install-remap)
  (remove-hook 'minibuffer-setup-hook #'test-small-default--minibuffer-remap)
  ;; Remove all buffer remaps.
  (dolist (entry test-small-default--remap-cookies)
    (let ((buf (car entry))
          (cookie (cdr entry)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (face-remap-remove-relative cookie)))))
  (setq test-small-default--remap-cookies nil)
  ;; Restore chrome faces.
  (dolist (entry test-small-default--saved-chrome-heights)
    (set-face-attribute (car entry) nil :height (cdr entry)))
  (setq test-small-default--saved-chrome-heights nil)
  ;; Restore frame default.
  (set-face-attribute 'default nil :height test-small-default--saved-frame-height)
  (setq test-small-default--saved-frame-height nil)
  (message "test-small-default: fully reverted."))

;;;###autoload
(defun test-small-default-status ()
  "Report current test state to *Messages*."
  (interactive)
  (if test-small-default--saved-frame-height
      (message (concat "test-small-default: ACTIVE. "
                       "frame=%dpt, buffer-remap=%dpt, %d cookie(s). "
                       "Chrome faces pinned: %s. "
                       "Hooks: major-mode=%s minibuffer=%s.")
               (/ test-small-default-frame-height 10)
               (/ test-small-default--saved-frame-height 10)
               (length test-small-default--remap-cookies)
               (if test-small-default--saved-chrome-heights
                   (mapconcat (lambda (e) (symbol-name (car e)))
                              test-small-default--saved-chrome-heights ", ")
                 "none")
               (if (memq #'test-small-default--install-remap
                         after-change-major-mode-hook)
                   "yes" "no")
               (if (memq #'test-small-default--minibuffer-remap
                         minibuffer-setup-hook)
                   "yes" "no"))
    (message "test-small-default: not applied.")))

(provide 'test-small-default)
;;; test-small-default.el ends here
