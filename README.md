# OmaRay (`0.1.0-dev`)

A Raycast-style command palette for [Omarchy](https://omarchy.org/) that
replaces the Omarchy menu: apps, open windows, Omarchy commands, keybindings,
calculator, offline unit conversion, colors, emoji, natural-language
reminders, calendar events, file search, clipboard history and web search —
one input, ranked so the top row is the one you meant.

Rebased onto [maajix/omarchy-spotlight](https://github.com/maajix/omarchy-spotlight)
v1.1.2 (MIT); see [docs/REBASE.md](docs/REBASE.md) for what was kept, dropped
and why. Full provider manual: [docs/manual.md](docs/manual.md).

## Install

```bash
omarchy plugin add https://github.com/datbuiquoc035/OmaRay.git --enable
omarchy restart shell   # keepLoaded plugins load on a fresh shell
```

Or from a checkout: `./bin/omaray install --enable` (removes the previous
plugin directory first, so stale files never linger).

Enabling takes Super+Space and every `omarchy menu` route; disabling
restores the stock menu. No migration: settings and ranking start fresh
(see Coexistence).

Extra keybind (optional) in `~/.config/hypr/bindings.lua`:

```lua
o.bind("CTRL + SPACE", "OmaRay", "omarchy-shell shell toggle datbuiquoc035.omaray '{}'")
```

Frosted glass (optional) in `~/.config/hypr/looknfeel.lua` (needs global blur on):

```lua
hl.layer_rule({
  match = { namespace = "omarchy-omaray" },
  blur = true,
  ignore_alpha = 0.4,
})
```

## Files

- `OmaRay.qml` — UI and actions.
- `BarWidget.qml` — bar button with the stock Omarchy glyph (\ue900).
- `lib/` — parsers and ranking (Apps, Calc, Units, Fuzzy, Frecency, Commands,
  NaturalTime, Web, Emoji, Colors, Hotkeys, Settings, Routes, Dmenu).
- `bin/omaray-helper` — bounded broker for every file read and subprocess.
- `bin/omaray` — install / uninstall / validate / test for this tree.
- `omaray.example.json` — copy to `~/.config/omarchy/omaray.json` to configure.
- `tests/` — node suites per lib plus helper round-trip tests.
- `docs/` — manual and rebase notes.

## Menu replacement

The manifest declares `clonedFrom: omarchy.menu`. The deep menu trees do not
come over — leaves stay reachable through the command catalogue, hotkey
search and the pickers.

| Route | Does |
|---|---|
| `root`, `menu`, `go`, `apps`, `system`, … | Opens the palette |
| `capture` | Opens primed with `screenshot` |
| `toggle` | Opens primed with `toggle` |
| `reminder-set` | Opens primed with `remind me ` |
| `trigger.capture.screenrecord` | Runs screen recording immediately |
| `theme`, `background` | Opens the theme / wallpaper picker |

`omarchy-menu-select` and `omarchy-menu-input` (and everything built on
them: theme/font/plugin setup flows, timezone, file picker) route here:
options narrow as you type with `width`/`maxheight` honored, Enter picks,
Esc cancels, and a new request cancels a pending one.

## Bar button

`BarWidget.qml` shows the stock Omarchy glyph and toggles through the
`omarchy.menu` route, so it keeps opening the palette even if OmaRay is
disabled. To seat it where the stock button was:

```bash
omarchy plugin enable datbuiquoc035.omaray left
omarchy bar move datbuiquoc035.omaray --section left --index 0
```

(Plain `omarchy bar put` will not seat a widget id that is already enabled
in `plugins[]` — the enable-with-section form is the repeatable path, also
after a disable cycle. Disabling swaps the stock button back automatically.)

## Settings

Optional, at `~/.config/omarchy/omaray.json` — or query `settings` in the
palette: one row per option, Enter toggles booleans / steps forward, ⇧↵
steps back, the change is written back and the row shows the new value.

```json
{
  "webSuggestions": false,
  "searchEngine": "g",
  "fileSearch": true,
  "maxApps": 8,
  "maxSuggestions": 4
}
```

Launch counts live in `~/.local/state/omaray/usage.json` — one
`{count, last}` per app, command, bang, window, emoji and hotkey, capped at
400 entries. Delete it to forget the ranking.

## Coexistence

| Resource | Upstream Spotlight | This plugin |
|---|---|---|
| Plugin id | `io.github.maajix.spotlight` | `datbuiquoc035.omaray` |
| Settings | `~/.config/omarchy/spotlight.json` | `~/.config/omarchy/omaray.json` |
| Launch counts | `~/.local/state/omarchy/spotlight-usage.json` | `~/.local/state/omaray/usage.json` |
| Layer namespace | `omarchy-spotlight` | `omarchy-omaray` |

## Development

```bash
./bin/omaray validate
./bin/omaray test
./bin/omaray install [--enable]
./bin/omaray uninstall [--purge]
```

## License

MIT — see [LICENSE](LICENSE). Fork of Spotlight v1.1.2 (Max Randhahn, MIT);
the Keystroke-based tree it replaced is archived — see
[docs/REBASE.md](docs/REBASE.md).
