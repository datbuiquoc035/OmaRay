// Menu-route aliases for direct `omarchy menu summon <route>` callers.
//
// The deep menu trees intentionally do not come over: leaves stay reachable
// through Commands.js, hotkey search and the dmenu pickers. This table only
// decides what a summoned route DOES — open the palette, open it primed with
// a query, or run a leaf argv immediately (the parity that matters: default
// keybinds like Super+Ctrl+R keep working).
//
// resolve(route) -> { kind: "open" }
//                 | { kind: "query", query: "..." }
//                 | { kind: "apps" }
//                 | { kind: "system" }
//                 | { kind: "exec", argv: [...] }

function normalize(route) {
  return String(route || "").toLowerCase().replace(/_/g, "-").trim()
}

function resolve(route) {
  var r = normalize(route)
  if (!r || r === "root" || r === "menu" || r === "go") return { kind: "open" }
  // Super+Alt+Space: the Apps category — the full frecency app list.
  if (r === "apps") return { kind: "apps" }
  // Super+Esc: the System category — its own seven-row view, not a query.
  if (r === "system") return { kind: "system" }
  if (r === "share" || r === "hardware") return { kind: "open" }
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
