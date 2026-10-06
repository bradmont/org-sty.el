;;; org-cite-appear.el --- Render org-cite references as (Author, Year) -*- lexical-binding: t; -*-

;; Author: Brad
;; Keywords: org, bib, convenience
;; Version: 0.1

;;; Commentary:

;; Hides the raw `[cite:@key]' syntax in Org buffers and replaces each
;; citation with a formatted display string such as "(Smith, 2020)" or
;; "(Smith & Jones, 2019; Brown, 2021, p. 14)".  The raw markup is
;; revealed when point enters the citation region and a non-motion
;; command is issued there (RET, C-c C-c, typing, or backspace).
;;
;; Architecture
;; ------------
;;
;; OVERLAYS own their entire lifecycle -- font-lock / jit-lock is
;; deliberately not involved.  Each `[cite:...]' span is covered by a
;; single persistent overlay carrying only a `display' property (no
;; `invisible' text property); the raw buffer text is still present
;; and point can enter the region normally.
;;
;; LIFECYCLE
;;   Mode enable   : `re-search-forward' full buffer; one overlay per
;;                   citation; every new overlay is marked as pending
;;                   (`org-cite-appear--needs-format' = t) with an
;;                   ellipsis placeholder.
;;   after-change  : delete any of our overlays touching the changed
;;                   region; re-scan the extended region; mark new
;;                   overlays pending; trigger formatter.
;;   Idle formatter: processes ONE pending overlay per timer firing,
;;                   then schedules itself again if more remain.  This
;;                   amortises the citar lookup cost across idle time
;;                   rather than blocking for the whole document.
;;   Mode disable  : cancel timer; delete all overlays; remove hooks.
;;
;; REVEAL / RE-HIDE
;;   Motion keys (arrows, mouse-1, etc.) do NOT reveal.  Reveal is
;;   triggered by specific commands only:
;;
;;   pre-command-hook  : if point is inside a citation overlay and the
;;                       incoming command is `self-insert-command' or
;;                       `delete-backward-char', reveal the overlay and
;;                       reposition point to just before the closing `]'
;;                       before the command executes.  This means typed
;;                       characters are appended before `]'; backspace
;;                       deletes the last citation character, never `]'.
;;
;;   Overlay keymap    : each overlay carries a sparse keymap active
;;                       when point is inside it:
;;                         RET, C-c C-c  -- reveal at point
;;                         mouse-2       -- edit whole [cite:...] in
;;                                          the minibuffer
;;
;;   post-command-hook : if a citation is currently revealed and point
;;                       has left its region, re-apply the display
;;                       string and clear state.
;;
;; LOCATORS (page numbers etc.)
;;   Org-cite per-reference suffixes, e.g. `[cite:@smith2020, p. 42]',
;;   are extracted from the raw overlay text by regex.  The locator
;;   appears after the key and before `;' or `]'; leading comma/space
;;   is stripped.  Formatted as "(Smith, 2020, p. 42)".
;;
;; CITAR ACTIVATION SUPPRESSION
;;   `citar-org-cite-basic-activate' stamps O(citation_length) face
;;   fragments on every jit-lock cycle.  When
;;   `org-cite-appear-suppress-citar-activation' is non-nil (default),
;;   an advice on that function skips it in buffers where this mode is
;;   active, since its output lands on non-rendered hidden text anyway.
;;   A `help-echo' on our overlay replaces the tooltip.
;;
;; Usage:
;;   (add-hook 'org-mode-hook #'org-cite-appear-mode)
;;   ;; or from an org-sty-alist :eval form:
;;   (:eval (org-cite-appear-mode 1))

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'oc)

(defgroup org-cite-appear nil
  "Render org-cite references as formatted display strings."
  :group 'org)


;;; ----------------------------------------------------------------
;;; Faces and customisation
;;; ----------------------------------------------------------------

(defface org-cite-appear
  '((t :inherit org-cite))
  "Face applied to the rendered citation display string."
  :group 'org-cite-appear)

(defcustom org-cite-appear-format-function
  #'org-cite-appear--format-default
  "Function to format a citation into a display string.

Called with one argument: a list of (KEY . LOCATOR) cons cells,
where KEY is a cite-key string and LOCATOR is the per-reference
suffix string (e.g. \"p. 42\"), or nil if absent.

Must return a propertized or plain string.  The default produces
\"(Author, Year)\" or \"(Author, Year, p. N)\" strings."
  :group 'org-cite-appear
  :type 'function)

(defcustom org-cite-appear-format-inter-cite-delay 0.2
  "Seconds between formatting individual citations during idle.
Each idle timer invocation formats one citation, then schedules
the next after this delay.  Keeps the UI responsive when a
document has many citations."
  :group 'org-cite-appear
  :type 'number)

(defcustom org-cite-appear-suppress-citar-activation t
  "When non-nil, skip `citar-org-cite-basic-activate' in buffers
where `org-cite-appear-mode' is active.

That function stamps per-key face fragments on every jit-lock
cycle; in org-cite-appear buffers those fragments land on text
that is visually replaced by our overlay and are never rendered.
Suppressing it removes nearly all remaining jit-lock cost for
cite-containing paragraphs.

Set to nil to re-enable citar activation, e.g. if you rely on
its per-key `help-echo' tooltips (though org-cite-appear sets its
own `help-echo' on the overlay)."
  :group 'org-cite-appear
  :type 'boolean)


;;; ----------------------------------------------------------------
;;; Internal constants and buffer-local state
;;; ----------------------------------------------------------------

(defconst org-cite-appear--cite-open-re
  "\\[cite"
  "Regex matching the opening of an org-cite citation.
The full span is located by `org-cite-appear--find-end', which
tracks bracket depth to handle `]' characters inside affixes.")

(defconst org-cite-appear--hidden-prop 'org-cite-appear--hidden
  "Overlay property used as sentinel for overlays placed by this mode.")

(defconst org-cite-appear--needs-format-prop 'org-cite-appear--needs-format
  "Overlay property: non-nil means display is still a placeholder.")

;; Forward declaration: `define-minor-mode' generates this variable, but it
;; is referenced in functions above the `define-minor-mode' form.
(defvar org-cite-appear-mode)

;; Matches @KEY followed by optional suffix up to ; or ].
;; Group 1 = bare key (no @).
;; Group 2 = raw suffix text (may be empty).
(defconst org-cite-appear--ref-re
  "@\\([^][ \t\n;,@]+\\)\\([^];]*\\)"
  "Extract (key . raw-suffix) pairs from a raw citation string.")

(defcustom org-cite-appear-new-cite-delay 1.0
  "Idle seconds before folding a newly inserted citation.
After `org-cite-insert' (or manually completing a `[cite:...]' tag),
this delay keeps the raw markup visible so the user can add a locator
\(e.g. \", p. 42\") before the citation is folded.  The timer is an
idle timer, so it fires only after the user pauses for this long."
  :group 'org-cite-appear
  :type 'number)

(defvar-local org-cite-appear--format-timer nil
  "Pending idle format timer, or nil.")

(defvar-local org-cite-appear--new-cite-timer nil
  "Idle timer for folding newly inserted citations, or nil.")

(defvar-local org-cite-appear--new-cite-regions nil
  "List of (BEG . END) line regions that may contain new unfolded citations.
Populated by `org-cite-appear--after-change' when a new `[cite...]'
completion is detected; processed by `org-cite-appear--fold-new-cites'
after `org-cite-appear-new-cite-delay' seconds of idle time.")

(defvar-local org-cite-appear--pending nil
  "Queue of overlays awaiting idle formatting.
Overlays are pushed here when created by `org-cite-appear--make-overlay'
and popped one at a time by `org-cite-appear--format-one'.  Entries
whose `overlay-buffer' is nil (deleted by an edit) are silently
skipped when encountered.")

(defvar-local org-cite-appear--revealed nil
  "Plist for the currently revealed citation, or nil.
Keys:
  :ov     the overlay temporarily without a `display' value
  :range  (BEG . END) for the cheap point-still-inside check")


;;; ----------------------------------------------------------------
;;; Keymap placed on each overlay
;;; ----------------------------------------------------------------

(defvar org-cite-appear--overlay-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")     #'org-cite-appear-reveal-at-point)
    (define-key map (kbd "C-c C-c") #'org-cite-appear-reveal-at-point)
    map)
  "Keymap active on folded (display-set) org-cite-appear overlays.
Mouse-1 clicks are handled separately via `post-command-hook' to
avoid the overlay-keymap/display-property interaction that prevents
`[mouse-1]' bindings from firing reliably on display overlays.")


;;; ----------------------------------------------------------------
;;; Extracting keys and locators from raw cite text
;;; ----------------------------------------------------------------

(defun org-cite-appear--refs-in-string (s)
  "Return a list of (KEY . LOCATOR) pairs extracted from string S.
LOCATOR is nil when the reference has no suffix."
  (let (pairs)
    (with-temp-buffer
      (insert s)
      (goto-char (point-min))
      (while (re-search-forward org-cite-appear--ref-re nil t)
        (let* ((key    (match-string-no-properties 1))
               (raw    (match-string-no-properties 2))
               ;; Strip leading comma and whitespace from the suffix.
               (loc    (when raw
                         (let ((trimmed (string-trim
                                         (replace-regexp-in-string
                                          "\\`[, \t]+" "" raw))))
                           (unless (string-empty-p trimmed) trimmed)))))
          (push (cons key loc) pairs))))
    (nreverse pairs)))

(defun org-cite-appear--refs-in-region (beg end)
  "Return (KEY . LOCATOR) pairs for the citation at BEG..END."
  (org-cite-appear--refs-in-string
   (buffer-substring-no-properties beg end)))


;;; ----------------------------------------------------------------
;;; Default formatter
;;; ----------------------------------------------------------------

(defun org-cite-appear--year-for-key (key)
  "Return the year string for KEY from citar, or \"?\"."
  (when (fboundp 'citar-get-value)
    (or (citar-get-value "year" key)
        (let ((d (citar-get-value "date" key)))
          (when (and d (>= (length d) 4)) (substring d 0 4)))
        (citar-get-value "issued" key)
        "?")))

(defun org-cite-appear--author-for-key (key)
  "Return a shortened author/editor string for KEY, or nil."
  (when (fboundp 'citar-get-value)
    (let ((raw (or (citar-get-value "author" key)
                   (citar-get-value "editor" key))))
      (when raw
        (if (fboundp 'citar--shorten-names)
            (citar--shorten-names raw 2 "&")
          ;; Fallback: first surname only.
          (car (split-string raw "[, ]" t)))))))

(defun org-cite-appear--format-ref (key locator)
  "Format a single KEY + LOCATOR as \"Author, Year[, locator]\"."
  (let ((author (org-cite-appear--author-for-key key))
        (year   (org-cite-appear--year-for-key key)))
    (concat (or author key)
            ", "
            (or year "?")
            (when locator (concat ", " locator)))))

(defun org-cite-appear--format-default (refs)
  "Format REFS (a list of (KEY . LOCATOR) pairs) as a citation string.
Produces e.g. \"(Smith, 2020)\" or \"(Smith, 2020, p. 3; Jones, 2019)\"."
  (propertize
   (concat "("
           (mapconcat (lambda (ref)
                        (org-cite-appear--format-ref (car ref) (cdr ref)))
                      refs "; ")
           ")")
   'face 'org-cite-appear))

(defun org-cite-appear--placeholder ()
  "Return the placeholder display string shown before idle formatting."
  (propertize "(…)" 'face 'org-cite-appear))


;;; ----------------------------------------------------------------
;;; Overlay creation / deletion
;;; ----------------------------------------------------------------

(defun org-cite-appear--delete-overlays-in (beg end)
  "Delete all org-cite-appear overlays overlapping BEG..END."
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov org-cite-appear--hidden-prop)
      (delete-overlay ov))))

(defun org-cite-appear--find-end (limit)
  "Scan forward for the `]' that closes the already-opened `[cite'.
Point should be just after the `[cite' opener.  Tracks nested bracket
pairs so that `]' characters inside citation affixes (e.g. a link
`[[url][desc]]' in a common prefix) do not prematurely end the match.
Returns the position after the closing `]', or nil if LIMIT is reached."
  (let ((depth 1))
    (while (and (> depth 0)
                (re-search-forward "[][]" limit t))
      (if (eq (char-before) ?\[)
          (cl-incf depth)
        (cl-decf depth)))
    (when (zerop depth)
      (point))))

(defun org-cite-appear--make-overlay (beg end)
  "Create a citation overlay at BEG..END with a placeholder display.
The overlay's `face' property is set to `org-cite' so that the raw
markup receives the correct colour when the citation is revealed
(display nil) -- no extra work is needed in the reveal/re-hide path.
The new overlay is pushed onto `org-cite-appear--pending' for the
idle formatter to process."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov org-cite-appear--hidden-prop       t)
    (overlay-put ov org-cite-appear--needs-format-prop t)
    (overlay-put ov 'display   (org-cite-appear--placeholder))
    (overlay-put ov 'face      'org-cite)
    (overlay-put ov 'keymap      org-cite-appear--overlay-map)
    (overlay-put ov 'mouse-face  'highlight)
    (overlay-put ov 'help-echo   "RET/C-c C-c: reveal  mouse-1: edit")
    (push ov org-cite-appear--pending)
    ov))

(defun org-cite-appear--scan-and-create (beg end)
  "Scan BEG..END for `[cite:...]' patterns and create overlays.
Uses `org-cite-appear--find-end' to track bracket depth, so citations
whose affixes contain `]' characters (e.g. links) are bounded correctly.
Existing overlays in the region are deleted first."
  (org-cite-appear--delete-overlays-in beg end)
  (save-excursion
    (goto-char beg)
    (while (re-search-forward org-cite-appear--cite-open-re end t)
      (let* ((cite-beg (match-beginning 0))
             (cite-end (org-cite-appear--find-end end)))
        (when cite-end
          (org-cite-appear--make-overlay cite-beg cite-end))))))


;;; ----------------------------------------------------------------
;;; Idle formatter (one citation per timer firing)
;;; ----------------------------------------------------------------

(defun org-cite-appear--do-format (ov)
  "Format the citation under OV and update its display string."
  (let* ((beg (overlay-start ov))
         (end (overlay-end   ov)))
    (when (and beg end)
      (let* ((refs    (org-cite-appear--refs-in-region beg end))
             (display (when refs
                        (funcall org-cite-appear-format-function refs)))
             ;; Build help-echo from raw refs list for tooltip.
             (echo    (when refs
                        (mapconcat (lambda (r)
                                     (concat "@" (car r)
                                             (when (cdr r)
                                               (concat " " (cdr r)))))
                                   refs "; "))))
        (when display
          (overlay-put ov 'display   display)
          (overlay-put ov 'help-echo (or echo "RET/C-c C-c: reveal  mouse-1: edit")))
        (overlay-put ov org-cite-appear--needs-format-prop nil)))))

(defun org-cite-appear--format-one ()
  "Pop one overlay from the pending queue, format it, schedule the next.
Stale queue entries (overlays deleted by edits) are discarded silently."
  (setq org-cite-appear--format-timer nil)
  (when org-cite-appear-mode
    ;; Discard any stale entries at the head of the queue.
    (while (and org-cite-appear--pending
                (not (overlay-buffer (car org-cite-appear--pending))))
      (pop org-cite-appear--pending))
    (when-let ((ov (pop org-cite-appear--pending)))
      (org-cite-appear--do-format ov)
      ;; If more remain, discard any leading stale entries now so the
      ;; schedule decision is accurate, then schedule if queue non-empty.
      (while (and org-cite-appear--pending
                  (not (overlay-buffer (car org-cite-appear--pending))))
        (pop org-cite-appear--pending))
      (when org-cite-appear--pending
        (org-cite-appear--schedule-format)))))

(defun org-cite-appear--schedule-format ()
  "Schedule an idle formatting pass if one is not already pending."
  (unless org-cite-appear--format-timer
    (let ((buf (current-buffer)))
      (setq org-cite-appear--format-timer
            (run-with-idle-timer
             org-cite-appear-format-inter-cite-delay nil
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (org-cite-appear--format-one)))))))))

(defun org-cite-appear--cancel-format-timer ()
  "Cancel any pending idle format timer."
  (when (timerp org-cite-appear--format-timer)
    (cancel-timer org-cite-appear--format-timer)
    (setq org-cite-appear--format-timer nil)))


;;; ----------------------------------------------------------------
;;; Deferred new-citation folding
;;; ----------------------------------------------------------------

(defun org-cite-appear--schedule-new-cite ()
  "Schedule an idle timer to fold any pending new citations."
  (unless org-cite-appear--new-cite-timer
    (let ((buf (current-buffer)))
      (setq org-cite-appear--new-cite-timer
            (run-with-idle-timer
             org-cite-appear-new-cite-delay nil
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (org-cite-appear--fold-new-cites)))))))))

(defun org-cite-appear--fold-new-cites ()
  "Fold any new citations in `org-cite-appear--new-cite-regions'.
Called by the idle timer.  Scans each recorded line region for a
complete `[cite:...]' span that does not yet have an overlay, and
creates one.  If point is inside the new overlay at the moment it is
created, the citation is left revealed (display nil) so the user is
not abruptly interrupted."
  (setq org-cite-appear--new-cite-timer nil)
  (when org-cite-appear-mode
    (let ((regions org-cite-appear--new-cite-regions))
      (setq org-cite-appear--new-cite-regions nil)
      (dolist (region regions)
        (let ((rbeg (max (point-min) (car region)))
              (rend (min (point-max) (cdr region))))
          (save-excursion
            (goto-char rbeg)
            (while (re-search-forward "\\[cite" rend t)
              (let* ((cite-beg (match-beginning 0))
                     (cite-end (save-excursion
                                 (goto-char (1+ cite-beg))
                                 (org-cite-appear--find-end rend))))
                (when (and cite-end
                           (not (cl-some
                                 (lambda (ov)
                                   (overlay-get ov org-cite-appear--hidden-prop))
                                 (overlays-in cite-beg cite-end))))
                  (let ((ov (org-cite-appear--make-overlay cite-beg cite-end)))
                    (if (and (>= (point) cite-beg) (< (point) cite-end))
                        ;; Point is still inside — reveal silently so the
                        ;; user is not interrupted; rehide fires naturally
                        ;; when they navigate away.
                        (progn
                          (overlay-put ov 'display     nil)
                          (overlay-put ov 'mouse-face  nil)
                          (overlay-put ov 'keymap      nil)
                          (setq org-cite-appear--revealed
                                (list :ov    ov
                                      :range (cons cite-beg cite-end))))
                      (org-cite-appear--schedule-format))))))))))))


;;; ----------------------------------------------------------------
;;; after-change-functions handler
;;; ----------------------------------------------------------------

(defun org-cite-appear--after-change (beg end _old-len)
  "Re-process only citations whose buffer text was directly modified.

Two cases:

1. The change overlaps an existing citation overlay: delete and
   rescan exactly the union of the affected overlay region(s).
   The scan cannot reach neighbouring citations.

2. The change is outside all existing overlays: do not disturb any
   overlay.  Only create a new overlay if the change appears to
   complete a freshly-typed citation (look for an unclosed `[cite'
   opener on the same line).

For deletions `after-change' fires with BEG = END; use (1+ BEG) as
the upper bound for `overlays-in' so that at least one buffer
position is examined."
  (let* ((check-end  (max end (1+ beg)))
         (overlapping
          (cl-remove-if-not
           (lambda (ov) (overlay-get ov org-cite-appear--hidden-prop))
           (overlays-in beg check-end))))
    (if overlapping
        ;; --- Change directly touched existing citation overlay(s) ------
        ;; IMPORTANT: exclude the currently revealed overlay.  When the
        ;; user is actively editing inside a revealed citation its overlay
        ;; must not be deleted and recreated — that destroys `revealed'
        ;; state, causes the snapshot range to become stale, and makes
        ;; post-command-hook immediately re-hide the citation.  The overlay
        ;; stays in place with display=nil; --do-rehide will reformat it
        ;; (reading the updated buffer text) when point eventually exits.
        (let* ((revealed-ov  (and org-cite-appear--revealed
                                  (plist-get org-cite-appear--revealed :ov)))
               (to-rescan    (if revealed-ov
                                 (delq revealed-ov (copy-sequence overlapping))
                               overlapping)))
          (when to-rescan
            (let ((scan-beg (apply #'min beg (mapcar #'overlay-start to-rescan)))
                  (scan-end (apply #'max end (mapcar #'overlay-end to-rescan))))
              (dolist (ov to-rescan)
                (setq org-cite-appear--pending
                      (delq ov org-cite-appear--pending)))
              (org-cite-appear--scan-and-create scan-beg scan-end)
              (org-cite-appear--schedule-format))))
      ;; --- Change is outside all existing citations -------------------
      ;; Only act if the change might complete a new citation: search
      ;; backward from END for an unclosed [cite opener on the same line.
      ;; Do NOT fold immediately — record the line region and let an idle
      ;; timer handle it after `org-cite-appear-new-cite-delay' seconds.
      ;; This gives the user time to add a locator (e.g. ", p. 42") before
      ;; the citation is folded.
      (save-excursion
        (goto-char end)
        (when (search-backward "[cite" (line-beginning-position) t)
          (push (cons (line-beginning-position)
                      (line-end-position))
                org-cite-appear--new-cite-regions)
          (org-cite-appear--schedule-new-cite))))))



;;; ----------------------------------------------------------------
;;; Reveal / re-hide
;;; ----------------------------------------------------------------

(defun org-cite-appear--overlay-at-point ()
  "Return the org-cite-appear overlay at point, or nil."
  (cl-find-if (lambda (ov) (overlay-get ov org-cite-appear--hidden-prop))
              (overlays-at (point))))

(defun org-cite-appear--do-reveal (ov)
  "Reveal the citation covered by OV by removing its display string.
Positions point at the last character of the citation (just before
the closing `]') so the user can immediately edit the citation end
or add a locator without having to navigate there manually."
  (overlay-put ov 'display     nil)
  (overlay-put ov 'mouse-face  nil)
  ;; Remove keymap so RET, C-c C-c etc. fall through to normal Org
  ;; bindings while the raw markup is visible.  Mouse-1 is handled
  ;; via post-command-hook and is unaffected by this.
  (overlay-put ov 'keymap      nil)
  (let ((beg (overlay-start ov))
        (end (overlay-end   ov)))
    (setq org-cite-appear--revealed
          (list :ov ov :range (cons beg end)))
    ;; Place point just before ] — the natural editing position for
    ;; appending a locator, adding another key, etc.
    (goto-char (1- end))))

(defun org-cite-appear--do-rehide ()
  "Re-hide the currently revealed citation."
  (when org-cite-appear--revealed
    (let ((ov (plist-get org-cite-appear--revealed :ov)))
      (when (and (overlayp ov) (overlay-buffer ov))
        ;; Reformat from current buffer text (user may have edited it).
        (overlay-put ov org-cite-appear--needs-format-prop t)
        (org-cite-appear--do-format ov)
        ;; Restore keymap and mouse-face now that citation is folded.
        (overlay-put ov 'keymap     org-cite-appear--overlay-map)
        (overlay-put ov 'mouse-face 'highlight)))
    (setq org-cite-appear--revealed nil)))

;;;###autoload
(defun org-cite-appear-reveal-at-point ()
  "Reveal the org-cite citation at point, if any."
  (interactive)
  (when-let ((ov (org-cite-appear--overlay-at-point)))
    (org-cite-appear--do-reveal ov)))

;;;###autoload
(defun org-cite-appear-edit-in-minibuffer (&optional target-ov)
  "Edit the org-cite citation in the minibuffer.
TARGET-OV, if supplied, is the overlay to edit directly (used by the
mouse-1 path in `org-cite-appear--post-command').  When called
interactively, finds the citation from point or the current revealed
state."
  (interactive)
  (let* ((ov  (or target-ov
                  (org-cite-appear--overlay-at-point)
                  (and org-cite-appear--revealed
                       (plist-get org-cite-appear--revealed :ov))))
         (beg (and ov (overlay-start ov)))
         (end (and ov (overlay-end   ov))))
    (unless (and beg end)
      (user-error "No citation at point"))
    ;; Reveal first so the user can see the raw text in the buffer
    ;; while editing in the minibuffer.
    (org-cite-appear--do-reveal ov)
    (let* ((raw (buffer-substring-no-properties beg end))
           (new (read-string "Edit citation: " raw)))
      (unless (equal new raw)
        (delete-region beg end)
        (goto-char beg)
        (insert new)))))


;;; ----------------------------------------------------------------
;;; pre-command-hook: intercept typing / backspace inside a citation
;;; ----------------------------------------------------------------

(defun org-cite-appear--pre-command ()
  "Reveal and reposition point for typing/backspace inside a citation.
`--do-reveal' already positions point at (1- overlay-end); the
explicit goto-char here is therefore omitted."
  (when (and org-cite-appear-mode
             (derived-mode-p 'org-mode)
             (memq this-command '(self-insert-command
                                  delete-backward-char
                                  backward-delete-char
                                  backward-delete-char-untabify)))
    (when-let ((ov (org-cite-appear--overlay-at-point)))
      (org-cite-appear--do-reveal ov))))


;;; ----------------------------------------------------------------
;;; post-command-hook: re-hide when point leaves
;;; ----------------------------------------------------------------

(defun org-cite-appear--post-command ()
  "Handle post-command duties for org-cite-appear-mode.

1. Re-hide the revealed citation if point has left its region.
   Uses live overlay positions for robustness against marker drift.

2. Fire `org-cite-appear-edit-in-minibuffer' when mouse-1 is clicked
   on a folded citation.  This is handled here rather than via the
   overlay keymap because `[mouse-1]' bindings on overlays with a
   `display' property are unreliable: the click position maps to
   `overlay-start', but `mouse-drag-region' (bound to `down-mouse-1')
   may move point elsewhere before the `mouse-1' keymap lookup fires.
   Inspecting `last-command-event' directly is position-accurate and
   version-agnostic."
  (when (and org-cite-appear-mode
             (derived-mode-p 'org-mode))
    ;; ── 1. Re-hide on exit ──────────────────────────────────────────
    (when org-cite-appear--revealed
      (let* ((ov  (plist-get org-cite-appear--revealed :ov))
             (beg (if (and (overlayp ov) (overlay-buffer ov))
                      (overlay-start ov)
                    (car (plist-get org-cite-appear--revealed :range))))
             (end (if (and (overlayp ov) (overlay-buffer ov))
                      (overlay-end ov)
                    (cdr (plist-get org-cite-appear--revealed :range)))))
        (unless (and (>= (point) beg) (< (point) end))
          (org-cite-appear--do-rehide))))
    ;; ── 2. Mouse-1 on folded citation ───────────────────────────────
    (when (and (not org-cite-appear--revealed)
               (mouse-event-p last-command-event)
               (eq (event-basic-type last-command-event) 'mouse-1))
      (let* ((pos (posn-point (event-start last-command-event)))
             (ov  (when (and pos (number-or-marker-p pos))
                    (cl-find-if
                     (lambda (o)
                       (and (overlay-get o org-cite-appear--hidden-prop)
                            (overlay-get o 'display)))
                     (overlays-at pos)))))
        (when ov
          (org-cite-appear-edit-in-minibuffer ov))))))


;;; ----------------------------------------------------------------
;;; Citar activation suppression
;;; ----------------------------------------------------------------

(defun org-cite-appear--suppress-activate (orig citation)
  "Skip citar activation in org-cite-appear-mode buffers if configured.
ORIG is `citar-org-cite-basic-activate'; CITATION is the org-element."
  (if (and (bound-and-true-p org-cite-appear-mode)
           org-cite-appear-suppress-citar-activation)
      ;; Still stamp font-lock-multiline so jit-lock handles cite spans
      ;; correctly; skip all the expensive per-key property work.
      (pcase-let ((`(,beg . ,end) (org-cite-boundaries citation)))
        (put-text-property beg end 'font-lock-multiline t))
    (funcall orig citation)))

;; Install advice once when citar-org loads; never in mode enable/disable
;; (to avoid the lifecycle bug where removing advice in one buffer strips
;; it globally).
(with-eval-after-load 'citar-org
  (advice-add 'citar-org-cite-basic-activate :around
              #'org-cite-appear--suppress-activate))


;;; ----------------------------------------------------------------
;;; Minor mode
;;; ----------------------------------------------------------------

;;;###autoload
(define-minor-mode org-cite-appear-mode
  "Render org-cite references as formatted display strings, revealing near point.

Each `[cite:@key]' span is replaced by a formatted overlay such as
\"(Smith, 2020)\" or \"(Smith & Jones, 2019, p. 14)\".  The raw markup
is revealed when point is inside the citation and a non-motion command
is issued: RET, C-c C-c, typing, or backspace.

Requires `oc' (org-cite).  Uses citar for bibliographic data when
available; falls back to the raw key when citar is not loaded."
  :lighter " CiteA"
  (if org-cite-appear-mode
      (progn
        (unless (derived-mode-p 'org-mode)
          (user-error "org-cite-appear-mode is only for Org buffers"))
        (setq org-cite-appear--revealed nil)
        ;; Full initial scan.
        (save-restriction
          (widen)
          (org-cite-appear--scan-and-create (point-min) (point-max)))
        ;; Kick off idle formatting.
        (org-cite-appear--schedule-format)
        ;; Hooks: pre-command must run before the command mutates the buffer;
        ;; post-command runs after to check whether to re-hide.
        (add-hook 'pre-command-hook  #'org-cite-appear--pre-command  nil t)
        (add-hook 'post-command-hook #'org-cite-appear--post-command nil t)
        (add-hook 'after-change-functions #'org-cite-appear--after-change nil t))
    ;; ---- disable ----
    (org-cite-appear--cancel-format-timer)
    (when (timerp org-cite-appear--new-cite-timer)
      (cancel-timer org-cite-appear--new-cite-timer))
    (setq org-cite-appear--new-cite-timer   nil
          org-cite-appear--new-cite-regions nil)
    (remove-hook 'after-change-functions #'org-cite-appear--after-change t)
    (remove-hook 'post-command-hook #'org-cite-appear--post-command t)
    (remove-hook 'pre-command-hook  #'org-cite-appear--pre-command  t)
    ;; Re-hide anything currently revealed before tearing down overlays.
    (org-cite-appear--do-rehide)
    (setq org-cite-appear--revealed nil)
    (setq org-cite-appear--pending  nil)
    ;; Remove all our overlays.
    (save-restriction
      (widen)
      (org-cite-appear--delete-overlays-in (point-min) (point-max)))))

(provide 'org-cite-appear)
;;; org-cite-appear.el ends here
