# AGENTS.md — org-sty

## What this repo is

Four independent Emacs Lisp minor modes that form a word-processor visual
layer for Org mode. Each file is self-contained and loadable on its own;
`org-sty` is the only one that `require`s the others.

| File | Purpose |
|---|---|
| `org-sty.el` | Reads `#+FILETAGS`, merges style plists, applies them; provides `org-sty-mode` |
| `variable-spacing.el` | Per-element proportional line spacing via jit-lock |
| `org-title-fold.el` | Folds `#+KEYWORD:` lines below `#+TITLE:` |
| `org-block-appear.el` | Hides `#+begin_`/`#+end_` lines; reveals near point |

## Build / test / lint

- **No build system.** Files are plain `.el`; load with `require` or `load-file`.
- **No test suite yet.** Verify changes by loading the file in a live Emacs
  session (`M-x load-file`) and exercising the affected mode interactively.
- **Byte-compile check:** `emacs --batch -f batch-byte-compile <file>.el`
  is the closest thing to a CI pass. Fix all warnings (not just errors).
- **Lint:** `package-lint` and `checkdoc` are the conventional Emacs Lisp
  linters; run them if available, but they are not enforced by any CI.

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
- **No global side-effects at load time** except the one `advice-add` in
  `org-sty.el` (which is intentional and documented). New global hooks or
  advice must be scoped to the minor mode body (add on enable, remove on
  disable).
- **All new features go through `:eval`**, not new plist keys, unless the
  feature is a genuine primitive that belongs in the style plist itself.

## Architecture constraints

### Long-term file structure

The planned post-v1 dependency graph is:

```
face-extra.el          ← generic core: registry, pass dispatcher, backend protocol
    ↑                       (no deps beyond Emacs + cl-lib)
variable-spacing.el    ← spacing/text-body impl; depends on face-extra; standalone useful
org-title-fold.el      ← standalone; no new deps
org-block-appear.el    ← standalone; no new deps
    ↑
org-sty.el             ← dispatcher
```

Pass 0 (face/font resolution) is the only mode-specific layer.  Passes 1–4
are mode-agnostic — they operate on faces and geometry.  A backend for
another major mode supplies pass 0 knowledge (face configuration + bare-text
predicate) and the rest of the pipeline works unchanged.

### Independence of files
The four files are deliberately decoupled. Do not add cross-`require`
dependencies between `variable-spacing`, `org-title-fold`, or
`org-block-appear`. `org-sty.el` is the only allowed aggregator.

### `:eval` is the extension point
`org-sty` has no knowledge of spacing, folding, or block appearance.
Wiring those modes in is done via `:eval` in the user's style plist, not
by adding new plist keys to the dispatcher.

### Font remap ownership (`org-sty`)
`:font` uses `assq-delete-all` to strip any prior `default` face remap
before installing its own. This is intentional — relative remaps stack and
hook ordering is unreliable. Do not switch this to `face-remap-add-relative`
for `default`; doing so breaks font precedence. Heading faces use
`face-remap-add-relative` with `:family`-only to preserve their
`:height`/`:weight`.

### Pixel spacers, not `line-spacing` (`variable-spacing`)
Spacing is applied as `line-prefix`/`wrap-prefix` display properties with a
`(space :height (Npx))` spec, computed from the live font via `font-at`.
Never replace this with the `line-spacing` variable — it applies uniformly
to all lines, defeating the per-element design.

### jit-lock + deferred initial refresh (`variable-spacing`)
The initial visible-area refresh after mode enable is deferred via
`(run-with-idle-timer 0 ...)`. Do not call `variable-spacing--refresh-visible`
synchronously during a mode hook — window geometry is unsettled at that
point and `window-end` returns a wrong value.

### `text-scale-mode` advice scoping (`variable-spacing`)
The advice on `text-scale-mode` is added/removed inside the minor mode body,
not at file load time. Keep it that way — it must be active only in buffers
where `variable-spacing-mode` is on.

### `org-fold-core` spec is buffer-local (`org-title-fold`)
`org-fold-core--specs` is buffer-local. The fold spec must be registered per
buffer via `org-title-fold--ensure-spec`, not once at file load. The existing
top-level registration is only a best-effort fallback for the current buffer
at load time.

### Fold region starts at `line-end-position` (`org-title-fold`)
The fold `beg` is the newline character at the end of the `#+TITLE:` line
(not the start of the next line). This places the ellipsis at the end of the
title line, matching `org-fold-core`'s drawer convention. Do not change this
to `(line-beginning-position 2)`.

### Custom sentinel property (`org-block-appear`)
The mode uses `org-block-appear--hidden` as a separate sentinel text property
alongside `invisible`. This is intentional — it lets the mode clear exactly
its own spans without touching Org's heading-folding or any other package's
`invisible` uses. Do not collapse this into a plain `invisible`-only check.

### Buffer-local `default` floor (`variable-spacing`)

`variable-spacing-mode` installs a buffer-local remap on `default` to a
small floor height (`variable-spacing-floor-height`, default 60 = 6pt).
This makes `default` the **floor** for metadata/structural elements in that
buffer, while body text opts up via `text-body`.  The global `default` face
is never touched; non-WP buffers are entirely unaffected.

**`frame-char-height` as a fallback is wrong** in buffers where
`variable-spacing-mode` is active, because the buffer-local floor remap
makes it return the small floor value rather than the body text height.
Code that uses `frame-char-height` as a proxy for line height in the current
buffer (notably `variable-spacing--spacer`) will compute incorrect results
for off-screen content.  The correct approach is to read the effective
`:height` from `face-remapping-alist` for the current buffer and convert to
pixels using the frame's pixels-per-point ratio.  Do not add new callers of
`frame-char-height` for font-metric purposes; fix the existing one before
implementing pagination.

### Rendering pipeline — passes and ordering

Visual properties are applied in a fixed sequence of passes.  Dependencies
between properties are shallow and map cleanly onto this sequence; no general
dependency resolver is needed.  (The same fixed-pipeline approach underlies
CSS's style → box-model → layout → paint sequence, which handles a far wider
property vocabulary than ours.)

**Pass 0 — Face/font resolution** (Emacs `face-remapping-alist`; always first)
Font family, size, height.  Resolved automatically by Emacs before any
display properties are consulted.  All subsequent passes may read font metrics
via `font-at` or `face-remapping-alist`.

**Pass 1 — Vertical metrics** (after-fontify; no line-breaking dependency)
Line spacing ratio (`variable-spacing-ratio`), space-before/after paragraphs.
These stamp `line-prefix`/`wrap-prefix` pixel spacers derived from font
metrics.  They affect vertical rhythm but do not need to know where lines
break.  Properties in this pass are independent of each other.

**Pass 2 — Horizontal bounds** (after-fontify; *affects* subsequent
line-breaking)
Left/right margins, first-line indent, hanging indent, tab stops.  These
stamp `line-prefix`/`wrap-prefix` to narrow the available text width.
Intra-pass ordering: margins must be applied before first-line-indent and
tab stops, since the latter are margin-relative.  Note: because these are
applied in the after-fontify pass and the display engine re-breaks lines on
the following render cycle, there is an inherent one-cycle lag between a
margin change and any property in pass 3 seeing the updated line breaks.
This is normally imperceptible.

**Pass 3 — Line-break-dependent** (after-fontify; reads line geometry)
Justification, centre alignment, right alignment.  These need to know where
the display engine broke each visual line and how wide the text is.  They
either read visual line boundaries from the display engine (window-dependent;
same off-screen limitation as `variable-spacing--spacer`) or compute
available-width = window-width − margins directly and measure non-space text
width with `string-pixel-width`.  Intra-pass ordering: tab stop geometry must
be resolved before justification, since justification distributes remaining
space after tab-consumed space is accounted for.

**Pass 4 — Page layout** (separate idle-timer pass; not fontification)
Cumulative pixel heights, page breaks, page count.  Runs after jit-lock has
settled for the visible region.  Needs reliable line heights for all buffer
positions including off-screen content; blocked on the `variable-spacing--spacer`
fallback fix.

**Registry implication:** when the `face-remap-add-extra` API is generalised,
each registered property should declare its pass number.  The after-fontify
dispatcher iterates passes 1–3 in order, running all properties registered
for each pass before moving to the next.

## Known planned work (not yet implemented)

### v1 release

- **~~Rename `org-filetag-style` → `org-sty`~~** — DONE.
- **~~`org-sty-mode` minor mode~~** — DONE.  `org-style-mode` is a
  `defalias`.  Disable body tracks and reverses face remaps and `:eval`-
  activated modes via `org-sty--eval-activated-modes`.
- **Git tag `v1.0-beta`:** Tag the rename commit as `v1.0-beta`.

### `face-extra` branch

- **New file `face-extra.el` — generic synthetic attribute core:**
  Extract and generalise the current `variable-spacing-face-remap-add-extra`
  / `remove-extra` API into a standalone `face-extra.el`.  This becomes the
  foundation for all synthetic face properties — attributes that drive display
  effects not expressible as standard Emacs face attributes.

  #### Registry API

  Properties are registered once at load time:

  ```elisp
  (face-extra-define-property 'variable-spacing-ratio
    :pass 1
    :apply  (lambda (face value) ...)  ; installs the effect, returns a cookie
    :clear  (lambda (cookie) ...))     ; reverses the effect from cookie
  ```

  `face-extra--registry` is an alist mapping property symbol → plist
  (`(:pass N :apply FN :clear FN)`).

  The public API for callers:

  ```elisp
  (face-extra-add  face property value) → cookie
  (face-extra-remove cookie)
  ```

  Each cookie is an opaque value produced by the `:apply` function and
  consumed by `:clear`.  The existing `(FACE PROPERTY OLD-VALUE)` triple
  used by `variable-spacing-face-remap-add-extra` is the natural cookie
  format for symbol-property-based effects.

  #### Pass dispatcher

  The after-fontify advice (currently in `variable-spacing.el`) moves to
  `face-extra.el` and becomes a generic dispatcher:

  1. Call the active backend's bare-text stamper (pass 0 completion;
     mode-specific — see Backend protocol below).
  2. Iterate passes 1, 2, 3 in order.  For each pass, scan the fontified
     region for text positions carrying faces that have registered properties
     at that pass level; call each property's `:apply` function.

  `variable-spacing.el` registers its properties via
  `face-extra-define-property` and no longer owns the dispatch loop.

  #### Inheritance (subtask — implement within this work)

  Each registered property's lookup must follow the face remap/inheritance
  chain, consistent with standard Emacs face attribute inheritance.  Correct
  lookup order (shown for `variable-spacing-ratio`; same pattern for every
  registered property):

  1. Check the direct symbol property (`get face 'property`).  Value 0 = 
     explicitly suppressed (stops the search).
  2. If nil, scan the face's `face-remapping-alist` entry left-to-right;
     for each spec with `:inherit FACE`, recurse into FACE.
  3. If still nil, follow the face's global `:inherit` attribute(s).

  Guard the recursive walker against inheritance cycles with a visited set.
  The lookup must be universal — all faces.

  **Config update required on implementation:** `org-block`, `org-quote`,
  and `org-verse` in `org-sty-config.el` will begin inheriting the
  `text-body` ratio (1.6) through the content-face remap chain.  Add
  `:variable-spacing-ratio 0` to their `:faces` entries to suppress it.

  #### `org-sty-remap` integration

  `org-sty-remap` (in `org-sty.el`) currently has a hardcoded special case
  for `:variable-spacing-ratio`.  After generalisation, it should:

  1. Separate the attrs plist into standard face attributes and registered
     extra properties (check each key against `face-extra--registry`).
  2. Pass standard attrs to `face-remap-add-relative` as before.
  3. Pass registered extra properties to `face-extra-add`, storing the
     returned cookies in `org-sty--face-remap-cookies` alongside the
     existing remap cookies.
  4. Warn and skip unknown keys (keys that are neither standard face
     attributes nor registered extra properties).

  #### Backend protocol (deferred — specify before generalising beyond Org)

  The pass dispatcher needs to call a mode-specific bare-text stamper to
  complete pass 0 for the current major mode.  The backend interface should
  provide at minimum:

  - A bare-text predicate: given a buffer position, is this unattributed
    body text that should receive the `text-body` stamp?  (For Org: no
    `face` or `font-lock-face` present.  For other modes: TBD.)
  - Face configuration: which faces should receive `(:inherit text-body)`
    remaps on mode enable?

  The backend is discovered via a variable (e.g.
  `face-extra-backend-alist`, keyed by major mode symbol).  Specify the
  full protocol before implementing support for any non-Org mode.

- **Text alignment (`text-align` as a synthetic face property):** Left,
  centre, right, and justify, implemented as a symbol property on faces.
  Centre and right require measuring the rendered pixel width of each visual
  line at fontification time (`string-pixel-width`); the measurement drives a
  `line-prefix` `(space :align-to ...)` spec.  Justify stamps `(space :width
  Npx)` on each interword space to fill the line to the window margin.  The
  chicken-and-egg concern (justification changes word spacing, which could
  cause the display engine to re-break lines) is manageable in practice:
  justification only adds space within lines already broken by word-wrap, so
  re-breaking is rare and can be guarded against.  jit-lock's incremental
  invalidation means only edited regions are recalculated.  The open question
  is whether `string-pixel-width` per visual line per fontified chunk is fast
  enough during typing — this warrants an experiment before committing to the
  design.  A natural next synthetic attribute after spacing ratio is fully
  working.

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

## Architecture notes — `text-body` face model

Body-text sizing uses `default` as a true floor (very small, e.g. 6pt);
body text opts in to a larger `text-body` face via two orthogonal mechanisms:

1. **Buffer-local face remaps** (`face-remap-add-relative`): a curated list
   of faces (`variable-spacing-body-faces`) each receive `(:inherit text-body)`
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
   advice): after Org's complete keyword list has run for each jit-lock chunk,
   scans the region for characters with *neither* `face` nor `font-lock-face`
   (plain paragraph text Org leaves bare) and stamps `text-body` on those runs,
   skipping bare `\n` characters.  Stale stamps are cleared before re-stamping
   so that text newly covered by an Org face does not retain a stale stamp.
   The advice targets `font-lock-fontify-keywords-region` (not the outer
   `font-lock-fontify-region`) because that inner function is called with the
   already-extended `[fstart, fend]` bounds that jit-lock marks as clean —
   advising the outer function would miss text covered by region extension.

On mode **disable**: `variable-spacing--remove-body-face` is called over the
full buffer to clean up stamps (which carry no `variable-spacing--prop`
sentinel and so are not caught by `variable-spacing-clear`).

`text-body` `:height` is expressed as a float `2.0` relative to `default`,
so `text-scale-mode`'s float multiplier on `default` propagates through
`text-body` to all content faces correctly.  The floor remap on `default`
remains absolute (`variable-spacing-floor-height`), so metadata elements
stay small regardless of text scale.

### Content and metadata face lists

Two `defcustom` lists govern which faces receive the `text-body` remap
and which are exempt from the after-fontify stamp:

  - **`variable-spacing-content-faces`** — document content: headings,
    body blocks, tables, quotes.  Receive a buffer-local
    `(:inherit text-body)` remap on mode enable.  The after-fontify
    pass also skips them (they are already sized).

  - **`variable-spacing-metadata-faces`** — structural annotations:
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
                         (put 'text-body 'variable-spacing-ratio 1.6)
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

`:variable-spacing-ratio` is not a face attribute and cannot be passed to
`face-remap-add-relative`.  Both `--apply-faces` and `org-sty-remap` strip it
from the attrs plist before calling `face-remap-add-relative`, and route it
instead to `variable-spacing-face-remap-add-extra` (defined in
`variable-spacing.el`), which stores the previous symbol property value as a
cookie so it can be precisely restored on teardown.

If `variable-spacing` is not loaded, `:variable-spacing-ratio` entries are
silently skipped (guarded with `fboundp`), preserving the ability to use
`org-sty` without `variable-spacing`.

#### What stays in `:eval`

`:eval` remains correct for:

  - Enabling/disabling minor modes (`variable-spacing-mode`, `org-title-fold-mode`, etc.)
  - Setting symbol properties not tied to a specific face (`put 'text-body …`)
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
