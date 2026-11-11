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

test("stock admission: every term a substring of name text", () => {
  const e = { id: "install.editor.vscode", label: "VSCode" }
  assert.ok(Menu.matches(e, "vscode"))
  assert.ok(Menu.matches(e, "code"))
  assert.ok(Menu.matches(e, "vs code"))
  assert.ok(!Menu.matches(e, "vscode zebra"))
  // No acronyms, unlike Fuzzy: "vsc" is not a substring of anything here.
  assert.ok(!Menu.matches({ id: "x.y", label: "Visual Studio Code" }, "vsc"))
})

test("description matches whole words only", () => {
  const e = { id: "x.y", label: "Y", description: "fast package manager" }
  assert.ok(Menu.matches(e, "package"))
  assert.ok(!Menu.matches(e, "pack"))
})

test("normalize keeps description", () => {
  const e = Menu.normalizeItem("x.y", { label: "Y", description: "does things" })
  assert.equal(e.description, "does things")
})

test("stock tiers ascend: exact, prefix, contains", () => {
  const q = "term";
  const exact = Menu.matchScore({ id: "a", label: "Term" }, q)
  const prefix = Menu.matchScore({ id: "b", label: "Terminal" }, q)
  const contains = Menu.matchScore({ id: "c", label: "Long Term Goal" }, q)
  assert.ok(exact < prefix && prefix < contains)
  assert.equal(Menu.matchScore({ id: "d", label: "Other" }, q), -1)
  assert.equal(Menu.matchScore({ id: "e", label: "Anything" }, ""), 0)
})

test("aliases normalize from string or list, capped", () => {
  assert.deepEqual(Menu.normalizeItem("x", { aliases: "solo" }).aliases, ["solo"])
  assert.deepEqual(Menu.normalizeItem("x", { aliases: ["a", "", 7] }).aliases, ["a", "7"])
  assert.deepEqual(Menu.normalizeItem("x", {}).aliases, [])
})

test("aliases join the name text", () => {
  const e = { id: "x.y", label: "Why", aliases: ["power-menu"] }
  assert.ok(Menu.matches(e, "power"))
})

test("inSubtree covers the root and everything below it", () => {
  assert.ok(Menu.inSubtree("install", ["install", "remove"]))
  assert.ok(Menu.inSubtree("install.editor.vim", ["install", "remove"]))
  assert.ok(!Menu.inSubtree("installs", ["install"]))
  assert.ok(!Menu.inSubtree("setup", ["install", "remove"]))
})

test("menuPath walks the parent chain", () => {
  const items = {
    install: { id: "install", parent: "root", label: "Install" },
    "install.editor": { id: "install.editor", parent: "install", label: "Editor" },
    "install.editor.vim": { id: "install.editor.vim", parent: "install.editor", label: "Vim" },
  }
  assert.equal(Menu.menuPath(items, "install.editor.vim"), "Install › Editor")
  assert.equal(Menu.menuPath(items, "install"), "")
  assert.equal(Menu.menuPath(items, "missing"), "")
})

test("AUR-style exact labels match", () => {
  assert.equal(Menu.matchScore({ id: "install.aur", label: "AUR" }, "aur"), 0)
  assert.ok(Menu.matchScore({ id: "install.editor", label: "Editor" }, "editor") >= 0)
})

test("hostile ids cannot pollute prototypes", () => {
  const merged = Menu.mergeSources([Menu.normalizeItem("__proto__", { label: "P" })], [])
  assert.equal({}.polluted, undefined)
  assert.ok(Menu.childrenOf(merged, "root").length >= 0)
})

test("checked and disabled append checkmark to label", () => {
  const a = Menu.normalizeItem("appearance.top-bar.background.opaque", {
    label: "Opaque Bar",
    checked: '[[ $(omarchy-bar background) == "opaque" ]]',
  })
  const b = Menu.normalizeItem("install.browser.chrome", {
    label: "Chrome",
    disabled: "omarchy-pkg-present google-chrome",
  })
  assert.equal(Menu.labelFor(a, { [a.id]: true }, {}), "Opaque Bar ✓")
  assert.equal(Menu.labelFor(a, { [a.id]: false }, {}), "Opaque Bar")
  assert.equal(Menu.labelFor(b, {}, { [b.id]: true }), "Chrome ✓")
  assert.equal(Menu.labelFor(b, {}, { [b.id]: false }), "Chrome")
})

test("isVisible hides static submenus when all children are guarded out, keeps provider submenus", () => {
  const merged = Menu.mergeSources([
    Menu.normalizeItem("appearance.font", { label: "Font", provider: "fonts" }),
    Menu.normalizeItem("remove.ai", { label: "AI" }),
    Menu.normalizeItem("remove.ai.claude", { label: "Claude", action: "rm", when: "has-claude" }),
  ], [])
  assert.equal(Menu.isVisible(merged, {}, merged.items["appearance.font"]), true)
  assert.equal(Menu.isVisible(merged, { "remove.ai.claude": false }, merged.items["remove.ai"]), false)
  assert.equal(Menu.isVisible(merged, { "remove.ai.claude": true }, merged.items["remove.ai"]), true)
})

test("swapProviderRows replaces only that provider menu's rows", () => {
  const base = Menu.mergeSources([
    Menu.normalizeItem("appearance.font", { label: "Font", provider: "fonts" }),
  ], [])
  const first = Menu.swapProviderRows(base.items, base.order, "appearance.font", [
    { id: "appearance.font.fira", parent: "appearance.font", action: "omarchy-font-set Fira", label: "Fira", isChecked: true },
  ])
  assert.equal(Menu.childrenOf(first, "appearance.font").length, 1)
  assert.equal(Menu.labelFor(first.items["appearance.font.fira"], {}, {}), "Fira ✓")
  const second = Menu.swapProviderRows(first.items, first.order, "appearance.font", [
    { id: "appearance.font.jet", parent: "appearance.font", action: "omarchy-font-set Jet", label: "Jet", isChecked: false },
  ])
  assert.deepEqual(Menu.childrenOf(second, "appearance.font").map((r) => r.id), ["appearance.font.jet"])
})
