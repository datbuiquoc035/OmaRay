# Rebase note: Keystroke base → Spotlight base (`0.1.0-dev`)

The `v0.1.0-dev` tag used to point at the Keystroke-based tree
(`e76f7a12ed0d16503a419f5f864ecb56871d975d`, ~24MB / 500+ files: C++
engine, Smart Match, voice, Opencode serve-mode, extensions system, menu
tree model, docs site). That tree now lives on branch
`archive/keystroke-0.1.0-dev` and the tag moved here.

(Note on the plan: it said to record the old hash in `docs/releases.md`,
but `docs/releases/` is already a directory of release notes, so the
pointer lives here instead.)

## Why

Spotlight v1.1.2 is ~3.9K LOC with the bounded-helper security model
already built in; the rebase keeps its core palette, adds back OmaRay's
emoji / colors / hotkeys / settings UI as small `lib/` ports, and replaces
`omarchy.menu` through the proven `clonedFrom` pattern — at ~350KB total.

## Keep / port / delete

- **Kept from Spotlight:** apps, windows, calculator, units, files,
  clipboard, reminders, calendar, web+bangs, settings shape, frecency math.
- **Ported from the old tree:** emoji (`:` + picker rows), colors (`#hex`
  answers + `hyprpicker` eyedropper), hotkeys (fuzzy rows + dispatch through
  `omarchy-menu-keybindings`, greyed keyboard-only binds), settings UI with
  `write-settings`, `win:`/`emoji:`/`hotkey:` frecency namespaces.
- **Deleted:** all AI (`opencode/`, assistants, Codex), `voice/`, Smart
  Match, C++ `engine/`, extensions system, deep menu trees
  (`omarchy/MenuModel.js`), bar widget, plus `site/`, `assets/`, `tools/`,
  `experiments/`, `examples/` and most of `core/` + `providers/` + `tests/`
  + `docs/`.
- **Deliberately not ported:** suspend row (same marketplace rationale as
  Spotlight — no `systemctl` wrapper call from the catalogue).

## Compatibility contract (P4)

- `clonedFrom: omarchy.menu` — Super+Space and every `omarchy menu` route;
  disabling restores stock.
- dmenu select/input protocol (list + text input, `width`/`maxHeight`,
  selection files) so Install/Remove/Setup pickers, timezone and the file
  picker keep working.
- Route aliases: palette for submenus, primed queries for `capture` /
  `toggle` / `reminder-set`, immediate exec for screenrecord / theme /
  background leaves.
- No migration: fresh `omaray.json` + `usage.json` by design.

## Verification history

P1–P4 gates are recorded in the conversation that built this tree; the
repeatable parts ship as `tests/` (43 node + 11 Python, run with
`./bin/omaray test`) plus `./bin/omaray validate`. Two bugs the live matrix
caught and fixed: `close()` SIGTERMed its own dmenu-finish helper via
`stopQueryWork` (finish writes are fire-and-forget — see the comment on
`finishRequest`), and keepLoaded QML never reloads without
`omarchy restart shell` (neither file-watch nor disable+enable does it).
