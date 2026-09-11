// Stock-menu tree support: JSONC parsing, default/user merging, and the
// guard batch that hides inapplicable rows.
//
// Only the structure comes over — OmaRay browses the stock install/remove
// subtrees with this, it does not reimplement the menu. Guards evaluate in
// bin/omaray-helper (`menu-guards`); this file builds the one bash script
// they all run in.

function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

function normalizeItem(id, raw) {
  var value = raw || {}
  var parent = value.parent
  if (parent === undefined)
    parent = id.indexOf(".") >= 0 ? id.split(".").slice(0, -1).join(".") : "root"
  if (id === "root") parent = ""
  return {
    id: id,
    parent: parent,
    kind: value.action ? "action" : (value.target ? "link" : "menu"),
    icon: String(value.icon || "").slice(0, 16),
    label: String(value.label || id).slice(0, 128),
    target: String(value.target || "").slice(0, 256),
    action: String(value.action || "").slice(0, 2048),
    when: String(value.when || "").slice(0, 2048)
  }
}

function parseMenuJsonc(raw) {
  var stripped = stripJsonc(raw)
  if (!stripped.trim()) return []
  var parsed
  try {
    parsed = JSON.parse(stripped)
  } catch (e) {
    return []
  }
  if (typeof parsed !== "object" || parsed === null) return []
  var source = (parsed.items && typeof parsed.items === "object" && !Array.isArray(parsed.items))
    ? parsed.items
    : parsed
  var out = []
  for (var id in source) {
    var entry = source[id]
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue
    out.push(normalizeItem(id, entry))
  }
  return out
}

// User extensions override stock rows by id; brand-new ids join at the end.
function mergeSources(defaultItems, userItems) {
  var byId = Object.create(null)
  var order = []
  var lists = [defaultItems || [], userItems || []]
  for (var s = 0; s < lists.length; s++) {
    var src = lists[s]
    for (var i = 0; i < src.length; i++) {
      var entry = src[i]
      if (!entry || !entry.id) continue
      if (!byId[entry.id]) {
        byId[entry.id] = entry
        order.push(entry.id)
      } else {
        byId[entry.id] = entry
      }
    }
  }
  return { items: byId, order: order }
}

function childrenOf(merged, parentId) {
  var out = []
  var order = (merged && merged.order) || []
  for (var i = 0; i < order.length; i++) {
    var entry = merged.items[order[i]]
    if (entry && entry.parent === parentId) out.push(entry)
  }
  return out
}

function parentScope(scope) {
  var id = String(scope || "")
  var dot = id.lastIndexOf(".")
  return dot < 0 ? "" : id.slice(0, dot)
}

if (typeof module !== "undefined") {
  module.exports = {
    stripJsonc: stripJsonc, normalizeItem: normalizeItem,
    parseMenuJsonc: parseMenuJsonc, mergeSources: mergeSources,
    childrenOf: childrenOf, parentScope: parentScope
  }
}
