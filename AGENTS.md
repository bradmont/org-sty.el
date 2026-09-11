# AGENTS.md — org-filetag-style

## What this repo is

Four independent Emacs Lisp minor modes that form a word-processor visual
layer for Org mode. Each file is self-contained and loadable on its own;
`org-filetag-style` is the only one that `require`s the others.

| File | Purpose |
|---|---|
| `org-filetag-style.el` | Reads `#+FILETAGS`, merges style plists, applies them |
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
  `org-filetag-style.el` (which is intentional and documented). New global
  hooks or advice must be scoped to the minor mode body (add on enable,
  remove on disable).
- **All new features go through `:eval`**, not new plist keys, unless the
  feature is a genuine primitive that belongs in the style plist itself.

## Architecture constraints

### Independence of files
The four files are deliberately decoupled. Do not add cross-`require`
dependencies between `variable-spacing`, `org-title-fold`, or
`org-block-appear`. `org-filetag-style.el` is the only allowed aggregator.

### `:eval` is the extension point
`org-filetag-style` has no knowledge of spacing, folding, or block
appearance. Wiring those modes in is done via `:eval` in the user's style
plist, not by adding new plist keys to the dispatcher.

### Font remap ownership (`org-filetag-style`)
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

### Global small `default` face — the settled model

The frame `default` face is set globally to a small size (the minimum line
height wanted for WP body text, e.g. 6pt). This inverts the usual assumption:
`default` is the **floor**, not the UI baseline.

Every non-WP buffer opts back up to the original size via a buffer-local
`face-remapping-alist` entry for `default`, installed by
`after-change-major-mode-hook`. Existing buffers get the remap applied
retroactively when the feature is first enabled. WP-tagged Org buffers are
exempt — `org-filetag-style--apply-font` already strips any prior `default`
remap with `assq-delete-all` before installing its own `:font-size`, so they
receive whatever size the style plist specifies.

**Chrome faces bypass `face-remapping-alist`.** The header-line, mode-line,
tab-bar, tab-line, and menu faces resolve `:height` at the frame level, not
through any buffer's remap alist. They must be pinned with an explicit
`set-face-attribute` call (to the pre-shrink size) so they no longer fall
through to `default`. Restore their original values (which may be
`unspecified`) on disable.

**The minibuffer** is a real buffer and does receive face remapping, but
`after-change-major-mode-hook` does not fire for it reliably.
`minibuffer-setup-hook` is the correct hook — it fires inside the minibuffer
buffer on every activation, which is when the remap needs to be in effect.

**`frame-char-height` as a fallback is now wrong.** Once `default` is set to
the small floor size, `frame-char-height` returns that small value. Code that
uses it as a proxy for "the body text height in this buffer" (notably
`variable-spacing--spacer`) will compute incorrect results for off-screen
content. The correct approach is to read the effective `:height` from
`face-remapping-alist` for the current buffer and convert to pixels using the
frame's pixels-per-point ratio. Do not add new callers of `frame-char-height`
for font-metric purposes; fix the existing one before implementing pagination.

`test-small-default.el` is a standalone reversible test harness that
validates this model interactively. It is not part of the library.

## Known planned work (not yet implemented)

- **Document portability / style snapshots:** For a genuine WP workflow,
  a document should be viewable identically by another user who does not
  have the same `org-filetag-style-alist` configuration.  A function to
  export or snapshot the fully-resolved style for the current buffer —
  writing it as file-local variables or a portable header block — would
  allow the style to travel with the file.  Not yet designed; note the
  requirement here so the `:faces` / `org-filetag-style-remap` API is
  kept serialisation-friendly.

- **Global `default` face resize — implement as a library feature:** The
  approach has been validated interactively via `test-small-default.el`.
  See that file and the architecture notes below for the full design.
  What remains is lifting it into a proper minor mode in this library.
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

## Branch `text-body-face` — current state

This branch reworks body-text sizing so that `default` is a true floor
(very small, e.g. 6pt) and body text opts in to a larger `text-body` face.

### What is implemented and working

**Two orthogonal mechanisms** give every character the right size:

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

### Known remaining issues

**Newline face propagation** — each `\n` should display at the same height
as the character immediately before it (so inter-paragraph blank lines are
body-sized, but newlines at the end of floor-sized structural lines stay
small).  This was attempted by adding a `search-forward "\n"` loop as a
third pass inside `variable-spacing--after-fontify`, but it caused Emacs to
lock up on mode enable.  The loop fires on every `font-lock-fontify-keywords-
region` call, which is extremely frequent; the approach needs rethinking.
The fix should *not* use a linear character search inside a per-fontification
callback.  One candidate: run the newline pass lazily via a separate
`jit-lock-register`ed function so it is rate-limited by jit-lock's own
scheduling.

**`text-scale-mode` compatibility** — `text-scale-mode` works by adding a
float `:height` multiplier to `default`.  Float multipliers compose
multiplicatively up the remap chain, but our integer heights (`text-body`
`:height 120`, floor remap `:height 60`) are absolute overrides that ignore
the float.  The fix requires expressing both as floats: the floor as
`floor_pt / global_default_pt` computed at mode-enable time, and `text-body`
as a float ratio (body / floor).  This was implemented and reverted because
the interaction with `org-filetag-style--apply-font` (which strips all
`default` remaps via `assq-delete-all` before installing its own) broke the
floor.  The two modules need a coordination protocol before this can land.

**Some faces not fontified correctly** — noted during testing but not yet
diagnosed.  Likely candidates: faces applied by Org constructs not yet in
`variable-spacing-body-faces`, or timing issues with the after-fontify pass
on initial buffer load before the mode is enabled.

### Face-driven spacing — IMPLEMENTED

`variable-spacing-ratio` symbol property (stored with `put`, intercepted
from `set-face-attribute` via `:around` advice) drives the spacing pass.
See the current `variable-spacing.el` for the full implementation.

### `variable-spacing-ratio` inheritance — NOT YET IMPLEMENTED

**Known design gap:** `variable-spacing-ratio` is currently a bare symbol
property and does not follow the face remap/inheritance chain.  This is
inconsistent with how all other face attributes behave: `:inherit` in a
face spec propagates all face attributes, but symbol properties are
completely separate and are never inherited.

**Correct design:** the ratio lookup in `variable-spacing--face-with-ratio`
should follow the `:inherit` key in remap specs recursively, for all
faces.  The correct lookup order is:

  1. Check the direct symbol property on the face (`get face
     'variable-spacing-ratio`).  A value of 0 means "explicitly no
     spacing" and stops the search (analogous to `:slant normal`
     cancelling an inherited slant).  A positive value is used as-is.
  2. If nil (unspecified), scan the face's entry in `face-remapping-alist`
     left-to-right.  For each spec that is a plist with `:inherit FACE`,
     recursively apply this lookup to FACE.
  3. If still nil after exhausting the remap chain, follow the face's
     global `:inherit` attribute(s) the same way.

**Universality:** the lookup must be universal — all faces, not just
content faces.  The reason metadata faces naturally get no spacing is
that their remap chains do not include any face with a ratio set, not
because they are excluded from the lookup.  A user who wants spacing on
a metadata face should be able to get it by setting the ratio explicitly.

**Practical consequence of the current gap:** `text-body` has ratio 1.6
set in WP buffers, but `org-level-N`, `org-quote`, `org-block` etc. do
not inherit it — each face with a ratio must have it set explicitly.
Until this is fixed, the workaround is to `put` the ratio on each face
that should have spacing.  Setting ratio 0 on a face already works to
suppress spacing; the missing piece is propagation of non-nil ratios
through the inheritance chain.

**Implementation note:** `variable-spacing--face-with-ratio` is the
function to update.  It currently uses `cl-some` over face lists and
a direct `get` per face; it needs a recursive remap-chain walker.
Guard against cycles (a face inheriting itself or a loop) with a
visited set.

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

### Per-face styling in org-filetag-style — settled design

The current `org-filetag-style-alist` plist conflates three concerns:

  1. **`default` remaps** (`:font`, `:font-size`) — already handled correctly
     and buffer-locally by `--apply-font`.
  2. **Document-wide mode toggles** (`variable-spacing-mode`, `hl-line-mode`,
     etc.) — handled by `:eval`; idempotent and correct as-is.
  3. **Face attribute overrides** (heading heights, block backgrounds, etc.)
     — currently done via bare `set-face-attribute` calls inside `:eval`,
     which is **global** (not buffer-local), **not tracked**, and therefore
     not cleaned up when the style changes or the buffer is killed.

The goal is to move concern 3 into a first-class, tracked, buffer-local
mechanism.  The design uses two complementary mechanisms that share a single
implementation path.

#### Why `set-face-attribute` in `:eval` is wrong

`set-face-attribute` with `frame = nil` mutates the global face definition.
In a multi-buffer session this means face changes leak across all buffers and
are never reversed when a style is re-applied, a tag is changed, or the
buffer is killed.  `face-remap-add-relative`, by contrast, is buffer-local
and fully reversible via `face-remap-remove-relative`.

#### `org-filetag-style-default` is always the base layer

`org-filetag-style-default` is applied to **every** Org buffer before any
tag-specific style is layered on top.  It is not a fallback for untagged
buffers — it is a permanent base.  Tag styles are additive layers over it,
not replacements for it.  This is an explicit architectural norm, not an
implementation accident.

#### Two mechanisms, one implementation path

**1. `:faces` declarative key**

A `:faces` key in the style plist accepts an alist of `(FACE . ATTRS-PLIST)`
pairs.  It is pure syntax sugar: `--apply-faces` iterates the alist and calls
`org-filetag-style-remap` for each entry.  Example:

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

**2. `org-filetag-style-remap` helper**

For cases requiring runtime values or conditional logic, a public helper is
available for use inside `:eval`:

    (org-filetag-style-remap FACE &rest ATTRS)

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

A single buffer-local list `org-filetag-style--face-remap-cookies` holds all
cookies from both `:faces` and `org-filetag-style-remap` calls.  On each
call to `org-filetag-style-apply`, all cookies are removed via
`face-remap-remove-relative` (and symbol-property side-effects reversed —
see below) before the full style is re-applied.  Re-applying a style is
therefore fully idempotent.

#### `:variable-spacing-ratio` dispatch

`:variable-spacing-ratio` is not a face attribute and cannot be passed to
`face-remap-add-relative`.  Both `--apply-faces` and `org-filetag-style-remap`
strip it from the attrs plist before calling `face-remap-add-relative`, and
route it instead to `variable-spacing-face-remap-add-extra` (defined in
`variable-spacing.el`), which stores the previous symbol property value as a
cookie so it can be precisely restored on teardown.

If `variable-spacing` is not loaded, `:variable-spacing-ratio` entries are
silently skipped (guarded with `fboundp`), preserving the ability to use
`org-filetag-style` without `variable-spacing`.

#### What stays in `:eval`

`:eval` remains correct for:

  - Enabling/disabling minor modes (`variable-spacing-mode`, `org-title-fold-mode`, etc.)
  - Setting symbol properties not tied to a specific face (`put 'text-body …`)
  - Any logic requiring runtime conditions or imperative sequencing

All face attribute changes should go through `:faces` or
`org-filetag-style-remap` so they are tracked and cleaned up correctly.
Bare `set-face-attribute` calls in `:eval` are now an anti-pattern.

## Emacs version requirement

- `org-title-fold` requires Org 9.6+ (`org-fold-core`).
- `variable-spacing` uses `org-element-at-point` with the element cache;
  requires a recent Org (9.5+ for reliable cache behaviour).
- All files use `lexical-binding` and standard `cl-lib`; no Emacs version
  below 27 is supported.
