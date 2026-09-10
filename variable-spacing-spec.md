# variable-spacing-mode — Architecture Specification

## Purpose

`variable-spacing-mode` applies proportional line spacing to buffer text
based on the faces active at each character position.  Spacing ratios are
configured per-face and the library applies them automatically as part of
Emacs's normal font-lock pipeline.  No document-structure parsing is
performed; the library is face-driven throughout.

A secondary goal is a two-tier size model: a small floor size for
structural/metadata text and a larger body size for readable content.
These are implemented through buffer-local face remaps rather than global
face modifications.

---

## 1. Size Model

### 1.1 The floor

On mode enable, `default` is remapped buffer-locally using
`face-remap-add-relative` with an integer `:height` equal to
`variable-spacing-floor-height` (default 60, i.e. 6 pt).  An integer is
used rather than a float so the floor is an absolute size and not relative
to whatever `default` happens to be globally.

Any Org text that carries no explicit `face` or `font-lock-face` text
property — drawers, property values, keywords, affiliated keywords — falls
through to `default` and renders at the floor size with no per-face
configuration.

### 1.2 The `text-body` face

`text-body` is a custom face defined by this library.  It has an explicit
integer `:height` (default 120 = 12 pt) so it does not inherit its size
from `default`.  Plain paragraph text, which Org leaves completely unstyled,
receives `text-body` as a low-priority face text property applied by the
face-stamp pass (see §3.1).

Users set the body text height globally once:

```elisp
(set-face-attribute 'text-body nil :height 110)
```

### 1.3 Body-face remaps

`variable-spacing-body-faces` is a list of faces that should render at body
size.  On mode enable each face in the list receives a buffer-local
`face-remap-add-relative` entry injecting `(:inherit text-body)`.  Three
populations are covered:

| Population | Examples | Why remap is needed |
|---|---|---|
| Heading faces | `org-level-1`…`org-level-8` | Applied by Org as `font-lock-face`; the face-stamp pass skips them, so the remap is the only lift above the floor |
| Primitive emphasis | `bold`, `italic`, `underline` | Applied directly by Org anchor functions as `face`; inherit `default` without a remap |
| Content block / inline | `org-quote`, `org-block`, `org-link`, `org-cite`, `org-footnote`, … | Applied by Org anchor functions as `face`; need body sizing by default |

**The `facep` guard is intentionally absent.**  Faces that are not yet
defined at mode-enable time (e.g. `org-cite` from `oc.el`, which loads
lazily) still receive a `face-remapping-alist` entry.  That entry has no
effect until the face is first used for display, at which point it
takes effect automatically.

All cookies are stored in `variable-spacing--body-remap-cookies` and
removed on mode disable.

**Note on face-remapping non-transitivity.**  `face-remapping-alist` is
consulted only for the face directly referenced as a text property.
Inheritance chains in global face definitions follow those definitions, not
the remap alist.  Remapping `link` does not affect `org-cite` (which
inherits from `link` globally) when `org-cite` is the direct text-property
face.  Each face that Org stamps directly must be listed explicitly.

---

## 2. Spacing Configuration

Spacing ratios are stored as symbol properties on face symbols:

```elisp
(put 'text-body 'variable-spacing-ratio 1.5)
(put 'org-quote 'variable-spacing-ratio 1.0)
```

A `:around` advice on `set-face-attribute` provides a more natural API:

```elisp
(set-face-attribute 'text-body nil :variable-spacing-ratio 1.5)
```

The advice (`variable-spacing--set-face-attribute-advice`) extracts
`:variable-spacing-ratio` from the argument list, calls `put`, strips the
key before forwarding to the real `set-face-attribute` (which would signal
an error on an unknown attribute), and triggers a flush in all active
buffers (see §4.2).

---

## 3. Fontification Pipeline Integration

### 3.1 Why `font-lock-fontify-keywords-region`

Org uses standard `font-lock-mode` and `jit-lock-mode`.  When jit-lock
decides a buffer region needs fontification, the call chain is:

```
jit-lock-fontify-now
  → font-lock-fontify-region (BEG END)       ; called with jit-lock's region
      → font-lock-default-fontify-region (BEG END)
          → extend region via font-lock-extend-region-functions → [FSTART FEND]
          → font-lock-unfontify-region FSTART FEND
          → font-lock-fontify-keywords-region FSTART FEND   ; ← our hook point
          → return (cons FSTART FEND)         ; jit-lock marks THIS range clean
```

jit-lock marks `[FSTART FEND]` (the extended bounds) as clean, not the
original `[BEG END]`.  Both of our passes advise
`font-lock-fontify-keywords-region` with `:after`, receiving the
already-extended bounds.  This ensures our passes cover exactly the same
region that jit-lock considers authoritative.

### 3.2 Pass ordering

Multiple `:after` advisors on the same function run in FIFO order.  The
face-stamp pass is added first and runs first; the spacing pass is added
second and runs second.  This guarantees that when the spacing pass reads
face properties, the face-stamp pass has already applied `text-body` to
unstyled text.

### 3.3 Pass 1 — Face-stamp (`variable-spacing--after-fontify`)

**Purpose:** ensure every character that should participate in body-size
rendering carries an explicit face, so the spacing pass can find a ratio for it.

After Org's keyword list has run, characters fall into two categories:

- **Styled** — has a `face` text property (set by anchor functions: blocks,
  emphasis, links, citations) or a `font-lock-face` property (set by regexp
  keywords: headlines, tables, TODO keywords).
- **Unstyled** — neither property set.  Plain paragraph text that Org
  intentionally leaves bare.

**Algorithm:**

1. Clear stale `text-body` stamps from BEG..END using
   `variable-spacing--remove-body-face`.  This handles the case where text
   has since acquired an Org face (e.g. a newly-typed quote block).

2. Walk BEG..END by property spans, advancing to the minimum of the next
   `face` and `font-lock-face` change boundary.

3. For each unstyled span (both properties nil), stamp `text-body` on
   non-newline character runs using `add-face-text-property … t` (append,
   low priority so any later Org face remains higher-priority).

4. **Bare newlines are skipped.**  A `\n` character with `text-body` would
   inflate the line height for blank lines and structural-line newlines.
   Each unstyled span is walked character-by-character with
   `skip-chars-forward "^\n"` to stamp only non-newline runs.

**Survival across unfontify cycles.**  `text-body` stamps carry no
`font-lock-fontified t` marker and are therefore not managed by
`font-lock-default-unfontify-region`.  They survive unfontify and are only
removed by the explicit clearing step at the start of the next pass
invocation.

### 3.4 Pass 2 — Spacing (`variable-spacing--spacing-pass`)

**Purpose:** compute and apply pixel-height line spacers based on the face
active at each span.

**Algorithm:**

1. Call `variable-spacing-clear BEG END` to remove stale spacing properties
   (those marked with the sentinel `variable-spacing--prop`).

2. Walk BEG..END by property spans using the same dual-property boundary
   detection as Pass 1.

3. For each span, read the face at `pos` from both `face` and
   `font-lock-face` properties.

4. Call `variable-spacing--face-with-ratio` on the face value (which may be
   a symbol or a list of symbols).  This returns the first face in the value
   that has a non-nil `variable-spacing-ratio` symbol property, or nil.

5. If a ratio face is found, compute a pixel spacer via
   `variable-spacing--spacer` and stamp `line-prefix`, `wrap-prefix`, and
   `variable-spacing--prop` on the span.

The entire pass runs inside `with-silent-modifications` to suppress
modification hooks and avoid spurious redisplay.

---

## 4. Spacer Computation

`variable-spacing--spacer (ratio face)` returns a
`(space :width 0 :height (Npx))` display specification.

**Pixel height:** reads the rendered height of FACE using `face-font` on the
current window's frame and `font-info`.  Falls back to `frame-char-height`
if no live window is available.  `face-font` accounts for buffer-local face
remapping, so the spacer reflects the actual rendered size of the face in
this buffer.

**Application:** the spacer is written to both `line-prefix` and
`wrap-prefix`.  `line-prefix` controls the height of the line as a whole
(the space appears before the first character of each logical line).
`wrap-prefix` applies the same height to continuation lines so wrapped
paragraphs are uniformly spaced.

---

## 5. Sentinel and Clearing

`variable-spacing--prop` (the symbol `variable-spacing--spacing`) is
stamped alongside every set of spacing properties.  `variable-spacing-clear`
uses `next-single-property-change` on this sentinel to efficiently skip
unstyled spans, making clearing O(number of spaced regions) rather than
O(buffer size).

`variable-spacing-clear` removes `variable-spacing--prop`, `line-prefix`,
and `wrap-prefix` from spans where the sentinel is present.  It does not
touch face properties.  The separate `variable-spacing--remove-body-face`
function handles `text-body` stamp removal.

---

## 6. Lifecycle

### 6.1 Mode enable

```
variable-spacing--install-body-remaps      ; floor + body-face remaps
variable-spacing--enable-after-fontify-advice
variable-spacing--enable-spacing-advice    ; must follow after-fontify
variable-spacing--enable-face-attr-advice  ; :variable-spacing-ratio interception
advice-add text-scale-mode :after --text-scale-refresh
advice-add set-face-attribute :after --text-body-face-refresh
font-lock-flush                            ; trigger refontification of whole buffer
```

`font-lock-flush` marks the buffer as needing refontification.  jit-lock
processes it lazily, running both passes on each chunk as the user scrolls
or Emacs is idle.  This ensures that text fontified before the mode was
enabled also goes through the passes.

### 6.2 Mode disable

```
variable-spacing--remove-body-remaps
variable-spacing-clear                                    ; remove spacing props
variable-spacing--remove-body-face (point-min) (point-max) ; remove text-body stamps
advice-remove all four advice functions
variable-spacing--disable-{after-fontify,spacing,face-attr}-advice
```

No `font-lock-flush` is needed on disable; properties are removed directly
and Emacs redraws on next redisplay.

### 6.3 Invalidation

Two situations require existing spacers to be discarded and recomputed:

**`text-scale-mode` change** (`variable-spacing--text-scale-refresh`):
text-scale alters the rendered pixel height of faces; baked-in spacers are
stale.  Calls `variable-spacing-clear` + `font-lock-flush`.

**`text-body` height change** (`variable-spacing--text-body-face-refresh`):
`set-face-attribute` `:after` advice watches for changes to `text-body`;
same clear + flush.

The `:variable-spacing-ratio` interception advice (`--set-face-attribute-advice`)
also triggers clear + flush in all active buffers when a ratio changes.

---

## 7. Global Advice and Reference Counting

`font-lock-fontify-keywords-region`, `set-face-attribute`, and
`text-scale-mode` are global functions.  Advising them affects all buffers,
so all advice bodies are guarded by
`(when (bound-and-true-p variable-spacing-mode) …)`.

The disable helpers (`variable-spacing--disable-{…}-advice`) remove advice
only if no other buffer still has `variable-spacing-mode` active, preventing
the advice from being removed while another buffer still depends on it:

```elisp
(unless (cl-some (lambda (buf)
                   (and (not (eq buf (current-buffer)))
                        (buffer-local-value 'variable-spacing-mode buf)))
                 (buffer-list))
  (advice-remove …))
```

---

## 8. User-facing Variables and Faces

| Symbol | Type | Default | Purpose |
|---|---|---|---|
| `text-body` | `defface` | `:height 120` | Sizing root for body content |
| `variable-spacing-floor-height` | `defcustom` integer | `60` | Floor height for `default` (1/10 pt) |
| `variable-spacing-body-faces` | `defcustom` list | see source | Faces that inherit `text-body` via remap |

Spacing ratios are not stored in a defcustom; they are symbol properties
set by the user per face.  No central configuration variable holds all
ratios — the face symbol itself is the locus of configuration.
