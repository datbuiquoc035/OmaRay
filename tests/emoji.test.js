const assert = require("node:assert/strict")
const test = require("node:test")
const Emoji = require("../lib/Emoji.js")

const DATA = [
  { e: "😀", k: "grinning face smile happy" },
  { e: "😂", k: "laughing joy tears haha" },
  { e: "❤", k: "red heart love" },
  { e: "👍", k: "thumbs up approve yes" },
]

test("title case keeps at most six words", () => {
  assert.equal(Emoji.title("grinning face smile happy"), "Grinning face smile happy")
  assert.equal(Emoji.title("a b c d e f g h"), "A b c d e f")
})

test("every term must appear or the entry is rejected", () => {
  assert.ok(Emoji.search(DATA, "grinning", 10).length > 0)
  assert.equal(Emoji.search(DATA, "grinning zebra", 10).length, 0)
})

test("best match first, data order breaking ties", () => {
  const rows = Emoji.search(DATA, "happy", 10)
  assert.equal(rows[0].e, "😀")
})

test("empty query lists data order up to the limit", () => {
  const rows = Emoji.search(DATA, "", 2)
  assert.equal(rows.length, 2)
  assert.equal(rows[0].index, 0)
})

test("malformed entries are skipped, never thrown on", () => {
  const rows = Emoji.search([{ e: "x" }, null, { e: "😀", k: "" }, ...DATA], "joy", 10)
  assert.ok(rows.every((r) => r.e && r.k))
  assert.equal(Emoji.search(null, "joy", 10).length, 0)
})

test("acronyms match", () => {
  const rows = Emoji.search([{ e: "😀", k: "grinning face" }], "gf", 10)
  assert.equal(rows.length, 1)
})
