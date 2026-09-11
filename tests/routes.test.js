const assert = require("node:assert/strict")
const test = require("node:test")
const Routes = require("../lib/Routes.js")

test("root aliases open the palette", () => {
  for (const r of ["", "root", "menu", "go", "ROOT", "  ", "unknown-route", "setup.default.agent", "share", "hardware"]) {
    assert.equal(Routes.resolve(r).kind, "open", r)
  }
})

test("system opens the dedicated System view", () => {
  assert.deepEqual(Routes.resolve("system"), { kind: "system" })
})

test("apps opens the Apps category expanded", () => {
  assert.deepEqual(Routes.resolve("apps"), { kind: "apps" })
})

test("underscores and case are normalized", () => {
  assert.equal(Routes.normalize("Setup_Power"), "setup-power")
})

test("submenu routes prime the palette", () => {
  assert.deepEqual(Routes.resolve("capture"), { kind: "query", query: "screenshot" })
  assert.deepEqual(Routes.resolve("toggle"), { kind: "query", query: "toggle" })
  assert.deepEqual(Routes.resolve("reminder-set"), { kind: "query", query: "remind me " })
})

test("leaves run immediately as argv vectors", () => {
  const rec = Routes.resolve("trigger.capture.screenrecord")
  assert.equal(rec.kind, "exec")
  assert.deepEqual(rec.argv, ["omarchy", "capture", "screenrecording"])
  assert.deepEqual(Routes.resolve("theme"), { kind: "exec", argv: ["omarchy", "theme", "switcher"] })
  assert.deepEqual(Routes.resolve("background"), { kind: "exec", argv: ["omarchy", "theme", "bg-switcher"] })
})

test("non-string routes fall through to open", () => {
  assert.equal(Routes.resolve(null).kind, "open")
  assert.equal(Routes.resolve(undefined).kind, "open")
})
