const assert = require("node:assert/strict")
const test = require("node:test")
const Menu = require("../lib/Menu.js")

test("jsonc comments and trailing commas are stripped", () => {
  const rows = Menu.parseMenuJsonc(`{
    // a comment
    "a.b": { "label": "Bee", },
    "root": { "label": "Go", },
  }`)
  assert.equal(rows.length, 2)
  assert.equal(rows[0].parent, "a")
})

test("parents default from dotted ids, root has none", () => {
  assert.equal(Menu.normalizeItem("a.b.c", {}).parent, "a.b")
  assert.equal(Menu.normalizeItem("top", {}).parent, "root")
  assert.equal(Menu.normalizeItem("root", {}).parent, "")
})

test("leaf kinds come from action, then target", () => {
  assert.equal(Menu.normalizeItem("x", { action: "run" }).kind, "action")
  assert.equal(Menu.normalizeItem("x", { target: "y" }).kind, "link")
  assert.equal(Menu.normalizeItem("x", {}).kind, "menu")
})

test("user extensions override by id, new ids append", () => {
  const merged = Menu.mergeSources(
    [Menu.normalizeItem("a", { label: "Old" }), Menu.normalizeItem("b", {})],
    [Menu.normalizeItem("a", { label: "New" }), Menu.normalizeItem("c", {})]
  )
  assert.deepEqual(merged.order, ["a", "b", "c"])
  assert.equal(merged.items.a.label, "New")
})

test("childrenOf lists a submenu in file order", () => {
  const merged = Menu.mergeSources([
    Menu.normalizeItem("install", {}),
    Menu.normalizeItem("install.b", { label: "B" }),
    Menu.normalizeItem("install.a", { label: "A" }),
    Menu.normalizeItem("other", {}),
  ], [])
  assert.deepEqual(Menu.childrenOf(merged, "install").map((e) => e.id), ["install.b", "install.a"])
})

test("parentScope climbs one level", () => {
  assert.equal(Menu.parentScope("install.editor"), "install")
  assert.equal(Menu.parentScope("install"), "")
  assert.equal(Menu.parentScope(""), "")
})

test("hostile ids cannot pollute prototypes", () => {
  const merged = Menu.mergeSources([Menu.normalizeItem("__proto__", { label: "P" })], [])
  assert.equal({}.polluted, undefined)
  assert.ok(Menu.childrenOf(merged, "root").length >= 0)
})
