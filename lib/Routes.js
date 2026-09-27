// Menu-route aliases for direct `omarchy menu summon <route>` callers.
//
// Summoning is a shortcut, not a full menu port: a route either opens a view
// the palette already owns (Apps, System, a stock subtree) or primes a query.
// Everything else — every leaf, every picker row — stays reachable through
// Commands.js, hotkey search and the dmenu pickers. The only routes that RUN
// on summon are the leaves behind default keybinds (Super+Ctrl+R, the
// screenrecord keys), because those would otherwise regress to show-and-wait.
//
// resolve(route) -> { kind: "open" }
//                 | { kind: "query", query: "..." }
//                 | { kind: "apps" }
//                 | { kind: "system" }
//                 | { kind: "scope", scope: "trigger.hardware" }
//                 | { kind: "exec", argv: [...] }

function normalize(route) {
  return String(route || "").toLowerCase().replace(/_/g, "-").trim()
}

// Alias -> stock-menu id, for the subtrees worth landing on directly. These
// are the alias pairs Omarchy's own JSONC declares, so a keybind's route
// opens the rows the stock menu would have shown instead of dropping the
// caller on the front page.
//
// A switch rather than a lookup table on purpose: routes arrive from an
// external IPC payload, and a plain object literal would answer
// `SCOPES["constructor"]` with a function, which is truthy.
function scopeFor(route) {
  switch (route) {
    case "hardware": case "hw": return "trigger.hardware"
    case "share": return "trigger.share"
    default: return ""
  }
}

function resolve(route) {
  var r = normalize(route)
  if (!r || r === "root" || r === "menu" || r === "go") return { kind: "open" }
  // Super+Alt+Space: the Apps category — the full frecency app list.
  if (r === "apps") return { kind: "apps" }
  // Super+Esc: the System category — its own seven-row view, not a query.
  if (r === "system") return { kind: "system" }
  var scope = scopeFor(r)
  if (scope) return { kind: "scope", scope: scope }
  // Submenus whose rows share one word: prime with it.
  if (r === "capture") return { kind: "query", query: "screenshot" }
  if (r === "toggle" || r === "toggles") return { kind: "query", query: "toggle" }
  // Leaves that must RUN on summon, not show-and-wait: the default
  // keybinds behind them (Super+Ctrl+R, screenrecord keys) would regress.
  if (r === "reminder-set") return { kind: "query", query: "remind me " }
  if (r === "trigger.capture.screenrecord") {
    return { kind: "exec", argv: ["omarchy", "capture", "screenrecording"] }
  }
  // Pickers that summon back through the select/input protocol.
  if (r === "theme") return { kind: "exec", argv: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\""] }
  if (r === "background") return { kind: "exec", argv: ["bash", "-c", "bg=$(omarchy-theme-bg-switcher); [[ -n $bg ]] && omarchy-theme-bg-set \"$bg\""] }
  // Setup flows and everything unlisted: the palette, unprimed.
  return { kind: "open" }
}

if (typeof module !== "undefined") {
  module.exports = { normalize: normalize, resolve: resolve }
}
