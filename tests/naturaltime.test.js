const assert = require("node:assert/strict")
const test = require("node:test")
const NT = require("../lib/NaturalTime.js")

// Fixed Tuesday noon: deterministic regardless of when the suite runs.
function noon() { return new Date(2026, 8, 22, 12, 0, 0) }

function at(y, mo, d, h, mi) { return new Date(y, mo - 1, d, h, mi, 0, 0) }

test("README example keeps trigger word as the title", () => {
  const r = NT.parseEvent("meeting tomorrow at 9 for 1h", noon())
  assert.ok(r)
  assert.equal(r.title, "Meeting")
  assert.deepEqual(r.start, at(2026, 9, 23, 9, 0))
  assert.equal(r.durationMinutes, 60)
})

test("time-only event still yields a titled row", () => {
  const r = NT.parseEvent("meeting tomorrow at 9", noon())
  assert.ok(r)
  assert.equal(r.title, "Meeting")
  assert.deepEqual(r.start, at(2026, 9, 23, 9, 0))
})

test("titled events keep working", () => {
  const r = NT.parseEvent("cal lunch tomorrow at 12", noon())
  assert.ok(r)
  assert.equal(r.title, "Lunch")
  assert.deepEqual(r.start, at(2026, 9, 23, 12, 0))
})

test("dd-mm-yyyy with clock keeps the date", () => {
  const r = NT.parseEvent("meeting 25-12-2026 at 18:00 party", noon())
  assert.ok(r)
  assert.deepEqual(r.start, at(2026, 12, 25, 18, 0))
  assert.match(r.title, /party/i)
})

test("dd-mm-yyyy without clock defaults to 9:00", () => {
  const r = NT.parseEvent("event 25-12-2026 release", noon())
  assert.ok(r)
  assert.deepEqual(r.start, at(2026, 12, 25, 9, 0))
})

test("dotted date with 'at' keeps the date", () => {
  const r = NT.parseEvent("meeting 25.12.2026 at 18:00 party", noon())
  assert.ok(r)
  assert.deepEqual(r.start, at(2026, 12, 25, 18, 0))
})

test("slash date works too", () => {
  const r = NT.parseEvent("meeting 25/12/2026 at 18:00 party", noon())
  assert.ok(r)
  assert.deepEqual(r.start, at(2026, 12, 25, 18, 0))
})

test("ISO dates still parse", () => {
  const r = NT.parseEvent("meeting 2026-09-23 14:00 review", noon())
  assert.ok(r)
  assert.equal(r.title, "Review")
  assert.deepEqual(r.start, at(2026, 9, 23, 14, 0))
})

test("out-of-range numbers are not dates", () => {
  const w = NT.parseWhen("99-99-9999", noon())
  assert.equal(w, null)
})

test("month name with 'at' keeps the date", () => {
  const r = NT.parseEvent("event dec 24 at 18:00 dinner", noon())
  assert.ok(r)
  assert.deepEqual(r.start, at(2026, 12, 24, 18, 0))
  assert.match(r.title, /dinner/i)
})

test("reminders are unaffected", () => {
  const r = NT.parseReminder("remind me in 20m to call mom", noon())
  assert.ok(r)
  assert.equal(r.message, "Call mom")
  assert.equal(r.minutes, 20)
})
