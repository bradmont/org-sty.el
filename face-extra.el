;;; face-extra.el --- Generic synthetic face-attribute registry and dispatch -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: faces, display
;; Version: 0.1.0

;;; Commentary:

;; `face-extra' provides a generic mechanism for defining synthetic face
;; attributes — properties that drive display effects not expressible as
;; standard Emacs face attributes (e.g. line-spacing ratio, text alignment).
;;
;; A synthetic property is registered once at load time:
;;
;;   (face-extra-define-property 'variable-spacing-ratio
;;     :pass  1
;;     :after nil
;;     :apply #'my-apply-fn   ; called with (spans) = list of (beg end value)
;;     :clear #'my-clear-fn)
;;
;; Properties can be attached to faces globally or buffer-locally:
;;
;;   ;; Global — affects all buffers:
;;   (face-extra-add 'body 'variable-spacing-ratio 1.5)
;;
;;   ;; Buffer-local — per-document styling:
;;   (face-extra-add-relative 'org-quote 'variable-spacing-ratio 1.0)
;;
;; Both return a cookie; pass it to `face-extra-remove' to undo.
;;
;; Passes 1–3 correspond to the rendering pipeline described in AGENTS.md:
;;   Pass 1 — vertical metrics (spacing ratios, space-before/after)
;;   Pass 2 — horizontal bounds (margins, indent, tab stops)
;;   Pass 3 — line-break-dependent (justification, alignment)
;;
;; The after-fontify dispatch (section 5) is wired up in Phase 3.

;;; Code:

(require 'cl-lib)

;; Forward declaration — defined in horizontal-layout.el.
;; Suppresses byte-compiler "free variable" warning when face-extra.el
;; is compiled before horizontal-layout.el.
(defvar text-align--debug)
(require 'face-remap)


;;;; ================================================================
;;;; Section 1 — Registry
;;;; ================================================================

(defvar face-extra--registry (make-hash-table :test #'equal)
  "Global hash table mapping (property . pass) → registration plist.

The key is a cons `(PROPERTY . PASS)' so that the same property symbol
may be registered independently at multiple passes (e.g. a property
that does pass-2 narrowing and pass-3 expansion).

Each entry has the form:
  (:pass PASS :after AFTER-LIST :apply APPLY-FN :clear CLEAR-FN)

where PASS is 1, 2, or 3; AFTER-LIST is a list of property symbols
in the same pass that must run before this one; APPLY-FN is called
once per dispatch with a list of (beg end value) triples; CLEAR-FN
is called with a cookie to undo a global installation.")

(defvar face-extra--pass-order (make-hash-table :test #'eql)
  "Hash table mapping pass number (1, 2, 3) → sorted list of property symbols.

Entries are recomputed by `face-extra--sort-pass' whenever a new
property is registered for that pass.")


(defun face-extra-registered-p (property)
  "Return non-nil if PROPERTY is registered in any pass."
  (or (gethash (cons property 0) face-extra--registry)
      (gethash (cons property 1) face-extra--registry)
      (gethash (cons property 2) face-extra--registry)
      (gethash (cons property 3) face-extra--registry)))

(defun face-extra--validate-after (property after pass)
  "Signal an error if any symbol in AFTER is not registered in PASS.
This enforces that modes defining properties with `:after' dependencies
must be enabled after the modes that own those dependencies.  An error
here means modes were enabled out of order — check the `:eval' block
in your style config and ensure the dependency mode is enabled first."
  (dolist (dep after)
    (unless (gethash (cons dep pass) face-extra--registry)
      (error "face-extra: `%s' (pass %d) has :after `%s' but that \
property is not registered; enable the mode that provides it first"
             property pass dep))))

(defun face-extra--sort-pass (pass)
  "Compute the topological sort order for all properties in PASS.

Updates `face-extra--pass-order' entry for PASS in place.
Signals an error if a dependency cycle is detected.

The algorithm is Kahn's: collect all registered properties for PASS,
build an in-degree map from the :after constraints, and iteratively
remove zero-in-degree nodes."
  (let ((props-in-pass nil))
    ;; Collect all properties registered for this pass.
    ;; Registry keys are (property . pass) cons cells; filter by cdr.
    (maphash (lambda (key _entry)
               (when (eql (cdr key) pass)
                 (push (car key) props-in-pass)))
             face-extra--registry)
    (if (null props-in-pass)
        (puthash pass nil face-extra--pass-order)
      ;; Build adjacency (before → list-of-dependents) and in-degree maps.
      (let ((in-degree (make-hash-table :test #'eq))
            (dependents (make-hash-table :test #'eq)))
        (dolist (sym props-in-pass)
          (puthash sym 0 in-degree))
        (dolist (sym props-in-pass)
          (let ((after (plist-get (gethash (cons sym pass) face-extra--registry) :after)))
            (dolist (dep after)
              ;; dep must run before sym → dep → sym edge.
              (push sym (gethash dep dependents))
              (puthash sym (1+ (gethash sym in-degree 0)) in-degree))))
        ;; Kahn's algorithm.
        (let ((queue (cl-remove-if (lambda (s) (> (gethash s in-degree 0) 0))
                                   props-in-pass))
              (sorted nil))
          (while queue
            (let ((node (pop queue)))
              (push node sorted)
              (dolist (dep (gethash node dependents))
                (let ((new-deg (1- (gethash dep in-degree 0))))
                  (puthash dep new-deg in-degree)
                  (when (zerop new-deg)
                    (push dep queue))))))
          (when (< (length sorted) (length props-in-pass))
            (error "face-extra: dependency cycle detected in pass %d properties" pass))
          (puthash pass (nreverse sorted) face-extra--pass-order))))))

;; `face-extra-mode' is defined here (before `face-extra-define-property')
;; so that `face-extra-mode-require' can call `(face-extra-mode 1)'.
(define-minor-mode face-extra-mode
  "Infrastructure minor mode: active while face-extra dispatch is running.

Enabled by `face-extra-mode-require' when the first property mode
enables in the current buffer; disabled by `face-extra-mode-release'
when the last property mode disables.  Do not toggle directly — use
`face-extra-mode-require' and `face-extra-mode-release' instead."
  :lighter " FExtra"
  :interactive nil
  (if face-extra-mode
      (face-extra--enable-dispatch)
    (face-extra--disable-dispatch)))

(defvar-local face-extra--buffer-users 0
  "Ref count: number of property modes currently active in this buffer.
Incremented by `face-extra-mode-require'; decremented by
`face-extra-mode-release'.  When it transitions 0→1 `face-extra-mode'
is enabled; when it transitions 1→0 `face-extra-mode' is disabled.")

(defun face-extra-mode-require ()
  "Increment the face-extra ref count in the current buffer.

Called from property mode enable bodies (e.g. `variable-spacing-mode',
`horizontal-layout-mode', `body-face-mode').  On the 0→1 transition,
enables `face-extra-mode' (which installs dispatch advice globally and
registers pass-3 jit-lock dispatch in this buffer).

Each call to `face-extra-mode-require' must be paired with exactly one
call to `face-extra-mode-release' in the corresponding disable body."
  (cl-incf face-extra--buffer-users)
  (when (= face-extra--buffer-users 1)
    (face-extra-mode 1)))

(defun face-extra-mode-release ()
  "Decrement the face-extra ref count in the current buffer.

Called from property mode disable bodies.  On the 1→0 transition,
disables `face-extra-mode' (which removes dispatch advice and unregisters
pass-3 jit-lock dispatch from this buffer).

Each call to `face-extra-mode-release' must be paired with an earlier
call to `face-extra-mode-require'."
  (cl-decf face-extra--buffer-users)
  (when (<= face-extra--buffer-users 0)
    (setq face-extra--buffer-users 0)
    (face-extra-mode -1)))

;;;###autoload
(defun face-extra-define-property (property &rest plist)
  "Register a synthetic face PROPERTY with the face-extra dispatch system.

PLIST must contain:
  :pass   Integer 0, 1, 2, or 3 (pipeline pass number).
          Pass 0: bare-text stamping; :apply called as (fn beg end).
          Passes 1–3: :apply called with a list of (beg end value) triples.
  :apply  Function — see :pass above for call signature.
  :mode   The minor-mode symbol that owns this property (e.g.
          `variable-spacing-mode').  Required.  The dispatcher checks
          `(symbol-value :mode)' before invoking :apply, :pre-clear,
          or :pre-command in any buffer.  This is how globally-registered
          properties are suppressed in buffers where the owning mode is
          not active — the check lives in the dispatcher, not in the
          individual callback functions.

Optional:
  :clear      Function called with a cookie to undo a global installation.
  :after      List of property symbols in the same PASS that must run before
              this property.  Cross-pass references are rejected.  Not valid
              for pass 0.
  :pre-clear  Function called with (beg end) before the pass-3 walk.
  :pre-command  Function called with (vline-beg vline-end) from
              `pre-command-hook'.

Properties are registered at load time, once globally, and remain in
the registry permanently.  Buffer-local lifecycle is managed via
`face-extra-mode-require' and `face-extra-mode-release'."
  (let ((pass         (plist-get plist :pass))
        (mode         (plist-get plist :mode))
        (after        (plist-get plist :after))
        (apply-fn     (plist-get plist :apply))
        (clear-fn     (plist-get plist :clear))
        (pre-clear    (plist-get plist :pre-clear))
        (pre-command  (plist-get plist :pre-command)))
    (unless (memql pass '(0 1 2 3))
      (error "face-extra-define-property: :pass must be 0, 1, 2, or 3 (got %S)" pass))
    (unless (symbolp mode)
      (error "face-extra-define-property: :mode must be a symbol (got %S)" mode))
    (unless mode
      (error "face-extra-define-property: :mode is required"))
    (unless (functionp apply-fn)
      (error "face-extra-define-property: :apply must be a function"))
    (when (and after (= pass 0))
      (error "face-extra-define-property: :after is not valid for pass 0"))
    (let ((ref-key (cons property pass)))
      (when (and (> pass 0) after)
        (face-extra--validate-after property after pass))
      (puthash ref-key
               (list :pass pass :mode mode :after after :apply apply-fn
                     :clear clear-fn :pre-clear pre-clear
                     :pre-command pre-command)
               face-extra--registry)
      (when (> pass 0)
        (face-extra--sort-pass pass))
      ;; Invalidate all caches since a new property may affect resolution.
      (face-extra--invalidate-all-caches))))


;;;; ================================================================
;;;; Section 2 — Per-face cache (data structures; populated in Phase 3)
;;;; ================================================================

(defvar-local face-extra--local-properties nil
  "Buffer-local hash table: (face . property) → value.

Nil until first use; created lazily by `face-extra-add-relative'.
A value of 0 means \"explicitly suppressed\" — stops inheritance search.")

(defvar-local face-extra--pass3-pending nil
  "Cons `(beg . end)' of the region pass-2 processed in the current
jit-lock cycle, set by `face-extra--dispatch' and consumed by
`face-extra--dispatch-pass3'.

`font-lock-fontify-keywords-region' (where pass-2 runs via :after
advice) receives font-lock's extended region — for multiline constructs
like org-quote blocks this covers the full block.  The jit-lock
registered function (where pass-3 runs) receives only the original
smaller jit-lock chunk.  This variable bridges that gap so pass-3
always covers at least the region pass-2 processed.  Multiple calls
to `face-extra--dispatch' within one jit-lock cycle accumulate the
union of all sub-regions.")

(defvar-local face-extra--pass3-flush-timer nil
  "Buffer-local idle timer that runs a deferred full pass-3 flush.
Set by `face-extra--dispatch-pass3' when it detects active typing and
defers the full pending region to idle time.  Cancelled and rescheduled
on each keystroke so only one flush fires per typing burst.")

(defvar-local face-extra--pass3-flush-beg nil
  "Buffer position BEG for the pending pass-3 flush, or nil.")

(defvar-local face-extra--pass3-flush-end nil
  "Buffer position END for the pending pass-3 flush, or nil.")

(defvar-local face-extra--line-spans-table nil
  "Reusable hash table for the pass-3 visual-line walk.
Allocated once per buffer and cleared between walks to avoid
per-walk allocation that drives GC during active typing.")

(defvar-local face-extra--pass3-force-full nil
  "When non-nil, skip visual-line narrowing in `face-extra--dispatch-pass3'.
Consumed (reset to nil) at the start of the narrowing check so it applies
to exactly one jit-lock cycle.  Set by callers such as
`text-align--pre-command-justify' when overflow is detected and the full
logical-line walk is needed on the very next redisplay cycle.")

(defvar-local face-extra--pass3-last-flushed-beg nil
  "Buffer position BEG of the most recently completed pass-3 flush region.
Updated by `face-extra--pass3-flush-callback' after dispatch completes.
Used by `face-extra--window-scroll' to suppress re-scheduling when the
new visible region is already covered by the last flush — breaking the
feedback loop where stamping display properties changes line heights,
causing Emacs to fire `window-scroll-functions', scheduling another flush.")

(defvar-local face-extra--pass3-last-flushed-end nil
  "Buffer position END of the most recently completed pass-3 flush region.
See `face-extra--pass3-last-flushed-beg'.")

(defvar-local face-extra--vline-beg nil
  "Cached visual-line beginning position for `face-extra--pre-command'.
Set to the result of `vertical-motion' 0 on point's visual line.
Invalidated (set to nil) whenever point leaves the range
`[face-extra--vline-beg, face-extra--vline-end)'.")

(defvar-local face-extra--vline-end nil
  "Cached visual-line end position for `face-extra--pre-command'.
Set to the position after `vertical-motion' 1 from `face-extra--vline-beg'.
Recomputed together with `face-extra--vline-beg' whenever point leaves
the range [vline-beg, vline-end).")

(defvar-local face-extra--pass3-geometry-unsettled nil
  "Non-nil while the pass-3 visual-line walk is executing in this buffer.

This is a display-geometry gate, not merely a reentrancy guard.

Pass-3 calls `window-text-pixel-size' to measure line widths for
justification.  That measurement requires settled display geometry —
the same geometry the user sees on screen.  The walk achieves this by
running from an idle-timer callback, after the display engine has
finished a full render cycle.

`vertical-motion' inside the walk asks the display engine to compute
visual-line boundaries, which unsettles geometry for the duration of
each step.  If jit-lock fires during `vertical-motion' and calls
`face-extra--dispatch-pass3' again, any `window-text-pixel-size' call
in that inner invocation would measure against mid-motion geometry and
produce wrong pixel widths — causing visible over- or under-spacing.

When this flag is non-nil, geometry is unsettled: a call to
`face-extra--dispatch-pass3' defers to a flush scheduled for after the
outer walk completes, at which point geometry will be settled again.
When nil, geometry is settled and the walk may proceed.")

(defvar face-extra--typing-commands
  '(self-insert-command
    org-self-insert-command               ; Org mode's self-insert wrapper
    delete-backward-char                  ; backspace in most modes
    backward-delete-char-untabify         ; backspace with tab expansion
    org-delete-backward-char              ; backspace in Org mode
    delete-forward-char                   ; C-d / forward delete
    delete-char                           ; forward delete variant
    org-delete-char                       ; Org's forward delete
    evil-delete-backward-char-and-join    ; Evil normal/insert backspace
    evil-delete-char)                     ; Evil forward delete
  "Commands treated as active typing for passes 1–2 narrowing and
`:pre-command' dispatch.  During these commands, passes 1–2 are narrowed
to point's logical line, keeping per-keystroke cost near zero.  All other
commands — scrolling, initial render, fontified=nil re-fontification —
get full unrestricted passes.  `self-insert-command' is first so the
common case is a single pointer comparison before `memq' returns.

Extend this list to add support for other editing commands, e.g.:
  (add-to-list \\='face-extra--typing-commands \\='my-delete-command)")

(defvar face-extra--pass3-flush-delay 0.05
  "Idle delay in seconds before the deferred full-paragraph pass-3 flush runs.
During active typing, pass-3 processes only the visual line at point;
the full paragraph region is deferred until this many seconds of idle
time have elapsed.  Raise this for faster hardware where the flush feels
intrusive; lower it if justification settling on pause feels too slow.")

(defvar-local face-extra--face-cache nil
  "Buffer-local hash table: face-symbol → per-pass sorted apply lists.

Nil until first use; populated lazily by `face-extra--build-cache-entry'
during dispatch.  Each value is a plist:

  (:pass1 [(prop val apply-fn) ...]
   :pass2 [...]
   :pass3 [...])

Cache is invalidated (set to nil) on:
  - New property registered (face-extra-define-property)
  - face-remapping-alist changes (org-sty-apply)
  - face-extra--local-properties changes (face-extra-add-relative/remove)
  - Global symbol property mutation (face-extra-remove for global cookie)")

(defvar face-extra-invalidate-cache-functions nil
  "Abnormal hook run in the current buffer when the per-face cache is cleared.

Each function is called with no arguments, in the current buffer.  Use
this to clear any secondary caches (e.g. natural-space-width tables) that
derive from font metrics and therefore become stale whenever face remapping
changes — typically after `org-sty-apply', font-family change, or
`text-scale-mode'.

Register with `add-hook':
  (add-hook \\='face-extra-invalidate-cache-functions #\\='my-clear-fn)")

(defun face-extra--invalidate-cache ()
  "Clear the per-face cache for the current buffer.
Also runs `face-extra-invalidate-cache-functions' so secondary caches
that depend on font metrics (e.g. space-width tables) are cleared too."
  (setq face-extra--face-cache nil)
  (run-hooks 'face-extra-invalidate-cache-functions))

(defun face-extra--invalidate-all-caches ()
  "Clear the per-face cache in every live buffer."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq face-extra--face-cache nil)))))

(defun face-extra--invalidate-face (face)
  "Remove the cache entry for FACE in the current buffer, if any."
  (when face-extra--face-cache
    (remhash face face-extra--face-cache)))


;;;; ================================================================
;;;; Section 3 — Public install API
;;;; ================================================================

;; Cookie format:
;;   Global:       (global FACE PROPERTY OLD-VALUE)
;;   Buffer-local: (local  FACE PROPERTY BUFFER)
;;
;; Using the buffer reference in the local cookie lets `face-extra-remove'
;; operate correctly even when called from a different buffer context.

;;;###autoload
(defun face-extra-add (face property value)
  "Set synthetic PROPERTY on FACE to VALUE globally (all buffers).

Stores VALUE via `(put FACE PROPERTY VALUE)' so it is visible to
`face-extra--resolve-property' in every buffer.

Returns an opaque cookie.  Pass it to `face-extra-remove' to restore
the previous value precisely (including nil if the property was unset).

Use this for library-level defaults that should apply everywhere.
For per-document styling, use `face-extra-add-relative' instead."
  (let ((old (get face property)))
    (put face property value)
    ;; Invalidate the per-face entry in every buffer so the new global
    ;; value is picked up on the next dispatch cycle.
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (face-extra--invalidate-face face))))
    (list 'global face property old)))

;;;###autoload
(defun face-extra-add-relative (face property value)
  "Set synthetic PROPERTY on FACE to VALUE in the current buffer only.

Writes into `face-extra--local-properties' (a buffer-local hash table),
leaving the global symbol property on FACE untouched.

Returns an opaque cookie.  Pass it to `face-extra-remove' to undo the
buffer-local assignment and restore the previous local value (if any).

Use this for per-document styling (the usual case in org-sty and
variable-spacing).  Global library-level defaults should use
`face-extra-add' instead."
  (unless face-extra--local-properties
    (setq face-extra--local-properties (make-hash-table :test #'equal)))
  (let* ((key      (cons face property))
         (old      (gethash key face-extra--local-properties :face-extra-unset))
         (old-real (if (eq old :face-extra-unset) :face-extra-unset old))
         (buf      (current-buffer)))
    (puthash key value face-extra--local-properties)
    ;; Invalidate the whole cache, not just the entry for FACE.  Any face
    ;; that inherits from FACE through face-remapping-alist or face :inherit
    ;; may have cached a stale value resolved before this change was made.
    ;; Single-face invalidation (`face-extra--invalidate-face') is
    ;; insufficient when the changed face is a base like `body' whose
    ;; properties propagate transitively to dozens of inheriting faces (e.g.
    ;; `org-list-dt', all `org-level-*', etc.).  A full wipe is safe because
    ;; the cache is rebuilt lazily on next access.
    (face-extra--invalidate-cache)
    (list 'local face property old-real buf)))

;;;###autoload
(defun face-extra-remove (cookie)
  "Undo the property installation described by COOKIE.

COOKIE must be a value previously returned by `face-extra-add' or
`face-extra-add-relative'.  The function restores the prior value
(including removing the entry entirely if the property was previously
unset)."
  (pcase (car cookie)
    ('global
     (let ((face     (nth 1 cookie))
           (property (nth 2 cookie))
           (old      (nth 3 cookie)))
       (if (null old)
           (setplist face (cl-loop for (k v) on (symbol-plist face) by #'cddr
                                   unless (eq k property)
                                   append (list k v)))
         (put face property old))
       ;; Invalidate the whole cache in every buffer — removing a global
       ;; property may affect all faces that inherited it transitively.
       (dolist (buf (buffer-list))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (face-extra--invalidate-cache))))))
    ('local
     (let ((face     (nth 1 cookie))
           (property (nth 2 cookie))
           (old      (nth 3 cookie))
           (buf      (nth 4 cookie)))
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (let ((key (cons face property)))
             (if (eq old :face-extra-unset)
                 (remhash key face-extra--local-properties)
               (puthash key old face-extra--local-properties)))
           ;; Full cache wipe for the same reason as face-extra-add-relative:
           ;; inherited faces cached before this removal are now stale.
           (face-extra--invalidate-cache)))))
    (_
     (error "face-extra-remove: unrecognised cookie format: %S" cookie))))


;;;; ================================================================
;;;; Section 4 — (Pass-0 registration is handled via
;;;;              face-extra-define-property :pass 0 in Section 1)
;;;; ================================================================


;;;; ================================================================
;;;; Section 4c — Body-backend registry
;;;; ================================================================
;;
;; `face-extra--body-backend-alist' maps major-mode → body-backend plist.
;; A body-backend plist supplies three keys:
;;
;;   :content-faces   List of faces that receive (:inherit body) remaps.
;;   :metadata-faces  List of faces that receive (:inherit default) anchors.
;;   :stamp-body-text A function (beg end) for pass-0 body stamping.
;;
;; `body-face-mode' reads all three when it enables, then registers
;; the :stamp-body-text via `face-extra-define-property' with :pass 0.

(defvar face-extra--body-backend-alist nil
  "Alist mapping major-mode symbol → body-backend plist.

Each body-backend plist must supply:
  :content-faces   Faces that receive `(:inherit body)' remaps on enable.
  :metadata-faces  Faces that receive `(:inherit default)' anchors on enable.
  :stamp-body-text A function (beg end) for pass-0 body stamping.

Register via `face-extra-register-body-backend'.")

(defun face-extra-register-body-backend (major-mode-sym plist)
  "Register PLIST as the body-face backend for MAJOR-MODE-SYM.

PLIST must contain :content-faces, :metadata-faces, and :stamp-body-text.
Called at load time (or by user config) before `body-face-mode' is enabled.
`body-face-mode' reads the plist when it enables in a buffer of MAJOR-MODE-SYM."
  (unless (plist-get plist :stamp-body-text)
    (error "face-extra-register-body-backend: `%s' backend lacks :stamp-body-text"
           major-mode-sym))
  (unless (plist-get plist :content-faces)
    (error "face-extra-register-body-backend: `%s' backend lacks :content-faces"
           major-mode-sym))
  (unless (plist-get plist :metadata-faces)
    (error "face-extra-register-body-backend: `%s' backend lacks :metadata-faces"
           major-mode-sym))
  (setf (alist-get major-mode-sym face-extra--body-backend-alist) plist))

(defun face-extra-deregister-body-backend (major-mode-sym)
  "Remove the body-face backend registered for MAJOR-MODE-SYM."
  (setf (alist-get major-mode-sym face-extra--body-backend-alist
                   nil 'remove)
        nil))

(defun face-extra--active-body-backend ()
  "Return the body-backend plist for the current buffer's major mode, or nil."
  (alist-get major-mode face-extra--body-backend-alist))


;;;; ================================================================
;;;; Section 4b — Body face: Org backend and face hierarchy
;;;; ================================================================
;;
;; The `body' face is a semantic identity face meaning "this character
;; is prose body text."  It lives in face-extra (not variable-spacing)
;; because it is a face/rendering concept consumed by multiple property
;; packages: variable-spacing, horizontal-layout, text-align.  None of
;; those packages own it.
;;
;; The Org backend (`face-extra-org-body-backend') is the reference
;; implementation of the backend protocol.  Phase 3 will introduce
;; `body-face-mode' to manage the backend lifecycle and make the
;; defface attrs neutral; for now `defface body' retains :height 2.0
;; so rendering is not broken before body-face-mode exists.
;;
;; `face-extra--install-body-remaps' and `face-extra--remove-body-remaps'
;; manage the (:inherit body) remaps on content faces and the
;; (:inherit default) anchors on metadata faces.  They are called by
;; `variable-spacing-mode' on enable/disable; the floor remap on
;; `default' (a spacing concern) stays in `variable-spacing.el'.

(defgroup face-extra nil
  "Generic synthetic face properties and body-face infrastructure."
  :group 'faces)

(defface body
  '((t :inherit default :height 2.0))
  "Semantic identity face for prose body text.

Any character that is prose body text — as opposed to structural or
metadata text — should carry this face.  Property packages
\(`variable-spacing-mode', `horizontal-layout-mode', `text-align-mode')
target `body' spans to apply spacing ratios, margins, and alignment.

The `:height 2.0' multiplier is relative to `default'.  When
`variable-spacing-mode' is active it remaps `default' to a small floor
height (`variable-spacing-floor-height'), so body text renders at
2.0 × floor — the same visible size without the floor being
accidentally applied to body content.

TODO Phase 3: change attrs to \\='((t :inherit default)) once
`body-face-mode' supplies the body:floor ratio via a buffer-local
remap on enable."
  :group 'face-extra)

(defcustom face-extra-org-content-faces
  '(;; Heading faces — sized at body scale.
    org-level-1 org-level-2 org-level-3 org-level-4
    org-level-5 org-level-6 org-level-7 org-level-8
    ;; org-document-title is the rendered title VALUE — content.
    org-document-title
    ;; Block-content faces.  Block delimiter lines (#+begin_/#+end_)
    ;; are metadata and belong in `face-extra-org-metadata-faces'.
    org-block org-table org-formula org-list-dt org-quote org-verse)
  "Document-content faces that track body-text size in Org WP buffers.

Each face in this list receives a buffer-local `(:inherit body)' remap
when `body-face-mode' (or `variable-spacing-mode' as a temporary
proxy) is enabled, lifting it above the floor height on `default'.

Inline faces (bold, italic, org-code, org-link, org-cite, org-footnote,
etc.) are intentionally absent: they can appear alongside a structural
face in a list (e.g. `(italic org-level-2)') and a remap would cause
body height to dominate incorrectly.  The pass-0 stamp handles them by
marking bare-text runs with `body' directly.

Can be set buffer-locally for per-document customisation."
  :type '(repeat face)
  :group 'face-extra)

(defcustom face-extra-org-metadata-faces
  '(;; Heading stars.
    org-hide
    ;; Drawer structure.
    org-drawer org-special-keyword org-property-value
    ;; Internal gap face — whitespace in property lines left unstyled.
    variable-spacing--default
    ;; Block delimiter lines (#+begin_X / #+end_X).
    org-block-begin-line org-block-end-line
    ;; File-level keyword lines.
    org-meta-line org-keyword
    org-document-info-keyword org-document-info)
  "Metadata faces exempt from `body' stamping in Org WP buffers.

Faces in this list do NOT receive a `(:inherit body)' remap and are
excluded from the pass-0 body stamp, so they inherit floor size from
the `default' remap regardless of whether they arrive as `font-lock-face'
or `face' text properties.

Can be set buffer-locally for per-document customisation."
  :type '(repeat face)
  :group 'face-extra)

(defun face-extra--org-explicit-face-p (face)
  "Return non-nil if FACE contains at least one Org content or metadata face.
FACE may be a symbol, an anonymous attribute plist `(:strike-through t)',
or a list thereof.

A face is explicit if it appears in `face-extra-org-content-faces' or
`face-extra-org-metadata-faces'.  Anonymous plists are never explicit.

The pass-0 stamp stamps `body' on characters where this returns nil and
no `font-lock-face' is present — the blacklist design means arbitrary
faces not in either list are treated as non-explicit and do not block
the stamp."
  (cond
   ((null face) nil)
   ((and (consp face) (keywordp (car face))) nil)
   ((symbolp face)
    (or (memq face face-extra-org-content-faces)
        (memq face face-extra-org-metadata-faces)))
   ((listp face)
    (cl-some (lambda (f)
               (and (symbolp f)
                    (or (memq f face-extra-org-content-faces)
                        (memq f face-extra-org-metadata-faces))))
             face))
   (t nil)))

(defun face-extra--add-body-face (beg end)
  "Add `body' as a low-priority `face' property over BEG..END.
Uses `add-face-text-property' with APPEND=t so that any face already
present remains as the higher-priority entry."
  (add-face-text-property beg end 'body t))

;;;###autoload
(defun face-extra-remove-body-face (beg end)
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

(defun face-extra--org-stamp-body-text (beg end)
  "Stamp `body' on characters in BEG..END that Org left unstyled.

Called during pass 0 of each dispatch cycle (before pass-1 property
apply functions run) for `org-mode' buffers.

After Org's full keyword list runs for a jit-lock chunk, characters fall
into two categories:

  Styled   — Org set a `face' or `font-lock-face' text property.
  Unstyled — neither property is set (plain paragraph text Org leaves bare).

This function stamps `body' on unstyled characters so they render at
body-text size rather than falling through to the floor height of
`default'.

A \\='\\n' in the middle of a body-context span is stamped `body' along
with the rest of that span.  A \\='\\n' that opens a body-context span is
stamped with the preceding character's face so it renders at the height
of the line it terminates.  Blank lines (\\n preceded by \\n) are stamped
`body'.  Stale stamps from a previous cycle are cleared first."
  ;; Mode guard enforced by dispatcher via :mode 'body-face-mode.
  (with-silent-modifications
      (face-extra-remove-body-face beg end)
      (let ((pos beg))
        (while (< pos end)
          (let* ((next-face    (next-single-property-change pos 'face nil end))
                 (next-fl-face (next-single-property-change
                                pos 'font-lock-face nil end))
                 (next         (min (or next-face end) (or next-fl-face end))))
            (when (and (null (get-text-property pos 'font-lock-face))
                       (not (face-extra--org-explicit-face-p
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

(defvar face-extra-org-body-backend
  (list :content-faces  face-extra-org-content-faces
        :metadata-faces face-extra-org-metadata-faces
        :stamp-body-text #'face-extra--org-stamp-body-text)
  "Body-face backend plist for `org-mode'.

Supplies all three keys required by the body-backend protocol:
  :content-faces   Faces that receive `(:inherit body)' remaps (see
                   `face-extra-org-content-faces').
  :metadata-faces  Faces anchored to floor size via `(:inherit default)'
                   (see `face-extra-org-metadata-faces').
  :stamp-body-text `face-extra--org-stamp-body-text' — the pass-0
                   bare-text stamper for Org buffers.

This is the reference implementation of the body-backend protocol.
Other major modes can define their own plist and register it via
`face-extra-register-body-backend'.")

(defun face-extra--install-body-remaps (content-faces metadata-faces)
  "Install body-hierarchy face remaps for CONTENT-FACES and METADATA-FACES.

For each face in CONTENT-FACES installs a buffer-local
`(:inherit body)' remap so it tracks body-text size.  For each face in
METADATA-FACES installs a `(:inherit default)' remap to anchor it at
floor size even when it globally inherits from a content face.

Returns the list of remap cookies.  Pass the returned list to
`face-extra--remove-body-remaps' to undo."
  (let (cookies)
    (dolist (face content-faces)
      (push (face-remap-add-relative face :inherit 'body) cookies))
    (dolist (face metadata-faces)
      (push (face-remap-add-relative face :inherit 'default) cookies))
    cookies))

(defun face-extra--remove-body-remaps (cookies)
  "Remove face remaps installed by `face-extra--install-body-remaps'.
COOKIES is the list returned by that function."
  (dolist (cookie cookies)
    (face-remap-remove-relative cookie)))

(defvar-local body-face--remap-cookies nil
  "List of remap cookies installed by `body-face-mode'.
Populated on enable; cleared on disable.")

;;;###autoload
(define-minor-mode body-face-mode
  "Minor mode that installs the body-face hierarchy for the current buffer.

On enable, looks up the body-backend registered for the current
`major-mode' via `face-extra-register-body-backend', then:
  1. Installs `(:inherit body)' remaps on the backend's :content-faces.
  2. Installs `(:inherit default)' anchors on the backend's :metadata-faces.
  3. Calls `face-extra-mode-require' to activate face-extra dispatch in
     this buffer.
  4. Flushes font-lock so the new remaps take effect immediately.

On disable, reverses all of the above.

Property modes (`variable-spacing-mode', `horizontal-layout-mode', etc.)
enable this mode as a dependency; users rarely need to toggle it directly."
  :lighter nil
  (if body-face-mode
      (let ((backend (face-extra--active-body-backend)))
        (unless backend
          (setq body-face-mode nil)
          (error "body-face-mode: no body-backend registered for `%s'" major-mode))
        (setq body-face--remap-cookies
              (face-extra--install-body-remaps
               (plist-get backend :content-faces)
               (plist-get backend :metadata-faces)))
        (face-extra-mode-require)
        (font-lock-flush))
    (face-extra--remove-body-remaps body-face--remap-cookies)
    (setq body-face--remap-cookies nil)
    (face-extra-mode-release)
    (face-extra-remove-body-face (point-min) (point-max))
    (font-lock-flush)))

;; Register the Org reference body-backend at load time.
;; `body-face-mode' reads this when first enabled in an org-mode buffer.
(face-extra-register-body-backend 'org-mode face-extra-org-body-backend)

;; Register the pass-0 body-stamp property at load time.
;; `body-face-mode' controls whether it runs (the apply function guards
;; on `(bound-and-true-p body-face-mode)').
(face-extra-define-property 'body-stamp
  :pass 0
  :mode 'body-face-mode
  :apply #'face-extra--org-stamp-body-text)


;;;; ================================================================
;;;; Section 5 — Per-face cache resolver and dispatch
;;;; ================================================================


;;;; ================================================================

;;;; ------ Cache resolver ------

(defun face-extra--resolve-property (face property)
  "Resolve the effective value of synthetic PROPERTY for FACE.

Resolution order:
  1. Buffer-local `face-extra--local-properties' table.
  2. Global symbol property via `(get face property)'.
  3. `:inherit' entries in `face-remapping-alist' for FACE (buffer-local
     remap chain; each entry's :inherit attr is followed recursively).
  4. Global face `:inherit' attribute(s).

A value of 0 at any level means \"explicitly suppressed\" and stops
the search immediately, returning nil.  Returns nil if the property is
not found at any level.

Cycle guard: the VISITED argument (an eq-hash-set) prevents
infinite loops in inheritance graphs that contain cycles."
  (face-extra--resolve-property-1 face property (make-hash-table :test #'eq)))

(defun face-extra--resolve-property-1 (face property visited)
  "Inner recursive resolver for `face-extra--resolve-property'.
VISITED is a hash table of already-examined face symbols."
  (when (gethash face visited)
    (cl-return-from face-extra--resolve-property-1 nil))
  (puthash face t visited)
  (cl-block face-extra--resolve-property-1
    ;; Level 1: buffer-local table.
    (when face-extra--local-properties
      (let* ((key (cons face property))
             (local-val (gethash key face-extra--local-properties
                                 :face-extra-unset)))
        (unless (eq local-val :face-extra-unset)
          (cl-return-from face-extra--resolve-property-1
            (and (not (eql local-val 0)) local-val)))))
    ;; Level 2: global symbol property.
    (let ((global-val (get face property)))
      (when global-val
        (cl-return-from face-extra--resolve-property-1
          (and (not (eql global-val 0)) global-val))))
    ;; Level 3: face-remapping-alist :inherit chain (buffer-local remaps).
    ;; Each element of face-remapping-alist for FACE is either a full spec
    ;; plist or a face symbol.  We look for :inherit entries among them.
    (let ((remap-entries (cdr (assq face face-remapping-alist))))
      (dolist (spec remap-entries)
        (let ((inherits
               (cond
                ((symbolp spec)
                 ;; A bare face symbol in the remap list — treat as :inherit.
                 (list spec))
                ((and (consp spec) (keywordp (car spec)))
                 ;; A plist: extract the :inherit value.
                 (let ((inh (plist-get spec :inherit)))
                   (when inh
                     (if (symbolp inh) (list inh) inh))))
                (t nil))))
          (dolist (iface (cl-remove-if-not #'symbolp inherits))
            (let ((val (face-extra--resolve-property-1 iface property visited)))
              (when val
                (cl-return-from face-extra--resolve-property-1 val)))))))
    ;; Level 4: global face :inherit attribute.
    ;; Guard with facep: in batch mode or early init, unknown faces would
    ;; signal "Invalid face" from face-attribute.
    (let ((global-inherit (and (facep face) (face-attribute face :inherit t))))
      (when (and global-inherit (not (eq global-inherit 'unspecified)))
        (let ((ifaces (if (symbolp global-inherit)
                          (list global-inherit)
                        (cl-remove-if-not #'symbolp global-inherit))))
          (dolist (iface ifaces)
            (let ((val (face-extra--resolve-property-1 iface property visited)))
              (when val
                (cl-return-from face-extra--resolve-property-1 val)))))))
    nil))

(defun face-extra--build-cache-entry (face)
  "Build and cache the pass-dispatch entry for FACE in the current buffer.

Iterates all registered properties, resolves each via
`face-extra--resolve-property', and accumulates per-pass lists of
  (property value apply-fn)
triples, pre-sorted according to `face-extra--pass-order'.

Returns the entry plist, which is also stored in `face-extra--face-cache'."
  (unless face-extra--face-cache
    (setq face-extra--face-cache (make-hash-table :test #'eq)))
  (let ((pass1 nil) (pass2 nil) (pass3 nil))
    ;; Iterate in pass-order to get pre-sorted lists directly.
    (dolist (pass-num '(1 2 3))
      (dolist (prop (gethash pass-num face-extra--pass-order))
        (let ((val (face-extra--resolve-property face prop)))
          (when val
            (let* ((entry    (gethash (cons prop pass-num) face-extra--registry))
                   (apply-fn (plist-get entry :apply))
                   (triple   (list prop val apply-fn)))
              (pcase pass-num
                (1 (push triple pass1))
                (2 (push triple pass2))
                (3 (push triple pass3))))))))
    (let ((cache-entry (list :pass1 (nreverse pass1)
                             :pass2 (nreverse pass2)
                             :pass3 (nreverse pass3))))
      (puthash face cache-entry face-extra--face-cache)
      cache-entry)))

(defun face-extra--get-cache-entry (face)
  "Return the cached dispatch entry for FACE, building it if absent."
  (or (and face-extra--face-cache
           (gethash face face-extra--face-cache))
      (face-extra--build-cache-entry face)))

;;;; ------ Dispatch ------

(defun face-extra--collect-spans (beg end)
  "Scan BEG..END and return a hash table of per-property span lists.

Returns a hash table mapping property-symbol → list of (beg end value)
triples.  Only properties that appear at least once in the region are
present in the table.

Scans by face-boundary steps (minimum of `face' and `font-lock-face'
change points), looks up each leading face in the cache, and collects
triples for any properties found.

Suppressor-wins semantics: if ANY face in the face list at a position
has an explicit local suppressor (value 0 in
`face-extra--local-properties') for a property, that property is NOT
collected from any face at that position.  This prevents a stale
`body' stamp alongside a suppressed face (e.g. `org-quote') from
leaking the `body' ratio through."
  (let ((spans (make-hash-table :test #'eq))
        (pos beg))
    (while (< pos end)
      (let* ((next-face    (next-single-property-change pos 'face nil end))
             (next-fl-face (next-single-property-change pos 'font-lock-face nil end))
             (next         (min (or next-face end) (or next-fl-face end)))
             ;; Use font-lock-face preferentially (set by Org regexp keywords);
             ;; fall back to face (set by Org anchor functions).
             (f            (or (get-text-property pos 'font-lock-face)
                               (get-text-property pos 'face))))
        ;; For lists of faces use all symbols; for single-face spans wrap.
        (let ((faces (cond
                      ((null f)      nil)
                      ((symbolp f)   (list f))
                      ((and (consp f) (keywordp (car f))) nil) ; anon plist
                      ((listp f)     (cl-remove-if-not #'symbolp f))
                      (t             nil))))
          (when faces
            ;; Build a set of properties explicitly suppressed (value = 0 in
            ;; local-properties) by ANY face in the list at this position.
            ;; A suppressor on one face cancels contributions from all others.
            (let ((suppressed
                   (when face-extra--local-properties
                     (let (supp)
                       (dolist (face faces)
                         (maphash
                          (lambda (key val)
                            (when (and (eq (car key) face) (eql val 0))
                              (cl-pushnew (cdr key) supp)))
                          face-extra--local-properties))
                       supp))))
              (dolist (face faces)
                (let ((entry (face-extra--get-cache-entry face)))
                  (dolist (pass-key '(:pass1 :pass2))
                    (dolist (triple (plist-get entry pass-key))
                      (let ((prop (nth 0 triple))
                            (val  (nth 1 triple)))
                        (unless (memq prop suppressed)
                          (push (list pos next val)
                                (gethash prop spans)))))))))))
        (setq pos next)))
    spans))

(defun face-extra--run-pass (pass-num spans-table)
  "Run all registered properties for PASS-NUM using SPANS-TABLE.

For each property in `face-extra--pass-order' for PASS-NUM, calls its
:apply function with the full list of (beg end value) triples collected
for that property.  Properties not present in SPANS-TABLE are skipped
with zero overhead."
  (dolist (prop (gethash pass-num face-extra--pass-order))
    (let ((spans (gethash prop spans-table)))
      (when spans
        (let* ((entry    (gethash (cons prop pass-num) face-extra--registry))
               (mode     (plist-get entry :mode))
               (apply-fn (plist-get entry :apply)))
          (when (and mode (symbol-value mode))
            (funcall apply-fn (nreverse spans))))))))

(defun face-extra--dispatch (beg end &optional _loudly)
  "After-fontify dispatch: stamp body text and run pass-1/2/3 properties.

Advises `font-lock-fontify-keywords-region' with :after.  Active while
`face-extra-mode' is on (i.e. while the registry is non-empty).

Steps:
  1. Call every registered pass-0 :apply function with (beg end).
  2. Scan BEG..END once, building per-property span lists.
  3. Run pass-1, pass-2, pass-3 properties in order."
  ;; Run pass-0 and passes 1-2 when dispatch is active (face-extra-mode is on
  ;; iff the registry is non-empty, i.e. some mode has defined properties).
  (when face-extra-mode
    ;; Pass 0: call every registered pass-0 :apply function with (beg end),
    ;; guarded by the property's :mode so it only runs in buffers where the
    ;; owning mode is active.
    (maphash (lambda (key entry)
               (let ((mode (plist-get entry :mode)))
                 (when (and (consp key) (= (cdr key) 0)
                            mode (symbol-value mode))
                   (funcall (plist-get entry :apply) beg end))))
             face-extra--registry)
      ;; Always accumulate the FULL region for pass-3 before any narrowing,
      ;; so the pass-3 flush covers everything font-lock dirtied.
      (setq face-extra--pass3-pending
            (if face-extra--pass3-pending
                (cons (min beg (car face-extra--pass3-pending))
                      (max end (cdr face-extra--pass3-pending)))
              (cons beg end)))
      ;; Passes 1–2: scan once, then dispatch.
      ;; Pass 3 runs separately via jit-lock-register (face-extra--dispatch-pass3)
      ;; after the display engine has settled, so vertical-motion is safe there.
      ;;
      ;; During active typing, narrow beg/end to point's visual line before
      ;; running passes 1–2.  Stamps on other lines are already correct for
      ;; their unchanged content and faces, so re-running them is pure waste.
      ;; Adjacent blocks (e.g. a quote block right after the paragraph) are
      ;; swept into the jit-lock region by Org's font-lock-extend-region-functions
      ;; and would otherwise trigger expensive margin + text-align work on every
      ;; keystroke.  The full region is handled by the pass-3 flush on idle.
      (let ((passes-beg beg)
            (passes-end end))
        ;; Narrow to point's logical line only during rapid character entry.
        ;; Non-typing events (initial load, scroll, fontified=nil
        ;; re-fontification from org-cite-appear) get the full region so
        ;; passes 1–2 always run on freshly-dirtied chunks.
        (when (and (null (current-idle-time))
                   (memq this-command face-extra--typing-commands))
          (let ((pt (point)))
            (if (and (>= pt beg) (< pt end))
                ;; Narrow to point's logical line (line-beginning-position /
                ;; line-end-position).  This covers all visual wraps of the
                ;; same logical line, so when word-wrap pushes a character
                ;; onto a new visual line, that character — still part of the
                ;; same logical line — receives pass-1/2 stamps.  Narrowing to
                ;; the visual line (via vertical-motion) left new wrap
                ;; characters unstamped, causing missing variable-spacing
                ;; heights on newly created visual lines.
                ;;
                ;; Adjacent blocks (quote, verse, etc.) are separate logical
                ;; lines and remain excluded.  Pass-1/2 work in face-span
                ;; steps with O(1) put-text-property per span, so a long
                ;; logical line is still fast — no vertical-motion, no
                ;; window-text-pixel-size.
                (save-excursion
                  (goto-char pt)
                  (setq passes-beg (line-beginning-position)
                        passes-end (line-end-position)))
              ;; Point outside region: skip passes 1–2 entirely.
              (setq passes-beg passes-end))))
        (unless (= passes-beg passes-end)
          (let ((spans-table (face-extra--collect-spans passes-beg passes-end)))
            (face-extra--run-pass 1 spans-table)
            (face-extra--run-pass 2 spans-table))))))

;;;; ------ Advice wiring ------

(defun face-extra--after-ensure (&rest _)
  "Run pass-3 on the visible window after `font-lock-ensure'.

`font-lock-update' calls `font-lock-ensure' which drives
`font-lock-fontify-region' directly, bypassing jit-lock entirely.
Pass-2 runs (via the :after advice on `font-lock-fontify-keywords-region')
but `jit-lock-register' functions never fire, so pass-3 is skipped.

This advice closes that gap: after `font-lock-ensure' finishes (outside
jit-lock, so `vertical-motion' is safe), pass-3 is run on the currently
visible window region.  Off-screen content is corrected lazily when the
user scrolls and jit-lock processes it normally."
  (when (and face-extra-mode
             (gethash 3 face-extra--pass-order))
    (let ((win (get-buffer-window (current-buffer) t)))
      (when win
        (face-extra--schedule-pass3-flush
         (current-buffer)
         (window-start win)
         (window-end win t))))))

(defun face-extra--window-scroll (win _new-start)
  "Schedule a pass-3 flush when window WIN scrolls.
Added to `window-scroll-functions' so that unjustified-but-fontified
content (paragraphs with no citations that jit-lock never re-dirtied)
gets stamped when scrolled into view."
  (let ((buf (window-buffer win)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and face-extra-mode
                   (gethash 3 face-extra--pass-order))
          (let ((wstart (window-start win))
                (wend   (window-end win t)))
            ;; Only schedule if the new visible region is not already covered
            ;; by the last completed flush.  Display-property stamping changes
            ;; line heights, causing Emacs to fire `window-scroll-functions'
            ;; even when the user hasn't scrolled; without this guard that
            ;; produces a flush → scroll-event → flush → … feedback loop.
            ;; 20-char slack absorbs `window-end' jitter (~a word) from line
            ;; height changes near the bottom of the screen.
            (unless (and face-extra--pass3-last-flushed-beg
                         face-extra--pass3-last-flushed-end
                         (>= wstart face-extra--pass3-last-flushed-beg)
                         (<= wend   (+ face-extra--pass3-last-flushed-end 20)))
              (face-extra--schedule-pass3-flush buf wstart wend))))))))

(defun face-extra--enable-dispatch ()
  "Register pass-3 jit-lock dispatch in the current buffer.
Called by `face-extra-mode' enable body.  Also registers advice and
global hooks if not already installed (idempotent — `advice-add' and
`add-hook' are both idempotent).

The global dispatch advice (`face-extra--dispatch') is installed at load
time, so this function only needs to handle the per-buffer pass-3
registration."
  (when (gethash 3 face-extra--pass-order)
    (face-extra--enable-dispatch-pass3)))

(defun face-extra--disable-dispatch ()
  "Unregister pass-3 jit-lock dispatch from the current buffer.
Called by `face-extra-mode' disable body.  Global advice and hooks
installed at load time are intentionally left in place — removing them
here would break any other buffer that still has `face-extra-mode'
active."
  (face-extra--disable-dispatch-pass3))

;;;; ------ Pass-3 jit-lock dispatch ------

(defun face-extra--expand-to-lines (beg end)
  "Expand BEG..END to logical-line boundaries within already-fontified text.

Extends BEG backward to `line-beginning-position' and END forward to
`line-end-position', but only if the gap region is entirely fontified.
Drops partial lines at unfontified boundaries — they will be processed
when their own jit-lock chunk fires.

Returns a (BEG . END) cons, or nil if the region is empty after clipping."
  (let* ((lbeg (save-excursion (goto-char beg) (line-beginning-position)))
         (lend (save-excursion (goto-char end) (line-end-position))))
    ;; Extend backward only if [lbeg, beg) is entirely fontified.
    (when (and (< lbeg beg)
               (not (text-property-any lbeg beg 'fontified nil)))
      (setq beg lbeg))
    ;; Extend forward only if [end, lend) is entirely fontified.
    (when (and (> lend end)
               (not (text-property-any end lend 'fontified nil)))
      (setq end lend))
    (when (< beg end)
      (cons beg end))))

(defun face-extra--pass3-flush-callback (buf)
  "Idle timer callback: run the deferred pass-3 flush for BUF.
Reads the pending region from buffer-local `face-extra--pass3-flush-beg'
and `face-extra--pass3-flush-end'.  Using a named function avoids
allocating a new closure on every keystroke.

If BUF is not currently visible in the selected frame (e.g. the user
has switched focus to another frame), the flush is deferred: the
pending region is left intact and the timer cleared so no CPU is spent
on `vertical-motion' and `window-text-pixel-size' calls for a buffer
the user is not looking at.  `face-extra--window-selected' reschedules
the flush when the buffer's frame regains focus.

Existing justify/alignment stamps are intentionally preserved in this
case — the `:pre-clear' in `face-extra--dispatch-pass3' would strip
them before re-applying, so leaving the function early without calling
dispatch keeps the buffer correctly stamped until focus returns."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq face-extra--pass3-flush-timer nil)
      (when (and face-extra--pass3-flush-beg face-extra--pass3-flush-end)
        (if (not (get-buffer-window buf))
            ;; Buffer not visible in the selected frame.  Leave the pending
            ;; beg/end in place so `face-extra--window-selected' can
            ;; reschedule the flush when focus returns.  Do NOT call
            ;; `face-extra--dispatch-pass3': that would run `:pre-clear'
            ;; (stripping justify stamps) and then fail to re-apply them
            ;; because `window-text-pixel-size' needs a live window.
            nil
          ;; Buffer is visible: run the flush normally.
          ;; Refine the accumulated region to paragraph boundaries here,
          ;; at idle time, rather than on every keystroke.  This clips the
          ;; region at Org structural boundaries (headings, #+, [fn:) so
          ;; the walk never bleeds into adjacent structural elements —
          ;; without paying the regex cost on the hot keystroke path.
          (let* ((raw-b face-extra--pass3-flush-beg)
                 (raw-e face-extra--pass3-flush-end)
                 (para  (face-extra--paragraph-bounds raw-b raw-e))
                 (b     (car para))
                 (e     (cdr para)))
            (setq face-extra--pass3-flush-beg nil
                  face-extra--pass3-flush-end nil)
            (face-extra--dispatch-pass3 b e)
            ;; Record the flushed region so `face-extra--window-scroll'
            ;; can suppress re-scheduling for the same on-screen region.
            (setq face-extra--pass3-last-flushed-beg b
                  face-extra--pass3-last-flushed-end e)))))))

(defun face-extra--window-selected (frame)
  "Reschedule any pending pass-3 flush when a buffer gains focus.
Added to `window-selection-change-functions' by `face-extra--enable-dispatch'.

Fires whenever the selected window changes — including when an Emacs
frame gains OS focus.  If the newly-selected buffer has a pending
flush region that was deferred by `face-extra--pass3-flush-callback'
(because the buffer was not visible in the selected frame at the time),
this schedules a new idle timer to run it now that the buffer is focused.

FRAME is the frame whose selected window changed (passed by Emacs)."
  (let* ((win (frame-selected-window frame))
         (buf (window-buffer win)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and face-extra--pass3-flush-beg
                   face-extra--pass3-flush-end
                   (not face-extra--pass3-flush-timer))
          (setq face-extra--pass3-flush-timer
                (run-with-idle-timer face-extra--pass3-flush-delay nil
                                     #'face-extra--pass3-flush-callback buf)))))))

(defun face-extra--schedule-pass3-flush (buf beg end)
  "Accumulate BEG..END into the pending pass-3 flush region for BUF.
Only creates a new idle timer if none is already running.  This means
rapid bursts of fontified=nil marks (e.g. from org-cite-appear
formatting citations one by one) do not keep resetting the delay clock;
the flush fires `face-extra--pass3-flush-delay' seconds after the
FIRST event in the burst, covering the union of all regions dirtied
during that burst."
  (with-current-buffer buf
    (setq face-extra--pass3-flush-beg
          (if face-extra--pass3-flush-beg
              (min beg face-extra--pass3-flush-beg)
            beg))
    (setq face-extra--pass3-flush-end
          (if face-extra--pass3-flush-end
              (max end face-extra--pass3-flush-end)
            end))
    ;; Do not create a new timer while a pass-3 walk is already in progress
    ;; (geometry-unsettled = t).  The walk was triggered by a flush; creating
    ;; another timer here would cause it to fire immediately once the current
    ;; flush callback returns (Emacs is already past the idle threshold), and
    ;; the flush would reschedule itself on every jit-lock or font-lock call
    ;; that happens inside the walk (e.g. from vertical-motion), producing a
    ;; 100% CPU busy loop.  The beg/end accumulation above is still done so
    ;; that if a timer already exists it will cover the full union; but the
    ;; walk itself will process the region correctly before returning.
    (unless (or face-extra--pass3-flush-timer
                face-extra--pass3-geometry-unsettled)
      (setq face-extra--pass3-flush-timer
            (run-with-idle-timer face-extra--pass3-flush-delay nil
                                 #'face-extra--pass3-flush-callback buf)))))

(defun face-extra--paragraph-bounds (beg end)
  "Return a (BEG . END) cons expanded to paragraph boundaries.

A paragraph boundary is a blank line (a line containing only whitespace),
an Org keyword line (#+begin_…, #+end_…, or any #+KEYWORD:), a footnote
definition label (\\[fn:… at column 0), a heading (one or more leading
stars followed by a space), or the buffer start/end.

Using only blank lines as boundaries caused the flush region to absorb
adjacent Org structural elements (quote blocks, footnote definitions) when
there is no blank line separating them from the body paragraph.  Pass-3
would then walk over those elements and leak justify/spacing stamps onto
faces (e.g. `org-quote') that carry explicit suppressors — suppressors that
only fire when the face appears in the same span as the body text, not when
the body text's flush region is simply expanded to include unrelated lines.

Expansion is done with `re-search-backward'/`re-search-forward' and
`case-fold-search' t (to match both #+BEGIN_ and #+begin_) — no
`vertical-motion' calls, so safe to call during active editing.

The returned BEG is the start of the first line of the paragraph that
contains the original BEG; the returned END is the end of the last line
of the paragraph that contains the original END."
  (let ((boundary-re
         (rx bol
             (or (seq (* (any " \t")) eol)   ; blank line
                 (seq (* (any " \t")) "#+" ) ; any Org keyword (begin_, end_, etc.)
                 "[fn:"                       ; footnote definition label
                 (seq (+ "*") " ")))))        ; heading (one or more stars + space)
    (cons (save-excursion
            (goto-char beg)
            (let ((case-fold-search t))
              (if (re-search-backward boundary-re (point-min) t)
                  ;; Found a boundary — the paragraph starts on the next line.
                  (line-beginning-position 2)
                (point-min))))
          (save-excursion
            (goto-char end)
            (let ((case-fold-search t))
              (if (re-search-forward boundary-re (point-max) t)
                  ;; Found a boundary — the paragraph ends just before it.
                  (match-beginning 0)
                (point-max)))))))

(defun face-extra--dispatch-pass3 (beg end)
  "jit-lock-register pass-3 dispatch: one visual-line walk, not spanwise.

Registered via `face-extra--enable-dispatch-pass3'; fires after
`face-extra--dispatch' (passes 1 and 2) has stamped line-prefix/
wrap-prefix spacers and margins.

Pass 3 is fundamentally linewise, not spanwise.  A typical visible
window produces O(face_boundaries) spans from `face-extra--collect-spans'
— potentially hundreds per screen on cite-heavy documents — but only
O(visual_lines) lines need to be processed.  Using `collect-spans' then
iterating spans with `vertical-motion' per span would be O(spans) walks;
this function does one O(lines) walk and resolves properties at the BOL
of each visual line via the face cache.

The per-pass-3-property span lists passed to `:apply' functions contain
one (lbeg lend value) triple per visual line where the property is active.
Apply functions must not call `vertical-motion' themselves.

`vertical-motion' is safe here because jit-lock-register functions fire
after the display engine has settled for the chunk.  It would deadlock
inside the :after advice where `face-extra--dispatch' (passes 1-2) runs."
  ;; Geometry-settled gate.  Pass-3 calls `window-text-pixel-size', which
  ;; requires settled display geometry.  `vertical-motion' inside the walk
  ;; unsettles geometry; any call that arrives while the walk is running
  ;; (face-extra--pass3-geometry-unsettled = t) must NOT run the walk — it
  ;; would measure wrong widths.  Schedule a flush instead so the region
  ;; is processed after the outer walk finishes and geometry settles again.
  (if face-extra--pass3-geometry-unsettled
      (face-extra--schedule-pass3-flush (current-buffer) beg end)
    (when (and face-extra-mode
               (gethash 3 face-extra--pass-order))
      (let ((face-extra--pass3-geometry-unsettled t)
            (pass3-narrowed nil))
    ;; Expand beg/end by any region pass-2 covered in this jit-lock cycle.
    ;; Pass-2's :after advice receives font-lock's extended region (e.g.
    ;; the full org-quote block); jit-lock only passes us the smaller
    ;; original chunk.  Without this, the tail of a multi-line block never
    ;; gets pass-3 treatment because font-lock already marked it fontified.
    ;;
    ;; Debounce: during active typing, defer pass 3 to idle so that
    ;; `vertical-motion' and `window-text-pixel-size' see settled geometry.
    ;; For non-typing events (scroll, window-focus change, initial fontify)
    ;; pass 3 runs immediately — no feedback loop risk when the buffer is
    ;; not being modified.
    ;;
    ;; Org's font-lock-extend-region-functions pre-expand the jit-lock chunk
    ;; to the full paragraph element before face-extra sees it, so the
    ;; pending region always ≈ chunk — making a size-based threshold useless.
    ;;
    ;; When deferred, the flush fires immediately when Emacs goes idle
    ;; (idle-0 timer via face-extra--schedule-pass3-flush), so justification
    ;; settles as soon as the user pauses with no perceptible lag.

    ;; First, merge any pending region accumulated by face-extra--dispatch.
    (when face-extra--pass3-pending
      (setq beg (min beg (car face-extra--pass3-pending))
            end (max end (cdr face-extra--pass3-pending)))
      (setq face-extra--pass3-pending nil))
    ;; Debounce: during active typing, narrow the walk to the single visual
    ;; line containing point rather than walking the full paragraph.
    ;;
    ;; This gives O(1) vertical-motion calls per keystroke (2: one to find
    ;; BOL, one to find EOL of point's line) instead of O(paragraph_lines).
    ;; Lines other than point's keep their existing stamps — those stamps are
    ;; correct as long as their content hasn't changed; any line whose breaks
    ;; shift (overflow) will be corrected by the deferred flush.
    ;;
    ;; The full region is always scheduled for a flush after
    ;; `face-extra--pass3-flush-delay' seconds of idle, so justification
    ;; settles correctly on any genuine pause.  Brief inter-keystroke
    ;; hesitations (< flush-delay) do not trigger the full-paragraph walk.
    ;;
    ;; The deferral is gated on `face-extra--typing-commands' (not on
    ;; (current-idle-time) alone) so that scroll, window-focus, and other
    ;; non-typing events run pass 3 immediately.  The measurement-mid-keystroke
    ;; feedback loop that originally motivated the unconditional idle-gate
    ;; only arises when buffer content is being modified; for read-only
    ;; events (scroll, focus change) running pass 3 synchronously is safe
    ;; and eliminates the visible snap/jitter after scrolling.
    ;; Consume force-full unconditionally so it is never left stuck at t.
    ;; post-command-reflow calls dispatch-pass3 directly with this-command=nil,
    ;; which bypasses the when-typing-commands block below; without this early
    ;; consume the flag would never be reset and every subsequent jit-lock call
    ;; would see force=t permanently.
    (let ((force-full (prog1 face-extra--pass3-force-full
                        (setq face-extra--pass3-force-full nil))))
    (when text-align--debug
      (message "jd dispatch3: cmd=%s idle=%s force=%s beg=%d end=%d pt=%d"
               this-command (current-idle-time) force-full
               beg end (point)))
    (when (and (null (current-idle-time))
               (memq this-command face-extra--typing-commands))
      ;; Schedule flush for idle.  Start from point's visual line rather
      ;; than the paragraph start: overflow cascades only propagate forward,
      ;; so lines before point are unaffected and the content-hash check in
      ;; text-align--apply skips them cheaply.  paragraph-bounds refinement
      ;; (structural-boundary clipping) happens in the flush callback at
      ;; idle.  The scheduler takes (min existing new-beg) so rapid edits at
      ;; different positions always cover the union of all dirty regions.
      (face-extra--schedule-pass3-flush
       (current-buffer)
       (if (and face-extra--vline-beg
                (>= face-extra--vline-beg beg)
                (<= face-extra--vline-beg end))
           face-extra--vline-beg
         beg)
       end)
      ;; Narrow beg/end to point's visual line, unless force-full is set.
      (if force-full
          nil  ; skip narrowing — let expand-to-lines cover the full line
      ;; Normal narrowing path: reduce to point's visual line.
      ;;
      ;; New ordering:
      ;;   1. Point outside chunk → skip (no vertical-motion).
      ;;   2. Paragraph-final logical line (end-of-line + char-after, cheap)
      ;;      → skip (no vertical-motion).
      ;;   3. Non-final line → narrow with vertical-motion 0 + 1.
      ;;   4. Visual-final wrap of non-final logical line → skip.
      ;; jit-lock does (goto-char start) before calling registered functions,
      ;; so (point) = beg (paragraph start), not the user's cursor.  Use
      ;; face-extra--vline-beg (set by pre-command-hook before the keystroke)
      ;; to find the actual visual line the user is editing.
      (let ((pt (or (and face-extra--vline-beg
                         (>= face-extra--vline-beg beg)
                         (<  face-extra--vline-beg end)
                         face-extra--vline-beg)
                    (point))))
        (cond
         ;; Point outside the jit-lock chunk: skip entirely.
         ((not (and (>= pt beg) (< pt end)))
          (setq beg end))
         ;; Non-final line: narrow to point's visual line.
         (t
          (save-excursion
            (goto-char pt)
            (let ((fontification-functions nil))
              (vertical-motion 0)
              (setq beg (point))
              (vertical-motion 1))
            ;; Do NOT clip by outer end: paragraph-final guard in
            ;; text-align--apply needs to see the trailing \\n.
            (setq end (point)))
          (when text-align--debug
            (message "jd narrow t-branch: beg=%d end=%d char-before-end=%s"
                     beg end (and (> end 0) (char-to-string (char-after (1- end))))))
          ;; Visual-final line of a non-final logical line: skip.
          ;; Otherwise mark that narrowing succeeded.
          (if (and (< beg end)
                   (eq (char-after (1- end)) ?\n))
              (setq beg end)
            (setq pass3-narrowed t)))))))  ; closes cond / let pt / if force-full
    (when text-align--debug
      (message "jd dispatch3 post-narrow: pass3-narrowed=%s beg=%d end=%d"
               pass3-narrowed beg end))
    ;; Walk the (possibly narrowed) region.  beg = end → loop never runs.
    ;; When pass3-narrowed, skip expand-to-lines: beg/end are exact visual-
    ;; line positions; expanding to the logical line re-inflates to the full
    ;; paragraph for soft-wrapped text, defeating the narrowing entirely.
    (let ((region (if pass3-narrowed
                      (when (< beg end) (cons beg end))
                    (face-extra--expand-to-lines beg end))))
      (when region
        (let ((rbeg (car region))
              (rend (cdr region))
              ;; line-spans: property → list of (lbeg lend value) triples,
              ;; one per visual line.  Reuse a buffer-local table (cleared
              ;; below) to avoid per-walk allocation that drives GC.
              (line-spans (or face-extra--line-spans-table
                              (setq face-extra--line-spans-table
                                    (make-hash-table :test #'eq)))))
          ;; Clear the reused table from any previous walk.
          (clrhash line-spans)
          ;; Pre-clear pass: call :pre-clear for each registered pass-3 property.
          ;; text-align no longer registers :pre-clear (it does per-line clearing
          ;; inside text-align--apply using content hashes).  Other properties
          ;; may still register :pre-clear here.
          (dolist (prop (gethash 3 face-extra--pass-order))
            (let* ((entry  (gethash (cons prop 3) face-extra--registry))
                   (mode   (plist-get entry :mode))
                   (pre-fn (plist-get entry :pre-clear)))
              (when (and pre-fn mode (symbol-value mode))
                (funcall pre-fn rbeg rend))))
          (save-excursion
            (goto-char rbeg)
            (while (< (point) rend)
              (let* ((lbeg  (point))
                     (moved (let ((fontification-functions nil))
                              (vertical-motion 1)))
                     ;; Do NOT clip lend by rend.  The paragraph-final guard
                     ;; in text-align--apply checks (char-after (1- lend));
                     ;; for the last line of a paragraph lend must land past
                     ;; the trailing \n, not at it.  Clipping to rend when
                     ;; rend sits on that \n shifts lend one position early,
                     ;; making (char-after (1- lend)) the last content char
                     ;; rather than \n — silently disabling the guard.
                     ;; The apply functions already receive lend bounded by
                     ;; the buffer, so no clipping is needed here.
                     (lend  (point))
                     ;; Face at visual-line BOL.  font-lock-face takes
                     ;; priority (Org regexp keywords); fall back to face
                     ;; (Org anchor functions, body stamp).
                     ;;
                     ;; When lbeg is inside an invisible (folded) region —
                     ;; e.g. the "#+TITLE: " prefix folded by
                     ;; org-title-fold-mode — the face there belongs to the
                     ;; keyword markup, not the content.  Scan forward to
                     ;; the first non-invisible position so that
                     ;; org-document-title (applied to the title value text)
                     ;; is resolved correctly.  The line-prefix stamp is
                     ;; still written at lbeg: the display engine reads
                     ;; line-prefix from the buffer BOL regardless of
                     ;; whether that position is invisible.
                     (fpos  (if (get-text-property lbeg 'invisible)
                                (let ((p (next-single-property-change
                                          lbeg 'invisible nil lend)))
                                  (or p lend))
                              lbeg))
                     (f     (when (< fpos lend)
                              (or (get-text-property fpos 'font-lock-face)
                                  (get-text-property fpos 'face))))
                     (faces (cond
                              ((null f)                          nil)
                              ((symbolp f)                       (list f))
                              ((and (consp f) (keywordp (car f))) nil)
                              ((listp f) (cl-remove-if-not #'symbolp f))
                              (t                                 nil))))
                (when faces
                  ;; Resolve pass-3 properties from the face cache.
                  ;; Use a per-line alist to take the first (highest-priority)
                  ;; value when multiple faces on the same BOL carry the same
                  ;; property (e.g. body + org-cite both have text-align).
                  (let ((line-props nil))
                    (dolist (face faces)
                      (let ((entry (face-extra--get-cache-entry face)))
                        (dolist (triple (plist-get entry :pass3))
                          (let ((prop (nth 0 triple))
                                (val  (nth 1 triple)))
                            (unless (assq prop line-props)
                              (push (cons prop val) line-props))))))
                    (dolist (pair line-props)
                      (push (list lbeg lend (cdr pair))
                            (gethash (car pair) line-spans)))))
                (when (zerop moved)
                  (goto-char rend)))))
          (face-extra--run-pass 3 line-spans)
          ;; Record the completed region so `face-extra--window-scroll'
          ;; can suppress re-scheduling for the same on-screen content.
          ;; This is needed for inline (non-idle) runs too: when pass 3
          ;; fires synchronously on scroll, stamping changes line heights
          ;; which makes Emacs fire `window-scroll-functions' again; without
          ;; this guard that produces an endless flush → scroll-event loop.
          (setq face-extra--pass3-last-flushed-beg
                (min rbeg (or face-extra--pass3-last-flushed-beg rbeg)))
          (setq face-extra--pass3-last-flushed-end
                (max rend (or face-extra--pass3-last-flushed-end rend))))))))))) ; closes let force-full

(defun face-extra--pre-command ()
  "Dispatch `:pre-command' callbacks for registered pass-3 properties.
Added to `pre-command-hook' buffer-locally by
`face-extra--enable-dispatch-pass3'.

Fires only for self-inserting and deletion commands — the cases where a
single keystroke may alter line width and cause a justified line to
overflow before jit-lock can re-measure.  Other commands (navigation,
etc.) are skipped immediately.

Maintains a cached visual line in `face-extra--vline-beg' and
`face-extra--vline-end':
- If point is still within [vline-beg, vline-end) the cached values are
  reused, saving two `vertical-motion' calls per keystroke.
- If point has moved outside that range both are recomputed together."
  (when (memq this-command face-extra--typing-commands)
    (let* ((pt (point))
           ;; Reuse cache if point is still on the same visual line;
           ;; otherwise recompute both beg and end via vertical-motion.
           (vbeg (if (and face-extra--vline-beg
                          face-extra--vline-end
                          (>= pt face-extra--vline-beg)
                          (<  pt face-extra--vline-end))
                     face-extra--vline-beg
                   (save-excursion
                     (let ((fontification-functions nil))
                       (vertical-motion 0)
                       (setq face-extra--vline-beg (point))
                       (vertical-motion 1)
                       (setq face-extra--vline-end (point)))
                     face-extra--vline-beg)))
           (vend face-extra--vline-end))
      ;; Dispatch to each pass-3 property that registered :pre-command.
      (dolist (prop (gethash 3 face-extra--pass-order))
        (let* ((entry   (gethash (cons prop 3) face-extra--registry))
               (mode    (plist-get entry :mode))
               (pre-cmd (plist-get entry :pre-command)))
          (when (and pre-cmd mode (symbol-value mode))
            (funcall pre-cmd vbeg vend)))))))

(defun face-extra--enable-dispatch-pass3 ()
  "Register `face-extra--dispatch-pass3' as a jit-lock function.
Also adds `face-extra--pre-command' to `pre-command-hook' buffer-locally.
`jit-lock-register' is buffer-local; this must be called in each buffer
that requires pass-3 dispatch.  Called by `face-extra-mode-require' (via
`face-extra--enable-dispatch') when pass-3 properties exist.  Idempotent."
  (jit-lock-register #'face-extra--dispatch-pass3)
  (add-hook 'pre-command-hook #'face-extra--pre-command nil t))

(defun face-extra--disable-dispatch-pass3 ()
  "Unregister `face-extra--dispatch-pass3' from jit-lock in the current buffer.
Also removes `face-extra--pre-command' from `pre-command-hook'.
Called by `face-extra-mode-release' when the ref count reaches zero."
  (jit-lock-unregister #'face-extra--dispatch-pass3)
  (remove-hook 'pre-command-hook #'face-extra--pre-command t))


;;;; ================================================================
;;;; Section 9 — Load-time dispatch wiring
;;;; ================================================================
;;
;; The dispatch advice is installed once at load time, globally and permanently.
;; The buffer-local `face-extra-mode' guard makes it a cheap no-op in
;; inactive buffers.  `jit-lock-register' cannot be made buffer-local via
;; advice; pass-3 is registered per-buffer by `face-extra-mode-require'.

(advice-add 'font-lock-fontify-keywords-region :after #'face-extra--dispatch)
(advice-add 'font-lock-ensure :after #'face-extra--after-ensure)
(add-hook 'window-scroll-functions #'face-extra--window-scroll)
(add-hook 'window-selection-change-functions #'face-extra--window-selected)


(provide 'face-extra)
;;; face-extra.el ends here
