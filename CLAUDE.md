# Agent documentation — org-filetag-style

## Project purpose

This repo is a visual word-processor layer for Emacs Org mode, built
for writing long-form documents (PhD thesis, books, articles). The goal
is to make Org buffers look and feel like a document editor while
keeping all of Org's structural power. It is a work in progress; new
pieces are added incrementally.

## Files and responsibilities

| File | Role |
|---|---|
| `org-filetag-style.el` | Dispatch: reads `#+FILETAGS`, merges style plists, applies font/num/indent/olivetti, runs `:eval` |
| `variable-spacing.el` | Proportional paragraph line spacing via jit-lock |
| `org-title-fold.el` | Folds `#+KEYWORD:` lines below `#+TITLE:` using `org-fold-core` |
| `org-block-appear.el` | Hides `#+begin_`/`#+end_` delimiter lines; reveals near point |

These are deliberately independent. `org-filetag-style` knows nothing
about spacing, folding, or block appearance. The `:eval` key is the
composition point — users wire the other modes in from there.

## Key design decisions

### org-filetag-style: `:eval` as the extension point

Rather than adding dedicated plist keys for every feature (line spacing,
block hiding, title folding, etc.), `org-filetag-style` provides a
generic `:eval` key that runs arbitrary Emacs Lisp after the built-in
keys are applied. New modes are enabled from `:eval`, not from new keys.
This keeps the dispatcher lean and makes it trivially extensible.

### org-filetag-style: font remap ownership

`:font` uses `assq-delete-all` to strip any prior `default` face remap
and install its own as the sole entry. This is intentional: relative
remaps stack, and hook ordering is unreliable, so ownership is the only
way to guarantee the right font wins. Heading faces get a separate
`:family`-only relative remap to preserve their `:height`/`:weight`.

### variable-spacing: pluggable backend system

`variable-spacing-mode` uses a backend plist to abstract element
detection, making it usable outside Org mode.

**Backend plist keys** (each a function):
- `:element-at-point ()` → opaque element value
- `:element-type (el)` → type symbol
- `:element-begin (el)` / `:element-end (el)` → buffer positions
- `:contents-begin (el)` → position to enter container, or nil
- `:container-p (type)` → whether the type can hold child elements

**Inheritance:** a backend may include `:parent` pointing to another
backend plist. `variable-spacing--backend-get` walks the chain;
`variable-spacing-text-backend` is the ultimate fallback. This allows
partial backends that override only specific functions.

**Backend detection:** `variable-spacing-mode-backends` is an alist of
`(major-mode . backend-variable-name)`. On mode enable,
`variable-spacing--detect-backend` walks it with `derived-mode-p` and
sets `variable-spacing-backend` buffer-locally.

**Two bundled backends:**
- `variable-spacing-text-backend` — one `line` element per physical line, no containers, works anywhere
- `variable-spacing-org-backend` — uses `org-element-at-point` (cache-backed); `org-element-greater-elements` as the container predicate

### variable-spacing: per-type rules plist

`variable-spacing-rules` is a buffer-local plist mapping element type
symbols to ratios, e.g. `'(paragraph 1.6  item 1.2  src-block nil)`.

**Walk-based application:** `variable-spacing-apply` walks forward using
the backend's `:element-at-point`. For each element:

- **In plist with positive ratio** → apply ratio, jump past (parent wins)
- **In plist with nil** → jump past (explicit exclude; children skipped)
- **Absent, container type** → enter transparently via `:contents-begin`
- **Absent, non-container** → jump past

**Parent wins** is structural: once a plist type is encountered, the
walker jumps past it entirely. No `org-element-lineage` check needed.

**`org-element-greater-elements`** is the container discriminator in the
org backend. Non-greater types (`src-block`, `verse-block`, `table-row`,
etc.) are jumped past automatically when absent from the plist.

### variable-spacing: pixel spacers, not line-spacing

`line-spacing` applies uniformly to every line. The word-processor
effect requires structured elements (code blocks, tables, drawers) to
stay at normal line height while prose paragraphs get extra space. The
implementation uses `line-prefix`/`wrap-prefix` display properties set
to a `(space :height (Npx))` spec, which only affects the lines they
are applied to. The pixel height is computed from the live rendered font
via `font-at` so it responds correctly to `text-scale-mode`.

### variable-spacing: jit-lock + deferred initial refresh

Spacing is applied lazily via jit-lock so large files (e.g. a full PhD
thesis) aren't blocked on open. The initial visible-area refresh is
deferred with `(run-with-idle-timer 0 ...)` — calling it synchronously
during `org-mode-hook` produces an unsettled `window-end` that misses
the paragraph at point, after which jit-lock never re-visits it.

### variable-spacing: text-scale-mode advice

`text-scale-mode` is advised (not `text-scale-set`) because
`text-scale-increase`/`decrease` toggle the mode off and on, making
`text-scale-mode` the right interception point. The advice clears stale
pixel-height spacers and re-applies to the visible range, since merely
clearing text properties does not trigger jit-lock refontification.

The advice is added/removed inside the minor mode body, not at file
load time, so it is scoped to buffers where the mode is active.

### org-title-fold: fold starts at line-end-position

The fold region's `beg` is `(line-end-position)` of the `#+TITLE:` line
(at the newline character), not the start of the next line. This matches
`org-fold-core`'s drawer convention and causes the ellipsis to appear at
the end of the `#+TITLE:` line rather than on the line below.

`org-fold-core--specs` is buffer-local, so the spec must be registered
in each buffer via `--ensure-spec`, not just once at load time.

### org-block-appear: font-lock for hiding, post-command for revealing

Hiding via font-lock means re-hiding after edits is free — font-lock
already re-fontifies changed regions. A custom sentinel text property
(`org-block-appear--hidden`) is used alongside `invisible` so the mode
can clear exactly its own spans without touching Org's own
heading-folding or any other package's `invisible` uses.

Revealing uses a two-level check: a cheap numeric range comparison first
(is point still in the same block as last time?), and only if point has
left the range does it call `org-element-at-point`. This keeps
per-keystroke cost negligible.

## Emacs line-height constraint (not yet addressed)

Emacs enforces a minimum line height equal to the frame's `default`
face. When a large body font is in use, this forces UI elements
(minibuffer, mode line, header line, tab bar) to be at least that tall
even if their own faces are smaller. The fix — not yet implemented — is
to make `default` globally small and set all displayed faces explicitly,
giving full control over line heights everywhere. This is a planned next
step in the word-processor project.

## What exists vs. what is planned

**Done:**
- Tag-based style dispatch with merge semantics and `:eval` escape hatch
- Buffer-local font/size remap that wins regardless of hook order
- Proportional paragraph spacing via jit-lock, excluding structured elements
- `#+TITLE:` metadata block folding via `org-fold-core`
- `#+begin_`/`#+end_` delimiter hiding with cursor-proximity reveal

**Planned / in progress:**
- Global default-face resizing to unlock sub-body line heights in UI chrome
- Generalising `variable-spacing-mode` beyond Org (pluggable paragraph predicate)
