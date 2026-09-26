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
content-keyed cache adds nothing.

This is acceptable for centering (few lines in a document are centred).
For **justification** the same cost applies per-line and is not
acceptable.

**Planned hybrid approach (deferred):**
1. Quick first pass using `font-get-glyphs` advance widths (fast, ~90%
   accurate, misses mixed-face lines with different font sizes).
2. Deferred second pass via idle timer using `window-text-pixel-size`
   (accurate).  May produce a brief jitter on mixed-face lines.

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
