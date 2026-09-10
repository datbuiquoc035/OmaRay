const assert = require("node:assert/strict")
const test = require("node:test")
const Fuzzy = require("../lib/Fuzzy.js")
const Hotkeys = require("../lib/Hotkeys.js")

const scoreFn = (candidate, query) => Fuzzy.score(candidate, query)

// Fixture shaped like omarchy-menu-keybindings output_binding_records:
// display, dispatcher, arg tab-separated; one keyboard-only bind (no
// dispatcher); one label bound twice; hostile labels included.
const FIXTURE = [
  "SUPER + F                           → Full screen\tlua\thl.dsp.window.fullscreen({ mode = \"fullscreen\" })",
  "SUPER SHIFT + RETURN              → Browser\texec\tchromium",
  "SUPER SHIFT + B                   → Browser\texec\tchromium",
  "SUPER + Q                           → Close window\t\t",
  "__proto__                           → Prototype poke\texec\ttrue",
  "no arrow here",
  "",
].join("\n")

test("parse merges duplicate labels into one bind with two combos", () => {
  const binds = Hotkeys.parse(FIXTURE)
  const browser = binds.filter((b) => b.label === "Browser")
  assert.equal(browser.length, 1)
  assert.deepEqual(browser[0].combos, ["SUPER SHIFT + RETURN", "SUPER SHIFT + B"])
})

test("keyboard-only binds parse with an empty dispatcher", () => {
  const binds = Hotkeys.parse(FIXTURE)
  const close = binds.find((b) => b.label === "Close window")
  assert.ok(close)
  assert.equal(Hotkeys.runnable(close), false)
  assert.equal(Hotkeys.subtitle(close), "Only from the keyboard")
})

test("hostile labels cannot pollute prototypes", () => {
  const binds = Hotkeys.parse(FIXTURE)
  assert.ok(binds.find((b) => b.label === "Prototype poke"))
  assert.equal({}.polluted, undefined)
  assert.equal(Hotkeys.parse(FIXTURE).length, 4)
})

test("lines without an arrow are skipped", () => {
  assert.ok(!Hotkeys.parse(FIXTURE).find((b) => b.label === "no arrow here"))
})

test("combo spelling becomes readable", () => {
  assert.equal(Hotkeys.keys("SUPER + F"), "Super + F")
  assert.equal(Hotkeys.keys("SUPER SHIFT + RETURN"), "Super + Shift + ↵")
  assert.equal(Hotkeys.accessory({ combos: ["SUPER + F"] }), "Super + F")
})

test("subtitles name what Enter would run", () => {
  assert.equal(Hotkeys.subtitle({ dispatcher: "exec", arg: "chromium" }), "chromium")
  assert.equal(
    Hotkeys.subtitle({ dispatcher: "lua", arg: "hl.dsp.window.fullscreen({ mode = \"fullscreen\" })" }),
    "Hyprland window.fullscreen({ mode = \"fullscreen\" })"
  )
})

test("rows match labels, combos and commands", () => {
  const binds = Hotkeys.parse(FIXTURE)
  assert.ok(Hotkeys.rows("browser", binds, {}, scoreFn).length > 0)
  assert.ok(Hotkeys.rows("chromium", binds, {}, scoreFn).length > 0)
  assert.ok(Hotkeys.rows("super f", binds, {}, scoreFn).find((r) => r.label === "Full screen"))
})

test("the exact combo outranks partial matches", () => {
  const binds = Hotkeys.parse(FIXTURE)
  const rows = Hotkeys.rows("super shift b", binds, {}, scoreFn)
  assert.equal(rows[0].label, "Browser")
})

test("keyboard-only binds are hidden when keyboardOnly is false", () => {
  const binds = Hotkeys.parse(FIXTURE)
  assert.ok(Hotkeys.rows("close", binds, {}, scoreFn).find((r) => !r.runnable))
  assert.equal(Hotkeys.rows("close", binds, { keyboardOnly: false }, scoreFn).length, 0)
})

test("empty query returns no rows", () => {
  assert.deepEqual(Hotkeys.rows("", Hotkeys.parse(FIXTURE), {}, scoreFn), [])
})

test("dispatch argv carries dispatcher and arg as literal elements", () => {
  const argv = Hotkeys.dispatchArgv("/usr/share/omarchy", "exec", "chromium")
  assert.equal(argv[argv.length - 2], "exec")
  assert.equal(argv[argv.length - 1], "chromium")
  assert.ok(argv[3].includes("omarchy-menu-keybindings"))
})
