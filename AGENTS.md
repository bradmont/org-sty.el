# AGENTS.md — org-sty

## What this repo is

A collection of Emacs Lisp packages that form a word-processor visual layer for Org mode.
The packages are independently usable and publishable; `org-sty-config.el` is personal configuration, not a published package.

**Architecture, contracts, and API surfaces are documented in `ARCHITECTURE.org`.** That document is the source of truth for module boundaries, the rendering pipeline, the face-extra lifecycle, measurement rules, and what constitutes an architectural change. Read it before making structural changes.

| File | Purpose |
|---|---|
| `face-extra.el` | Generic synthetic face-property engine: registry, pass dispatcher (passes 0–3), `face-extra-mode`, `face-extra-mode-require`/`release` lifecycle API |
| `body-face.el` | Body-face hierarchy: `defface body`, `body-face-mode`, backend registry, Org backend, body-stamp pass-0 |
| `variable-spacing.el` | Per-element proportional line spacing; depends on `body-face` |
| `horizontal-layout.el` | Left/right margins, hanging indent, text alignment (centre, right, justify); depends on `face-extra` |
| `org-sty.el` | Style dispatcher: reads `#+FILETAGS`, merges style plists, applies them; provides `org-sty-mode`. Depends on `face-extra`, `body-face`; all other package deps optional via `:eval` |
| `org-title-fold.el` | Folds `#+KEYWORD:` lines below `#+TITLE:`; standalone |
| `org-block-appear.el` | Hides `#+begin_`/`#+end_` lines; reveals near point; standalone |
| `org-footnote-extra.el` | Inline paragraph-local footnote rendering; depends on `face-extra`, `body-face`, `horizontal-layout` |
| `org-cite-appear.el` | Hides raw `[cite:@key]` markup behind rendered text; standalone (soft-dep citar) |
| `page-metrics.el` | Physical page geometry (mm/pt/in → px); standalone (soft-dep olivetti) |
| `org-sty-config.el` | **Personal config, not a package.** Wires all modules into a WP style via `org-sty`'s `:eval` key |

## Build / test / lint

- **No build system.** Files are plain `.el`; load with `require` or `load-file`.
- **Test suite:** `test/` contains ERT tests per module. Run all: `bash test/run-tests.sh`. Run one suite: `emacs --batch -L . -l test/test-face-extra.el -f ert-run-tests-batch-and-exit`.
- **Byte-compile check:** `emacs --batch -L . -f batch-byte-compile face-extra.el body-face.el variable-spacing.el horizontal-layout.el org-sty.el org-footnote-extra.el` (adjust file list). Fix all warnings, not just errors. This is the CI pass.
- **Lint:** `package-lint` and `checkdoc` are the conventional Emacs Lisp linters; run them before publishing.

## Code conventions

- **`lexical-binding: t`** is required in every file (already present in all
  four; never remove it).
- **Naming:** `package-name-` prefix for public symbols; `package-name--`
  (double dash) for internal/private ones. Match the pattern already in use
  per file.
- **Prefer `cl-lib` forms** (`cl-loop`, `cl-pushnew`, etc.) over deprecated
  `cl` macros.
- **`defcustom` for user-facing vars**, `defvar-local` for buffer-local
  internal state, `defconst` for fixed values.
- **No global side-effects at load time** except: (1) `face-extra.el` installs `advice-add` on `font-lock-fontify-keywords-region`, `font-lock-ensure`, `window-scroll-functions`, and `window-selection-change-functions` at load time — this is intentional, permanent, and documented; (2) each package's load-time `face-extra-define-property` calls populate the global registry. All other global hooks or advice must be scoped to mode bodies (add on enable, remove on disable).
- **All new features go through `:eval`**, not new plist keys, unless the
  feature is a genuine primitive that belongs in the style plist itself.

## Architecture and contracts

See **`ARCHITECTURE.org`** — the authoritative source of truth for module
boundaries, the rendering pipeline, face-extra property contracts, lifecycle
semantics, measurement rules, and what constitutes an architectural change.
Read it before making any structural change.

## Package refactor history (branch: `package-refactor`)

All six phases complete. Summary of what was done:

- **Phase 1** — Renamed `text-body` → `body` throughout.
- **Phase 2** — Moved body-face machinery out of `variable-spacing.el`.
  Final destination: new standalone `body-face.el` (originally planned for
  `face-extra.el`; split out to keep `face-extra` Org-agnostic).
- **Phase 3** — `face-extra-mode` as `define-minor-mode :interactive nil`
  with `face-extra-mode-require`/`release` ref-counted public API.
  `body-face-mode` in `body-face.el`. Global dispatch advice installed
  permanently at load time. `:pre-clear` → `:before-pass3-walk`;
  `:pre-command` → `:before-keystroke`. `:mode` made a required key on
  all `face-extra-define-property` calls; dispatcher enforces the guard
  centrally, callbacks need no guard of their own.
- **Phase 4** — `variable-spacing.el` stripped to spacing-only; calls
  `(body-face-mode 1/−1)` as a dependency.
- **Phase 5** — `(require 'variable-spacing)` removed from `org-sty.el`;
  `(require 'body-face)` added.
- **Phase 6** — Package headers (`Package-Requires`, `URL`, `Keywords`)
  added to all 10 publishable files.

## Known planned work (not yet implemented)

### ~~⚑ HIGH PRIORITY — Move `text-body` and bare-text scan to `face-extra`~~ — superseded

This work is superseded and significantly expanded by the package refactor plan. See **Package refactor plan** above.

### v1 release

- **~~Rename `org-filetag-style` → `org-sty`~~** — DONE.
- **~~`org-sty-mode` minor mode~~** — DONE.  `org-style-mode` is a
  `defalias`.  Disable body tracks and reverses face remaps and `:eval`-
  activated modes via `org-sty--eval-activated-modes`.
- **Git tag `v1.0-beta`:** Tag the rename commit as `v1.0-beta`.

### ~~`face-extra` branch~~ — DONE (see Package refactor plan)

- **~~New file `face-extra.el` — generic synthetic attribute core~~** — DONE.
  `face-extra.el` is the registry, cache, and dispatch core.  `body-face.el`
  owns body-face machinery and the Org backend.  See Package refactor plan
  for the complete record of design decisions and what landed where.



- **Text alignment (`text-align` as a synthetic face property):** Left,
  centre, right, and justify, implemented as a symbol property on faces.
  Registered at pass 3.  Implementation order: centre first (simplest; used
  to build and validate the linewise Pass 3 infrastructure), then right, then
  justify.

  **Centre alignment** (`text-align = center`): for each visual line, compute
  `offset = (available-px - text-px) / 2` and stamp a `line-prefix`
  `(space :align-to offset-px)` spec at BOL.  `available-px` is derived from
  the window pixel width minus the left and right margin values read from the
  `line-prefix`/`wrap-prefix` display properties stamped by Pass 2.
  `text-px` is measured via `window-text-pixel-size` on the live buffer.
  Re-processing is idempotent (overwrites the same stamp).  Stale stamps from
  a previous window width are cleared by the `window-size-change-functions`
  hook that calls `font-lock-flush`.

  **Pass 0 font-lock keyword (future refactor):** body-text stamping in Pass 0
  is currently done via `:after` advice on `font-lock-fontify-keywords-region`.
  The natural long-term home is a font-lock keyword appended to
  `font-lock-keywords`, which would integrate with Org's own keyword list and
  give guaranteed ordering without advice.  Not a blocker for any current work;
  mark for refactoring after the Pass 3 infrastructure is stable.

  **Justify** (`text-align = justify`): stamps `(space :width Npx)` on each
  interword space to distribute slack across the line.  Unlike centre/right,
  justify mutates character display widths, which risks re-triggering
  line-breaking and a jit-lock feedback loop.  Whether to use a deferred
  execution path (`jit-lock-register` with `defer=t`) is an open decision.
  Justify must clear old interword-space stamps before re-measuring (stale
  stamps inflate `string-pixel-width`).

- **Document portability / style snapshots:** For a genuine WP workflow,
  a document should be viewable identically by another user who does not
  have the same `org-sty-alist` configuration.  A function to export or
  snapshot the fully-resolved style for the current buffer — writing it as
  file-local variables or a portable header block — would allow the style to
  travel with the file.  Not yet designed; note the requirement here so the
  `:faces` / `org-sty-remap` API is kept serialisation-friendly.

- **`variable-spacing--spacer` off-screen height (`variable-spacing`):**
  The `frame-char-height` fallback in `variable-spacing--spacer` will
  return the small floor size once the global default is shrunk.  For
  on-screen content this is masked by the `font-at` path, but it is wrong
  for off-screen content.  This must be fixed — by reading effective
  `:height` from `face-remapping-alist` plus frame DPI rather than from a
  window — before pagination can be implemented correctly.  Pagination
  requires reliable line-height figures for arbitrary buffer positions,
  including content that is not currently displayed in any window.
- **Pagination:** computing cumulative pixel heights over a document to
  support page-break markers and page-count display.  Depends on the
  `variable-spacing--spacer` fallback fix above.
- **Generalising `variable-spacing-mode`** beyond Org via pluggable backends
  is partially done (text backend exists) but not fully exercised outside Org.

- **`raise` and `lower` as synthetic face properties (`face-extra`):**
  Superscript and subscript positioning cannot be expressed as standard Emacs
  face attributes — `:raise` is silently ignored by `face-remap-add-relative`
  and `defface`.  Vertical offset must be applied as a `display` text property
  (`(raise N)`, where N is a float in units of the character's own font
  height).

  Currently `org-footnote-extra` hard-codes `(raise 0.5)` directly on the
  label span.  The right long-term home is a face-extra synthetic property:

  ```elisp
  (face-extra-define-property 'raise
    :pass 1   ; vertical metrics, no line-break dependency
    :apply #'face-extra--apply-raise
    :clear #'face-extra--clear-raise)

  ;; then, in org-footnote-extra--install-styling:
  (face-extra-add-relative 'org-footnote-extra-reference 'raise 0.3)
  ```

  The `:apply` function walks `spans` and calls
  `(put-text-property beg end 'display \`(raise ,value))` on each span.
  `:clear` removes those `display` properties.

  `lower` is syntactic sugar for a negative `raise` value and can share the
  same implementation (`(raise -N)` drops text below the baseline for
  subscripts); expose it as an alias or a separate property that negates its
  value before delegating to `raise`.

  When implemented, both properties should compose cleanly with
  `variable-spacing-ratio` (a raised span in a double-spaced paragraph should
  not inflate the visual line height above the surrounding line rhythm) — this
  may require the `:apply` function to check whether a `line-prefix` spacer
  is already present and leave it undisturbed.

## Pass-3 performance architecture — decisions and known issues

This section records the design decisions made during the justify
performance work so future sessions can reason from a known baseline.

### What the profiler showed (starting point)

Before optimisation, a typical typing profile showed:
- `citar-org-cite-basic-activate` ~28% — citar re-scanned bibliography
  files on every citation activation, twice per cite (once for entry
  lookup, once for format).
- `face-extra--dispatch-pass3` ~29% — full O(paragraph_lines) visual-line
  walk + `window-text-pixel-size` per space on every keystroke, because
  Org's `font-lock-extend-region-functions` extend the jit-lock chunk to
  the full paragraph element before face-extra sees it.

### Optimisations implemented

**Citar activation defer** (`org-sty.el`):
- `citar-org-cite-basic-activate` adviced globally via `with-eval-after-load
  'citar-org` (not in the mode enable/disable body — that caused the advice
  to be removed globally when any one buffer disabled the mode).
- When `org-sty-mode` is active and Emacs is not idle: apply only the cheap
  `org-cite` face; schedule an idle-0 `font-lock-flush` so full activation
  runs the moment typing pauses.
- `citar-org-local-bib-files` adviced to cache the bibliography file list
  per `buffer-chars-modified-tick` — eliminates the `org-collect-keywords`
  `re-search-forward` that was running on every citation activation.

**Pass-3 debounce** (`face-extra.el`, `face-extra--dispatch-pass3`):
- Passes 1–2 (`face-extra--dispatch`): narrowed to point's visual line
  when not idle. Adjacent blocks swept into the jit-lock region by Org
  (e.g. a quote block after the paragraph) are skipped; they keep their
  existing stamps (still correct for unchanged content and faces).
- Pass 3 (`face-extra--dispatch-pass3`): similar point-line narrowing with
  a fast paragraph-final pre-check that avoids `vertical-motion` entirely
  for the common case (typing at end of paragraph):
  1. Point outside chunk → skip.
  2. `end-of-line` + `char-after (1+eol)` = `\n` or EOB → paragraph-final
     logical line → skip without any `vertical-motion` calls.
  3. Otherwise → narrow to visual line with `vertical-motion 0` + `1`.
  4. Visual-final line of a non-final logical line → skip.
- Full-paragraph flush deferred to `face-extra--pass3-flush-delay` seconds
  of idle (default 2.0s). Timer stored in buffer-local var with named
  callback function — avoids per-keystroke closure allocation that was
  driving GC.

**Paragraph-final guard hoisted** (`horizontal-layout.el`,
`text-align--stamp`):
- The `unless (eq (char-after (1- lend)) ?\n)` guard was inside the
  function body AFTER all `let*` bindings including `window-text-pixel-size`.
  Hoisted to a top-level `unless` wrapping the entire function body so
  the guard fires before any measurement or face lookup.

**`lend` clipping removed** (`face-extra.el`):
- The walk loop previously used `(lend (min rend (point)))`. When `rend`
  landed exactly on the `\n`, `(1- lend)` pointed to the last content char
  rather than `\n`, silently disabling the paragraph-final guard.  Changed
  to `(lend (point))` — unclipped — so the guard sees the `\n`.

**Content hash for flush lines** (`horizontal-layout.el`,
`text-align--apply`):
- `text-align--apply` now computes `(sxhash-equal (buffer-substring-no-properties
  lbeg lend))` per visual line before calling `text-align--stamp`.
- If the hash matches the stored `text-align--line-hash-prop` at `lbeg`,
  the line is skipped — existing stamps are still correct.
- If changed: per-line `text-align--justify-clear` (removes stale space
  stamps for clean measurement), then stamp, then store new hash.
- The global `:before-pass3-walk` (formerly `:pre-clear`) was removed from
  the `text-align` registration in favour of this per-line selective clear.  `text-align--justify-clear`
  still clears hash props when called from `text-align-clear` (mode disable
  or re-apply), so font/scale changes correctly invalidate all hashes.

**`line-spans` hash table reuse** (`face-extra.el`):
- Previously `make-hash-table` was called fresh in every pass-3 walk.
  Now a buffer-local `face-extra--line-spans-table` is allocated once and
  `clrhash`ed between walks, eliminating per-walk GC allocation.

**Pre-command hook infrastructure** (`face-extra.el`, `horizontal-layout.el`):
- `face-extra-define-property` has a `:before-keystroke` slot (formerly `:pre-command`).
  `face-extra--pre-command` is added to `pre-command-hook` buffer-locally
  when pass-3 is enabled; it fires only for self-insert and delete commands,
  maintains a cached visual BOL/EOL in `face-extra--vline-beg/end`
  (recomputed via `vertical-motion` only when point leaves the cached range),
  and dispatches to any pass-3 property that registered `:before-keystroke`.
- `face-extra--pass3-force-full`: buffer-local flag consumed by
  `face-extra--dispatch-pass3` on the next jit-lock cycle.  When set,
  the visual-line narrowing is bypassed so `face-extra--expand-to-lines`
  sees the full logical line (= paragraph for soft-wrapped text).  Set by
  overflow handlers to force a full paragraph re-justify.

**Live justify: pre-command stamps + space ring** (`horizontal-layout.el`):
The idle-flush reflow is now complemented by a per-keystroke path that
keeps the line at point justified in real time without any
`window-text-pixel-size` call per keystroke (after the cache warms up).

*Data structures (buffer-local):*
- `text-align--char-width-cache` — `(face . char-code) → pixel-width`.
  Natural space width (`(face . ?\s)`) replaces the old
  `text-align--space-width-cache`, which has been removed.  Cleared on font
  or scale change via `face-extra-invalidate-cache-functions`.
- `text-align--line-natural-px` — running total of natural character widths
  on point's visual line.  `nil` = stale; defers to idle flush.
- `text-align--line-zone-px` — zone width (avail − margins) at last stamp.
- `text-align--space-ring` — list of `(marker . extra-px)` for every
  interword space on point's visual line; built by `text-align--stamp` for
  point's line only.  Invariant: `sum(extra-px) = zone − line-natural-px`.
- `text-align--ring-lbeg` — visual BOL when the ring was built; used to
  detect when point has moved to a different line (stale ring).
- `text-align--ring-cursor-idx` — integer index of the next space to reduce;
  initialised to `remainder − 1` (last long space in the Bresenham
  distribution); advances backward by 1 for each pixel removed, wrapping
  from 0 to `n − 1`.

*Pre-command path (`text-align--pre-command-justify`):*
- When the ring is **warm** (valid for point's line): looks up
  `last-command-event` in the char-width cache.  Cache hit → exact overflow
  check before the character is inserted; on overflow, clears the next
  visual line's stamps and schedules `text-align--post-command-reflow`
  buffer-locally (fires before redisplay).  No-overflow → schedules
  `text-align--post-command-ring-walk`.  Cache miss → uses `?W` width or
  1.5 × space-width as a conservative bound.  Space character → ring is
  stale after insertion (new gap added); invalidate ring and schedule full
  reflow.  Does **not** clear the current line's stamps when the ring is
  warm — the ring-walk re-stamps correctly in post-command.
- When the ring is **stale**: clears the current line's stamps and falls
  back to the avg-based overflow heuristic (1.5 × avg-char-px).

*Post-command ring walk (`text-align--post-command-ring-walk`):*
  One-shot; removes itself, then:
  1. Measures the just-typed character at `(1- (point))` via the cache
     (O(1) hit; one `window-text-pixel-size` call on first encounter).
  2. Increments `line-natural-px` by char-px.
  3. Overflow: invalidate ring, clear next visual line, call
     `text-align--post-command-reflow` directly (same post-command cycle,
     before redisplay).
  4. No overflow: call `text-align--ring-walk` to reclaim char-px pixels of
     slack from the ring.

*Ring walk (`text-align--ring-walk`):*
  Removes 1 px per step, advancing `ring-cursor-idx` backward by 1 on each
  step (wrapping 0 → n−1).  Starting from the last long space and working
  left mirrors the Bresenham stamp direction — the last long space loses its
  extra pixel first, matching what the idle reflow would produce and
  minimising the visual shift when the flush fires.  Updates `display`
  properties in place; spaces that reach `extra-px = 0` have their stamp
  removed.

*Overflow cascade prevention:*
  On near-overflow in pre-command (slack < 1.5 × avg-char-px for the stale
  path, or exact detection for the cache-hit path), the next visual line's
  justify stamps are cleared before the character is inserted.  This prevents
  the wrapping word from landing on expanded spaces and cascading through the
  paragraph.  When overflow is confirmed in post-command ring-walk,
  `text-align--post-command-reflow` triggers a full-paragraph pass-3 walk
  with `face-extra--pass3-force-full` set, firing before redisplay.

### Performance floor

With the above changes, the per-keystroke cost for typing at the end of a
paragraph is approximately:
- Org font-lock (link activation, emphasis, etc.): ~18% of profiler samples.
  This is Org's own baseline cost — irreducible without patching Org.
- `face-extra--dispatch` (passes 1–2 narrow): ~6%.
- Pass-3 narrow path (final line): near-zero (paragraph-final heuristic
  fires before any `vertical-motion`).
- `face-extra--pass3-flush-delay`: 0.05 s (lowered from 0.15 s; faster
  flush is needed to prevent metric drift in the live-justify ring from
  accumulating across keystrokes and causing cascade overflows).
- Ring-walk path (mid-paragraph non-final line): O(char-px) iterations over
  ~5–10 spaces per keystroke; `nth` on a small list.  Effectively free after
  the char-width cache warms up (~80 (face, char) pairs for Latin prose).

The remaining ~6% overhead above Org's baseline is our unavoidable cost.
Turning off `text-align-mode` still shows some lag, meaning passes 1–2
and/or Org keyword activation are the remaining contributors.

### Known remaining issues

**`text-scale-mode` increase breaks justification** (FIXED):
Two-part fix:
1. `variable-spacing--text-scale-refresh`: add `(face-extra--invalidate-cache)'
   which runs `face-extra-invalidate-cache-functions' and fires
   `text-align--clear-char-width-cache' — clearing the char-width cache,
   ring, and natural-px.
2. `text-align--clear-char-width-cache': also remove all
   `text-align--line-hash-prop' from the buffer.  Without this, the content
   hash check in `text-align--apply' sees unchanged buffer text, declares a
   hit, and skips re-stamping — leaving old stamps at the wrong scale even
   after `font-lock-flush' had re-triggered pass 3.

**Heading justification: over-wide spaces and wrong visual-line wrap** (FIXED):
Root cause: `org-hide` (the face Org applies as a `face` text property to
leading heading stars) was absent from `body-face-org-metadata-faces` (formerly `variable-spacing-metadata-faces`).
`body-face--org-explicit-face-p` returned nil for it, so pass 0 stamped `body` on
the star characters.  Pass 3 then saw `body` → `justify` on those
positions and applied justification to the whole heading visual line.

Fix: added `org-hide` to `body-face-org-metadata-faces`.

**Debugging path — for future "something fontifies wrong" bugs:**
When a pass-3 property (e.g. `text-align`) fires on an element where it
shouldn't, the first question is always "why does pass 0 think that position
is bare body text?"  Use `describe-char` on the offending character and check
the `face` text property.  If it contains a face that is absent from both
`body-face-org-content-faces` and `body-face-org-metadata-faces`,
`body-face--org-explicit-face-p` returns nil and pass 0 stamps `body` on it —
which then propagates `text-align`, `variable-spacing-ratio`, and any other
`body`-inherited property to that position.  The fix is to add the face
to the appropriate list.

**Mid-paragraph spacing goes crazy** (UNFIXED, needs diagnosis):
When editing in the middle of a paragraph (not on the final line), spacing
stamps from `variable-spacing-mode` become erratic — line spacing gets very
large or inconsistent.  Suspected cause: the pass-1 spacing stamps for
lines near point are being cleared and re-applied out of sync with the
pass-3 narrow-path walk, possibly because the point-line narrowing in
`face-extra--dispatch` (passes 1–2) clips the spacing pass differently
than what the spacing measurements expect.  Use `text-align-justify-debug-mode`
and instrument `variable-spacing--apply-ratio` to diagnose.

**Right-margin measurement in quote/verse blocks** (UNFIXED):
`window-text-pixel-size` for `text-px` includes the after-string overlay
from the right-margin stamp at `(1- lend)`, inflating the measurement and
making slack negative (justify thinks the line overflows). The right margin
was removed from `org-quote`/`org-verse` as a workaround. The fix requires
measuring text-px BEFORE applying or excluding the right-margin after-string.

**Right-margin double-subtract** (UNFIXED):
Intermittent: pass-3 re-fires on positions it already restored, causing
`combined - right` double-subtraction that collapses the left margin to zero.

**Passes 1–2 lag for non-final lines** (KNOWN, partly addressed):
When editing in the middle of a long paragraph, passes 1–2 still walk
point's full visual line (needed for correct margin/spacing stamps on that
line). The 2 `vertical-motion` calls for visual-line boundary detection are
unavoidable here. No fast logical-line heuristic applies because mid-paragraph
lines are not paragraph-final.

**variable-spacing not applied when an org-cite-appear citation straddles a line break** (UNFIXED, not yet diagnosed):
When an inlined citation rendered by `org-cite-appear-mode` wraps across a
visual line boundary, `variable-spacing` spacing stamps appear to be missing
or incorrect on the line(s) affected by the citation overlay.  Suspected
interaction between the display overlay's contribution to visual-line
geometry and passes 1–2 face resolution, possibly related to the invisible-
region face-lookup fix in `face-extra--dispatch-pass3` (commit 213dfb5) not
covering the passes 1–2 path.  Reproduce by placing a citation near the end
of a long line so it wraps.

**Passes 1–2 not applied to some paragraphs on initial open** (OPEN, root cause unknown):
In large or structurally complex Org buffers (e.g. a file containing both
test-case EXPECT blocks and thousands of lines of body text), some paragraphs
on the first visible screen render without variable-spacing height stamps or
margins, while neighbouring paragraphs render correctly.  The face at
affected positions is correctly `body` (pass-0 runs), but `line-prefix`
is absent (passes 1–2 did not run).  Removing the passes 1–2 narrowing
entirely does not fix it and introduces a regression (justify clears on
focus loss).  The idle-0 refresh that correctly handles simpler files does
not reliably repair the affected paragraphs in the problem case.  Root cause
not yet identified; needs targeted instrumentation of `face-extra--dispatch`
to determine which jit-lock chunks are processed, at what idle state, and
whether the affected paragraphs are ever included in a full-region passes 1–2
run.

**Occasional paragraph spacing not applied during editing** (OBSERVED, not yet diagnosed):
Intermittent: some paragraphs lose their `variable-spacing` height stamps
during normal editing — neighbours render correctly while the affected
paragraph shows no line-prefix spacing.  First noticed after the
`text-align-clean` merge (delete-path ring-walk + underflow detection
commits).  Unclear whether caused by the new pre-clear logic, the
window-end cap in `post-command-reflow`, or the stale-ring discard.
Distinguish from the "initial open" bug below by checking whether the
affected paragraph had stamps before the edit and lost them, vs never
receiving stamps at all.  Needs reproduction steps before diagnosis.

**Footnote definition gap collapses when org-cite-appear expands a citation** (UNFIXED):
When `org-cite-appear-mode` is active and the cursor moves into a footnote
definition that contains a citation, `org-cite-appear` re-renders the citation
from its collapsed `(...)` form to the full inline form.  This re-fontification
fires `--fontify-definitions` again, and the `window-text-pixel-size` call
that computes the gap on `]` appears to run at a moment when the citation
overlay has already altered visual layout — the resulting gap pixel value is
wrong (collapses to near zero).  Additionally, while typing in a footnote
that contains a citation, each keystroke triggers a citation re-render, and
the gap oscillates visibly between correct and collapsed sizes (jitter).

The core issue: `--fontify-definitions` computes the gap during font-lock
fontification using `window-text-pixel-size`, but `org-cite-appear` overlays
change the rendered width of the line at an unpredictable point relative to
when font-lock fires, making the measurement unstable.

Possible approaches:
  1. Move the gap stamp out of the font-lock function and into a pass-2
     face-extra property that runs after `org-cite-appear` has settled
     (i.e. after idle, not inline).  Requires the gap stamp to coexist with
     justify without participating in justify's space ring — the existing
     `(not (get-text-property pos 'display))` guard in the space collector
     already handles this.
  2. Re-run `--fontify-definitions` on the affected line via a post-command
     hook that fires after `org-cite-appear` finishes, so the measurement
     sees the final rendered state.

### Potential next optimisations

- **Skip pass-3 flush for lines unchanged since last justify.** DONE via
  content hash — see above.

- **Idle render-ahead window.** An idle timer crawls the viewport frontier
  and pre-fontifies + pre-stamps content ahead of the visible area so that
  scrolling into new content is instantaneous rather than requiring a
  jit-lock fontification cycle.  Also a prerequisite for the pagination
  height accumulator (Pass 4), which needs reliable cumulative line heights
  for off-screen content.

  **Design:**
  - Register a function on `jit-lock-after-fontify-buffer` (or use a
    dedicated idle timer) that, when Emacs has been idle for a short
    interval (e.g. 0.5 s), identifies the frontier: the first position
    after `window-end` that has `fontified = nil`.
  - Call `jit-lock-fontify-now frontier (+ frontier N)` for a fixed N
    (e.g. 3 × window height in characters).  This drives the full
    font-lock + face-extra pipeline (passes 0–2) for that region.
  - Pass-3 (justify) is NOT pre-applied: the idle flush already handles
    visible content at 0.15 s, and pre-applying justify to off-screen
    content would waste `window-text-pixel-size` calls whose results
    become stale the moment the user scrolls (avail might differ for a
    horizontally-resized window).  Pass-3 fires via the normal jit-lock
    registered path when the content enters the viewport.
  - The render-ahead timer should be lower priority than the pass-3 flush
    (fire at a longer idle delay, e.g. 0.5–1.0 s) so justify on visible
    content always settles first.
  - Cancel and reschedule on `window-scroll-functions` so rapid scrolling
    does not pile up work.

  **Interaction with pagination:** the render-ahead pass populates
  `line-prefix`/`wrap-prefix` spacers for off-screen content.  The Pass-4
  height accumulator can then walk the buffer reading these spacers to
  compute cumulative pixel heights without needing a window.

- **`window-text-pixel-size` cache for text-px.** Cache the whole-line
  text-px measurement keyed by line content hash + face-remapping state.
  Would make the stamp essentially free for unchanged lines even when the
  hash check misses (e.g. after font change).

- **~~Passes 1–2 narrow path: logical-line expansion.~~** DONE — narrowing
  now uses `line-beginning-position`/`line-end-position` instead of
  `vertical-motion`, covering all visual wraps of the logical line and
  fixing missing variable-spacing heights on word-wrapped new lines.

- **`make-hash-table` in `face-extra--collect-spans`.** Each per-keystroke
  pass-1/2 dispatch creates a spans hash table. Reuse the same buffer-local
  table pattern applied to `line-spans`.

- **Org font-lock cost (~18%).** This is Org's own jit-lock keyword work
  (link activation, emphasis, citar activation). The only lever is reducing
  how often the paragraph-level extension fires, or deferring specific
  expensive keywords (e.g. `org-activate-links`) to idle.

- **Cite-block visual replacement (`org-cite-appear-mode`).** Replace the
  raw `[cite:@smith2024]` markup in the buffer display with a rendered
  citation string (e.g. `(Smith, 2024)` or `Smith (2024, p. 5)`), similar
  to how `org-block-appear-mode` hides `#+begin_`/`#+end_` delimiters.

  **Motivation:** two independent benefits:
  1. **WP readability** — the user reads prose, not markup.  Rendered
     citations integrate naturally with surrounding text.
  2. **Face-extra performance** — citar's activator applies faces
     (`mouse-face`, `keymap`, `help-echo`, `org-cite`, `org-cite-key`) with
     different extents per syntactic sub-element, producing O(citation_length)
     face boundaries per cite block.  `face-extra--collect-spans` walks every
     boundary; even though most resolve to empty cache entries (immediate
     skip), the iteration is O(N_cite_chars) per jit-lock cycle.  Replacing
     the markup with a single display overlay makes the entire cite block
     O(1) to face-extra: one span, one cache lookup, one skip.

  **Implementation sketch (`org-cite-appear.el`, new standalone minor mode):**
  - On enable: walk the buffer (and hook into jit-lock) to find all
    `[cite:...]` spans.  For each, place an overlay covering the full span
    with:
    - `display`: the rendered citation string (computed from citar's entry
      data — author last name + year, formatted per document style).
    - `invisible`: the underlying raw text (so the markup is hidden).
    - `org-cite-appear--hidden`: sentinel property (same pattern as
      `org-block-appear`) so the mode can find and remove exactly its own
      overlays on disable.
  - **Near-point reveal:** when point enters a cite overlay, make it
    temporarily visible (remove `invisible`, restore display) so the user
    can see and edit the raw syntax.  Restore on point-exit.  Same
    `post-command-hook` pattern as `org-block-appear-mode`.
  - **Citation format:** configurable via a defcustom or driven by the
    org-sty style plist.  Minimum viable format: `(Author Year)`.  Full
    format with page locators: read from the cite's `:suffix` slot in the
    org-element parse.
  - **citar integration:** use `citar-get-entry` to look up author/year
    from the bibliography.  Cache results per cite key in a buffer-local
    hash table; invalidate on bibliography file change.
  - **Wire-in via `:eval`** in the WP style, not a new plist key.

  **Known remaining face fragmentation (if org-cite-appear not active):**
  The coalesce-empty-spans optimisation in `face-extra--collect-spans` is
  still worth implementing as a fallback: when stepping face boundaries,
  if the next face resolves to an empty cache entry, jump directly to the
  next non-empty boundary via repeated `next-single-property-change` rather
  than processing each character individually.

- **~~Live justify — zero-measurement keystroke path.~~** DONE — see
  "Pre-command hook infrastructure" and "Live justify" in the Optimisations
  implemented section above, and "Known limits" for remaining gaps.

## Architecture notes — `body` face model

> **Ownership note:** `body` (formerly `text-body`) and the bare-text scan loop now live in `body-face.el`.  The move from `variable-spacing.el` is complete.  `defface body` is `'((t :inherit default))` — neutral, no sizing opinion; height is supplied by the style config (`(body . (:height 2.0 :variable-spacing-ratio 1.6))` in `wp-faces`).

Body-text sizing uses `default` as a true floor (very small, e.g. 6pt);
body text opts in to a larger `body` face via two orthogonal mechanisms:

1. **Buffer-local face remaps** (`face-remap-add-relative`): a curated list
   of faces (`body-face-org-content-faces`) each receive `(:inherit body)`
   injected into their effective attribute chain.  Three populations:
   - Heading faces `org-level-1`…`org-level-8` — applied by Org as
     `font-lock-face`; remap is the only way to lift them above the floor.
   - Primitive emphasis faces `bold`, `italic`, `underline` — applied by
     Org's anchor functions directly as `face`; without a remap they would
     fall to the floor.
   - Content block / inline markup faces: `org-quote`, `org-verse`,
     `org-block`, `org-block-begin-line`, `org-block-end-line`, `org-table`,
     `org-formula`, `org-code`, `org-verbatim`, `org-link`, `org-link-id`,
     `org-cite`, `org-cite-key`, `org-footnote`, `org-list-dt`.

2. **After-fontify pass** (`font-lock-fontify-keywords-region` `:after`
   advice, installed permanently by `face-extra.el` at load time): after Org's
   complete keyword list has run for each jit-lock chunk, `body-face--org-stamp-body-text`
   scans the region for characters with *neither* `face` nor `font-lock-face`
   (plain paragraph text Org leaves bare) and stamps `body` on those runs,
   skipping bare `\n` characters.  Stale stamps are cleared before re-stamping
   so that text newly covered by an Org face does not retain a stale stamp.
   The advice targets `font-lock-fontify-keywords-region` (not the outer
   `font-lock-fontify-region`) because that inner function is called with the
   already-extended `[fstart, fend]` bounds that jit-lock marks as clean —
   advising the outer function would miss text covered by region extension.

On `body-face-mode` **disable**: `body-face-remove-body-face` is called over
the full buffer to clean up stamps.

`body` `:height` is expressed as a float `2.0` in the style config (via
`(body . (:height 2.0 :variable-spacing-ratio 1.6))` in `wp-faces`) relative
to `default`, so `text-scale-mode`'s float multiplier on `default` propagates
through `body` to all content faces correctly.  The floor remap on `default`
remains absolute (`variable-spacing-floor-height`), so metadata elements
stay small regardless of text scale.

### Content and metadata face lists

Two `defcustom` lists (now in `body-face.el`) govern which faces receive
the `body` remap and which are exempt from the after-fontify stamp:

  - **`body-face-org-content-faces`** — document content: headings,
    body blocks, tables, quotes.  Receive a buffer-local
    `(:inherit body)` remap on `body-face-mode` enable.  The after-fontify
    pass also skips them (they are already sized).

  - **`body-face-org-metadata-faces`** — structural annotations:
    drawers, property blocks, keyword tags, block delimiter lines.
    Receive no remap.  Also excluded from the stamp so they inherit
    floor size from the `default` remap.

The distinction is functional, not visual: a user may style metadata
faces at any size.  "Metadata" means the element is about the document
rather than part of its readable content.

**`org-document-title` vs `org-document-info-keyword`:** `org-document-title`
is the face for the rendered title value — it is content.
`org-document-info-keyword` is the face for the `#+TITLE:` tag itself — it
is metadata.  Both are handled correctly by their respective lists.

**Per-document customisability:** both lists are `defcustom` values and
can be set buffer-locally via `setq-local` in file-local or dir-local
variables.  This is the intended hook for the document portability /
style-snapshot feature: the snapshot captures and restores these lists
alongside the style plist so that another user's Emacs renders the
document identically without requiring the same global configuration.

### Per-face styling in org-sty

The `org-sty-alist` plist separates three concerns:

  1. **`default` remaps** (`:font`, `:font-size`) — handled buffer-locally
     by `--apply-font`.
  2. **Document-wide mode toggles** (`variable-spacing-mode`, `hl-line-mode`,
     etc.) — handled by `:eval`; idempotent.
  3. **Face attribute overrides** (heading heights, block backgrounds, etc.)
     — handled via `:faces` / `org-sty-remap`; buffer-local, tracked, and
     cleaned up on style change or buffer kill.

#### Why `set-face-attribute` in `:eval` is wrong

`set-face-attribute` with `frame = nil` mutates the global face definition.
In a multi-buffer session this means face changes leak across all buffers and
are never reversed when a style is re-applied, a tag is changed, or the
buffer is killed.  `face-remap-add-relative`, by contrast, is buffer-local
and fully reversible via `face-remap-remove-relative`.

#### `org-sty-default` is always the base layer

`org-sty-default` is applied to **every** Org buffer before any tag-specific
style is layered on top.  It is not a fallback for untagged buffers — it is a
permanent base.  Tag styles are additive layers over it, not replacements for
it.  This is an explicit architectural norm, not an implementation accident.

#### Two mechanisms, one implementation path

**1. `:faces` declarative key**

A `:faces` key in the style plist accepts an alist of `(FACE . ATTRS-PLIST)`
pairs.  It is pure syntax sugar: `--apply-faces` iterates the alist and calls
`org-sty-remap` for each entry.  Example:

    ("thesis" . (:font "Times New Roman" :font-size 12
                 :num-level 3 :indent nil :olivetti-width 68
                 :faces ((org-level-1 . (:height 2.4))
                         (org-level-2 . (:height 2.2))
                         (org-quote   . (:slant italic
                                         :variable-spacing-ratio 1.0)))
                 :eval (progn
                         (variable-spacing-mode 1)
                         (org-title-fold-mode 1))))

**2. `org-sty-remap` helper**

For cases requiring runtime values or conditional logic, a public helper is
available for use inside `:eval`:

    (org-sty-remap FACE &rest ATTRS)

It installs a buffer-local face remap for FACE (handling
`:variable-spacing-ratio` specially — see below) and records the cookie into
the same tracked list as `:faces`.

#### Stacked remaps — Emacs norms apply

Remaps follow the standard Emacs `face-remap-add-relative` stacking model.
The default style's remaps are installed first; tag-style remaps are
installed on top and take priority on attributes they specify.  There is no
deep per-face attribute merge and no nil-out mechanism.  To override an
attribute set by the default style, supply an explicit value in the tag style
(e.g. `:slant normal` to cancel `:slant italic`).  This matches how Emacs
face remapping works everywhere else.

#### Cookie tracking and idempotency

A single buffer-local list `org-sty--face-remap-cookies` holds all cookies
from both `:faces` and `org-sty-remap` calls.  On each call to
`org-sty-apply`, all cookies are removed via `face-remap-remove-relative`
(and symbol-property side-effects reversed — see below) before the full
style is re-applied.  Re-applying a style is therefore fully idempotent.

#### `:variable-spacing-ratio` dispatch

`:variable-spacing-ratio` is not a standard face attribute and cannot be passed to
`face-remap-add-relative`.  Both `--apply-faces` and `org-sty-remap` detect it
via the `face-extra--registry` lookup (it is a registered extra property), strip it
from the attrs plist, and route it to `face-extra-add-relative` (buffer-local),
storing the cookie in `org-sty--face-remap-cookies` alongside the standard remap
cookies.  Teardown calls `face-extra-remove` on those cookies.

If `face-extra` is not loaded (unusual — `org-sty` now requires it), `:variable-spacing-ratio`
entries are silently skipped.

#### What stays in `:eval`

`:eval` remains correct for:

  - Enabling/disabling minor modes (`variable-spacing-mode`, `org-title-fold-mode`, etc.)
  - Any logic requiring runtime conditions or imperative sequencing

All face attribute changes should go through `:faces` or `org-sty-remap` so
they are tracked and cleaned up correctly.  Bare `set-face-attribute` calls
in `:eval` are now an anti-pattern.

## Emacs version requirement

- `org-title-fold` requires Org 9.6+ (`org-fold-core`).
- `variable-spacing` uses `org-element-at-point` with the element cache;
  requires a recent Org (9.5+ for reliable cache behaviour).
- All files use `lexical-binding` and standard `cl-lib`; no Emacs version
  below 27 is supported.

---

## Page layout — design decisions

Decisions recorded from design session. Not yet implemented.

### Physical measurements (`page-metrics.el`)

All user-facing measurements are expressed in **mm, pt, or inches**.  Pixels
are an internal derived quantity.  A new `page-metrics.el` module is the
single source of truth for all physical → pixel conversions; no other module
does raw DPI arithmetic.

```elisp
(page-metrics-mm-to-px mm &optional frame)
(page-metrics-pt-to-px pt &optional frame)   ; face :height = (* 10 pt)
(page-metrics-in-to-px in &optional frame)
(page-metrics-px-to-mm px &optional frame)
(page-metrics-char-width-px &optional frame) ; default face char width in px
```

All functions accept an optional `frame` argument so they work correctly on
multi-monitor setups where DPI varies per display.  Measurements are
recomputed on `move-frame-functions` (monitor change) and
`window-size-change-functions` (geometry change).

**DPI source:** `(/ (display-pixel-width frame) (display-mm-width frame))`.
This is unreliable on X11 (often reports 96 dpi regardless of actual
screen).  A user-overridable `page-metrics-dpi-override` per frame should be
provided so the user can supply the real physical DPI.

**Char-width rounding:** fill-column and character-column measurements are
derived from pixels by dividing by `(frame-char-width frame)`.  All rounding
happens at the conversion boundary inside `page-metrics.el`; internal
calculations stay in pixels as long as possible.

### Page width and wrapping

**Foundation: `olivetti-mode`.**  Olivetti already handles centering a
fixed-width body in the window and degrades gracefully when the window is
narrower than the body.  It is the foundation for page-width control rather
than a replacement.  `page-metrics-apply` feeds Olivetti an integer body
width derived from physical measurements:

```elisp
(setq olivetti-body-width body-cols)
; body-cols = round(body-px / frame-char-width)
; body-px   = body-pt × font-info[2] × 10 / face-default-height-tenths
```

**`text-scale-mode` is handled by Olivetti internally** via
`olivetti-scale-width`, which reads the `:height` factor from
`face-remapping-alist` and scales the pixel body width accordingly.
`page-metrics-apply` does NOT need to be called on text-scale changes;
the integer `olivetti-body-width` stays constant and Olivetti zooms the
page correctly on its own.

**Column round-trip and print correspondence.**  The current approach
converts physical mm → px → integer columns, then Olivetti converts
columns → px again internally (`olivetti-normalize-width` multiplies by
`frame-char-width`).  The `round()` in both directions introduces up to
`frame-char-width / 2` pixels (~4–5 px) of error — acceptable for screen
display but not for pixel-perfect screen/print correspondence.

The correct long-term path is to **bypass the column round-trip entirely**
and drive Olivetti's layout with pixels throughout.  Olivetti's internal
layout already operates in pixels; the only lossy step is `set-window-margins`,
which only accepts integer column counts.  The pixel-precise alternative is
to express all page geometry through **fringes** (`set-window-fringes` takes
integer pixels):

- Outer fringe = desktop colour, sized to centre the page in the window
- Inner fringe = physical page margin (left/right gutter)
- Zero character margins

This eliminates `set-window-margins` entirely.  The body width the display
engine renders into becomes `window-pixel-width − 2×outer-fringe −
2×inner-fringe` in exact pixels, and word-wrap fires at the correct physical
boundary.  Implementing this requires overriding or forking
`olivetti-set-window`; the rest of Olivetti (window-resize hooks, split-window
handling, mode-line) can be reused.

Questions added by user: does emacs have a concept of outer and inner fringes? Will they render as we like, with a different background colour for the "desktop" vs the page "margin"? Alternatively, could we modify the window-margins to use a different width character? Perhaps with a pixel-wise :display property as we're doing for justification padding, or substituting some other space for the frame-char-width space?

### Window narrower than the page

**First choice — revert to non-paginated view.**  When
`window-pixel-width < page-pixel-width` (i.e. Olivetti cannot maintain the
declared body width), pagination is disabled for that window and a
mode-line indicator or message informs the user.  The document remains fully
editable; only the page-break overlay and footnote-zone rendering are
suppressed.  Non-paginated view is the same as the current `variable-spacing`
+ `horizontal-layout` baseline.

**Re-enabling pagination.**  The user controls zoom via `text-scale-mode`
(decreasing zoom reduces the effective pixel width of the body).  After each
`text-scale-mode` change the page-layout layer checks whether the window is
now wide enough for the current body width and, if so, automatically
re-enables pagination without prompting.  The check also fires on
`window-size-change-functions`.

**Second choice — auto-fit zoom.**  If it becomes desirable to stay in
paginated view at all times, zoom can be computed as
`window-pixel-width / page-pixel-width` and applied as a buffer-local face
height multiplier on `default`.  Because scaling is uniform, fill-column in
characters is invariant (the zoom factor cancels in
`text-area-px / char-width-px`), so line breaks do not change.  This is
complex to wire correctly and is deferred until the first choice proves
insufficient.

**Horizontal scroll is not an option.**  Emacs's `word-wrap` always fires at
the window text-area boundary.  There is no mechanism to make it wrap at a
column wider than the window.  `truncate-lines t` removes wrapping entirely
and does not provide a fixed wider wrap point.  This was investigated and
confirmed at the C display-engine level (`it->last_visible_x` in `xdisp.c`).

### Page background and chrome

**Desktop / page separation.**  `default` face is remapped buffer-locally to
the desktop colour (gray).  A low-priority buffer-spanning overlay with
`:extend t` paints the text area page-white.  Fringe face is remapped
buffer-locally to the desktop colour.  Margin areas inherit from `default`
and therefore show the desktop colour without additional work.

**Left border.**  `line-prefix` and `wrap-prefix` are set to a propertized
border character (e.g. `▏`) appearing at the left edge of the text area on
every screen line, including continuations.

**Right border.**  No clean solution: Emacs has no `line-suffix` text
property.  Deferred.  Options when revisited: fringe bitmap at the inner
edge of the right fringe, or per-line `after-string` overlays (expensive).

**Document zoom** is separate from `text-scale-mode`.  `text-scale-mode`
remains the user's accessibility/preference control.  Document zoom is a
multiplier on the style's declared font size, either auto-computed (auto-fit)
or user-pinned (100% view).

### Pagination — prerequisite

~~**Fix `variable-spacing--spacer` off-screen height before implementing
pagination.**  Replace the `frame-char-height` fallback with: effective face
`:height` resolved from `face-remapping-alist` → converted to px via frame
DPI × `variable-spacing-ratio`.  This must work for arbitrary buffer
positions with no window.  Pagination requires reliable cumulative line
heights across the entire buffer, including off-screen content.~~  **DONE.**
`frame-char-height` removed; replaced with `face-font` + `font-info` on
`(selected-frame)` as the fallback frame.  `face-font` is called in the
current buffer's context so it correctly consults the buffer-local
`face-remapping-alist` regardless of whether a live window exists.

### Pass 4 — height cache architecture

Pass 4 is the page-height accumulator: it walks the buffer summing per-line
pixel heights to determine where page breaks fall.  It runs as a **separate
idle-timer pass**, after jit-lock has settled for the region being walked
(passes 1–2 must have stamped `line-prefix` spacers before any line height
is measured).

#### Height source

A logical line's pixel height is derived entirely from text properties
already in the buffer — no window or `window-text-pixel-size` call is needed:

```
line_height_px = spacer_px + char_height_px
```

where `spacer_px` is the `:height` value inside the `line-prefix` display
spec stamped by pass 1, and `char_height_px` is `font-info` index 2 for the
effective face at that position.  Both are readable off-screen.

A multi-visual-line (wrapped) logical line contributes one spacer per
visual sub-line (each visual BOL carries the `line-prefix` stamp), so the
total logical-line height is the sum over all its visual sub-lines.

#### Window resize

The height cache is **not** invalidated on window resize.  Olivetti absorbs
resize events by growing or shrinking its fringes, keeping the text-area body
width constant.  Line wrapping therefore does not change, and all cached
heights remain valid.  (This holds strictly once Olivetti is switched to
pixel-width fringe geometry; with the current char-width margin approach
there is up to `frame-char-width / 2` of rounding error at the body edge,
which is acceptable for now.)

The only resize event that matters to pagination is the window becoming
**narrower than the page** — in that case pagination is disabled entirely
and the buffer falls back to a non-paginated view.  This is a simple
boolean check on each `window-size-change-functions` call; no cache work.

#### Per-line height cache

Per-logical-line pixel heights are stored as a text property
(`page-layout--line-height-px`) at each logical BOL.  `after-change-functions`
clears this property on the affected line(s) — the *only* work done on the
hot path.  Heights are recomputed lazily by Pass 4 when first needed after
invalidation.

Markers are **not** used for per-line storage.  Markers impose O(lines-after-
edit) update cost on every buffer modification.  Text properties shift with
the text at the C level with no per-property overhead.

#### Chunk vector

To avoid O(N) forward-line walking for prefix-sum queries (e.g. "what is
the cumulative pixel height at line 2000?"), logical lines are grouped into
variable-size chunks.  The chunk vector is a buffer-local Lisp vector of
`[marker chunk-height-px]` pairs:

- `marker` — points to the logical BOL of the first line in the chunk.
  Only O(N/K) markers exist (one per chunk, not one per line), so marker
  update overhead is negligible.
- `chunk-height-px` — sum of `page-layout--line-height-px` for all lines
  in this chunk, or `nil` if stale.

**Critical: each entry stores the chunk's own height, not the cumulative
total from the buffer start.**  This makes edit invalidation local: an edit
stales exactly one chunk entry, never any other.

Prefix-sum query for position P:
1. Binary-search the chunk vector by marker position → chunk C containing P.
2. Sum `chunk-height-px` for chunks 0 … C-1 (pure vector arithmetic;
   recompute any `nil` entries encountered by walking that chunk's lines).
3. Walk within chunk C from its marker to P, summing `page-layout--line-height-px`.

Total cost: O(N/K) additions + O(K) `forward-line` calls.  With K = 64 and
N = 10,000: ~220 operations ≈ 70 µs.  With K = 64 and N = 100,000: ~1,630
operations ≈ 0.5 ms.

#### Chunk rebalancing (idle, not on hot path)

`after-change-functions` does **not** restructure the chunk vector.  On a
newline insertion it increments a buffer-local counter
`page-layout--new-lines-since-rechunk`.  When that counter crosses K (the
target chunk size), an idle timer is scheduled to run
`page-layout--rechunk`:

- Walk each chunk from its marker; count lines to the next chunk's marker.
- Any chunk over 2K: insert a new `[marker-at-midpoint nil]` into the
  vector at that position.  New entries are stale (nil); heights are
  recomputed lazily.
- Fragmentation from deletion (many sub-K/4 chunks) is not aggressively
  repaired — it is harmless in practice and can be addressed if profiling
  ever shows it matters.

Chunk vector operations are O(C) where C = N/K ≈ 156 for a 10,000-line
document at K = 64.  This is negligible even as a synchronous operation,
but it stays off the hot path regardless.

#### Visual-line subdivision for mid-paragraph page breaks

When pagination determines a page break falls *within* a wrapped logical
line, it needs the positions of that line's visual sub-line BOLs to place
the break overlay correctly.  `line-move-visual` is called **on demand for
that specific logical line only** — not pre-cached across all wrapped lines.

This keeps the common case (break at a paragraph boundary) entirely free of
`line-move-visual` cost.  The uncommon case (break mid-paragraph) pays for
exactly one paragraph's worth of `line-move-visual` calls per page, which
is acceptable.

#### Idle-timer ordering

Pass 4 must fire *after* jit-lock has settled and passes 1–2 have stamped
`line-prefix` for the region being walked.  The idle delay for Pass 4 should
be strictly greater than the pass-3 flush delay (`face-extra--pass3-flush-delay`,
default 2.0 s) so the full pipeline has settled before page breaks are
recomputed.  A recommended default is 3.0 s idle.

### Page break and footnote zone rendering

**First choice — monolithic overlays + `pixel-scroll-precision-mode`.**
Page breaks are thin overlays (a few display lines) at the break position in
the buffer.  The footnote zone is a single `before-string` overlay containing
all footnote content for that page.  `pixel-scroll-precision-mode` (Emacs
29+) scrolls through large display elements incrementally and resolves the
scroll-jerk issue that monolithic overlays otherwise cause.  This is the
lowest-complexity approach and the correct starting point.

**Second choice — ephemeral anchor characters.**  If `pixel-scroll-precision-mode`
is insufficient (e.g. Emacs < 29, or very dense footnote pages), insert N
characters from the Unicode private-use area (U+E000–U+F8FF) just before the
page break — one per footnote display line.  Each character:

- Has `(display "")` — invisible in the buffer
- Is inserted with `(let ((buffer-undo-list t) (inhibit-modification-hooks t)) ...)`
  so it is absent from undo history and does not trigger Org's change hooks
- Carries a single-line `before-string` overlay with one line of footnote content
- Is marked with an `org-sty-ephemeral` text property

N independent one-line overlays at N distinct buffer positions scroll
smoothly because the display engine handles each as a separate display line.

**Ephemeral characters must never reach disk.**  A `write-file-functions`
hook collects the buffer string, strips all characters bearing the
`org-sty-ephemeral` property, and writes the stripped content to disk,
returning `t` to suppress the normal save.  Autosave is disabled
buffer-locally (`(setq-local auto-save-default nil)`) to avoid the autosave
path bypassing the hook.

Use **non-newline** private-use characters, not `\n`.  Org's parser treats
extra `\n` characters as paragraph separators; private-use characters in a
text run are ignored by Org's structural parser.

**Footnote side window (UX fallback).**  If overlay-based footnote rendering
proves unworkable, a dedicated split window below the body window shows the
current page's footnotes in a separate buffer updated by a
`window-scroll-functions` hook.  This gives correct scrolling performance at
the cost of showing only one page's footnotes at a time, with a visible snap
at page boundaries.

**Child frame per page (long-term / exploratory).**  Each page is a child
frame of fixed pixel dimensions, split into header / body / footnote /
footer windows.  A pool of ~3 frames is recycled as the user scrolls (virtual
scroll view).  Correct scrolling and footnote placement at no overlay cost.
Requires: pagination as a prerequisite, a custom scroll-event model
(replacing Emacs's built-in), and careful focus/input routing.  Not planned
for near-term implementation; noted here so the architecture is not designed
in a way that forecloses it.

### Print correspondence (long-term goal)

The ultimate goal of the page layout system is **pixel-perfect
screen/print correspondence**: a document that looks identical on screen
and on paper, with line breaks, page breaks, and element positions
matching between the two renderings.

This requires two things to be true simultaneously:

1. **Screen geometry is physically accurate.**  The body width in pixels
   must equal `text-area-mm × px/mm` with no rounding error.  The current
   column-based approach introduces up to `frame-char-width / 2` (~4–5 px)
   of error per edge.  The fix is to express all geometry through
   `set-window-fringes` (pixel-accurate) rather than `set-window-margins`
   (column-quantized); see the "Page width and wrapping" section above.

2. **Print output uses the same metrics.**  When printing via
   `ps-print`, `htmlize` + browser, or an Org export backend, the
   rendered widths, spacings, and page breaks must be computed from
   the same physical measurements (`page-metrics-*` vars) that drive
   the screen layout — not re-derived independently from the export
   backend's own defaults.  This means org-sty must either hook into
   the export pipeline to inject the correct page geometry, or produce
   output (e.g. CSS/PostScript) that encodes those measurements
   directly.

These two are independent prerequisites: screen accuracy can be
implemented without touching export, and export integration does not
require screen accuracy.  Both are long-term work; neither is planned
for the near term.  Do not design the `page-metrics` API in a way that
forecloses either path — keep physical measurements as first-class
values rather than deriving everything through Emacs pixel coordinates.

### Implementation order

1. ~~`page-metrics.el` — physical unit conversions, font-metric px/pt~~  DONE
2. ~~`variable-spacing--spacer` off-screen fix — `face-font` + `font-info`
   on `selected-frame`; no `frame-char-height`~~  DONE
3. Pass 4 height cache (`page-layout.el`) — per-line text-property cache,
   chunk vector with markers + chunk totals, idle rechunking, idle-timer
   pagination driver; see "Pass 4 — height cache architecture" above
4. Page break overlays — thin separator with header/footer chrome
5. Footnote zone — monolithic overlay first; ephemeral anchors if needed
6. Page background and chrome — desktop colour, page-white overlay, border
7. Pixel-accurate geometry — fringe-based layout, fork/override
   `olivetti-set-window`; prerequisite for print correspondence

---

## Bug log

A permanent record of confirmed bugs, their root causes, and fixes.
Entries are never removed — they document patterns that have caused
regressions before and may do so again.

### `org-footnote-extra`: footnote gap jitters on every keystroke while typing in a definition

**Symptom:** When typing inside a named footnote definition, the
pixel-space gap between the superscript label and the body text
alternates between the correct wide value and near-zero on every
keystroke.  The jitter also causes the last word of the first visual
line to flow onto a second visual line and back on alternating
keystrokes (the correct gap is wide enough to push the word off; the
collapsed gap is not).

**File:** `org-footnote-extra.el` —
`org-footnote-extra--fontify-definitions`

**Root cause:** The `label-px` measurement used to compute the gap width
was `(window-text-pixel-size win pfx-beg sfx-end)`, where `sfx-end` is
the position *after* the `]` character.  The `]` character
(`sfx-beg..sfx-end`) carries the gap stamp `(space :width (gap-px))`
from the previous font-lock run.  Font-lock does not clear `display`
text properties between runs, so on every re-fontification (triggered
by `font-lock-multiline` covering the whole definition block) the
old gap stamp is included in `label-px`:

```
label-px  = 0 (hidden [fn:)  +  label_render_px  +  old_gap_px
new_gap   = hang_px − label_render_px − old_gap_px
```

With the correct `old_gap_px = hang_px − label_render_px − bracket_px`
(where `bracket_px` is the natural `]` glyph width, ~5 px):

```
new_gap = bracket_px            ← collapses to ~5 px
```

The following run finds `old_gap_px = bracket_px`, so:

```
new_gap = hang_px − label_render_px − bracket_px   ← correct again
```

This produces a perfect every-keystroke alternation between the correct
gap and a near-zero gap.

**Fix:** Change the end bound of the `window-text-pixel-size` call from
`sfx-end` to `sfx-beg`, excluding `]` from the measurement.  The range
then covers only the hidden `[fn:` prefix (0 px) and the raised label
glyph, which is stable across re-fontifications regardless of what
`display` property `]` carries.

```elisp
;; Before (buggy — includes old gap stamp on `]' in label-px):
(label-px (car (window-text-pixel-size win pfx-beg sfx-end)))
;; After (fixed — excludes `]' entirely):
(label-px (car (window-text-pixel-size win pfx-beg sfx-beg)))
```

**General pattern:** Any font-lock matcher that (a) writes a
`display` property derived from a `window-text-pixel-size` measurement
and (b) measures a range that includes the character it is about to
stamp will produce this alternating-collapse bug.  The fix is always
to exclude the target character from the measurement range, or to
temporarily remove the old stamp before measuring.

---

### Bug: org-quote/verse/block and org-footnote spurious spacing and missing italics (fixed `8c4451a`)

**Symptoms:** In WP Org buffers, `org-quote`, `org-verse`, `org-block`,
and `org-footnote` text received unwanted `line-prefix` height stamps from
`variable-spacing`.  `org-quote`/`org-verse` text was not italic despite
`:slant italic` being declared in the style.

**Root cause 1 — Stale `.elc` shadowing `.el`.**  A compiled bytecode
file was newer than the source, so every `load-file` / `require` loaded
the old committed bytecode.  All config changes were silently ignored.
Symptom: `org-sty--face-remap-cookies` matched exactly the committed
`wp-faces` (15 entries) regardless of what the source said.  Fix: delete
`.elc` files; never commit compiled bytecode for actively edited config.

**Root cause 2 — `org-sty-default :faces` clobbered by shallow merge.**
`org-sty--merge` replaces the `:faces` key wholesale with the override
style's `:faces`.  Suppressors and `:slant italic` entries placed in
`org-sty-default :faces` were silently dropped whenever a WP tag style
was active.  Fix: move all WP-specific face attributes (body ratio,
org-quote/verse slant, suppressors) into `wp-faces` and `wp-eval` where
they survive the merge.

**Root cause 3 — Suppressor timing: `:faces` runs after first
fontification.**  `(variable-spacing-mode 1)` in `:eval` may trigger a
jit-lock cycle before `:faces` runs.  The face-extra cache is built at
that moment without the `:variable-spacing-ratio 0` suppressors for
`org-quote`, `org-verse`, and `org-block`.  `variable-spacing--apply-ratio`
stamps spacers at that point.  Its span-only clear loop never touches
positions in the suppressed set, so those stamps persist even after `:faces`
installs the suppressors.  Fix: install suppressors via `org-sty-remap`
in `:eval` **before** `(variable-spacing-mode 1)`.

**Root cause 4 — `org-footnote-extra-mode` hard-coding ratio 1.0.**
`org-footnote-extra--install-styling` called
`(face-extra-add-relative 'org-footnote 'variable-spacing-ratio 1.0)`.
If the mode ran after `org-sty-apply` (e.g. later in `org-mode-hook`),
it silently overwrote the `:faces` suppressor (ratio 0) that had just
been installed.  Fix: remove the ratio from `--install-styling` entirely.
Spacing policy belongs in the style config (`wp-faces`), not in the mode.
The `:variable-spacing-ratio 0` suppressor in `wp-faces` is still required
because `org-footnote-extra-mode` installs `(:inherit body)` on
`org-footnote`, which would otherwise let ratio 1.6 flow through from
`body`.  Also added `org-footnote-extra-mode 1` to `wp-eval` and
`org-footnote-extra-mode` to `org-sty--known-eval-modes` for clean teardown.

**Diagnostic pattern — when cookies are missing from `org-sty--face-remap-cookies`:**
Evaluate `(mapcar #'car org-sty--face-remap-cookies)` immediately after
`org-sty-apply`.  The list should contain one entry per `:faces` and `:eval`
`org-sty-remap` call.  If entries are missing, cross-reference against the
*committed* `org-sty-alist` (not the source file) — a stale `.elc` will
cause the in-memory alist to match the bytecode, not the edited `.el`.
Check with `(seq-take (plist-get (cdr (car org-sty-alist)) :faces) 3)` to
confirm the live alist reflects the current source.

---

### Bug: `frame-char-width` used as a proxy for face character width in pixel calculations

**Symptoms (recurring pattern):** Any calculation that multiplies a
margin or spacing value (in canonical character widths) by
`(frame-char-width)` to obtain pixels produces wrong results in WP
buffers.  Manifested as:
- Right-margin step 1 writing `wrap-prefix: (space :width 36)` instead
  of `4` at visual-continuation-line BOLs — causing ~45% indentation on
  wrapped lines in `org-quote` blocks.
- `variable-spacing--spacer` returning wrong spacer heights for
  off-screen content (the `frame-char-height` analogue of the same bug;
  now fixed separately).
- `text-align--stamp` computing incorrect `zone` offsets for center/right
  alignment when margins are expressed as face-character-width multiples.

**Root cause:** `(frame-char-width)` returns the pixel width of a
character in the **frame's default font** — the global default face, not
the buffer-local remapped one.  In WP buffers, `variable-spacing-mode`
installs a buffer-local remap on `default` to a small floor face
(e.g. Iosevka Aile 6pt, ~4–5 px/char).  Body text and quote-block text
use `body` → Times New Roman 12pt (~8–9 px/char).  `frame-char-width`
returns the floor font's width, which is roughly half the body font's width.

When a `(space :width N)` display spec is evaluated by the display engine,
`N` (if an integer) means N times the width of a space character **in the
face active at that buffer position** — not N times `frame-char-width`.
So the same integer `N = 4` produces ~36 px in org-quote context (4 × 9 px)
but only ~20 px from `frame-char-width × 4` (4 × 5 px).  The two values
are incommensurable, and mixing them corrupts any arithmetic that tries to
compute slack, offsets, or zone widths.

**General rule:** Never use `frame-char-width` (or `frame-char-height`) as
a pixel-conversion factor for a value that will be stored in or compared
against a `(space :width N)` display spec.  The two live in different unit
systems.

**Correct approaches by use case:**

- **Storing a margin/prefix as a display spec** — use the raw configured
  value (integer number of character widths) directly as `N` in
  `(space :width N)`.  Let the display engine convert using the face's own
  font at render time.  This is what pass 2 (`--apply-margin-right-pass2`)
  does correctly.

- **Pixel arithmetic for alignment offsets** (`:align-to (Npx)`) — resolve
  actual pixel widths via `window-text-pixel-size` on a live buffer position
  with the correct face in context.  `frame-char-width × N` is wrong; use
  the measurement.

- **Justify zone/slack calculation** — do not subtract margins from the
  zone using `frame-char-width × N`.  Instead, ensure the measurement
  (`window-text-pixel-size`) includes the margin display specs (via the
  line-prefix/wrap-prefix and after-string overlay) so that margins cancel
  naturally: `slack = avail − text-px` where `text-px` already includes
  both left and right margin visual widths in the face's own units.

- **Detecting whether a line is "full"** (overflow guard) — measure in
  pixels via `window-text-pixel-size`; never compare character-width values
  to pixel values without a face-aware conversion.

**Fix applied (right-margin pass 3):** Removed `(* (frame-char-width) ...)`
from step 1 of `--apply-margin-right-pass3`, which restores `wrap-prefix` to
left-only at the visual-line BOL.  The raw configured value is used directly,
matching the unit pass 2 stored.  Additionally, the `has-align` suppression
of the right-margin after-string was narrowed to center/right only: for
justify, the after-string must be present during `window-text-pixel-size`
measurement so `text-px = left + body + right` (all in face-character-width
units), giving `slack = underfill` with no unit-system mixing.
