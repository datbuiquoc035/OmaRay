# OmaRay

A Raycast-style command palette for [Omarchy](https://omarchy.org/) that
replaces the Omarchy menu: apps, open windows, Omarchy commands, keybindings,
calculator, offline unit conversion, colors, emoji, natural-language
reminders, calendar events, file search, clipboard history and web search —
one input, ranked so the top row is the one you meant.

An empty query shows the stock categories (Apps, Learn, Trigger, Style,
Setup, Install, Remove, Update, About, System). Categories open their
stock subtrees to browse and run (inapplicable rows hidden); Apps expands
the full app list, System primes its query — ← climbs back out. Any
keystroke leaves for full search.

## What it answers

| Type this | You get |
|---|---|
| `chrom`, `disc` | Applications and matching open windows |
| `screenshot`, `lock`, `theme` | Omarchy and system commands |
| `super f`, `browser` | Keybindings — Enter runs them |
| `12*7+3`, `10 km to miles` | Calculator and unit conversion answers |
| `#ff6644`, `pick a color` | Color answers and the screen eyedropper |
| `:smile` | Emoji search |
| `remind me in 20m to …`, `reminders` | Reminders |
| `f invoice`, `~/Downloads/` | File and folder search |
| `cb ssh` | Clipboard history |
| `settings` | One row per option, edited in place |
| `gh quickshell`, `example.com` | Bang searches, URLs, web search |

## Keys

| Key | Action |
|---|---|
| `↑` `↓`, `PageUp` `PageDown` | Move |
| `↵` | Primary action, named in the footer |
| `⇧↵` | Secondary action (`.ics` file, previous setting value) |
| `Tab` | Complete with the selected app's name |
| `←` | Back to categories from a category view |
| `→` | Open the selected category (empty query only) |
| `Esc` | Close from a fresh prime or empty query, else clear first |

## Menu replacement

Enabling takes Super+Space and every `omarchy menu` route (`apps` and
`system` open their categories directly); disabling restores the stock
menu. The bar button shows the stock Omarchy glyph. Everything else is
local — no telemetry, no background network.

## Settings

Optional, at `~/.config/omarchy/omaray.json` — or query `settings` in the
palette: Enter toggles booleans and steps forward, ⇧↵ steps back, the
change is written back. Launch counts live in
`~/.local/state/omaray/usage.json`; delete it to forget the ranking.

## Development

```bash
./bin/omaray validate
./bin/omaray test
```

## License

MIT — see [LICENSE](LICENSE).
