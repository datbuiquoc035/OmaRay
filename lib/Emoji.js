// Emoji keyword search over Omarchy's emojis.json ([{e, k}]).
//
// Self-contained by design: it cannot import Fuzzy.js (QML library imports
// are not requireable by node, and this file is unit-tested by node), so it
// carries its own scorer for the one field it searches. The rule mirrors
// Fuzzy's core admission — every term must appear as a substring of the
// keywords or of their acronym — with a small tiering of its own.

function title(keywords) {
  var ws = String(keywords || "").split(/\s+/).slice(0, 6).join(" ")
  return ws.charAt(0).toUpperCase() + ws.slice(1)
}

function acronym(text) {
  var parts = String(text || "").toLowerCase().split(/[^a-z0-9]+/)
  var out = ""
  for (var i = 0; i < parts.length; i++) if (parts[i]) out += parts[i].charAt(0)
  return out
}

function scoreKeywords(keywords, query) {
  var q = String(query || "").toLowerCase().trim()
  if (!q) return 0
  var k = String(keywords || "").toLowerCase()
  var ac = acronym(keywords)
  var terms = q.split(/\s+/)
  for (var i = 0; i < terms.length; i++) {
    if (!terms[i]) continue
    if (k.indexOf(terms[i]) < 0 && ac.indexOf(terms[i]) < 0) return -1
  }
  if (k === q) return 10000
  if (k.indexOf(q) === 0) return 9000 - k.length
  var word = k.indexOf(" " + q)
  if (word > 0) return 8000 - word
  if (k.indexOf(q) > 0) return 7000 - k.indexOf(q)
  if (ac === q) return 6500
  return 5000 - Math.min(k.length, 400)
}

// data: [{e, k}] from Omarchy's emojis.json. Returns at most `limit` rows as
// [{index, e, k, score}], best first, data order breaking ties.
function search(data, query, limit) {
  var out = []
  var list = Array.isArray(data) ? data : []
  var q = String(query || "").trim()
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    if (!entry || typeof entry.e !== "string" || typeof entry.k !== "string") continue
    if (!entry.e || !entry.k) continue
    var s = scoreKeywords(entry.k, q)
    if (s < 0) continue
    out.push({ index: i, e: entry.e, k: entry.k, score: s })
  }
  out.sort(function(a, b) { return b.score - a.score || a.index - b.index })
  return out.slice(0, limit > 0 ? limit : 24)
}

if (typeof module !== "undefined") {
  module.exports = { title: title, acronym: acronym, scoreKeywords: scoreKeywords, search: search }
}
