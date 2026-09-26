# Next session — text-align right + justify

## Status

Pass-3 linewise dispatch is working.  `text-align = center` is
implemented and verified:

- `face-extra--dispatch-pass3` is a `jit-lock-register` function that
  does one `vertical-motion` walk per chunk, resolving pass-3 properties
  at each visual-line BOL via the face cache.  O(visual_lines), not
  O(face_boundaries).
- `text-align--stamp-center` uses `window-text-pixel-size` on the live
  buffer (correct face-remapping-alist in scope) and stamps `line-prefix`
  at logical BOL and `wrap-prefix` at continuation visual-line starts,
  giving true per-visual-line centering including wrapped paragraphs.
- `text-align = test-marker` stub (hot-pink midpoint char) is kept in
  the repo as a diagnostic tool.

## Known performance note — pass-3 measurement cost

`window-text-pixel-size` dominates scroll time (~26% of jit-lock
samples) because it forces a layout pass for each newly-visible visual
line.  jit-lock caching already handles the "already-seen" case, so a
content-keyed cache adds nothing — jit-lock simply does not re-fontify
already-fontified regions.

This is acceptable for centering (few lines in a document are centred).
For **justification** the same cost applies per-line and is not
acceptable.

**Window resize:** with olivetti fancy mode (fringe-based desktop), the
text body width is held constant by the fringes — `window-body-width`
(text area) does not change when the window widens above page width.
`available-px` and `text-px` are both unchanged, so centering stamps
remain valid.  No font-lock flush is needed on window resize as long as
the window stays above page width.

**Planned: incremental idle look-ahead pre-render**

An idle timer crawls forward from the current viewport frontier,
pre-fontifying and pre-computing pass-3 stamps 2–3 screens at a time:

  1. `(jit-lock-fontify-now frontier-beg frontier-end)` — runs passes
     0–2 for the look-ahead region.
  2. `(face-extra--dispatch-pass3 frontier-beg frontier-end)` — runs
     pass 3 on the now-fontified region.
  3. Advance the frontier; reschedule.

When the user scrolls into pre-rendered territory, jit-lock finds it
already fontified and does nothing — zero measurement cost at scroll
time.  Crawling in small increments keeps individual idle slices short.
Large jumps (dozens of pages) land on pre-rendered territory more often
as the frontier advances.

**This is also the prerequisite infrastructure for pagination.**
Pagination requires cumulative pixel heights from `point-min` to the
current viewport — the entire document above the visible window must be
measured before page N can be computed.  The look-ahead pre-render and
the pagination height accumulator are the same idle pass and should be
designed together when pagination work begins.

**Planned hybrid measurement approach (for justification in particular):**
1. Quick first pass using `font-get-glyphs` advance widths (fast, ~90%
   accurate, misses mixed-face lines with different font sizes).
2. Deferred refinement via the idle look-ahead using `window-text-pixel-size`
   (accurate).  May produce a brief jitter on mixed-face lines.

**Also noted:** `org-cite-activate` / citar takes ~21% of jit-lock scroll
time independently of our code and produces many face-boundary spans per
citation.  Folding citations behind a single display character (analogous
to `org-appear` hiding emphasis markers) would collapse that span
explosion and reduce `face-extra--collect-spans` cost proportionally.
A prerequisite for correct justification on cite-heavy documents.

## Known performance note — org-cite-activate

`org-cite-activate` / citar takes ~21% of jit-lock scroll time
independently of our code.  It also produces many face-boundary spans
per citation, inflating `face-extra--collect-spans` cost.

**Planned fix (deferred):** fold citations behind a single display
character (analogous to `org-appear` hiding emphasis markers).  This
collapses the face-boundary explosion inside citation spans and reduces
`collect-spans` cost proportionally.  A prerequisite for correct
justification on cite-heavy documents.

## Next work

### Right alignment

`text-align = right`: for each visual line, compute
  offset = available-px - text-px
and stamp `line-prefix` / `wrap-prefix` with `(space :align-to (offset))`.
Same architecture as centre; reuse `text-align--stamp-center` structure.

### Justification

`text-align = justify`: distributes slack across interword spaces.
Mutates character display widths → risks jit-lock feedback loop.

Design decisions still open:
- Whether to use `jit-lock-register` with `defer=t`.
- Must clear old interword-space stamps before re-measuring (stale stamps
  inflate `string-pixel-width`).
- Intra-pass ordering: tab stops must be resolved before justify.
- Last line of a paragraph should NOT be justified (left-aligned).
- Use hybrid font-get-glyphs + idle window-text-pixel-size for measurement.
