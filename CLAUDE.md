# Agent documentation — org-sty

## Project purpose

This repo is a visual word-processor layer for Emacs Org mode, built
for writing long-form documents (PhD thesis, books, articles). The goal
is to make Org buffers look and feel like a document editor while
keeping all of Org's structural power.

## Files and responsibilities

| File | Role |
|---|---|
| `org-sty.el` | Dispatch: reads `#+FILETAGS`, merges style plists, applies font/num/indent/olivetti, runs `:eval`; provides `org-sty-mode` |
| `variable-spacing.el` | Proportional line spacing + `text-body` face model via jit-lock |
| `org-title-fold.el` | Folds `#+KEYWORD:` lines below `#+TITLE:` using `org-fold-core` |
| `org-block-appear.el` | Hides `#+begin_`/`#+end_` delimiter lines; reveals near point |
| `org-sty-config.el` | Personal style configuration (not part of the library) |

These are deliberately independent. `org-sty` knows nothing about spacing,
folding, or block appearance. The `:eval` key is the composition point —
users wire the other modes in from there.

## Key design decisions

### org-sty: `:eval` as the extension point

Rather than adding dedicated plist keys for every feature, `org-sty`
provides a generic `:eval` key that runs arbitrary Emacs Lisp after the
built-in keys are applied. New modes are enabled from `:eval`, not from
new keys. This keeps the dispatcher lean and makes it trivially extensible.

### org-sty: font remap ownership

`:font` uses `assq-delete-all` to strip any prior `default` face remap and
install its own as the sole entry. This is intentional: relative remaps
stack, and hook ordering is unreliable, so ownership is the only way to
guarantee the right font wins. Heading faces get a separate `:family`-only
relative remap to preserve their `:height`/`:weight`.

### org-sty: `org-sty-mode` minor mode

`org-sty-mode` is the standard activation mechanism. Its enable body calls
`org-sty-apply`; its disable body calls `org-sty--disable`, which clears all
tracked face remaps and turns off minor modes that were activated by `:eval`.
`org-style-mode` is a `defalias` for readability.

### org-sty: `:faces` and `org-sty-remap`

Face attribute overrides go through `:faces` (declarative alist in the style
plist) or `org-sty-remap` (imperative, for runtime values). Both are
buffer-local and tracked in `org-sty--face-remap-cookies`; all remaps are
reversed on re-apply, making the system idempotent. Bare `set-face-attribute`
calls in `:eval` are an anti-pattern — they are global and never cleaned up.

### variable-spacing: pluggable backend system

`variable-spacing-mode` uses a backend plist to abstract element detection,
making it usable outside Org mode.

**Backend plist keys** (each a function):
- `:element-at-point ()` → opaque element value
- `:element-type (el)` → type symbol
- `:element-begin (el)` / `:element-end (el)` → buffer positions
- `:contents-begin (el)` → position to enter container, or nil
- `:container-p (type)` → whether the type can hold child elements

**Inheritance:** a backend may include `:parent` pointing to another
backend plist. `variable-spacing--backend-get` walks the chain;
`variable-spacing-text-backend` is the ultimate fallback.

**Backend detection:** `variable-spacing-mode-backends` is an alist of
`(major-mode . backend-variable-name)`. On mode enable,
`variable-spacing--detect-backend` walks it with `derived-mode-p` and sets
`variable-spacing-backend` buffer-locally.

**Two bundled backends:**
- `variable-spacing-text-backend` — one `line` element per physical line, no containers
- `variable-spacing-org-backend` — uses `org-element-at-point` (cache-backed)

### variable-spacing: `text-body` face model and floor height

`variable-spacing-mode` installs a buffer-local remap on `default` to a small
floor height (`variable-spacing-floor-height`, default 60 = 6pt), making
`default` the floor for metadata elements. Body text opts up via `text-body`
(height 2.0 relative to `default`, so `text-scale-mode` propagates correctly).

Two mechanisms ensure all content text gets the right size:
1. Buffer-local `(:inherit text-body)` remaps on `variable-spacing-content-faces`
2. An after-fontify pass that stamps `text-body` on bare paragraph text Org leaves unfontified

### variable-spacing: pixel spacers, not line-spacing

Spacing is applied as `line-prefix`/`wrap-prefix` display properties with a
`(space :height (Npx))` spec computed from the live font via `font-at`. Never
replace this with the `line-spacing` variable — it applies uniformly to all
lines, defeating the per-element design.

### variable-spacing: jit-lock + deferred initial refresh

The initial visible-area refresh is deferred with `(run-with-idle-timer 0 ...)`.
Calling it synchronously during `org-mode-hook` produces an unsettled
`window-end` that misses the paragraph at point.

### org-title-fold: fold starts at line-end-position

The fold region's `beg` is `(line-end-position)` of the `#+TITLE:` line (at
the newline character), not the start of the next line. `org-fold-core--specs`
is buffer-local, so the spec must be registered per buffer via `--ensure-spec`.

### org-block-appear: font-lock for hiding, post-command for revealing

Hiding via font-lock means re-hiding after edits is free. A custom sentinel
text property (`org-block-appear--hidden`) lets the mode clear exactly its own
spans without touching Org's heading-folding. Revealing uses a cheap numeric
range check before calling `org-element-at-point`.
