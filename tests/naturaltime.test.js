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

// ------------------------------------------------------------- date maths
// Every shape is a full-query match, so each positive is a date question and
// each negative must not steal the cursor from the provider it belongs to.
// The gate test below locks isDateQuery to the parser: a shape that cannot
// resolve must not silence web suggestions, and a second approximation of the
// grammar would be free to drift from the first.
const DATE_POSITIVES = [
  "days until dec 25", "today + 90 days", "friday", "now", "1790000000",
  "fri", "next monday", "+90 days", "-2 weeks", "dec 25 - today",
  "today - dec 25", "weeks until dec 25", "hours until 18:00",
  "minutes until 14:45", "now + 2 hours", "today + 3 hours",
  "2026-01-31 + 1 month", "2026-12-25 + 90 days", "1789999999999",
  "tomorrow + 10 days", "yesterday + 1 day", "months until dec 25",
  "years until 2028-12-25", "months until 2026-06-25", "month until dec 25",
  "months until 20 December 2027", "months until december",
  "years until 20 December 2027", "years until december",
  "years until december 2027", "december + 10 days",
  "20 December 2027 + 1 month", "december 2027 - november 2027"
]

const DATE_NEGATIVES = [
  "meeting tomorrow at 9 for 1h", "remind me in 20m to call mom",
  "10 km to miles", "=2*(3+4)", "1 day to week", "docker desktop",
  "123", "#ff6644", "2026-12-25", "fortnights until dec 25",
  "17900000000", "99999999999999", "days until blah", "+3 mon",
  "in 20m", "", "   ", "constructor + 1 day", "days until constructor"
]

test("date-maths gate agrees with the parser on every fixture", () => {
  for (const q of DATE_POSITIVES) {
    assert.equal(NT.isDateQuery(q), true, JSON.stringify(q))
    assert.ok(NT.parseDateMath(q, noon()), JSON.stringify(q))
  }
  for (const q of DATE_NEGATIVES) {
    assert.equal(NT.isDateQuery(q), false, JSON.stringify(q))
    assert.equal(NT.parseDateMath(q, noon()), null, JSON.stringify(q))
  }
})

test("days until dec 25 counts calendar days", () => {
  const r = NT.parseDateMath("days until dec 25", noon())
  assert.equal(r.kind, "delta")
  assert.equal(r.values[0].label, "Days")
  assert.equal(r.values[0].text, "94")
  assert.equal(r.values[1].label, "Target")
  assert.equal(r.values[1].text, NT.formatLocal(at(2026, 12, 25, 0, 0)))
  assert.equal(r.subtitle, "in 13 weeks 3 days")
})

test("days until from 27 September is the README count", () => {
  const r = NT.parseDateMath("days until dec 25", new Date(2026, 8, 27, 12, 0, 0))
  assert.equal(r.values[0].text, "89")
})

test("today + 90 days lands on the calendar date at midnight", () => {
  const r = NT.parseDateMath("today + 90 days", noon())
  assert.equal(r.kind, "instant")
  const target = at(2026, 12, 21, 0, 0)
  assert.equal(r.values[0].text, NT.formatLocal(target))
  assert.equal(r.values[1].text, String(Math.floor(target.getTime() / 1000)))
  assert.equal(r.values[2].text, NT.formatIso(target, false))
  assert.equal(r.subtitle, "in 12 weeks 6 days · local midnight")
})

test("bare relative form equals the today-anchored one", () => {
  assert.deepEqual(NT.parseDateMath("+90 days", noon()), NT.parseDateMath("today + 90 days", noon()))
})

test("friday is the next Friday", () => {
  const r = NT.parseDateMath("friday", noon()) // noon() is a Tuesday
  const target = at(2026, 9, 25, 0, 0)
  assert.equal(r.values[0].text, NT.formatLocal(target))
  assert.equal(r.values[1].text, String(Math.floor(target.getTime() / 1000)))
  assert.equal(r.subtitle, "in 3 days · local midnight")
})

test("now answers the instant with its zone", () => {
  const r = NT.parseDateMath("now", noon())
  assert.deepEqual(r.at, noon())
  assert.equal(r.values[0].label, "Date")
  assert.equal(r.values[1].text, String(Math.floor(noon().getTime() / 1000)))
  assert.match(r.subtitle, /^Local time · UTC/)
})

test("a bare epoch decodes to the same instant everywhere", () => {
  const r = NT.parseDateMath("1790000000", noon())
  assert.deepEqual(r.at, new Date(1790000000 * 1000))
  assert.equal(r.values[1].label, "Unix")
  assert.equal(r.values[1].text, "1790000000")
  assert.match(r.subtitle, /^Unix seconds · UTC/)
})

test("a 13-digit number is milliseconds", () => {
  const r = NT.parseDateMath("1789999999999", noon())
  assert.deepEqual(r.at, new Date(1789999999999))
  assert.match(r.subtitle, /^Unix milliseconds · UTC/)
})

test("an 11-digit number past 2100 stays a number", () => {
  assert.equal(NT.parseDateMath("17900000000", noon()), null)
  assert.equal(NT.isDateQuery("17900000000"), false)
})

test("dec 25 - today mirrors the until form", () => {
  const r = NT.parseDateMath("dec 25 - today", noon())
  assert.equal(r.values[0].text, "94")
  assert.equal(r.values[1].text, NT.formatLocal(at(2026, 12, 25, 0, 0)))
  assert.equal(r.subtitle, "in 13 weeks 3 days")
})

test("today - dec 25 reads backwards", () => {
  const r = NT.parseDateMath("today - dec 25", noon())
  assert.equal(r.values[0].text, "94")
  assert.equal(r.subtitle, "13 weeks 3 days ago")
})

test("weeks until answers in weeks and explains the remainder", () => {
  const r = NT.parseDateMath("weeks until dec 25", noon())
  assert.equal(r.values[0].label, "Weeks")
  assert.equal(r.values[0].text, "13.4")
  assert.equal(r.subtitle, "in 13 weeks 3 days")
})

test("hours until points at the clock time", () => {
  const r = NT.parseDateMath("hours until 18:00", noon())
  assert.equal(r.values[0].label, "Hours")
  assert.equal(r.values[0].text, "6")
  assert.match(r.values[1].text, /18:00:00/)
})

test("clock units move the instant, not the calendar", () => {
  assert.deepEqual(NT.parseDateMath("now + 2 hours", noon()).at,
    new Date(noon().getTime() + 2 * 3600000))
  assert.deepEqual(NT.parseDateMath("today + 3 hours", noon()).at,
    new Date(noon().getTime() + 3 * 3600000))
})

test("month arithmetic clamps to the short month", () => {
  const jan31 = new Date(2026, 0, 31, 12, 0, 0)
  const r = NT.parseDateMath("2026-01-31 + 1 month", jan31)
  assert.equal(r.values[0].text, NT.formatLocal(new Date(2026, 1, 28, 0, 0)))
})

test("the minus in anchor arithmetic subtracts", () => {
  const back = NT.parseDateMath("friday - 2 weeks", noon())
  assert.equal(back.values[0].text, NT.formatLocal(at(2026, 9, 11, 0, 0)))
  const years = NT.parseDateMath("now - 2 years", noon())
  // Year units are calendar arithmetic like the other date units, so the
  // answer is the date at midnight — the same instant "today - 2 years" gives.
  assert.deepEqual(years.at, at(2024, 9, 22, 0, 0))
  assert.equal(years.values[1].text, String(Math.floor(at(2024, 9, 22, 0, 0).getTime() / 1000)))
})

test("yesterday + 1 day lands on today", () => {
  const r = NT.parseDateMath("yesterday + 1 day", noon())
  assert.equal(r.subtitle, "today · local midnight")
})

test("months until counts whole months with the odd days carried", () => {
  const r = NT.parseDateMath("months until dec 25", noon())
  assert.equal(r.kind, "delta")
  assert.equal(r.values[0].label, "Months")
  assert.equal(r.values[0].text, "3")
  assert.equal(r.values[1].text, NT.formatLocal(at(2026, 12, 25, 0, 0)))
  assert.equal(r.subtitle, "in 3 months 3 days")
})

test("months until from the 30th does not round up", () => {
  const now30 = new Date(2026, 8, 30, 12, 0, 0)
  const r = NT.parseDateMath("months until dec 25", now30)
  assert.equal(r.values[0].text, "2")
  assert.equal(r.subtitle, "in 2 months 3 weeks 4 days")
})

test("months until a past date reads backwards", () => {
  const r = NT.parseDateMath("months until 2026-06-25", noon())
  assert.equal(r.values[0].text, "2")
  assert.equal(r.subtitle, "2 months 3 weeks 6 days ago")
})

test("years until counts whole years with the odd months carried", () => {
  const r = NT.parseDateMath("years until 2028-12-25", noon())
  assert.equal(r.kind, "delta")
  assert.equal(r.values[0].label, "Years")
  assert.equal(r.values[0].text, "2")
  assert.equal(r.values[1].text, NT.formatLocal(at(2028, 12, 25, 0, 0)))
  assert.equal(r.subtitle, "in 2 years 3 months")
})

test("years until a past date reads backwards", () => {
  const r = NT.parseDateMath("years until 2024-06-25", noon())
  assert.equal(r.values[0].text, "2")
  assert.equal(r.subtitle, "2 years 2 months ago")
})

test("months until a year-bearing date keeps the year", () => {
  const r = NT.parseDateMath("months until 20 December 2027", noon())
  assert.equal(r.values[0].text, "14")
  assert.equal(r.values[1].text, NT.formatLocal(at(2027, 12, 20, 0, 0)))
  assert.equal(r.subtitle, "in 14 months 4 weeks")
})

test("months until a bare month counts to its first day", () => {
  const r = NT.parseDateMath("months until december", noon())
  assert.equal(r.values[0].text, "2")
  assert.equal(r.values[1].text, NT.formatLocal(at(2026, 12, 1, 0, 0)))
  assert.equal(r.subtitle, "in 2 months 1 week 2 days")
})

test("years until a month-year counts to its first day", () => {
  const r = NT.parseDateMath("years until december 2027", noon())
  assert.equal(r.values[0].text, "1")
  assert.equal(r.values[1].text, NT.formatLocal(at(2027, 12, 1, 0, 0)))
  assert.equal(r.subtitle, "in 1 year 2 months")
})

test("a bare month anchors arithmetic to its first day", () => {
  const r = NT.parseDateMath("december + 10 days", noon())
  assert.equal(r.values[0].text, NT.formatLocal(at(2026, 12, 11, 0, 0)))
})

test("a year in a month name pins the date instead of rolling forward", () => {
  assert.deepEqual(NT.parseWhen("20 December 2027", noon()).at, at(2027, 12, 20, 9, 0))
  assert.deepEqual(NT.parseWhen("december 2027", noon()).at, at(2027, 12, 1, 9, 0))
  assert.deepEqual(NT.parseWhen("20 December", noon()).at, at(2026, 12, 20, 9, 0))
})

test("calendar events take an explicit year", () => {
  const dated = NT.parseEvent("meeting 20 December 2027 at 18:00 review", noon())
  assert.deepEqual(dated.start, at(2027, 12, 20, 18, 0))
  const monthly = NT.parseEvent("event december 2027 planning", noon())
  assert.deepEqual(monthly.start, at(2027, 12, 1, 9, 0))
  assert.equal(monthly.title, "Planning")
})

test("answers carry the row contract the palette relies on", () => {
  for (const q of DATE_POSITIVES) {
    const r = NT.parseDateMath(q, noon())
    assert.ok(r.kind === "delta" || r.kind === "instant", q)
    assert.equal(typeof r.subtitle, "string", q)
    assert.ok(r.values.length >= 2, q)
    for (const v of r.values) {
      assert.equal(typeof v.label, "string", q)
      assert.equal(typeof v.text, "string", q)
      assert.equal(typeof v.mono, "boolean", q)
    }
  }
})

test("day counts ignore DST", () => {
  const saved = process.env.TZ
  try {
    process.env.TZ = "Europe/Berlin"
    const start = new Date(2026, 2, 28, 12, 0, 0)
    const r = NT.parseDateMath("2026-03-28 + 2 days", start)
    assert.equal(r.values[0].text, NT.formatLocal(new Date(2026, 2, 30, 0, 0)))
  } finally {
    if (saved === undefined) delete process.env.TZ
    else process.env.TZ = saved
  }
})
