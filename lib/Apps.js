// Application ranking for the fallback app source.
//
// OmaRay normally asks the shell's own AppLibrary for its application
// list, so applications rank exactly as they do in the Omarchy menu. Omarchy
// 4.0.3 stopped handing that library to third-party plugins, so the list has
// to be built here instead — from Quickshell's DesktopEntries, which is the
// same source AppLibrary reads.
//
// Ranking is therefore a port of Omarchy's own services/AppSearch.js (MIT),
// tier for tier. Keeping the numbers identical is what keeps the frecency
// bonus in OmaRay.qml valid: both caps sit under the smallest gap between
// two tiers here, so usage reorders rows inside a tier and never across one.

var FIELD_CHARS = 512
var SEARCH_CHARS = 2048
var KEYWORD_COUNT = 64

function bounded(value, chars) {
  return String(value || "").slice(0, chars)
}

function entryName(entry) {
  return bounded((entry && entry.name) || (entry && entry.id), FIELD_CHARS)
}

function entrySubtext(entry) {
  return bounded(entry && entry.genericName, FIELD_CHARS)
}

function entrySortKey(entry) {
  return entryName(entry).toLowerCase()
}

function keywordText(entry) {
  try {
    if (entry && entry.keywords && typeof entry.keywords.length === "number") {
      var out = []
      for (var i = 0; i < entry.keywords.length && i < KEYWORD_COUNT; i++)
        out.push(bounded(entry.keywords[i], 128))
      return out.join(" ").slice(0, SEARCH_CHARS)
    }
  } catch (e) {
  }
  return ""
}

function entrySearchText(entry) {
  if (!entry) return ""
  return [
    bounded(entry.name, FIELD_CHARS),
    bounded(entry.genericName, FIELD_CHARS),
    bounded(entry.comment, FIELD_CHARS),
    keywordText(entry),
    bounded(entry.id, 256)
  ].join(" ").slice(0, SEARCH_CHARS).toLowerCase()
}

function wordText(value) {
  return String(value || "")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/[._:/\\-]+/g, " ")
    .toLowerCase()
}

function words(value) {
  var values = wordText(value).split(/[^a-z0-9]+/)
  var result = []
  for (var i = 0; i < values.length; i++) {
    if (values[i]) result.push(values[i])
  }
  return result
}

function entryAcronym(entry) {
  var values = words([
    bounded(entry && entry.name, FIELD_CHARS),
    bounded(entry && entry.genericName, FIELD_CHARS),
    keywordText(entry),
    bounded(entry && entry.id, 256)
  ].join(" ").slice(0, SEARCH_CHARS))
  var result = ""
  for (var i = 0; i < values.length; i++) result += values[i].charAt(0)
  return result.slice(0, 256)
}

function termMatches(entry, term) {
  if (!term) return true

  var name = entryName(entry).toLowerCase()
  var id = bounded(entry && entry.id, 256).toLowerCase()
  var haystack = entrySearchText(entry)

  if (name.indexOf(term) >= 0) return true
  if (id.indexOf(term) >= 0) return true
  if (haystack.indexOf(term) >= 0) return true

  return term.length <= 5 && entryAcronym(entry).indexOf(term) >= 0
}

function allTermsMatch(entry, query) {
  var terms = String(query || "").toLowerCase().trim().split(/\s+/)
  for (var i = 0; i < terms.length; i++) {
    if (terms[i] && !termMatches(entry, terms[i])) return false
  }
  return true
}

// -1 rejects the candidate. Higher is better.
function score(entry, query) {
  var q = bounded(query, FIELD_CHARS).trim().toLowerCase()
  if (!q) return 0
  if (!allTermsMatch(entry, q)) return -1

  var name = entryName(entry).toLowerCase()
  var id = bounded(entry && entry.id, 256).toLowerCase()
  var haystack = entrySearchText(entry)
  var directName = name.indexOf(q)
  var directId = id.indexOf(q)
  if (directName === 0) return 10000 - name.length
  if (directId === 0) return 9500 - id.length
  if (directName > 0) return 8000 - directName * 10 - name.length
  if (directId > 0) return 7600 - directId * 10 - id.length

  var hayIndex = haystack.indexOf(q)
  if (hayIndex >= 0) return 6000 - hayIndex

  var acronym = entryAcronym(entry)
  var acronymIndex = acronym.indexOf(q)
  if (acronymIndex === 0) return 5000 - acronym.length
  if (acronymIndex > 0) return 4600 - acronymIndex * 10 - acronym.length

  return 4000 - name.length
}

var owned = Object.prototype.hasOwnProperty

// `hidden` is indexed with desktop ids, which come off disk, so it is read
// through hasOwnProperty rather than by plain lookup: an id of `constructor`
// would otherwise find a function on the prototype and hide a real entry.
function isHidden(hidden, entry) {
  var id = bounded(entry && entry.id, 256)
  return !!id && !!hidden && owned.call(hidden, id) && hidden[id] === true
}

// Returns [{entry, score}] — the same shape AppLibrary.sortedEntries returns,
// so the caller does not care which of the two produced it. Untyped: `values`
// is whatever DesktopEntries handed over.
function sortedEntries(values, query, hidden, resultLimit, scanLimit) {
  var q = bounded(query, FIELD_CHARS).trim()
  var rows = []
  var list = values || []
  var maxResults = Math.max(1, Math.min(2048, Number(resultLimit) || 512))
  var maxScan = Math.max(maxResults, Math.min(16384, Number(scanLimit) || 4096))

  for (var i = 0; i < list.length && i < maxScan; i++) {
    var entry = list[i]
    if (!entry || entry.noDisplay) continue
    if (isHidden(hidden, entry)) continue
    var name = entryName(entry)
    if (!name) continue
    var value = score(entry, q)
    if (value < 0) continue
    rows.push({ entry: entry, score: value, key: entrySortKey(entry), name: name.toLowerCase() })
  }

  rows.sort(function(a, b) {
    if (q && a.score !== b.score) return b.score - a.score
    if (a.key < b.key) return -1
    if (a.key > b.key) return 1
    if (a.name < b.name) return -1
    if (a.name > b.name) return 1
    return 0
  })

  return rows.slice(0, maxResults)
}

// The id map the helper's read-hides projection turns into, built with a null
// prototype for the same reason Frecency's store is.
function hiddenMap(ids) {
  var next = Object.create(null)
  var list = ids || []
  for (var i = 0; i < list.length && i < 400; i++) {
    var id = bounded(list[i], 256)
    if (id) next[id] = true
  }
  return next
}

if (typeof module !== "undefined") {
  module.exports = {
    entryName: entryName,
    entrySubtext: entrySubtext,
    entryAcronym: entryAcronym,
    score: score,
    sortedEntries: sortedEntries,
    hiddenMap: hiddenMap
  }
}
