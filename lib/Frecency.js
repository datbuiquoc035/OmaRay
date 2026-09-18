// Frecency — how often, weighted by how recently. The ranking `z` and zoxide
// use for directories, applied here to launches.
//
// A raw launch count ages badly: the app opened forty times last spring
// outranks the one opened twice this morning, forever. Decaying the count by
// the age of the last launch fixes that without keeping a full access log —
// two numbers per key is the whole store.

var HOUR = 3600000
var DAY = 86400000

// zoxide's aging curve. The steps are deliberate rather than a smooth
// exponential: something launched in the last hour should jump to the front,
// and anything older than a season settles on a floor instead of vanishing —
// a rarely used app still has to beat one that was never launched at all.
function decay(ageMs) {
  if (ageMs < HOUR) return 4
  if (ageMs < DAY) return 2
  if (ageMs < 7 * DAY) return 0.5
  if (ageMs < 90 * DAY) return 0.25
  return 0.1
}

// The decayed launch count. Unbounded, so it is only ever compared against
// itself — see weight() for the number callers actually rank with.
function rank(entry, now) {
  if (!entry) return 0
  var count = Number(entry.count) || 0
  if (count <= 0) return 0
  var last = Number(entry.last) || 0
  var age = Math.max(0, (Number(now) || Date.now()) - last)
  return count * decay(age)
}

// rank() mapped onto 0..1, saturating rather than linear. Callers scale this
// into a bounded bonus, and the saturation is what makes the bound meaningful:
// the fortieth launch adds almost nothing, so no amount of usage can carry an
// app across a match tier and past a name that starts with what was typed.
function weight(entry, now) {
  var r = rank(entry, now)
  return r > 0 ? r / (r + 6) : 0
}

// Every map in here is null-prototype, and that is load-bearing rather than
// stylistic. The keys are minted from application IDs and command IDs, and a
// hand-edited store can hold anything at all; on an ordinary `{}` a key of
// `__proto__` is not a key but an assignment to the object's prototype, so one
// such entry silently reshapes every lookup that follows. Object.create(null)
// has no prototype to reach, so a key is only ever a key.
function emptyMap() {
  return Object.create(null)
}

var owned = Object.prototype.hasOwnProperty

// Copies an arbitrary object — a freshly parsed store, say — into a map that
// is safe to index with data.
function adopt(source) {
  var next = emptyMap()
  if (!source || typeof source !== "object") return next
  var keys = Object.keys(source)
  for (var i = 0; i < keys.length; i++) {
    var entry = source[keys[i]]
    if (!entry || typeof entry !== "object") continue
    var count = Number(entry.count) || 0
    if (count <= 0) continue
    next[keys[i]] = { count: count, last: Number(entry.last) || 0 }
  }
  return next
}

// Returns a new map; the caller owns persisting it. Copying rather than
// mutating is what makes the QML property assignment fire a change signal.
function bump(usage, key, now) {
  var next = emptyMap()
  var keys = Object.keys(usage || {})
  for (var i = 0; i < keys.length; i++) next[keys[i]] = usage[keys[i]]
  var prev = (usage && owned.call(usage, key)) ? usage[key] : { count: 0 }
  next[key] = { count: (Number(prev.count) || 0) + 1, last: Number(now) || Date.now() }
  return next
}

// Keeps the store from growing without limit. Ranked entries are dropped from
// the bottom, so what survives is what the ranking would have used anyway.
function prune(usage, keep, now) {
  var keys = Object.keys(usage || {})
  if (keys.length <= keep) return usage

  keys.sort(function(a, b) { return rank(usage[b], now) - rank(usage[a], now) })
  var next = emptyMap()
  for (var i = 0; i < keep; i++) next[keys[i]] = usage[keys[i]]
  return next
}

if (typeof module !== "undefined") {
  module.exports = { decay: decay, rank: rank, weight: weight, bump: bump,
                     prune: prune, emptyMap: emptyMap, adopt: adopt }
}
