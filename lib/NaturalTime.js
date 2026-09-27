// Natural-language time parsing for the reminder and calendar rows.
//
// parseWhen() finds the first time phrase anywhere in a string and reports
// both the resolved Date and the span it consumed, so the caller can subtract
// it and keep the rest as the title/message. Everything resolves against an
// injected `now` so the behaviour is testable.

// Same rule as the other tables in lib/: these are indexed with words lifted
// out of the query, so they are only ever consulted for keys they own.
// Object.prototype is not a calendar.
var owned = Object.prototype.hasOwnProperty

function tableGet(table, key) {
  return owned.call(table, key) ? table[key] : undefined
}

var WEEKDAYS = {
  sunday: 0, sun: 0,
  monday: 1, mon: 1,
  tuesday: 2, tue: 2, tues: 2,
  wednesday: 3, wed: 3,
  thursday: 4, thu: 4, thur: 4, thurs: 4,
  friday: 5, fri: 5,
  saturday: 6, sat: 6
}

var MONTHS = {
  jan: 0, january: 0, feb: 1, february: 1, mar: 2, march: 2, apr: 3, april: 3,
  may: 4, jun: 5, june: 5, jul: 6, july: 6, aug: 7, august: 7,
  sep: 8, sept: 8, september: 8, oct: 9, october: 9, nov: 10, november: 10,
  dec: 11, december: 11
}

var UNIT_MINUTES = {
  s: 1 / 60, sec: 1 / 60, secs: 1 / 60, second: 1 / 60, seconds: 1 / 60,
  m: 1, min: 1, mins: 1, minute: 1, minutes: 1,
  h: 60, hr: 60, hrs: 60, hour: 60, hours: 60,
  d: 1440, day: 1440, days: 1440,
  w: 10080, week: 10080, weeks: 10080
}

var WEEKDAY_ALTERNATION = "sunday|sun|monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat"

function startOfDay(d) {
  var out = new Date(d.getTime())
  out.setHours(0, 0, 0, 0)
  return out
}

function addDays(d, n) {
  var out = new Date(d.getTime())
  out.setDate(out.getDate() + n)
  return out
}

// Next occurrence of `weekday`, strictly in the future. "next friday" on a
// Friday means the Friday a week out, which is what people mean by it.
function nextWeekday(now, weekday) {
  var delta = (weekday - now.getDay() + 7) % 7
  if (delta === 0) delta = 7
  return addDays(startOfDay(now), delta)
}

function applyClock(day, hour, minute) {
  var out = new Date(day.getTime())
  out.setHours(hour, minute, 0, 0)
  return out
}

function normalizeHour(hour, meridiem) {
  if (!meridiem) return hour
  var h = hour % 12
  return meridiem === "pm" ? h + 12 : h
}

function dayAnchor(now, word) {
  if (!word) return null
  var w = word.toLowerCase()
  if (w === "today") return startOfDay(now)
  if (w === "tonight") return startOfDay(now)
  if (w === "tomorrow" || w === "tmr" || w === "morgen") return addDays(startOfDay(now), 1)
  if (w.indexOf("next ") === 0) w = w.slice(5).trim()
  var weekday = tableGet(WEEKDAYS, w)
  if (weekday !== undefined) return nextWeekday(now, weekday)
  return null
}

function result(at, from, to, label) {
  return { at: at, from: from, to: to, label: label }
}

function labelFor(at, now) {
  var sameDay = startOfDay(at).getTime() === startOfDay(now).getTime()
  var tomorrow = startOfDay(at).getTime() === addDays(startOfDay(now), 1).getTime()
  var hh = ("0" + at.getHours()).slice(-2)
  var mm = ("0" + at.getMinutes()).slice(-2)
  var clock = hh + ":" + mm
  if (sameDay) return "today at " + clock
  if (tomorrow) return "tomorrow at " + clock
  var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var withinWeek = at.getTime() - now.getTime() < 7 * 86400000
  if (withinWeek) return names[at.getDay()] + " at " + clock
  return at.getDate() + " " + ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][at.getMonth()] + " at " + clock
}

// Returns { at, from, to, label } or null. `from`/`to` bound the matched span.
function parseWhen(text, now) {
  var s = String(text || "")
  if (!s.trim()) return null
  now = now || new Date()
  var m

  // "in 1h30", "in 2 hours and 15 minutes"
  m = s.match(/\bin\s+(\d+)\s*(?:h|hr|hrs|hour|hours)\s*(?:and\s+)?(\d+)\s*(?:m|min|mins|minute|minutes)?\b/i)
  if (m) {
    var mins = Number(m[1]) * 60 + Number(m[2])
    var at = new Date(now.getTime() + mins * 60000)
    return result(at, m.index, m.index + m[0].length, labelFor(at, now))
  }

  // "in 20m", "in 3 days"
  m = s.match(/\bin\s+(\d+(?:[.,]\d+)?)\s*(seconds|second|secs|sec|minutes|minute|mins|min|hours|hour|hrs|hr|days|day|weeks|week|s|m|h|d|w)\b/i)
  if (m) {
    var n = Number(String(m[1]).replace(",", "."))
    var per = tableGet(UNIT_MINUTES, m[2].toLowerCase())
    if (isFinite(n) && per) {
      var at2 = new Date(now.getTime() + Math.round(n * per) * 60000)
      return result(at2, m.index, m.index + m[0].length, labelFor(at2, now))
    }
  }

  // "in an hour", "in a minute"
  m = s.match(/\bin\s+(?:a|an|one)\s+(minute|hour|day|week)\b/i)
  if (m) {
    var at3 = new Date(now.getTime() + (tableGet(UNIT_MINUTES, m[1].toLowerCase()) || 0) * 60000)
    return result(at3, m.index, m.index + m[0].length, labelFor(at3, now))
  }

  // Calendar dates before any clock branch: "2026-09-12 14:00",
  // "25.12.2026 at 18:00", "25-12-2026", "25/12 9:00". These must run before
  // the "at HH:MM" branches below, or the clock tail of a dated query is
  // matched on its own and the date is silently dropped.
  m = s.match(/\b(\d{4})-(\d{2})-(\d{2})(?:\s+(\d{1,2}):(\d{2}))?\b/)
  if (m) {
    var atIso = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), m[4] ? Number(m[4]) : 9, m[5] ? Number(m[5]) : 0, 0, 0)
    return result(atIso, m.index, m.index + m[0].length, labelFor(atIso, now))
  }
  m = s.match(/\b(\d{1,2})[.\-/](\d{1,2})(?:[.\-/](\d{4}|\d{2}))?\s*(?:at\s+)?(?:(\d{1,2}):(\d{2}))?/)
  if (m && m[2]) {
    var dayN = Number(m[1]), monthN = Number(m[2])
    var hourN = m[4] ? Number(m[4]) : 9, minuteN = m[5] ? Number(m[5]) : 0
    // Out-of-range numbers are not dates — fall through to the clock and
    // word branches rather than letting the Date constructor roll over.
    if (dayN >= 1 && dayN <= 31 && monthN >= 1 && monthN <= 12 && hourN <= 23 && minuteN <= 59) {
      var yearD = m[3] ? (m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3])) : now.getFullYear()
      var atDated = new Date(yearD, monthN - 1, dayN, hourN, minuteN, 0, 0)
      if (!m[3] && atDated.getTime() < now.getTime()) atDated.setFullYear(yearD + 1)
      return result(atDated, m.index, m.index + m[0].length, labelFor(atDated, now))
    }
  }

  // "dec 24 at 18:00" / "24 dec" — also before the clock branches, for
  // the same reason: the "at HH:MM" tail must not win over the date.
  //
  // An explicit four-digit year pins the date to that year ("20 December
  // 2027", "december 2027" for the month's first day). Four digits on purpose:
  // with two, "dec 25 18:00" would read 18 as a year. Without a year the next
  // upcoming occurrence is used, as before.
  m = s.match(/\b(?:(\d{1,2})\s+([a-z]{3,9})(?:\s+(\d{4}))?|([a-z]{3,9})\s+(\d{4})|([a-z]{3,9})\s+(\d{1,2})(?:\s+(\d{4}))?)(?:\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?\b/i)
  if (m) {
    var monthWord = (m[2] || m[4] || m[6] || "").toLowerCase()
    var dayNum = m[4] ? 1 : Number(m[1] || m[7])
    var yearM = m[3] || m[5] || m[8]
    var monthIndex = tableGet(MONTHS, monthWord)
    if (monthIndex !== undefined && dayNum >= 1 && dayNum <= 31) {
      var hourM = m[9] ? normalizeHour(Number(m[9]), (m[11] || "").toLowerCase()) : 9
      var atMon = new Date(yearM ? Number(yearM) : now.getFullYear(), monthIndex, dayNum,
        hourM, m[10] ? Number(m[10]) : 0, 0, 0)
      if (!yearM && atMon.getTime() < now.getTime()) atMon.setFullYear(now.getFullYear() + 1)
      return result(atMon, m.index, m.index + m[0].length, labelFor(atMon, now))
    }
  }

  // "at noon" / "at midnight", optionally with a day word
  m = s.match(new RegExp("\\b(?:(today|tonight|tomorrow|tmr|morgen|next\\s+(?:" + WEEKDAY_ALTERNATION + ")|" + WEEKDAY_ALTERNATION + ")\\s+)?at\\s+(noon|midday|midnight)\\b", "i"))
  if (m) {
    var anchorA = dayAnchor(now, m[1]) || startOfDay(now)
    var hourA = m[2].toLowerCase() === "midnight" ? 0 : 12
    var atA = applyClock(anchorA, hourA, 0)
    if (!m[1] && atA.getTime() <= now.getTime()) atA = addDays(atA, 1)
    return result(atA, m.index, m.index + m[0].length, labelFor(atA, now))
  }

  // "[tomorrow] at 15:30" / "at 3pm" / "friday at 9"
  m = s.match(new RegExp("\\b(?:(today|tonight|tomorrow|tmr|morgen|next\\s+(?:" + WEEKDAY_ALTERNATION + ")|" + WEEKDAY_ALTERNATION + ")\\s+)?at\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\b", "i"))
  if (m) return fromClockMatch(s, m, now)

  // "tomorrow 15:30" / "friday 9am" — day word, no "at"
  m = s.match(new RegExp("\\b(today|tonight|tomorrow|tmr|morgen|next\\s+(?:" + WEEKDAY_ALTERNATION + ")|" + WEEKDAY_ALTERNATION + ")\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\b", "i"))
  if (m) return fromClockMatch(s, [m[0], m[1], m[2], m[3], m[4]].concat([]), now, m.index)

  // Bare day word: "tomorrow", "tonight", "friday"
  m = s.match(new RegExp("\\b(today|tonight|tomorrow|tmr|morgen|next\\s+(?:" + WEEKDAY_ALTERNATION + ")|" + WEEKDAY_ALTERNATION + ")\\b", "i"))
  if (m) {
    var anchorB = dayAnchor(now, m[1])
    if (anchorB) {
      var word = m[1].toLowerCase()
      var defaultHour = word === "tonight" ? 20 : 9
      var atB = applyClock(anchorB, defaultHour, 0)
      if (atB.getTime() <= now.getTime()) atB = new Date(now.getTime() + 3600000)
      return result(atB, m.index, m.index + m[0].length, labelFor(atB, now))
    }
  }

  // Bare clock: "15:30", "3pm"
  m = s.match(/\b(\d{1,2}):(\d{2})\s*(am|pm)?\b/i)
  if (!m) m = s.match(/\b(\d{1,2})()\s*(am|pm)\b/i)
  if (m) {
    var hourC = normalizeHour(Number(m[1]), (m[3] || "").toLowerCase())
    var minuteC = m[2] ? Number(m[2]) : 0
    if (hourC > 23 || minuteC > 59) return null
    var atC = applyClock(startOfDay(now), hourC, minuteC)
    if (atC.getTime() <= now.getTime()) {
      if (!m[3] && hourC < 12) {
        atC = applyClock(startOfDay(now), hourC + 12, minuteC)
        if (atC.getTime() <= now.getTime()) atC = addDays(atC, 1)
      } else {
        atC = addDays(atC, 1)
      }
    }
    return result(atC, m.index, m.index + m[0].length, labelFor(atC, now))
  }

  // "in 20" with no unit — minutes is the only sane reading
  m = s.match(/\bin\s+(\d{1,4})\b/i)
  if (m) {
    var atD = new Date(now.getTime() + Number(m[1]) * 60000)
    return result(atD, m.index, m.index + m[0].length, labelFor(atD, now))
  }

  return null
}

// Shared tail of the two "day word + clock" branches.
function fromClockMatch(source, m, now, indexOverride) {
  var dayWord = m[1]
  var hour = Number(m[2])
  var minute = m[3] ? Number(m[3]) : 0
  var meridiem = (m[4] || "").toLowerCase()
  if (hour > 23 || minute > 59) return null

  var anchor = dayAnchor(now, dayWord)
  var explicitDay = anchor !== null && String(dayWord || "").toLowerCase() !== "today" && String(dayWord || "").toLowerCase() !== "tonight"
  if (!anchor) anchor = startOfDay(now)

  var at = applyClock(anchor, normalizeHour(hour, meridiem), minute)

  if (!explicitDay && at.getTime() <= now.getTime()) {
    // No day was named and the clock already passed. Prefer the pm reading of
    // a bare morning hour ("at 3" at 14:00 means 15:00), then roll to tomorrow.
    if (!meridiem && hour < 12) {
      at = applyClock(anchor, hour + 12, minute)
      if (at.getTime() <= now.getTime()) at = addDays(at, 1)
    } else {
      at = addDays(at, 1)
    }
  }

  var index = indexOverride !== undefined ? indexOverride : m.index
  return result(at, index, index + m[0].length, labelFor(at, now))
}

function cut(text, from, to) {
  return (String(text).slice(0, from) + " " + String(text).slice(to)).replace(/\s+/g, " ").trim()
}

function tidy(text) {
  return String(text || "")
    .replace(/^(?:to|that|about|for|:|-|–|,)\s+/i, "")
    .replace(/\s+(?:to|that|about|at|on|for)$/i, "")
    .replace(/^[\s:,-]+|[\s:,-]+$/g, "")
    .replace(/\s+/g, " ")
    .trim()
}

function titleCase(text) {
  var s = String(text || "").trim()
  if (!s) return s
  return s.charAt(0).toUpperCase() + s.slice(1)
}

function minutesUntil(at, now) {
  return Math.max(1, Math.ceil((at.getTime() - (now || new Date()).getTime()) / 60000))
}

var REMINDER_TRIGGER = /^(?:remind\s+me|remind|reminder|reminders|remember|erinner\s+mich|erinnere\s+mich)\b[\s:,]*/i

function isReminderQuery(text) {
  return REMINDER_TRIGGER.test(String(text || "").trim())
}

// -> { message, at, minutes, label } | { needsTime: true, message } | null
function parseReminder(text, now) {
  var s = String(text || "").trim()
  if (!isReminderQuery(s)) return null
  now = now || new Date()

  var body = s.replace(REMINDER_TRIGGER, "")
  var when = parseWhen(body, now)
  if (!when) return { needsTime: true, message: titleCase(tidy(body)) }

  var message = titleCase(tidy(cut(body, when.from, when.to)))
  return {
    message: message,
    at: when.at,
    minutes: minutesUntil(when.at, now),
    label: when.label
  }
}

var EVENT_TRIGGER = /^(?:cal|calendar|event|meeting|appointment|appt|schedule|termin)\b[\s:,]*/i

var EVENT_NOUNS = {
  meeting: "Meeting", appointment: "Appointment", appt: "Appointment",
  event: "Event", termin: "Termin"
}

function isEventQuery(text) {
  return EVENT_TRIGGER.test(String(text || "").trim())
}

// -> { title, start, end, label, durationMinutes } | null
function parseEvent(text, now) {
  var s = String(text || "").trim()
  if (!isEventQuery(s)) return null
  now = now || new Date()

  var triggerMatch = s.match(EVENT_TRIGGER)
  var triggerWord = triggerMatch ? triggerMatch[0].replace(/[\s:,]+$/, "").toLowerCase() : ""
  var body = s.replace(EVENT_TRIGGER, "")

  // Pull an explicit duration out first so "for 2 hours" is never mistaken
  // for a start time.
  var durationMinutes = 60
  var dm = body.match(/\bfor\s+(\d+(?:[.,]\d+)?)\s*(minutes|minute|mins|min|hours|hour|hrs|hr|m|h)\b/i)
  if (dm) {
    var per = tableGet(UNIT_MINUTES, dm[2].toLowerCase())
    var n = Number(String(dm[1]).replace(",", "."))
    if (per && isFinite(n)) durationMinutes = Math.max(5, Math.round(n * per))
    body = cut(body, dm.index, dm.index + dm[0].length)
  }

  var when = parseWhen(body, now)
  var start
  var rest = body
  if (when) {
    start = when.at
    rest = cut(body, when.from, when.to)
  } else {
    // Next full hour is the least surprising default.
    start = new Date(now.getTime())
    start.setMinutes(0, 0, 0)
    start.setHours(start.getHours() + 1)
  }

  var title = tidy(rest)
  // "meeting with sarah" reads better than "With sarah": when the remainder
  // opens with a preposition, the trigger word was part of the name.
  var noun = tableGet(EVENT_NOUNS, triggerWord)
  if (noun && /^(with|w\/|re|about|für|fuer)\b/i.test(title))
    title = noun + " " + title
  title = titleCase(title)
  // A query that is only a trigger plus a time ("meeting tomorrow at 9 for
  // 1h") still names an event — the trigger word is the title.
  if (!title) title = noun || titleCase(triggerWord) || "Event"
  if (!title) return null

  return {
    title: title,
    start: start,
    end: new Date(start.getTime() + durationMinutes * 60000),
    durationMinutes: durationMinutes,
    label: labelFor(start, now)
  }
}

function pad(n) { return ("0" + n).slice(-2) }

// Google Calendar and iCalendar both take UTC basic format.
function toUtcBasic(d) {
  return d.getUTCFullYear() + pad(d.getUTCMonth() + 1) + pad(d.getUTCDate())
    + "T" + pad(d.getUTCHours()) + pad(d.getUTCMinutes()) + pad(d.getUTCSeconds()) + "Z"
}

function formatDuration(minutes) {
  var m = Math.max(1, Math.round(minutes))
  if (m < 60) return m + " min"
  var h = Math.floor(m / 60)
  var rest = m % 60
  if (m < 1440) return rest ? h + "h " + rest + "m" : h + "h"
  var d = Math.floor(m / 1440)
  var hRest = Math.floor((m % 1440) / 60)
  return hRest ? d + "d " + hRest + "h" : d + "d"
}

// ------------------------------------------------------------- date maths
// The direct date questions: "days until dec 25", "today + 90 days", "friday",
// "now", "1790000000". Every shape is a full-query match on purpose — a
// partial match would take the cursor off whatever app or command the query
// was aimed at, and the only date queries that deserve to answer first are
// the ones that are nothing but a date question.
//
// The date forms themselves are not re-implemented. Every operand goes back
// through parseWhen, which already knows months, ISO, dd-mm-yyyy and weekdays,
// so this file keeps one calendar rather than two.

var DM_DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var DM_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// Longest spellings first, so "sept" is not read as "sep" and "march" is not
// read as "mar". The table itself is the authority; this only tokenizes.
var DM_MONTH_ALTERNATION = "january|jan|february|feb|march|mar|april|apr|june|jun"
  + "|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec|may"

var DM_WEEKDAY_ALTERNATION = "next\\s+(?:" + WEEKDAY_ALTERNATION + ")|" + WEEKDAY_ALTERNATION
var DM_DAY_ALTERNATION = "today|tonight|tomorrow|tmr|morgen|yesterday|" + DM_WEEKDAY_ALTERNATION

// An operand that names a day. "now" is here rather than in the day-word list
// because it is the one anchor that resolves against the clock; resolveAnchor
// checks for it before anything else, so a token match never turns it into a
// midnight. The month alternatives mirror the month-name branch of parseWhen —
// day-first with an optional year, month plus a year for the month's first
// day, day-first without one, and a bare month for the same — so every date
// the parser understands also survives being an operand.
var DM_TOKEN = "(?:now|" + DM_DAY_ALTERNATION
  + "|\\d{4}-\\d{1,2}-\\d{1,2}"                             // 2026-12-25
  + "|\\d{1,2}[.\\-/]\\d{1,2}(?:[.\\-/]\\d{2,4})?"           // 25.12.2026, 25-12, 25/12
  + "|(?:" + DM_MONTH_ALTERNATION + ")\\s+\\d{4}"            // december 2027
  + "|\\d{1,2}\\s+(?:" + DM_MONTH_ALTERNATION + ")(?:\\s+\\d{4})?"  // 20 dec, 20 dec 2027
  + "|(?:" + DM_MONTH_ALTERNATION + ")\\s+\\d{1,2}(?:\\s+\\d{4})?" // dec 20, dec 20 2027
  + "|(?:" + DM_MONTH_ALTERNATION + "))"                     // december

// "day" units move the calendar, "clock" units move the instant, "month" is
// calendar too but needs a clamp. Bare "mon" is left out of the month units on
// purpose: it is a weekday abbreviation, and reading `+3 mon` as three months
// would be a coin flip.
var DM_UNITS = {
  s: { kind: "clock", ms: 1000, label: "Seconds" },
  sec: { kind: "clock", ms: 1000, label: "Seconds" },
  secs: { kind: "clock", ms: 1000, label: "Seconds" },
  second: { kind: "clock", ms: 1000, label: "Seconds" },
  seconds: { kind: "clock", ms: 1000, label: "Seconds" },
  min: { kind: "clock", ms: 60000, label: "Minutes" },
  mins: { kind: "clock", ms: 60000, label: "Minutes" },
  minute: { kind: "clock", ms: 60000, label: "Minutes" },
  minutes: { kind: "clock", ms: 60000, label: "Minutes" },
  h: { kind: "clock", ms: 3600000, label: "Hours" },
  hr: { kind: "clock", ms: 3600000, label: "Hours" },
  hrs: { kind: "clock", ms: 3600000, label: "Hours" },
  hour: { kind: "clock", ms: 3600000, label: "Hours" },
  hours: { kind: "clock", ms: 3600000, label: "Hours" },
  d: { kind: "day", count: 1, label: "Days" },
  day: { kind: "day", count: 1, label: "Days" },
  days: { kind: "day", count: 1, label: "Days" },
  w: { kind: "day", count: 7, label: "Weeks" },
  week: { kind: "day", count: 7, label: "Weeks" },
  weeks: { kind: "day", count: 7, label: "Weeks" },
  month: { kind: "month", count: 1, label: "Months" },
  months: { kind: "month", count: 1, label: "Months" },
  year: { kind: "month", count: 12, label: "Months" },
  years: { kind: "month", count: 12, label: "Months" },
  yr: { kind: "month", count: 12, label: "Months" },
  yrs: { kind: "month", count: 12, label: "Months" },
  y: { kind: "month", count: 12, label: "Months" }
}

var DM_UNIT_ALTERNATION = "seconds|second|secs|sec|minutes|minute|mins|min|hours|hour|hrs|hr"
  + "|days|day|weeks|week|months|month|years|year|yrs|yr|s|m|h|d|w|y"

// 1970-01-01 to 2100-01-01, seconds and milliseconds. The upper bound is the
// whole point: without it an 11-digit build number or a phone number would be
// answered as a date in the 25th century.
var DM_EPOCH_MAX_S = 4102444800
var DM_EPOCH_MAX_MS = DM_EPOCH_MAX_S * 1000
var DM_EPOCH_MIN_S = 100000000
var DM_EPOCH_S = /^\d{9,11}$/
var DM_EPOCH_MS = /^\d{13}$/
var DM_NOW = /^now$/i
var DM_WEEKDAY = new RegExp("^(?:" + DM_WEEKDAY_ALTERNATION + ")$", "i")
var DM_DAY_WORD = new RegExp("^(?:" + DM_DAY_ALTERNATION + ")$", "i")
var DM_UNTIL = /^\s*(days?|weeks?|hours?|minutes?|months?|years?)\s+(?:until|till|til|to|before)\s+(.+?)\s*$/i
var DM_REL = new RegExp("^\\s*(" + DM_TOKEN + ")\\s*([+-])\\s*(\\d+(?:[.,]\\d+)?)\\s*("
  + DM_UNIT_ALTERNATION + ")\\s*$", "i")
var DM_BARE_REL = new RegExp("^\\s*([+-])\\s*(\\d+(?:[.,]\\d+)?)\\s*("
  + DM_UNIT_ALTERNATION + ")\\s*$", "i")
// Spaces are required around the dash: without them "2026-12-25" would parse as
// a span of two years.
var DM_SPAN = new RegExp("^\\s*(" + DM_TOKEN + ")\\s+-\\s+(" + DM_TOKEN + ")\\s*$", "i")

function dmPad(n) { return ("0" + n).slice(-2) }

// Calendar-day count. Deliberately not (b - a) / 86400000: 28 to 30 March is
// 47 real hours in a DST zone and still two days apart, and "days until dec 25"
// is a question about the calendar, not about elapsed milliseconds.
function dayNumber(d) {
  return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / 86400000
}

function formatLocal(d) {
  return DM_DAYS[d.getDay()] + " " + d.getDate() + " " + DM_MONTHS[d.getMonth()] + " " + d.getFullYear()
}

function formatLocalTime(d) {
  return formatLocal(d) + ", " + dmPad(d.getHours()) + ":" + dmPad(d.getMinutes()) + ":" + dmPad(d.getSeconds())
}

// Local ISO 8601, not toISOString()'s Z. Copying a date into a calendar, a
// commit or a bug report wants the wall time the user was looking at.
function formatIso(d, withTime) {
  var head = d.getFullYear() + "-" + dmPad(d.getMonth() + 1) + "-" + dmPad(d.getDate())
  if (!withTime) return head
  var offset = -d.getTimezoneOffset()
  var sign = offset < 0 ? "-" : "+"
  var abs = Math.abs(offset)
  return head + "T" + dmPad(d.getHours()) + ":" + dmPad(d.getMinutes()) + ":" + dmPad(d.getSeconds())
    + sign + dmPad(Math.floor(abs / 60)) + ":" + dmPad(abs % 60)
}

// Derived from the offset rather than Intl, so the string is the same in the
// palette and under node, and so half-hour zones keep their half hour.
function formatZone(d) {
  var offset = -d.getTimezoneOffset()
  var sign = offset < 0 ? "-" : "+"
  var abs = Math.abs(offset)
  return "UTC" + sign + Math.floor(abs / 60) + (abs % 60 ? ":" + dmPad(abs % 60) : "")
}

function unixSeconds(d) { return Math.floor(d.getTime() / 1000) }

// Days are whole, a week count is not, and "12.7" beats "12 days and 5 hours".
function formatCount(n) { return String(Math.round(n * 10) / 10) }

function formatDaySpan(n) {
  var weeks = Math.floor(n / 7)
  var rest = n % 7
  if (weeks === 0) return n + (n === 1 ? " day" : " days")
  if (rest === 0) return weeks + (weeks === 1 ? " week" : " weeks")
  return weeks + (weeks === 1 ? " week " : " weeks ") + rest + (rest === 1 ? " day" : " days")
}

function formatSpan(ms) {
  var text = formatDuration(Math.round(Math.abs(ms) / 60000))
  return ms >= 0 ? "in " + text : text + " ago"
}

// A day-granularity answer describes itself in days, not in elapsed hours: from
// noon, ninety days is "in 90 days" and not "in 89d 12h".
function formatDayDelta(days) {
  if (days === 0) return "today"
  var n = Math.abs(days)
  return days >= 0 ? "in " + formatDaySpan(n) : formatDaySpan(n) + " ago"
}

function isMidnight(d) {
  return d.getHours() === 0 && d.getMinutes() === 0 && d.getSeconds() === 0
}

// A result's own instant resolves its own operands. "yesterday" is handled
// here rather than in dayAnchor so the reminder and calendar branches keep
// exactly the vocabulary they had.
function resolveAnchor(token, now) {
  var t = String(token || "").trim()
  if (!t) return null
  if (/^now$/i.test(t)) return new Date(now.getTime())
  if (/^yesterdays?$/i.test(t)) return addDays(startOfDay(now), -1)
  if (DM_DAY_WORD.test(t)) return dayAnchor(now, t.toLowerCase())
  // A bare month names its first day: "months until december" counts to
  // 1 December, this year if it is still ahead, else next year.
  var monthOnly = tableGet(MONTHS, t.toLowerCase())
  if (monthOnly !== undefined) {
    var first = new Date(now.getFullYear(), monthOnly, 1, 0, 0, 0, 0)
    if (first.getTime() < startOfDay(now).getTime())
      first = new Date(now.getFullYear() + 1, monthOnly, 1, 0, 0, 0, 0)
    return first
  }
  var when = parseWhen(t, now)
  return when ? when.at : null
}

function shift(at, amount, unit) {
  var u = tableGet(DM_UNITS, unit)
  if (!u) return null
  if (u.kind === "clock") return new Date(at.getTime() + amount * u.ms)
  // Calendar units, so a day is a day across a DST boundary. Fractional days
  // are rounded rather than silently truncated by setDate.
  var n = Math.round(amount)
  var out = startOfDay(at)
  if (u.kind === "day") {
    out.setDate(out.getDate() + n * u.count)
    return out
  }
  // Clamp instead of letting the Date constructor roll over: 31 January plus
  // one month is 28 February, not 3 March.
  var day = out.getDate()
  out.setDate(1)
  out.setMonth(out.getMonth() + n * u.count)
  var lastDay = new Date(out.getFullYear(), out.getMonth() + 1, 0).getDate()
  out.setDate(Math.min(day, lastDay))
  return out
}

// A count and the date it counted to. Always two rows: the number is the
// answer, the date is what the query resolved to, which is the other half of
// what was asked.
function deltaAnswer(count, targetText, label, subtitle) {
  return {
    kind: "delta",
    subtitle: subtitle,
    count: Math.abs(count),
    values: [
      { label: label, text: formatCount(Math.abs(count)), mono: true },
      { label: "Target", text: targetText, mono: false }
    ]
  }
}

// A resolved instant: what the user reads, the number a script wants, and the
// string a machine wants. Midnight results drop the clock from the human and
// ISO forms, because a date was asked for and 00:00 is noise.
function instantAnswer(at, now, subtitle) {
  var midnight = isMidnight(at)
  var span = midnight
    ? formatDayDelta(dayNumber(at) - dayNumber(now))
    : formatSpan(at.getTime() - now.getTime())
  return {
    kind: "instant",
    subtitle: subtitle || (span + (midnight ? " · local midnight" : "")),
    at: at,
    midnight: midnight,
    values: [
      { label: "Date", text: midnight ? formatLocal(at) : formatLocalTime(at), mono: false },
      { label: "Unix", text: String(unixSeconds(at)), mono: true },
      { label: "ISO", text: formatIso(at, !midnight), mono: true }
    ]
  }
}

// The date an operand resolved to, at the precision the question was asked at:
// "hours until 18:00" points at 18:00, "days until dec 25" at the day.
function readable(at, withTime) {
  return withTime ? formatLocalTime(at) : formatLocal(at)
}

// Whole calendar months from a to b: a month only counts once the
// day-of-month arrives. 22 Sep to 25 Dec is 3; 30 Sep to 25 Dec is 2, with
// the odd days carried in the subtitle rather than rounded away.
function monthDelta(from, to) {
  var months = (to.getFullYear() - from.getFullYear()) * 12 + (to.getMonth() - from.getMonth())
  if (months > 0 && to.getDate() < from.getDate()) months--
  if (months < 0 && to.getDate() > from.getDate()) months++
  return months
}

// Whole calendar years, same rule on the month and the day: 22 Sep 2026 to
// 25 Dec 2028 is 2, with the odd months carried in the subtitle.
function yearDelta(from, to) {
  var years = to.getFullYear() - from.getFullYear()
  if (years > 0 && (to.getMonth() < from.getMonth()
      || (to.getMonth() === from.getMonth() && to.getDate() < from.getDate()))) years--
  if (years < 0 && (to.getMonth() > from.getMonth()
      || (to.getMonth() === from.getMonth() && to.getDate() > from.getDate()))) years++
  return years
}

function plural(n, one, many) {
  return Math.abs(n) + " " + (Math.abs(n) === 1 ? one : many)
}

function formatMonthDelta(months, restDays) {
  var future = months > 0 || (months === 0 && restDays >= 0)
  var text = plural(months, "month", "months")
  if (Math.abs(restDays) > 0) text += " " + formatDaySpan(Math.abs(restDays))
  return future ? "in " + text : text + " ago"
}

function formatYearDelta(years, restMonths) {
  var future = years > 0 || (years === 0 && restMonths >= 0)
  var text = plural(years, "year", "years")
  if (Math.abs(restMonths) > 0) text += " " + plural(restMonths, "month", "months")
  return future ? "in " + text : text + " ago"
}

function untilAnswer(unit, target, now) {
  var u = tableGet(DM_UNITS, unit)
  if (!u) return null
  var spanMs = target.getTime() - now.getTime()
  var days = dayNumber(startOfDay(target)) - dayNumber(now)
  var label = u.label
  var count, subtitle
  if (u.kind === "clock") {
    count = spanMs / u.ms
    subtitle = formatSpan(spanMs)
  } else if (u.kind === "day") {
    count = days / u.count
    subtitle = formatDayDelta(days)
  } else if (unit.charAt(0) === "y") {
    // Year words start with "y", month words with "m" — the one place the
    // requested unit matters, because the answer keeps the unit it was asked in.
    label = "Years"
    var years = yearDelta(now, target)
    count = years
    subtitle = formatYearDelta(years, monthDelta(shift(now, years * 12, "month"), target))
  } else {
    label = "Months"
    var months = monthDelta(now, target)
    count = months
    subtitle = formatMonthDelta(months,
      dayNumber(startOfDay(target)) - dayNumber(shift(now, months, "month")))
  }
  var withTime = u.kind === "clock"
  return deltaAnswer(count, readable(withTime ? target : startOfDay(target), withTime), label, subtitle)
}

// -> { kind, subtitle, values: [{label, text, mono}] } | null
function parseDateMath(text, now) {
  var s = String(text || "").trim()
  if (!s) return null
  now = now || new Date()
  var m

  // Unix time in: 9-11 digits is seconds, 13 is milliseconds. Both bounded, so
  // a number that merely looks like a timestamp stays a number.
  if (DM_EPOCH_S.test(s)) {
    var seconds = Number(s)
    if (seconds >= DM_EPOCH_MIN_S && seconds <= DM_EPOCH_MAX_S) {
      var fromSeconds = new Date(seconds * 1000)
      return instantAnswer(fromSeconds, now, "Unix seconds · " + formatZone(fromSeconds))
    }
    return null
  }
  if (DM_EPOCH_MS.test(s)) {
    var millis = Number(s)
    if (millis <= DM_EPOCH_MAX_MS) {
      var fromMillis = new Date(millis)
      return instantAnswer(fromMillis, now, "Unix milliseconds · " + formatZone(fromMillis))
    }
    return null
  }

  if (DM_NOW.test(s)) return instantAnswer(new Date(now.getTime()), now, "Local time · " + formatZone(now))

  if (DM_WEEKDAY.test(s)) {
    var weekday = dayAnchor(now, s.toLowerCase())
    if (!weekday) return null
    return instantAnswer(weekday, now)
  }

  m = s.match(DM_UNTIL)
  if (m) {
    var until = resolveAnchor(m[2], now)
    if (!until) return null
    return untilAnswer(m[1].toLowerCase(), until, now)
  }

  // "today + 90 days", "friday - 2 weeks", "2026-01-31 + 1 month"
  m = s.match(DM_REL)
  if (m) {
    var unit = tableGet(DM_UNITS, m[4].toLowerCase())
    if (!unit) return null
    var left = resolveAnchor(m[1], now)
    if (!left) return null
    // "today + 3 hours" means three hours from now. A day word anchors to
    // midnight so that day-granularity arithmetic lands on a date, but that
    // would turn the clock units into a time this morning already passed.
    if (unit.kind === "clock" && /^(today|tonight)$/i.test(m[1]))
      left = new Date(now.getTime())
    var moved = shift(left,
      Number(String(m[3]).replace(",", ".")) * (m[2] === "-" ? -1 : 1), m[4].toLowerCase())
    if (!moved) return null
    return instantAnswer(moved, now)
  }

  // "+90 days", "-2 weeks" — the same arithmetic, anchored to now.
  m = s.match(DM_BARE_REL)
  if (m) {
    var bare = shift(new Date(now.getTime()),
      Number(String(m[2]).replace(",", ".")) * (m[1] === "-" ? -1 : 1), m[3].toLowerCase())
    if (!bare) return null
    return instantAnswer(bare, now)
  }

  // "dec 25 - today" is a day count by definition: two named days, no unit.
  // Subtraction reads left to right, so the minuend is the date being asked
  // about and it is the one shown as the target.
  m = s.match(DM_SPAN)
  if (m) {
    var minuend = resolveAnchor(m[1], now)
    var subtrahend = resolveAnchor(m[2], now)
    if (!minuend || !subtrahend) return null
    var days = dayNumber(startOfDay(minuend)) - dayNumber(startOfDay(subtrahend))
    return deltaAnswer(days, formatLocal(startOfDay(minuend)), "Days", formatDayDelta(days))
  }

  return null
}

// Whether a query is a date question, for the keystroke gate that decides if
// web suggestions are still worth fetching. Deliberately the same parse rather
// than a cheaper shape test: a shape that cannot resolve — an out-of-range
// epoch, "fortnights until dec 25" — must not silence the suggestions, and a second
// approximation of the grammar would be free to drift from the first.
function isDateQuery(text) {
  return parseDateMath(text, new Date()) !== null
}

if (typeof module !== "undefined") {
  module.exports = {
    parseWhen: parseWhen, parseReminder: parseReminder, parseEvent: parseEvent,
    isReminderQuery: isReminderQuery, isEventQuery: isEventQuery,
    labelFor: labelFor, formatDuration: formatDuration, toUtcBasic: toUtcBasic,
    parseDateMath: parseDateMath, isDateQuery: isDateQuery,
    formatLocal: formatLocal, formatIso: formatIso, dayNumber: dayNumber
  }
}
