// Stock-menu tree support: JSONC parsing, default/user merging, stock
// matching, and subtree navigation.
//
// Only the structure comes over — OmaRay browses and searches the stock
// install/remove subtrees with this, it does not reimplement the menu.
// Guards evaluate in bin/omaray-helper (`menu-guards`).

function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

function normalizeAliases(value) {
  var out = []
  var list = Array.isArray(value) ? value : (typeof value === "string" && value ? [value] : [])
  for (var i = 0; i < list.length && out.length < 20; i++) {
    var alias = String(list[i] || "").slice(0, 128)
    if (alias) out.push(alias)
  }
  return out
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
    iconFont: String(value.iconFont || "").slice(0, 64),
    label: String(value.label || id).slice(0, 128),
    target: String(value.target || "").slice(0, 256),
    action: String(value.action || "").slice(0, 2048),
    when: String(value.when || "").slice(0, 2048),
    checked: String(value.checked || "").slice(0, 2048),
    disabled: String(value.disabled || "").slice(0, 2048),
    provider: String(value.provider || "").slice(0, 64),
    description: String(value.description || "").slice(0, 512),
    aliases: normalizeAliases(value.aliases),
    isChecked: value.isChecked === true,
    providerMenu: String(value.providerMenu || "").slice(0, 128)
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

function swapProviderRows(items, order, menuId, rows) {
  var source = items || Object.create(null)
  var list = Array.isArray(order) ? order : []
  var incoming = Array.isArray(rows) ? rows : []
  var nextItems = Object.create(null)
  var nextOrder = []

  for (var i = 0; i < list.length; i++) {
    var id = list[i]
    var existing = source[id]
    if (!existing || existing.providerMenu === menuId) continue
    nextItems[id] = existing
    nextOrder.push(id)
  }

  for (var j = 0; j < incoming.length; j++) {
    var row = incoming[j]
    if (!row || !row.id || nextItems[row.id]) continue
    var copy = normalizeItem(row.id, row)
    copy.providerMenu = String(menuId || "").slice(0, 128)
    nextItems[copy.id] = copy
    nextOrder.push(copy.id)
  }

  return { items: nextItems, order: nextOrder }
}

function isVisible(merged, guards, entry, depth) {
  if (!entry) return false
  if (entry.when && guards && guards[entry.id] === false) return false
  if (entry.kind !== "menu" && entry.kind !== "link") return true
  if (entry.provider) return true
  var guard = depth || 0
  if (guard >= 32) return false
  var target = entry.kind === "link" && entry.target ? entry.target : entry.id
  var kids = childrenOf(merged, target)
  if (kids.length === 0) return false
  for (var i = 0; i < kids.length; i++) {
    if (isVisible(merged, guards, kids[i], guard + 1)) return true
  }
  return false
}

function isChecked(checkedMap, entry) {
  if (!entry) return false
  if (entry.isChecked === true) return true
  if (!entry.checked) return false
  return !!(checkedMap && checkedMap[entry.id] === true)
}

function isDisabled(disabledMap, entry) {
  if (!entry || !entry.disabled) return false
  return !!(disabledMap && disabledMap[entry.id] === true)
}

function labelFor(entry, checkedMap, disabledMap) {
  if (!entry) return ""
  var base = String(entry.label || "")
  if (base.slice(-2) === " ✓") return base
  var marked = isChecked(checkedMap, entry) || isDisabled(disabledMap, entry)
  return marked ? base + " ✓" : base
}

// Stock-menu matching (MenuModel.matchesQuery/searchScore), for browsing
// stock data the stock way. Every query term must appear as a substring of
// the name text (label plus leaf-id tokens) or as a whole word of the
// description — no acronyms, no subsequence fallback. Scores ascend: exact
// beats prefix beats contains, file order breaking ties.
function searchText(entry) {
  if (!entry) return ""
  var id = String(entry.id || "")
  var leaf = id.indexOf(".") >= 0 ? id.split(".").pop() : id
  var words = [String(entry.label || ""), leaf.replace(/[._-]+/g, " ")]
  if (entry.keywords) words.push(String(entry.keywords))
  var aliases = Array.isArray(entry.aliases) ? entry.aliases : []
  for (var i = 0; i < aliases.length; i++) words.push(String(aliases[i]))
  return words.join(" ").toLowerCase()
}

// True for the id itself and everything below it: "install",
// "install.editor", "install.editor.vim" are all in ["install"].
function inSubtree(id, roots) {
  var key = String(id || "")
  var list = Array.isArray(roots) ? roots : []
  for (var i = 0; i < list.length; i++) {
    var root = String(list[i] || "")
    if (!root) continue
    if (key === root || key.indexOf(root + ".") === 0) return true
  }
  return false
}

// "Install › Editor" — the parent chain labels, for search rows.
function menuPath(items, id) {
  var labels = []
  var current = items ? items[id] : null
  var guard = 0
  while (current && current.id !== "root" && guard < 32) {
    var parent = current.parent ? items[current.parent] : null
    if (parent && parent.id !== "root") labels.unshift(parent.label || parent.id)
    current = parent
    guard += 1
  }
  return labels.join(" › ")
}

function termIsWord(term, text) {
  var words = String(text || "").toLowerCase().split(/\s+/)
  for (var i = 0; i < words.length; i++) if (words[i] === term) return true
  return false
}

function matches(entry, query) {
  if (!entry) return false
  var terms = String(query || "").toLowerCase().trim().split(/\s+/)
  var name = searchText(entry)
  var description = String(entry.description || "").toLowerCase()
  for (var i = 0; i < terms.length; i++) {
    if (!terms[i]) continue
    if (name.indexOf(terms[i]) >= 0) continue
    if (termIsWord(terms[i], description)) continue
    return false
  }
  return true
}

// -1 rejects. Lower is better, mirroring the stock tiers.
function matchScore(entry, query) {
  var q = String(query || "").toLowerCase().trim()
  if (!q) return 0
  if (!matches(entry, query)) return -1
  var label = String(entry.label || "").toLowerCase()
  if (label === q) return 0
  if (label.indexOf(q) === 0) return 10
  if (label.indexOf(q) > 0) return 30
  return 40
}

if (typeof module !== "undefined") {
  module.exports = {
    stripJsonc: stripJsonc, normalizeAliases: normalizeAliases,
    normalizeItem: normalizeItem,
    parseMenuJsonc: parseMenuJsonc, mergeSources: mergeSources,
    childrenOf: childrenOf, parentScope: parentScope,
    swapProviderRows: swapProviderRows,
    isVisible: isVisible, isChecked: isChecked,
    isDisabled: isDisabled, labelFor: labelFor,
    inSubtree: inSubtree, menuPath: menuPath,
    searchText: searchText, termIsWord: termIsWord,
    matches: matches, matchScore: matchScore
  }
}
