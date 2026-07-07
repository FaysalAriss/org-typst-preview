# org-typst-preview

Obsidian-style live math previews for Emacs Org mode — with
[Typst](https://typst.app) as the math language instead of LaTeX.

```org
The identity $e^(i pi) + 1 = 0$ renders inline, and display math
uses double dollars: $$sum_(k=1)^n k = (n(n+1))/2$$
```

A fragment turns into a rendered image the moment your cursor leaves the
dollar signs, and turns back into editable text when you click into it or
arrow onto it — the same live-preview feel as Obsidian, but you write
Typst's lightweight math syntax (`alpha`, `sum_(k=1)^n`, `integral_0^oo`,
`sqrt(x)`) rather than LaTeX backslash commands.

## Features

- **Live round-tripping** — render on cursor exit, reveal source on entry,
  re-render instantly from cache when you leave again.
- **Asynchronous** — compilation runs in background processes; Emacs never
  blocks, even with many fragments.
- **Cached forever** — images are keyed by content, colour, and font size;
  each distinct fragment compiles exactly once across sessions.
- **Theme-aware** — glyphs use your theme's foreground colour on a
  transparent background, sized to match your font.
- **Forgiving** — broken math stays as plain text (compiler output goes to
  `*org-typst-preview-errors*`); money like "I paid $5" is ignored; `\$`
  escapes a literal dollar sign; code blocks are left alone.

## Requirements

- Emacs 27.1+ (SVG support recommended; falls back to PNG without it)
- the [`typst` CLI](https://github.com/typst/typst) on your `PATH`
  (`brew install typst` on macOS)

## Installation

Not on MELPA (yet) — install manually:

```elisp
;; put org-typst-preview.el somewhere on your load-path, then:
(require 'org-typst-preview)
(add-hook 'org-mode-hook #'org-typst-preview-mode)
```

or with `use-package`:

```elisp
(use-package org-typst-preview
  :ensure nil
  :load-path "path/to/org-typst-preview"
  :hook (org-mode . org-typst-preview-mode))
```

## Usage

Just write math between dollar signs in any Org buffer:

| You type                     | You get                          |
|------------------------------|----------------------------------|
| `$x^2 + y^2 = z^2$`          | inline math                      |
| `$$integral_0^oo e^(-x^2) dif x$$` | display-style math (one line) |
| `\$5 and \$10`               | literal dollar signs, no math    |

Interactive commands:

- `M-x org-typst-preview-buffer` — enable previews and render everything now
- `M-x org-typst-preview-clear` — remove previews and stop auto-rendering
- `M-x org-typst-preview-mode` — toggle the minor mode

Suggested keybindings:

```elisp
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c t p") #'org-typst-preview-buffer)
  (define-key org-mode-map (kbd "C-c t c") #'org-typst-preview-clear))
```

## Customization

`M-x customize-group org-typst-preview`, or:

| Variable                      | Default   | Purpose                             |
|-------------------------------|-----------|-------------------------------------|
| `org-typst-preview-scale`     | `1.0`     | extra image scaling if math looks too small/large |
| `org-typst-preview-delay`     | `0.25`    | idle seconds before re-scanning     |
| `org-typst-preview-program`   | `"typst"` | path to the typst executable        |
| `org-typst-preview-cache-dir` | `~/.emacs.d/org-typst-preview-cache` | image cache (safe to delete) |

## Notes & limitations

- Fragments must fit on a single line (both `$...$` and `$$...$$`).
- Like Obsidian, two prices on one line (`$10 ... 100$`) can pair up as
  math; escape with `\$` when that happens.
- Images are cached per foreground colour, so switching themes re-renders
  fragments once to match.
- Because rendered images follow real ink extents, a line with tall math
  (big exponents, integrals) grows slightly taller than a plain line.
- Images are automatically capped at the window's text width and shrink
  to fit when you narrow the window (re-expanding when you widen it).
  Besides looking right, this works around an Emacs redisplay hang that
  occurs when an image is wider than its window while `visual-line-mode`
  and `display-line-numbers-mode` are both enabled.

## Development

Run the test suites (they compile real Typst, so the CLI must be
installed):

```sh
emacs -Q --batch -l tests/test-org-typst-preview.el
emacs -Q --batch -l tests/test-org-typst-preview-e2e.el
```

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
