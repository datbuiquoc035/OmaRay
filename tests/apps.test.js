const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
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

test("upstream Omarchy MIT copyright notice is retained in LICENSE and lib/Apps.js", () => {
  const license = fs.readFileSync(path.join(__dirname, "..", "LICENSE"), "utf8")
  const appsSource = fs.readFileSync(path.join(__dirname, "..", "lib", "Apps.js"), "utf8")
  assert.match(license, /Copyright \(c\).*datbuiquoc035/)
  assert.match(license, /Copyright \(c\).*David Heinemeier Hansson/)
  assert.match(appsSource, /Copyright \(c\).*David Heinemeier Hansson/)
})
