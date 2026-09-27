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

**Pass 3 — Line-break-dependent** (after-fontify; inline, linewise)
Justification, centre alignment, right alignment.  Unlike passes 1–2 which
operate chunkwise, Pass 3 is **linewise**: it expands the jit-lock chunk to
full line boundaries before processing, then walks line by line.

**Chunk expansion rule:** extend `beg` backwards to BOL and `end` forwards to
EOL, but only as far as the text is already fontified — check the `fontified`
text property before extending in either direction.  Drop partial lines at
unfontified boundaries; they will be processed when their own chunk fires and
extends back to BOL.  Re-processing an already-correct line is idempotent
(same inputs, same stamp overwritten).

**Geometry source:** Pass 3 reads margin and indent geometry from the
`line-prefix`/`wrap-prefix` display properties stamped in the buffer by
Pass 2, and measures text widths with `window-text-pixel-size` on live
buffer positions.  Both require the text to be fontified — the `fontified`
expansion check is necessary for face-metric accuracy and for geometry
accuracy equally.  Pass 3 must not derive geometry from the face-extra
registry or local-properties table; those give unresolved values, not the
pixel widths that Pass 2 has computed and stamped.

**NEVER use `string-pixel-width` for any measurement in this codebase.**
It opens a temp buffer and measures with the global default face, completely
ignoring the buffer-local `face-remapping-alist`.  In WP buffers,
`variable-spacing-mode` remaps `default` to a floor font and body text to a
different family altogether; `string-pixel-width` will silently return the
wrong font's metrics.  Always use `window-text-pixel-size` on a live buffer
position in the target window.

**No deferral for centre/right:** these have no feedback loop — a `line-prefix`
alignment spacer shifts text rightward but does not change where lines wrap —
so they run inline and give live visual updates as the user types.

**Justification — deferred decision:** justify mutates interword space widths,
which changes line breaking and risks a jit-lock feedback loop.  Whether
justify should use a deferred execution path (e.g. `jit-lock-register` with
`defer=t`) is an open decision to be made when justify is implemented.
Justify must also clear its old interword-space stamps before re-measuring,
because stale stamps inflate the `window-text-pixel-size` measurement.

**Window resize:** when the window width changes, all Pass 3 stamps are stale.
A `window-size-change-functions` hook must call `font-lock-flush` to trigger
a full re-fontification.

Intra-pass ordering: tab stop geometry must be resolved before justification,
since justification distributes remaining space after tab-consumed space is
accounted for.

**Pass 4 — Page layout** (separate idle-timer pass; not fontification)
Cumulative pixel heights, page breaks, page count.  Like Pass 3, Pass 4 is
**linewise** — it operates on complete lines, not jit-lock chunks.  Runs
after jit-lock has settled for the visible region.  Needs reliable line
heights for all buffer positions including off-screen content; blocked on
the `variable-spacing--spacer` fallback fix.

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
    :pass  1
    :after nil        ; other property symbols in the same pass that must
                      ; run before this one — intra-pass ordering constraint
    :apply (lambda (spans) ...)  ; SPANS is a list of (beg end value) triples
    :clear (lambda (cookie) ...))
  ```

  `face-extra--registry` is a hash table mapping property symbol → plist.
  `:after` may only name properties in the same pass; cross-pass references
  are validated and rejected at registration time.  When a new property is
  registered, the intra-pass order for its bucket is recomputed via
  topological sort.

  The public API for installing a property value on a face:

  ```elisp
  (face-extra-add          face property value) → cookie  ; global
  (face-extra-add-relative face property value) → cookie  ; buffer-local
  (face-extra-remove       cookie)                        ; works for both
  ```

  `face-extra-add` sets the value globally via `(put face property value)`,
  affecting all buffers.  `face-extra-add-relative` writes into
  `face-extra--local-properties` (a buffer-local hash table keyed by
  `(face . property)`), leaving the global symbol property untouched.
  The cookie format encodes which mechanism was used so `face-extra-remove`
  knows how to undo it.  The natural cookie format for symbol-property
  effects is `(FACE PROPERTY OLD-VALUE)`.

  `org-sty-remap` and `variable-spacing` internals use
  `face-extra-add-relative` (buffer-local per-document styling).
  `face-extra-add` is for library-level defaults that should apply in all
  buffers.

  #### Per-face dispatch cache

  The central performance mechanism.  `face-extra--face-cache` is a
  buffer-local hash table:

  ```
  face-symbol →
    { pass1: [(property, value, apply-fn), ...],   ← pre-sorted
      pass2: [...],
      pass3: [...] }
  ```

  Built lazily the first time a face is encountered during a dispatch call.
  Each entry encodes the fully-resolved property values for that face and
  the pre-sorted apply-fn list for each pass.  Resolution order when
  building an entry (mirrors how `face-remapping-alist` relates to global
  face definitions):

  1. `face-extra--local-properties` buffer-local hash table `(face . property) → value`
  2. Global symbol property `(get face property)`
  3. `face-remapping-alist` `:inherit` chain
  4. Global face `:inherit` attribute(s)

  Cycle guard via visited set throughout.  Value 0 at any level means
  explicitly suppressed — stops the search.

  **Cache invalidation:**
  - New property registered → clear entire cache (load-time only, rare)
  - `face-remapping-alist` changes → clear buffer-local cache (happens on
    `org-sty-apply`)
  - `face-extra--local-properties` changes → clear buffer-local cache
  - Global symbol property mutated (via `set-face-attribute` advice) →
    clear entry for that face only

  #### Pass dispatcher

  The after-fontify advice moves from `variable-spacing.el` to
  `face-extra.el`.  On each jit-lock chunk:

  1. Call the active backend's bare-text stamper (pass 0 completion;
     mode-specific — see Backend protocol below).
  2. Scan the region once, building three pass-specific span lists:
     ```
     pass-N-spans: [(beg, end, face, apply-fns), ...]
     ```
     For each face boundary: look up the face in `face-extra--face-cache`
     (populate lazily if absent); append the span to the appropriate
     pass-specific lists.  Faces with no registered properties produce no
     entries — they are never revisited.
  3. Run pass-1-spans, pass-2-spans, pass-3-spans in order.  For each span,
     call each apply-fn in the pre-sorted list.

  Each property's `:apply` function receives `(spans)` — the full list of
  `(beg end value)` triples collected for it across the region — called
  once per dispatch.  This allows batched work (e.g. variable-spacing
  applies all spacers in a single loop).

  **Complexity:** O(region_size) for the scan with O(1) cache lookups; O(applicable_spans ×
  properties_per_face_per_pass) for application.  Properties absent from
  the region incur zero cost.

  `variable-spacing.el` registers its properties via
  `face-extra-define-property` and no longer owns the dispatch loop.

  #### Inheritance (subtask — implement within this work)

  Each registered property's lookup must follow the face remap/inheritance
  chain, consistent with standard Emacs face attribute inheritance.  The
  lookup order is the same as the cache resolution order defined above
  (local-properties → global symbol property → remap :inherit chain →
  global :inherit).

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
  3. Pass registered extra properties to `face-extra-add-relative` (buffer-local;
     per-document styling), storing cookies in `org-sty--face-remap-cookies`
     alongside the existing remap cookies.
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

  #### File and function plan

  **`face-extra.el`** — new; no deps beyond Emacs + cl-lib

  ```
  1. Registry
     face-extra--registry            global hash table:
                                       property-symbol → (:pass :after :apply :clear)
     face-extra-define-property      validates :after are same-pass; re-sorts bucket
     face-extra--validate-after      cross-pass reference check
     face-extra--sort-pass           topological sort within a pass bucket

  2. Per-face cache
     face-extra--local-properties    buffer-local hash table: (face . property) → value
     face-extra--face-cache          buffer-local hash table:
                                       face → { pass1 pass2 pass3: [(prop val apply-fn)...] }
                                       pre-sorted; built lazily
     face-extra--resolve-property    inheritance walker (local → global put →
                                       remap :inherit chain → global :inherit;
                                       cycle guard via visited set)
     face-extra--build-cache-entry
     face-extra--invalidate-cache    clear entire buffer-local cache
     face-extra--invalidate-face     clear single face entry

  3. Public install API
     face-extra-add           (face property value) → cookie   ; global via (put)
     face-extra-add-relative  (face property value) → cookie   ; buffer-local
     face-extra-remove        (cookie)                         ; works for both

  4. Backend protocol
     face-extra--backend-alist       major-mode → backend plist
     face-extra-register-backend
     face-extra--active-backend
     backend key: :stamp-body-text (beg end)

  5. Dispatch
     face-extra--dispatch            after-fontify function:
                                       1. call backend :stamp-body-text (pass 0)
                                       2. scan region once → pass1/2/3-span lists
                                          (face boundary → cache lookup → append;
                                           faces with no properties skipped entirely)
                                       3. run pass1, pass2, pass3 spans in order;
                                          each :apply called once with full (spans) list
     advice on font-lock-fontify-keywords-region
  ```

  **`variable-spacing.el`** — gains `(require 'face-extra)`; loses dispatch
  loop, after-fontify advice, and `variable-spacing-face-remap-add-extra` /
  `remove-extra` (dropped entirely — callers use `face-extra-add-relative`
  and `face-extra-remove` directly)

  ```
  1. Customization
     variable-spacing-floor-height
     variable-spacing-content-faces
     variable-spacing-metadata-faces
     variable-spacing-rules          (kept; element-based config API)

  2. Backend definitions
     variable-spacing-org-backend    (org-element-at-point; Org bare-text stamper)
     variable-spacing-text-backend   (one line per physical line; fallback)
     variable-spacing-mode-backends  (alist for auto-detection)

  3. Text-body face model
     variable-spacing--install-body-remaps
     variable-spacing--remove-body-remaps
     variable-spacing--remove-body-face    (stamp cleanup on mode disable)

  4. Spacer computation
     variable-spacing--spacer              (pixel height from font metrics)
     variable-spacing--apply-ratio         (:apply fn; receives (spans) list)
     variable-spacing--clear-ratio         (:clear fn)

  5. Minor mode
     variable-spacing-mode                 (enable/disable; text-scale-mode advice)

  6. Registration  (load time, after mode is defined)
     (face-extra-define-property 'variable-spacing-ratio ...)
     (face-extra-register-backend 'org-mode variable-spacing-org-backend)
  ```

  **`org-sty.el`** — minor updates only

  ```
  - add (require 'face-extra)
  - org-sty-remap: replace hardcoded :variable-spacing-ratio special case
      with face-extra--registry lookup; registered extra properties →
      face-extra-add-relative; standard face attrs → face-remap-add-relative;
      unknown keys → warn and skip
  - org-sty--clear-face-remaps: 'extra teardown calls face-extra-remove
      directly (no longer goes through variable-spacing wrapper)
  ```

  **`org-title-fold.el`**, **`org-block-appear.el`**, **`org-sty-config.el`**
  — untouched.

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

**Fix `variable-spacing--spacer` off-screen height before implementing
pagination.**  Replace the `frame-char-height` fallback with: effective face
`:height` resolved from `face-remapping-alist` → converted to px via frame
DPI × `variable-spacing-ratio`.  This must work for arbitrary buffer
positions with no window.  Pagination requires reliable cumulative line
heights across the entire buffer, including off-screen content.

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
2. `variable-spacing--spacer` off-screen fix — face metrics + frame DPI,
   no `frame-char-height`
3. Page break overlays — thin separator with header/footer chrome
4. Footnote zone — monolithic overlay first; ephemeral anchors if needed
5. Page background and chrome — desktop colour, page-white overlay, border
6. Pixel-accurate geometry — fringe-based layout, fork/override
   `olivetti-set-window`; prerequisite for print correspondence
