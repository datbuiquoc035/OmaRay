// dmenu select/input protocol shared with the QML side.
//
// An option may lead with an icon ("<glyph><TAB><label>") and may trail a
// subtext ("<glyph><TAB><label><TAB><subtext>"). The menu shows the glyph
// but never returns it: a plain option returns the label alone, one with a
// subtext returns "<label><TAB><subtext>", so callers with same-named rows
// get the subtext back as the stable key.

var MAX_OPTIONS = 1000
var MAX_OPTION_CHARS = 2048

function parseOption(raw) {
  var text = String(raw || "")
  if (text.length > MAX_OPTION_CHARS) text = text.slice(0, MAX_OPTION_CHARS)
  var parts = text.split("\t")
  var icon = parts.length > 1 ? parts.shift() : ""
  var label = parts.shift() || ""
  var detail = parts.join("\t")
  return {
    icon: icon,
    label: label,
    detail: detail,
    value: detail ? label + "\t" + detail : label
  }
}

// Substring filter over label and subtext, case-insensitive. An empty query
// lists everything in the caller's order.
function filterOptions(options, query) {
  var list = Array.isArray(options) ? options.slice(0, MAX_OPTIONS) : []
  var q = String(query || "").trim().toLowerCase()
  var out = []
  for (var i = 0; i < list.length; i++) {
    var parsed = parseOption(list[i])
    if (!parsed.label && !parsed.detail) continue
    if (q && parsed.label.toLowerCase().indexOf(q) < 0
        && parsed.detail.toLowerCase().indexOf(q) < 0) continue
    out.push({
      index: i, icon: parsed.icon, label: parsed.label,
      detail: parsed.detail, value: parsed.value
    })
  }
  return out
}

function clampWidth(value) {
  var n = Number(value)
  if (!isFinite(n)) return 300
  if (n < 1) return 1
  if (n > 2000) return 2000
  return Math.floor(n)
}

function clampMaxHeight(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return 0
  return Math.floor(n)
}

function dmenuValue(raw) {
  return parseOption(raw).value
}

function selections(options, selected, preserveOrder) {
  var list = Array.isArray(options) ? options.slice(0, MAX_OPTIONS) : []
  var picked = Array.isArray(selected) ? selected.map(function(v) { return String(v || "") }) : []
  var available = list.map(dmenuValue)
  return (preserveOrder ? picked : available).filter(function(value, index, values) {
    return value.length > 0 && available.indexOf(value) !== -1
      && picked.indexOf(value) !== -1 && values.indexOf(value) === index
  })
}

function toggleSelection(selected, value) {
  var list = Array.isArray(selected) ? selected.slice() : []
  var v = String(value || "")
  if (!v) return list
  return list.indexOf(v) === -1 ? list.concat([v])
    : list.filter(function(item) { return item !== v })
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_OPTIONS: MAX_OPTIONS, MAX_OPTION_CHARS: MAX_OPTION_CHARS,
    parseOption: parseOption, filterOptions: filterOptions,
    dmenuValue: dmenuValue, selections: selections,
    toggleSelection: toggleSelection,
    clampWidth: clampWidth, clampMaxHeight: clampMaxHeight
  }
}
