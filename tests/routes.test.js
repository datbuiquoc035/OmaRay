const assert = require("node:assert/strict")
const test = require("node:test")
const Routes = require("../lib/Routes.js")

test("root aliases open the palette", () => {
  for (const r of ["", "root", "menu", "go", "ROOT", "  ", "unknown-route", "setup.default.agent"]) {
    assert.equal(Routes.resolve(r).kind, "open", r)
  }
})

test("system opens the dedicated System view", () => {
  assert.deepEqual(Routes.resolve("system"), { kind: "system" })
})

test("apps opens the Apps category expanded", () => {
  assert.deepEqual(Routes.resolve("apps"), { kind: "apps" })
})

test("subtree routes open the scope the stock menu would have", () => {
  // Super+Ctrl+H / Super+Ctrl+S. These used to resolve to "open", which
  // dropped the caller on the categories front page.
  assert.deepEqual(Routes.resolve("hardware"), { kind: "scope", scope: "trigger.hardware" })
  assert.deepEqual(Routes.resolve("hw"), { kind: "scope", scope: "trigger.hardware" })
  assert.deepEqual(Routes.resolve("share"), { kind: "scope", scope: "trigger.share" })
  assert.deepEqual(Routes.resolve("HARDWARE"), { kind: "scope", scope: "trigger.hardware" })
})

test("routes are never scope-resolved through Object.prototype", () => {
  for (const r of ["constructor", "toString", "hasOwnProperty", "__proto__"]) {
    assert.equal(Routes.resolve(r).kind, "open", r)
  }
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
  assert.deepEqual(Routes.resolve("theme"), { kind: "exec", argv: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\""] })
  assert.deepEqual(Routes.resolve("background"), { kind: "exec", argv: ["bash", "-c", "bg=$(omarchy-theme-bg-switcher); [[ -n $bg ]] && omarchy-theme-bg-set \"$bg\""] })
})

test("non-string routes fall through to open", () => {
  assert.equal(Routes.resolve(null).kind, "open")
  assert.equal(Routes.resolve(undefined).kind, "open")
})
