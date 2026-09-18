const assert = require("node:assert/strict")
const test = require("node:test")
const Commands = require("../lib/Commands.js")
const Fuzzy = require("../lib/Fuzzy.js")

function matchedTitles(q) {
  const catalogue = Commands.commands().concat(Commands.quicklinks())
  return Fuzzy.rank(catalogue, q, 40).map((r) => r.title)
}

test("system surfaces the power rows", () => {
  const titles = matchedTitles("system")
  for (const t of ["Lock Screen", "Log Out", "Restart", "Shut Down"]) {
    assert.ok(titles.includes(t), t)
  }
})

test("screenshot surfaces capture rows", () => {
  const titles = matchedTitles("screenshot")
  assert.ok(titles.includes("Screenshot Region"))
  assert.ok(titles.includes("Screenshot Full Screen"))
})

test("theme surfaces appearance rows", () => {
  const titles = matchedTitles("theme")
  assert.ok(titles.includes("Change Theme"))
  assert.ok(titles.includes("Change Background"))
})

test("docs surfaces the manuals", () => {
  const titles = matchedTitles("docs")
  assert.ok(titles.includes("Omarchy Manual"))
  assert.ok(titles.includes("Hyprland Wiki"))
  assert.ok(titles.includes("Arch Wiki"))
})
