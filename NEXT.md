# Next session

## Status

- `text-align = center`, `right`, `justify` all implemented and working
  on plain body text.
- Right margin (`horizontal-layout-margin-right`) working on quote blocks.
- Justification is pixel-perfect on body text (Bresenham distribution,
  `window-text-pixel-size` on live buffer positions).

---

## Priority 1 — Justify in margin blocks (quote/verse)

Justify does not yet work correctly inside `org-quote` / `org-verse`
blocks that have both `horizontal-layout-margin-left` and
`horizontal-layout-margin-right` set.  The interaction between the
pass-2 line-prefix narrowing (left+right combined), pass-3 right-margin
restore, and pass-3 justify measurement needs investigation.

Likely cause: `window-text-pixel-size win lbeg lend` inside
`text-align--stamp` may be including the right-margin after-string
overlay at `(1- lend)`, inflating `text-px` and making slack appear
negative.  Alternatively the `zone` calculation (`avail - left - right`)
may not match what word-wrap actually uses after pass-3 restores
`line-prefix` to left-only.

Use `text-align-justify-debug-mode` to instrument: move point to BOL
of a line inside a quote block and read the echo area output.

---

## Priority 2 — Performance: space-width cache

Currently `text-align--stamp` calls `window-text-pixel-size` on the
first collected space once per visual line to get `natural-px`.  This
is already one call per line (not per space), but it can be reduced to
one call per *face combination* per dispatch cycle.

Add a `defvar-local text-align--space-width-cache` hash table keyed by
the raw face value at the space position (symbol, list, or nil).  On a
miss, measure and cache; on a hit, return directly.  Clear the cache at
the top of `text-align--justify-clear` (the `:pre-clear` callback) so
it is rebuilt fresh each dispatch cycle, picking up any font/scale
changes.

This correctly handles superscripts and other face variants — a space
in a superscript run has a smaller natural width than body-text spaces
and must get its own cache entry.  With the cache, all lines in a chunk
that share the same face combination pay zero marginal cost for the
space-width lookup.

## Priority 3 — Performance: idle render-ahead window

`window-text-pixel-size` is called once per justified visual line per
jit-lock chunk.  This dominates scroll performance on long documents
(~26% of jit-lock samples for centering alone; now applying to all body
text lines for justify).

**Fix: incremental idle look-ahead pre-render.**

An idle timer crawls forward from the current viewport frontier,
pre-fontifying and pre-stamping pass-3 properties 2–3 screens at a time:

  1. `(jit-lock-fontify-now frontier-beg frontier-end)` — runs passes 0–2.
  2. `(face-extra--dispatch-pass3 frontier-beg frontier-end)` — runs pass 3.
  3. Advance the frontier; reschedule at next idle.

When the user scrolls into pre-rendered territory, jit-lock finds it
already fontified and does nothing — zero measurement cost at scroll
time.  Short increments keep idle slices brief.

**This is also the prerequisite for pagination.**  The look-ahead pass
and the pagination height accumulator are the same idle pass and should
be designed together.

Also noted: `org-cite-activate` / citar takes ~21% of jit-lock scroll
time independently of our code, producing many face-boundary spans per
citation.  Folding citations behind a single display character would
help; deferred.

---

## Priority 3 — WP rendering test file (ACID3 analogue)

Currently visual testing is done against a chapter of a real
dissertation.  We need a dedicated test file that exercises the full
rendering stack systematically — analogous to ACID3 for browsers.

The `test` filetag in `org-sty-config.el` should activate the full WP
style.  The test file should cover at minimum:

**Text alignment**
- Body text: justify, center, right (one section each)
- Last line of paragraph: must be left-aligned (not stretched)
- Single-word lines, very short lines: must not be over-stretched
- Lines with guillemets, em-dashes, and other wide punctuation
- Mixed-face lines: bold words, italic phrases, inline code — justify
  must measure from buffer not temp buffer

**Margin blocks**
- `#+begin_quote` with justify: correct zone, no overflow
- `#+begin_quote` with center / right
- Nested or adjacent quote blocks
- Quote blocks at start/end of document

**Interaction tests**
- Justify + left margin only (no right)
- Justify + right margin only (no left)
- Justify + both margins
- Center + margins
- Right + margins

**Variable spacing**
- Heading lines (must not be justified — no `text-align` on headings)
- Metadata lines (drawer, keyword, property) — floor face, no stamps
- Code blocks — fixed-pitch, no justify

**Edge cases**
- Empty lines
- Lines containing only a single word
- Very long unbreakable words (URL, etc.)
- End of buffer (no trailing newline)
- `org-block-appear-mode` active: block delimiters hidden

The test file should be self-documenting: each section annotated with
what the expected visual result is, so regressions are immediately
visible.

---

## Deferred / noted

### Hanging punctuation
Commas, periods, closing quotes at visual line-end could hang into the
right margin (optical margin alignment).  Not yet implemented.  Low
priority until performance is resolved.

### `variable-spacing--spacer` off-screen height fix
The `frame-char-height` fallback in `variable-spacing--spacer` returns
the floor size once the global default is shrunk.  Must be fixed before
pagination (requires reliable line-height for arbitrary buffer
positions).

### Right-margin double-subtract bug
Intermittent: when pass-3 re-fires on positions it already restored in
a prior cycle, `combined - right` double-subtracts, collapsing the left
margin to zero.  Left for a dedicated session; the correct fix requires
either a sentinel property or a two-phase walk architecture.

### Pass-3 two-phase walk architecture
`text-align--stamp` for justify calls `vertical-motion` inside the
apply function (documented violation of the "apply must not call
vertical-motion" rule) because the single dispatch walk runs with
right-margin overlays absent.  The clean fix is a two-phase pass-3
walk: run right-margin first (stamps overlays), then walk for
text-align with overlays in place.  Not urgent while justify works in
practice; fix before shipping.
