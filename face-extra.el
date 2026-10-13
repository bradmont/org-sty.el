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
;;   (face-extra-add 'text-body 'variable-spacing-ratio 1.5)
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
  (or (gethash (cons property 1) face-extra--registry)
      (gethash (cons property 2) face-extra--registry)
      (gethash (cons property 3) face-extra--registry)))

(defun face-extra--validate-after (property after pass)
  "Signal an error if any symbol in AFTER is not registered in PASS."
  (dolist (dep after)
    (unless (gethash (cons dep pass) face-extra--registry)
      (error "face-extra: :after dependency `%s' for `%s' is not registered in pass %d"
             dep property pass))))

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

;;;###autoload
(defun face-extra-define-property (property &rest plist)
  "Register a synthetic face PROPERTY with the face-extra dispatch system.

PLIST must contain:
  :pass   Integer 1, 2, or 3 (rendering pipeline pass number).
  :apply  Function called with (spans) — a list of (beg end value) triples
          collected for this property across the dispatch region.
  :clear  Function called with a cookie (as returned by `face-extra-add')
          to undo a global property installation.

Optional:
  :after      List of property symbols in the same PASS that must run before
              this property.  Cross-pass references are rejected.
  :pre-clear  Function called with (beg end) once before the pass-3
              visual-line walk begins.  Use this to remove display artifacts
              (e.g. overlays) that would affect `vertical-motion' layout
              calculations.  Only meaningful for pass-3 properties.
  :pre-command  Function called with (vline-beg vline-end) from
              `pre-command-hook' before each self-inserting or deleting
              keystroke.  vline-beg is the cached visual BOL (recomputed
              via `vertical-motion' only when point has left the last-known
              visual line); vline-end is the logical EOL via
              `line-end-position' (recomputed cheaply each call).
              Only meaningful for pass-3 properties.

Registering a property clears the entire face cache (via
`face-extra--invalidate-all-caches') because existing per-face cache
entries may be stale.  At load time this is inexpensive and rare."
  (let ((pass       (plist-get plist :pass))
        (after      (plist-get plist :after))
        (apply-fn     (plist-get plist :apply))
        (clear-fn     (plist-get plist :clear))
        (pre-clear    (plist-get plist :pre-clear))
        (pre-command  (plist-get plist :pre-command)))
    (unless (memql pass '(1 2 3))
      (error "face-extra-define-property: :pass must be 1, 2, or 3 (got %S)" pass))
    (unless (functionp apply-fn)
      (error "face-extra-define-property: :apply must be a function"))
    ;; :after validation — must run after any prior properties exist.
    ;; We validate lazily (after registration) so that forward-declarations
    ;; are impossible; :after must only name already-registered symbols.
    (face-extra--validate-after property after pass)
    (puthash (cons property pass)
             (list :pass pass :after after :apply apply-fn :clear clear-fn
                   :pre-clear pre-clear :pre-command pre-command)
             face-extra--registry)
    ;; Re-sort the affected pass bucket.
    (face-extra--sort-pass pass)
    ;; Invalidate all per-face caches — rare (load-time only).
    (face-extra--invalidate-all-caches)))


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
    delete-backward-char          ; backspace in most modes
    org-delete-backward-char      ; backspace in Org mode
    delete-forward-char           ; C-d / forward delete
    delete-char)
  "Commands treated as active typing for passes 1–2 narrowing.
During these commands, passes 1–2 are narrowed to point's logical line,
keeping per-keystroke cost near zero.  All other commands — scrolling,
initial render, fontified=nil re-fontification — get full unrestricted
passes.  `self-insert-command' is first so the common case is a single
pointer comparison before `memq' returns.")

(defvar face-extra--pass3-flush-delay 0.15
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
    (face-extra--invalidate-face face)
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
       ;; Invalidate per-face entry in every buffer.
       (dolist (buf (buffer-list))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (face-extra--invalidate-face face))))))
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
           (face-extra--invalidate-face face)))))
    (_
     (error "face-extra-remove: unrecognised cookie format: %S" cookie))))


;;;; ================================================================
;;;; Section 4 — Backend protocol
;;;; ================================================================

(defvar face-extra--backend-alist nil
  "Alist mapping major-mode symbol → backend plist.

Each backend plist must supply at minimum:
  :stamp-body-text  A function (beg end) that stamps the pass-0
                    body-text face on unstyled bare-text runs in BEG..END.
                    Called once at the start of each dispatch cycle, before
                    the property scan.

Register a backend with `face-extra-register-backend'.")

(defun face-extra-register-backend (major-mode-sym backend-plist)
  "Register BACKEND-PLIST as the backend for MAJOR-MODE-SYM.

BACKEND-PLIST must contain at least:
  :stamp-body-text  A function (beg end) — see `face-extra--backend-alist'."
  (unless (plist-get backend-plist :stamp-body-text)
    (error "face-extra-register-backend: backend for `%s' lacks :stamp-body-text"
           major-mode-sym))
  (setf (alist-get major-mode-sym face-extra--backend-alist) backend-plist))

(defun face-extra--active-backend ()
  "Return the backend plist for the current buffer's major mode, or nil."
  (alist-get major-mode face-extra--backend-alist))


;;;; ================================================================
;;;; Section 5 — Per-face cache resolver and dispatch
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
`text-body' stamp alongside a suppressed face (e.g. `org-quote') from
leaking the `text-body' ratio through."
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
               (apply-fn (plist-get entry :apply)))
          (funcall apply-fn (nreverse spans)))))))

(defun face-extra--dispatch (beg end &optional _loudly)
  "After-fontify dispatch: stamp body text and run pass-1/2/3 properties.

Advises `font-lock-fontify-keywords-region' with :after.  Active in all
buffers that have at least one buffer-local property or a registered
backend for their major mode.

Steps:
  1. Call the active backend's :stamp-body-text (pass 0 completion).
  2. Scan BEG..END once, building per-property span lists.
  3. Run pass-1, pass-2, pass-3 properties in order."
  ;; Only run if there is something to do in this buffer.
  (when (or face-extra--local-properties
            (face-extra--active-backend))
    (let ((backend (face-extra--active-backend)))
      ;; Pass 0: mode-specific bare-text stamping.
      (when backend
        (let ((stamp-fn (plist-get backend :stamp-body-text)))
          (when stamp-fn
            (funcall stamp-fn beg end))))
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
            (face-extra--run-pass 2 spans-table)))))))

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
  (when (and (or face-extra--local-properties
                 (face-extra--active-backend))
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
        (when (and (or face-extra--local-properties
                       (face-extra--active-backend))
                   (gethash 3 face-extra--pass-order))
          (face-extra--schedule-pass3-flush buf
                                            (window-start win)
                                            (window-end win t)))))))

(defun face-extra--enable-dispatch ()
  "Add `face-extra--dispatch' as :after advice on fontification.
Advises `font-lock-fontify-keywords-region' so the dispatch runs
after Org (and all other font-lock keywords) have fully annotated the
region.  Also advises `font-lock-ensure' so that `font-lock-update'
(which bypasses jit-lock) still triggers pass-3.  Adds a
`window-scroll-functions' hook to flush pass-3 on scroll for regions
that jit-lock never re-dirtied.  Idempotent."
  (advice-add 'font-lock-fontify-keywords-region :after
              #'face-extra--dispatch)
  (advice-add 'font-lock-ensure :after #'face-extra--after-ensure)
  (add-hook 'window-scroll-functions #'face-extra--window-scroll))

(defun face-extra--disable-dispatch ()
  "Remove the `face-extra--dispatch' advice.

Only removes the advice when no live buffer still requires it — i.e.
when no buffer has `face-extra--local-properties' set and no registered
backend matches any live buffer's major mode."
  (let ((still-needed
         (cl-some
          (lambda (buf)
            (when (buffer-live-p buf)
              (with-current-buffer buf
                (or face-extra--local-properties
                    (face-extra--active-backend)))))
          (buffer-list))))
    (unless still-needed
      (advice-remove 'font-lock-fontify-keywords-region
                     #'face-extra--dispatch)
      (advice-remove 'font-lock-ensure
                     #'face-extra--after-ensure)
      (remove-hook 'window-scroll-functions #'face-extra--window-scroll))))

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
allocating a new closure on every keystroke."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq face-extra--pass3-flush-timer nil)
      (let ((b face-extra--pass3-flush-beg)
            (e face-extra--pass3-flush-end))
        (setq face-extra--pass3-flush-beg nil
              face-extra--pass3-flush-end nil)
        (when (and b e)
          (face-extra--dispatch-pass3 b e))))))

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
    (unless face-extra--pass3-flush-timer
      (setq face-extra--pass3-flush-timer
            (run-with-idle-timer face-extra--pass3-flush-delay nil
                                 #'face-extra--pass3-flush-callback buf)))))

(defun face-extra--paragraph-bounds (beg end)
  "Return a (BEG . END) cons expanded to paragraph boundaries.

A paragraph boundary is a blank line (a line containing only whitespace)
or the buffer start/end.  Expansion is done with `re-search-backward' and
`re-search-forward' — no `vertical-motion' calls, so safe to call during
active editing.

The returned BEG is the start of the first line of the paragraph that
contains the original BEG; the returned END is the end of the last line
of the paragraph that contains the original END."
  (cons (save-excursion
          (goto-char beg)
          (if (re-search-backward "^[ \t]*$" (point-min) t)
              ;; Found a blank line — the paragraph starts on the next line.
              (line-beginning-position 2)
            (point-min)))
        (save-excursion
          (goto-char end)
          (if (re-search-forward "^[ \t]*$" (point-max) t)
              ;; Found a blank line — the paragraph ends at the end of the
              ;; previous line (the last non-blank line).
              (match-beginning 0)
            (point-max)))))

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
    (when (and (or face-extra--local-properties
                   (face-extra--active-backend))
               (gethash 3 face-extra--pass-order))
      (let ((face-extra--pass3-geometry-unsettled t))
    ;; Expand beg/end by any region pass-2 covered in this jit-lock cycle.
    ;; Pass-2's :after advice receives font-lock's extended region (e.g.
    ;; the full org-quote block); jit-lock only passes us the smaller
    ;; original chunk.  Without this, the tail of a multi-line block never
    ;; gets pass-3 treatment because font-lock already marked it fontified.
    ;;
    ;; Debounce: when Emacs is not idle (active typing), always defer to
    ;; idle rather than walking visual lines now.
    ;;
    ;; DESIGN NOTE — why the check is unconditional (not gated on pending):
    ;; `face-extra--dispatch' (passes 1+2) sets `face-extra--pass3-pending'
    ;; and then calls this function inline for the same beg/end.  That inline
    ;; call sees pending, clears it, and defers.  But jit-lock-register ALSO
    ;; calls this function independently for the same chunk.  By the time
    ;; that registered call fires, pending is nil (cleared by the inline
    ;; call), so a `(when face-extra--pass3-pending ...)' guard would fall
    ;; through and run pass-3 immediately — defeating the debounce entirely.
    ;; Checking (null (current-idle-time)) unconditionally fixes this: the
    ;; registered call is also deferred when not idle, regardless of pending.
    ;;
    ;; Org's font-lock-extend-region-functions pre-expand the jit-lock chunk
    ;; to the full paragraph element before face-extra sees it, so the
    ;; pending region always ≈ chunk — making a size-based threshold useless.
    ;;
    ;; The flush fires immediately when Emacs goes idle (idle-0 timer via
    ;; face-extra--schedule-pass3-flush), so justification settles as soon
    ;; as the user pauses with no perceptible lag.

    ;; First, merge any pending region accumulated by face-extra--dispatch.
    (when face-extra--pass3-pending
      (setq beg (min beg (car face-extra--pass3-pending))
            end (max end (cdr face-extra--pass3-pending)))
      (setq face-extra--pass3-pending nil))
    ;; Debounce: when not idle (active typing), narrow the walk to the
    ;; single visual line containing point rather than skipping entirely.
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
    (when (null (current-idle-time))
      ;; Schedule full-paragraph flush for idle.
      ;; The jit-lock chunk only covers the lines around point; lines below
      ;; in the same paragraph are never re-dirtified by jit-lock.  Expand
      ;; beg/end to the full paragraph (blank-line-delimited) so the idle
      ;; flush re-justifies all lines, including those below the edit point.
      (let ((para (face-extra--paragraph-bounds beg end)))
        (face-extra--schedule-pass3-flush (current-buffer)
                                          (car para) (cdr para)))
      ;; Narrow beg/end to point's visual line, unless force-full is set.
      ;; force-full is consumed here (reset to nil) so it applies to
      ;; exactly this one jit-lock cycle; the full logical-line region
      ;; is then passed to face-extra--expand-to-lines below.
      (if (prog1 face-extra--pass3-force-full
            (setq face-extra--pass3-force-full nil))
          nil  ; skip narrowing — let expand-to-lines cover the full line
      ;; Normal narrowing path: reduce to point's visual line.
      ;;
      ;; New ordering:
      ;;   1. Point outside chunk → skip (no vertical-motion).
      ;;   2. Paragraph-final logical line (end-of-line + char-after, cheap)
      ;;      → skip (no vertical-motion).
      ;;   3. Non-final line → narrow with vertical-motion 0 + 1.
      ;;   4. Visual-final wrap of non-final logical line → skip.
      (let ((pt (point)))
        (cond
         ;; Point outside the jit-lock chunk: skip entirely.
         ((not (and (>= pt beg) (< pt end)))
          (setq beg end))
         ;; Paragraph-final logical line: no vertical-motion needed.
         ((save-excursion
            (end-of-line)
            (or (eobp)
                (eq (char-after (1+ (point))) ?\n)))
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
          ;; Visual-final line of a non-final logical line: skip.
          (when (and (< beg end)
                     (eq (char-after (1- end)) ?\n))
            (setq beg end)))))))  ; closes cond / let pt / if force-full
    ;; Walk the (possibly narrowed) region.  beg = end → loop never runs.
    (let ((region (face-extra--expand-to-lines beg end)))
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
                   (pre-fn (plist-get entry :pre-clear)))
              (when pre-fn
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
                     ;; (Org anchor functions, text-body stamp).
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
                  ;; property (e.g. text-body + org-cite both have text-align).
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
          (face-extra--run-pass 3 line-spans)))))))) ; closes let/when/if

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
  (when (memq this-command
              '(self-insert-command
                org-self-insert-command
                delete-backward-char
                backward-delete-char-untabify
                delete-forward-char))
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
               (pre-cmd (plist-get entry :pre-command)))
          (when pre-cmd
            (funcall pre-cmd vbeg vend)))))))

(defun face-extra--enable-dispatch-pass3 ()
  "Register `face-extra--dispatch-pass3' as a jit-lock function.
Also adds `face-extra--pre-command' to `pre-command-hook' buffer-locally.
`jit-lock-register' is buffer-local; this must be called in each buffer
that requires pass-3 dispatch.  Idempotent."
  (jit-lock-register #'face-extra--dispatch-pass3)
  (add-hook 'pre-command-hook #'face-extra--pre-command nil t))

(defun face-extra--disable-dispatch-pass3 ()
  "Unregister `face-extra--dispatch-pass3' from jit-lock in the current buffer.
Also removes `face-extra--pre-command' from `pre-command-hook'.

Only unregisters when no pass-3 properties remain active in this buffer
— i.e. when `face-extra--local-properties' carries no pass-3 values and
no registered backend is active.  This prevents one mode disabling pass-3
while another mode still requires it in the same buffer."
  (let ((still-needed
         (and (or face-extra--local-properties
                  (face-extra--active-backend))
              (gethash 3 face-extra--pass-order))))
    (unless still-needed
      (jit-lock-unregister #'face-extra--dispatch-pass3)
      (remove-hook 'pre-command-hook #'face-extra--pre-command t))))


(provide 'face-extra)
;;; face-extra.el ends here
