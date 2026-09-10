const assert = require("node:assert/strict")
const test = require("node:test")
const Apps = require("../lib/Apps.js")

test("application fields and result counts are bounded", () => {
  const entries = Array.from({ length: 50 }, (_, i) => ({
    id: `app-${i}`,
    name: "x".repeat(1000) + i,
    keywords: Array(100).fill("keyword")
  }))
  const rows = Apps.sortedEntries(entries, "", null, 7, 12)
  assert.equal(rows.length, 7)
  assert.equal(Apps.entryName(entries[0]).length, 512)
  assert.ok(Apps.entryAcronym(entries[0]).length <= 256)
})

test("hidden ids cannot pollute object prototypes", () => {
  const hidden = Apps.hiddenMap(["__proto__", "constructor"])
  assert.equal(Object.getPrototypeOf(hidden), null)
  assert.equal(hidden.__proto__, true)
  assert.equal(hidden.constructor, true)
  assert.equal({}.polluted, undefined)
})
