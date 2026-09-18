// Omarchy's Hyprland keybindings as palette rows. Everything Omarchy knows
// about a bind (Lua and conf binds, keycodes resolved through the keymap,
// descriptions, the dispatcher that runs it, the order the Super+K menu
// uses) comes from `omarchy-menu-keybindings`, the script behind that menu.
// Sourcing it with --print defines its functions and prints the display
// lines to /dev/null; `output_binding_records` then prints the cached
// records the menu itself selects from, one per line:
//
//   "SUPER + F                           → Full screen\tlua\thl.dsp.window.fullscreen({ mode = \"fullscreen\" })"
//
// and `dispatch_binding` runs one exactly as picking it in that menu would.
//
// The fuzzy scorer is injected (scoreFn(candidate, query)) because this file
// is unit-tested by node and cannot import the QML-side Fuzzy.js. The caller
// passes Fuzzy.score; the tests pass it too, by requiring both files.

// One record per line; the same label bound twice to the same action
// (Browser on Super+Shift+Return and Super+Shift+B) becomes one bind with
// two combos, so the row the user learns from lists every way to press it.
var ARROW = " → "
var MAX_BINDS = 2000

function script(omarchyPath) { return String(omarchyPath || "/usr/share/omarchy") + "/bin/omarchy-menu-keybindings" }

function loadArgv(omarchyPath) {
  return ["bash", "-lc", "source \"$0\" --print >/dev/null && output_binding_records", script(omarchyPath)]
}

// The dispatcher and its argument travel as literal argv elements; the
// script's own function decides how they reach Hyprland.
function dispatchArgv(omarchyPath, dispatcher, arg) {
  return ["bash", "-lc", "source \"$0\" --print >/dev/null; dispatch_binding \"$1\" \"$2\"", script(omarchyPath), String(dispatcher || ""), String(arg || "")]
}

function slug(text) {
  return String(text || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
}

function parse(text) {
  var lines = String(text || "").split("\n")
  var binds = [], byAction = Object.create(null), byLabel = Object.create(null)
  for (var i = 0; i < lines.length && binds.length < MAX_BINDS; i++) {
    var line = lines[i]
    if (!line.trim()) continue
    var fields = line.split("\t")
    var display = fields[0]
    var at = display.indexOf(ARROW)
    if (at < 0) continue
    var combo = display.substring(0, at).trim().replace(/\s+/g, " ")
    var label = display.substring(at + ARROW.length).trim()
    if (!combo || !label) continue
    var dispatcher = (fields[1] || "").trim()
    var arg = fields.slice(2).join("\t").trim()
    var actionKey = label + "\u001f" + dispatcher + "\u001f" + arg
    var hit = byAction[actionKey]
    if (hit) { if (hit.combos.indexOf(combo) < 0) hit.combos.push(combo); continue }
    var id = slug(label) || "bind"
    var n = (byLabel[id] || 0) + 1
    byLabel[id] = n
    if (n > 1) id += "-" + n
    var bind = { id: id, label: label, combos: [combo], dispatcher: dispatcher, arg: arg, order: binds.length }
    byAction[actionKey] = bind
    binds.push(bind)
  }
  return binds
}

var MODIFIERS = { SUPER: "Super", SHIFT: "Shift", CTRL: "Ctrl", ALT: "Alt" }
var KEYS = {
  RETURN: "↵", ENTER: "↵", SPACE: "Space", ESCAPE: "Esc", TAB: "Tab", BACKSPACE: "⌫", DELETE: "Del",
  PRINT: "Print", HOME: "Home", END: "End", PRIOR: "PgUp", NEXT: "PgDn", INSERT: "Ins",
  LEFT: "←", RIGHT: "→", UP: "↑", DOWN: "↓",
  COMMA: ",", PERIOD: ".", MINUS: "-", EQUAL: "=", SLASH: "/", BACKSLASH: "\\", GRAVE: "`",
  BRACKETLEFT: "[", BRACKETRIGHT: "]", SEMICOLON: ";", APOSTROPHE: "'"
}

function keyName(raw) {
  var key = String(raw || "").trim()
  if (!key) return ""
  var upper = key.toUpperCase()
  if (KEYS[upper]) return KEYS[upper]
  if (key.indexOf("XF86") === 0) return key.substring(4).replace(/([a-z])([A-Z])/g, "$1 $2")
  if (/^(LEFT|RIGHT|MIDDLE) MOUSE BUTTON$/.test(upper)) return upper.charAt(0) + upper.substring(1, upper.indexOf(" ")).toLowerCase() + " click"
  if (/^[A-Z]$/.test(upper)) return upper
  if (/^F[0-9]{1,2}$/.test(upper)) return upper
  if (upper === key && key.length > 1 && !/^(code|mouse):/.test(key)) return key.charAt(0) + key.substring(1).toLowerCase()
  return key
}

// "SUPER SHIFT + RETURN" → "Super + Shift + ↵": the record's spelling, made
// readable the way the palette's own key hints are.
function keys(combo) {
  var text = String(combo || "").trim()
  if (!text) return ""
  var plus = text.lastIndexOf(" + ")
  var mods = plus < 0 ? [] : text.substring(0, plus).split(/\s+/)
  var key = plus < 0 ? text : text.substring(plus + 3)
  var parts = []
  for (var i = 0; i < mods.length; i++) if (mods[i]) parts.push(MODIFIERS[mods[i].toUpperCase()] || keyName(mods[i]))
  parts.push(keyName(key))
  return parts.join(" + ")
}

function accessory(bind) {
  var out = []
  for (var i = 0; i < bind.combos.length; i++) out.push(keys(bind.combos[i]))
  return out.join("  ·  ")
}

function runnable(bind) { return !!bind.dispatcher }

function subtitle(bind) {
  if (!bind.dispatcher) return "Only from the keyboard"
  if (bind.dispatcher === "exec") return bind.arg
  if (bind.dispatcher === "lua") return "Hyprland " + bind.arg.replace(/^hl\.dsp\./, "")
  return "Hyprland " + bind.dispatcher + (bind.arg ? " " + bind.arg : "")
}

function comboKey(text) { return String(text || "").toLowerCase().replace(/\s*\+\s*/g, " ").replace(/\s+/g, " ").trim() }

// Abbreviations and the combo itself both find a bind: the label, the keys
// spelled out ("super f") and, for exec binds, the command it runs.
function keywords(bind) {
  var words = []
  for (var i = 0; i < bind.combos.length; i++) words.push(comboKey(bind.combos[i]))
  if (bind.dispatcher === "exec" && bind.arg) words.push(bind.arg.split(/\s+/)[0])
  return words.join(" ")
}

// Scores one bind. scoreFn(candidate, query) is the injected fuzzy scorer
// (the caller passes Fuzzy.score). -1 rejects. The keys spelled out
// ("super f") name one bind; the bonus puts it above binds that merely
// contain those words, just under a title that starts with the query.
var COMBO_EXACT_BONUS = 4500

function matchScore(bind, query, scoreFn) {
  // "super + f" as people write combos: a lone plus is punctuation, not a term.
  var needle = String(query || "").replace(/(^|\s)\+(?=\s|$)/g, " ").replace(/\s+/g, " ").trim()
  if (!needle) return 0
  var candidate = {
    title: bind.label,
    subtitle: subtitle(bind),
    keywords: keywords(bind),
    accessory: accessory(bind)
  }
  var s = scoreFn(candidate, needle)
  if (s < 0) return -1
  var qk = comboKey(needle)
  for (var c = 0; c < bind.combos.length; c++) {
    if (comboKey(bind.combos[c]) === qk) { s += COMBO_EXACT_BONUS; break }
  }
  return s
}

// The root mixes the best `limit` matches into the global search; binds that
// Omarchy cannot run from a menu (Lua closures such as Close window) still
// appear, greyed, so the keys can be learned — unless keyboardOnly is false.
// Returns plain specs; the caller maps them onto rows.
function rows(query, binds, opts, scoreFn) {
  var q = String(query || "").trim()
  if (!q) return []
  var list = Array.isArray(binds) ? binds : []
  var limit = (opts && opts.limit > 0) ? opts.limit : 7
  var showKeyboardOnly = !opts || opts.keyboardOnly !== false
  var scored = []
  for (var i = 0; i < list.length; i++) {
    var bind = list[i]
    if (!runnable(bind) && !showKeyboardOnly) continue
    var s = matchScore(bind, q, scoreFn)
    if (s < 0) continue
    scored.push({ bind: bind, score: s, order: bind.order })
  }
  scored.sort(function(a, b) { return b.score - a.score || a.order - b.order })
  var out = []
  for (var j = 0; j < scored.length && out.length < limit; j++) {
    var b = scored[j].bind
    var can = runnable(b)
    out.push({
      id: b.id, label: b.label, subtitle: subtitle(b), accessory: accessory(b),
      runnable: can, dispatcher: b.dispatcher, arg: b.arg, order: b.order,
      score: scored[j].score
    })
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    script: script, loadArgv: loadArgv, dispatchArgv: dispatchArgv,
    slug: slug, parse: parse, keyName: keyName, keys: keys,
    accessory: accessory, runnable: runnable, subtitle: subtitle,
    comboKey: comboKey, keywords: keywords,
    matchScore: matchScore, rows: rows, COMBO_EXACT_BONUS: COMBO_EXACT_BONUS
  }
}
