const assert = require("node:assert/strict")
const test = require("node:test")
const Colors = require("../lib/Colors.js")

test("six-digit hex with hash", () => {
  const c = Colors.parse("#ff6644")
  assert.equal(c.swatch, "#ff6644")
  assert.equal(c.values[0].text, "#FF6644")
  assert.equal(c.values[1].text, "rgb(255, 102, 68)")
  assert.match(c.values[2].text, /^hsl\(/)
})

test("three-digit hex expands", () => {
  const c = Colors.parse("#fa8")
  assert.equal(c.values[0].text, "#FFAA88")
  assert.equal(c.values[1].text, "rgb(255, 170, 136)")
})

test("bare hex needs a letter, so calculations stay calculations", () => {
  assert.ok(Colors.parse("fa8"))
  assert.equal(Colors.parse("123"), null)
  assert.equal(Colors.parse("12*7"), null)
})

test("non-colors are rejected", () => {
  assert.equal(Colors.parse(""), null)
  assert.equal(Colors.parse("hello"), null)
  assert.equal(Colors.parse("#gggggg"), null)
  assert.equal(Colors.parse("#12345"), null)
})

test("known conversions", () => {
  assert.equal(Colors.parse("#000000").values[2].text, "hsl(0, 0%, 0%)")
  assert.equal(Colors.parse("#ffffff").values[2].text, "hsl(0, 0%, 100%)")
  assert.equal(Colors.parse("#ff0000").values[2].text, "hsl(0, 100%, 50%)")
})
