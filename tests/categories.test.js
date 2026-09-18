const assert = require("node:assert/strict")
const test = require("node:test")
const Categories = require("../lib/Categories.js")
const Fuzzy = require("../lib/Fuzzy.js")

const scoreFn = (candidate, query) => Fuzzy.score(candidate, query)

test("ten stock categories", () => {
  assert.deepEqual(
    Categories.defs().map((d) => d.title),
    ["Apps", "Learn", "Trigger", "Style", "Setup", "Install", "Remove", "Update", "About", "System"]
  )
})

test("app query puts Apps first, above partial matches", () => {
  const rows = Categories.match("app", scoreFn, 5)
  assert.equal(rows[0].key, "cat.apps")
})

test("sys finds System, theme finds Style", () => {
  assert.equal(Categories.match("sys", scoreFn, 5)[0].key, "cat.system")
  assert.equal(Categories.match("theme", scoreFn, 5)[0].key, "cat.style")
})

test("keywords find categories by what they do", () => {
  assert.ok(Categories.match("power", scoreFn, 5).find((d) => d.key === "cat.system"))
  assert.ok(Categories.match("aur", scoreFn, 5).find((d) => d.key === "cat.install"))
  assert.ok(Categories.match("uninstall", scoreFn, 5).find((d) => d.key === "cat.remove"))
})

test("empty query matches nothing, misses match nothing", () => {
  assert.deepEqual(Categories.match("", scoreFn, 5), [])
  assert.deepEqual(Categories.match("zzzqqq", scoreFn, 5), [])
})

test("limit bounds the rows", () => {
  assert.ok(Categories.match("e", scoreFn, 2).length <= 2)
})

test("every def carries what its kind needs", () => {
  for (const d of Categories.defs()) {
    assert.ok(d.key && d.title && d.subtitle !== undefined && d.keywords)
    if (d.kind === "menuscope") assert.ok(d.scope, d.key)
    if (d.kind === "shell") assert.ok(Array.isArray(d.argv) && d.argv.length > 0, d.key)
    if (d.kind === "prime") assert.ok(typeof d.query === "string", d.key)
  }
})
