const assert = require("node:assert/strict")
const test = require("node:test")
const Dmenu = require("../lib/Dmenu.js")

test("plain option returns the label", () => {
  assert.deepEqual(Dmenu.parseOption("4k"), { icon: "", label: "4k", detail: "", value: "4k" })
})

test("glyph is shown but never returned", () => {
  const p = Dmenu.parseOption("󰍉\tDocuments")
  assert.equal(p.icon, "󰍉")
  assert.equal(p.value, "Documents")
})

test("subtext joins the returned value as the stable key", () => {
  const p = Dmenu.parseOption("󰍉\tDocs\t/home/qdot/Docs")
  assert.equal(p.value, "Docs\t/home/qdot/Docs")
})

test("filter matches label or subtext, case-insensitively", () => {
  const opts = ["󰍉\tDocuments", "🖼\tPictures\t/home/pics", "Music"]
  assert.equal(Dmenu.filterOptions(opts, "").length, 3)
  assert.deepEqual(Dmenu.filterOptions(opts, "doc").map((r) => r.label), ["Documents"])
  assert.deepEqual(Dmenu.filterOptions(opts, "PICS").map((r) => r.label), ["Pictures"])
  assert.equal(Dmenu.filterOptions(opts, "zzz").length, 0)
})

test("empty rows are dropped, caller order is kept", () => {
  const rows = Dmenu.filterOptions(["b", "", "a"], "")
  assert.deepEqual(rows.map((r) => r.label), ["b", "a"])
  assert.deepEqual(rows.map((r) => r.index), [0, 2])
})

test("option count and length are bounded", () => {
  const many = Array.from({ length: 1200 }, (_, i) => "opt-" + i)
  assert.equal(Dmenu.filterOptions(many, "").length, 1000)
  const long = Dmenu.parseOption("x".repeat(5000))
  assert.ok(long.label.length <= 2048)
})

test("width and height clamps", () => {
  assert.equal(Dmenu.clampWidth(undefined), 300)
  assert.equal(Dmenu.clampWidth("abc"), 300)
  assert.equal(Dmenu.clampWidth(-5), 1)
  assert.equal(Dmenu.clampWidth(99999), 2000)
  assert.equal(Dmenu.clampMaxHeight(undefined), 0)
  assert.equal(Dmenu.clampMaxHeight(-3), 0)
  assert.equal(Dmenu.clampMaxHeight(520), 520)
})
