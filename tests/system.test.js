const assert = require("node:assert/strict")
const test = require("node:test")
const System = require("../lib/System.js")

test("seven rows in stock order", () => {
  assert.deepEqual(
    System.defs().map((d) => d.title),
    ["Screensaver", "Lock", "Suspend", "Hibernate", "Logout", "Reboot", "Shutdown"]
  )
})

test("every row runs a stock action", () => {
  for (const d of System.defs()) {
    assert.ok(d.key.indexOf("system.") === 0, d.key)
    assert.ok(d.action.length > 0, d.key)
    assert.ok(d.icon.length > 0, d.key)
  }
})

test("destructive rows confirm, plain rows do not", () => {
  const byKey = {}
  for (const d of System.defs()) byKey[d.key] = d
  for (const k of ["system.logout", "system.reboot", "system.shutdown", "system.suspend", "system.hibernate"]) {
    assert.equal(byKey[k].confirm, true, k)
  }
  assert.equal(byKey["system.lock"].confirm, false)
  assert.equal(byKey["system.screensaver"].confirm, false)
})

test("suspend and hibernate carry their stock guards", () => {
  const byKey = {}
  for (const d of System.defs()) byKey[d.key] = d
  assert.ok(byKey["system.suspend"].when.includes("suspend-off"))
  assert.ok(byKey["system.hibernate"].when.includes("hibernation-available"))
  assert.equal(byKey["system.lock"].when, "")
})
