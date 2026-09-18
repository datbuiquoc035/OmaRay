// The flat settings list: option definitions plus the toggle/cycle math.
// Mirrors the helper's normalize_settings clamps (bin/omaray-helper) — the
// helper is the authority on the way in, this file only decides what Enter
// and Shift+Enter do to the value already on screen. No imports, so node can
// require it directly.

// options for searchEngine mirror the bang table in lib/Web.js. The helper
// accepts any [A-Za-z]{1,8} and the QML side falls back to "g" for unknown
// keys, so a lag here degrades to a shorter cycle, never a bad value.
var SEARCH_ENGINES = ["g", "gg", "google", "ddg", "yt", "gh", "w", "wde", "aw",
  "aur", "pkg", "so", "mdn", "npm", "crates", "docker", "maps", "tr", "img",
  "hn", "omarchy"]

function options() {
  return [
    { key: "webSuggestions", type: "boolean", label: "Web Suggestions",
      hint: "Live suggestions while you type (talks to Google)" },
    { key: "searchEngine", type: "enum", label: "Search Engine",
      options: SEARCH_ENGINES,
      hint: "Destination of the web-search row" },
    { key: "fileSearch", type: "boolean", label: "File Search",
      hint: "f / ~/ / absolute-path file lookup" },
    { key: "maxApps", type: "number", label: "Max App Rows",
      min: 3, max: 24, hint: "Applications shown per query" },
    { key: "maxSuggestions", type: "number", label: "Max Suggestions",
      min: 0, max: 8, hint: "Live web suggestions per query" }
  ]
}

function find(key) {
  var list = options()
  for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
  return null
}

function clampInt(value, low, high, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  n = Math.floor(n)
  if (n < low) return low
  if (n > high) return high
  return n
}

// The value after Enter (direction +1) or Shift+Enter (direction -1):
// booleans flip, enums cycle with wraparound, numbers step with wraparound.
function nextValue(option, current, direction) {
  var dir = direction < 0 ? -1 : 1
  if (!option) return current
  if (option.type === "boolean") return current !== true
  if (option.type === "enum") {
    var list = option.options || []
    if (list.length === 0) return current
    var at = list.indexOf(current)
    if (at < 0) return list[0]
    return list[(at + dir + list.length) % list.length]
  }
  if (option.type === "number") {
    var stepped = clampInt(current, option.min, option.max,
      dir > 0 ? option.min : option.max) + dir
    if (stepped > option.max) return option.min
    if (stepped < option.min) return option.max
    return stepped
  }
  return current
}

function displayValue(option, value) {
  if (!option) return ""
  if (option.type === "boolean") return value === true ? "On" : "Off"
  return String(value)
}

function describe(option, value) {
  if (!option) return ""
  var hint = option.hint ? " · " + option.hint : ""
  if (option.type === "boolean") return (value === true ? "On" : "Off") + hint
  if (option.type === "enum") {
    var list = option.options || []
    var at = list.indexOf(value)
    var shown = at >= 0 ? value + " (" + (at + 1) + "/" + list.length + ")" : String(value)
    return shown + hint
  }
  return String(value) + hint
}

if (typeof module !== "undefined") {
  module.exports = {
    SEARCH_ENGINES: SEARCH_ENGINES, options: options, find: find,
    nextValue: nextValue, displayValue: displayValue, describe: describe
  }
}
