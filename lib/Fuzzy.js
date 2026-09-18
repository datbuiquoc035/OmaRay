// Scorer for the non-application rows (commands, quicklinks, clipboard,
// files). Applications are scored by the shell's own AppLibrary so they keep
// ranking identically to the Omarchy menu.

function normalize(value) {
  return String(value || "").toLowerCase()
}

function acronym(text) {
  var parts = normalize(text).split(/[^a-z0-9]+/)
  var out = ""
  for (var i = 0; i < parts.length; i++) if (parts[i]) out += parts[i].charAt(0)
  return out
}

// True when every character of `query` appears in `text` in order. Cheap
// subsequence test, the last resort before rejecting a candidate.
function subsequence(text, query) {
  var t = 0
  for (var q = 0; q < query.length; q++) {
    var c = query.charAt(q)
    if (c === " ") continue
    t = text.indexOf(c, t)
    if (t < 0) return false
    t++
  }
  return true
}

// -1 rejects the candidate. Higher is better.
function score(candidate, query) {
  var q = normalize(query).trim()
  if (!q) return 0

  var title = normalize(candidate.title)
  var haystack = normalize([candidate.title, candidate.subtitle, candidate.keywords, candidate.accessory].join(" "))

  // Every term has to appear as a real substring, or as an acronym hit.
  // A pure subsequence test is too generous for this list — "disc" is a
  // subsequence of "SSD M.2 automatisches Mounten", which is not a match any
  // reader would accept. Subsequence survives only as a tiebreak in the
  // scores below, never as grounds for admitting a row.
  var terms = q.split(/\s+/)
  var ac = acronym(candidate.title)
  for (var i = 0; i < terms.length; i++) {
    if (!terms[i]) continue
    if (haystack.indexOf(terms[i]) < 0 && ac.indexOf(terms[i]) < 0) return -1
  }

  if (title === q) return 10000
  if (title.indexOf(q) === 0) return 9000 - title.length
  var word = title.indexOf(" " + q)
  if (word > 0) return 8000 - word
  if (title.indexOf(q) > 0) return 7000 - title.indexOf(q)

  if (ac.indexOf(q) === 0) return 6500 - ac.length
  if (ac.indexOf(q) > 0) return 6000

  var hay = haystack.indexOf(q)
  if (hay >= 0) return 5000 - Math.min(hay, 400)

  if (subsequence(title, q)) return 3000 - title.length
  return 2000 - title.length
}

// Filters and sorts `candidates` in place-free fashion.
function rank(candidates, query, limit) {
  var rows = []
  for (var i = 0; i < candidates.length; i++) {
    var s = score(candidates[i], query)
    if (s < 0) continue
    rows.push({ row: candidates[i], score: s, order: i })
  }
  rows.sort(function(a, b) {
    if (b.score !== a.score) return b.score - a.score
    return a.order - b.order
  })
  var out = []
  var max = limit || rows.length
  for (var j = 0; j < rows.length && out.length < max; j++) out.push(rows[j].row)
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    normalize: normalize, acronym: acronym, subsequence: subsequence,
    score: score, rank: rank
  }
}
