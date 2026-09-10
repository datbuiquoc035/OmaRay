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

  // ISO or dotted date, optional clock: "2026-09-12 14:00", "24.12. 18:00"
  m = s.match(/\b(\d{4})-(\d{2})-(\d{2})(?:\s+(\d{1,2}):(\d{2}))?\b/)
  if (m) {
    var atIso = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), m[4] ? Number(m[4]) : 9, m[5] ? Number(m[5]) : 0, 0, 0)
    return result(atIso, m.index, m.index + m[0].length, labelFor(atIso, now))
  }
  m = s.match(/\b(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?\s*(?:at\s+)?(?:(\d{1,2}):(\d{2}))?/)
  if (m && m[2]) {
    var year = m[3] ? (m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3])) : now.getFullYear()
    var atDot = new Date(year, Number(m[2]) - 1, Number(m[1]), m[4] ? Number(m[4]) : 9, m[5] ? Number(m[5]) : 0, 0, 0)
    if (!m[3] && atDot.getTime() < now.getTime()) atDot.setFullYear(year + 1)
    return result(atDot, m.index, m.index + m[0].length, labelFor(atDot, now))
  }

  // "dec 24 at 18:00" / "24 dec"
  m = s.match(/\b(?:(\d{1,2})\s+([a-z]{3,9})|([a-z]{3,9})\s+(\d{1,2}))(?:\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?\b/i)
  if (m) {
    var monthWord = (m[2] || m[3] || "").toLowerCase()
    var dayNum = Number(m[1] || m[4])
    var monthIndex = tableGet(MONTHS, monthWord)
    if (monthIndex !== undefined && dayNum >= 1 && dayNum <= 31) {
      var hourM = m[5] ? normalizeHour(Number(m[5]), (m[7] || "").toLowerCase()) : 9
      var atMon = new Date(now.getFullYear(), monthIndex, dayNum, hourM, m[6] ? Number(m[6]) : 0, 0, 0)
      if (atMon.getTime() < now.getTime()) atMon.setFullYear(now.getFullYear() + 1)
      return result(atMon, m.index, m.index + m[0].length, labelFor(atMon, now))
    }
  }

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
