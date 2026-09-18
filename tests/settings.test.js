const assert = require("node:assert/strict")
const test = require("node:test")
const Settings = require("../lib/Settings.js")

test("five options, all known keys", () => {
  const keys = Settings.options().map((o) => o.key)
  assert.deepEqual(keys, ["webSuggestions", "searchEngine", "fileSearch", "maxApps", "maxSuggestions"])
})

test("booleans flip either direction", () => {
  const opt = Settings.find("webSuggestions")
  assert.equal(Settings.nextValue(opt, false, 1), true)
  assert.equal(Settings.nextValue(opt, true, -1), false)
})

test("enums cycle with wraparound both ways", () => {
  const opt = Settings.find("searchEngine")
  const n = opt.options.length
  assert.equal(Settings.nextValue(opt, "g", 1), opt.options[1])
  assert.equal(Settings.nextValue(opt, "g", -1), opt.options[n - 1])
  assert.equal(Settings.nextValue(opt, opt.options[n - 1], 1), "g")
  assert.equal(Settings.nextValue(opt, "bogus", 1), "g")
})

test("numbers step with wraparound at the clamps", () => {
  const opt = Settings.find("maxApps")
  assert.equal(Settings.nextValue(opt, 8, 1), 9)
  assert.equal(Settings.nextValue(opt, 8, -1), 7)
  assert.equal(Settings.nextValue(opt, 24, 1), 3)
  assert.equal(Settings.nextValue(opt, 3, -1), 24)
})

test("maxSuggestions spans 0..8", () => {
  const opt = Settings.find("maxSuggestions")
  assert.equal(Settings.nextValue(opt, 0, -1), 8)
  assert.equal(Settings.nextValue(opt, 8, 1), 0)
})

test("describe names the value", () => {
  assert.match(Settings.describe(Settings.find("webSuggestions"), true), /^On/)
  assert.match(Settings.describe(Settings.find("maxApps"), 8), /^8/)
  assert.match(Settings.describe(Settings.find("searchEngine"), "g"), /^g \(1\//)
})

test("search engine list covers the bang table", () => {
  for (const e of ["g", "gg", "google", "ddg", "yt", "gh", "omarchy"]) {
    assert.ok(Settings.SEARCH_ENGINES.includes(e), e)
  }
})
