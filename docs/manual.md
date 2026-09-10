# OmaRay manual

Providers run in order; the top row is preselected, so Enter does the
obvious thing. On an empty query the front page shows the stock categories
(Apps, Learn, Trigger, Style, Setup, Install, Remove, Update, About,
System) above your most-used apps; a category primes its query (or runs,
for the self-contained leaves), Apps expands the full app list, and any
keystroke leaves for full search. The System view shows Commands, Hotkeys
and web search only — no applications.

## What it answers

| Type this | You get |
|---|---|
| `chrom` | Applications, ranked by match tier, then frecency |
| `disc` | …plus any open window whose title or app id matches |
| `screenshot`, `lock`, `theme` | Omarchy and system commands |
| `super f`, `browser`, `fl screen` | Omarchy keybindings — Enter runs the runnable ones; keyboard-only binds show greyed so the keys can be learned |
| `12*7+3`, `sqrt(144)`, `20% of 250` | Calculator — Enter copies the result |
| `10 km to miles`, `72f in c` | Offline unit conversion |
| `#ff6644`, `fa8` | HEX / RGB / HSL answers — Enter copies |
| `pick a color` | Screen eyedropper via `hyprpicker` |
| `:smile` | Emoji search — Enter copies the glyph |
| `remind me in 20m to check the oven` | Sets an `omarchy reminder` (natural times: `in 1h30`, `at 15:30`, `tomorrow at 9`) |
| `reminders` | Lists pending reminders, with a row to clear them |
| `meeting with sarah tomorrow at 14:00 for 90min` | Calendar event → Google Calendar, or ⇧↵ for an `.ics` file |
| `f invoice`, `~/Downloads/`, `/etc/` | File and folder search |
| `cb ssh` | Clipboard history search — Enter copies |
| `settings` | One row per option with its live value (see README) |
| `gh quickshell`, `yt lofi` | Bang searches, below matching applications |
| `example.com` | Opens the URL |
| anything else | A web-search row; optional live suggestions when enabled |

## Ranking

Applications score by match tier (exact, prefix, word, contains, id,
keywords, acronym) nudged by **frecency** — launch count decayed by age, the
way `z` ranks directories. The nudge only reorders rows that matched about
as well as each other; on an empty query the list is pure frecency. Commands,
windows, emoji and hotkeys rank the same way, each under its own usage
namespace.

## Keys

| Key | Action |
|---|---|
| `↑` `↓`, `Ctrl+P` `Ctrl+N` | Move |
| `PageUp` `PageDown` | Move a screen |
| `↵` | Primary action, named in the footer |
| `⇧↵` / `Ctrl+↵` | Secondary action (calendar → `.ics`, setting → previous value) |
| `Tab` | Complete the query with the selected app's name |
| `←` | Back to categories: from the Apps list on an empty query, or out of a just-primed category query (edited text keeps caret duty) |
| `Esc` | Clear the query; on an empty query, close (and cancel any picker request) |

Log out, restart and shut down ask for a second `↵` before they act.

## What it talks to

| Goes out | When | Turn it off with |
|---|---|---|
| `suggestqueries.google.com` | Each query, debounced, while `webSuggestions` is on | `"webSuggestions": false` |
| Your browser, to a search or calendar URL | Only when you press Enter on such a row | — |

Everything else is local. No telemetry, no analytics, no background network.
Every file read and subprocess goes through `bin/omaray-helper`, bounded by
byte ceilings, wall-clock deadlines and count-limited projections; a failure
degrades the feature, never the shell.
