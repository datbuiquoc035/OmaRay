const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const test = require("node:test")
const Routes = require("../lib/Routes.js")

const qml = fs.readFileSync(path.join(__dirname, "..", "OmaRay.qml"), "utf8")

function fnBody(name) {
  const i = qml.indexOf("function " + name + "(")
  assert.ok(i >= 0, name + "() exists")
  // Next function / lifecycle block boundary is enough for containment checks.
  const next = qml.indexOf("\n  function ", i + 1)
  const end = qml.indexOf("\n  // ", i + 1)
  let cut = qml.length
  if (next > 0) cut = Math.min(cut, next)
  if (end > 0) cut = Math.min(cut, end)
  return qml.slice(i, cut)
}

// Mirrors rebuild() idle priority: menuScope > systemExpanded > categories/apps.
function idleView(state) {
  if (state.menuScope) return "scope:" + state.menuScope
  if (state.systemExpanded) return "system"
  if (state.appsExpanded) return "apps"
  return "categories"
}

// Mirrors the fixed open(): every summon resets the view state, then applies
// the route. Routes never returns a scope, so menuScope is always "".
function nextOpenState(payloadJson) {
  const payload = JSON.parse(payloadJson || "{}")
  const route = payload.initialMenu || payload.menu || ""
  const resolved = Routes.resolve(route)
  let initial = typeof payload.query === "string" ? payload.query : ""
  let routeQuery = ""
  let routeApps = false
  let routeSystem = false
  if (resolved && resolved.kind === "query" && !initial) {
    initial = resolved.query
    routeQuery = resolved.query
  } else if (resolved && resolved.kind === "apps") routeApps = true
  else if (resolved && resolved.kind === "system") routeSystem = true
  return {
    menuScope: "",
    appsExpanded: routeApps,
    systemExpanded: routeSystem,
    primedQuery: routeQuery,
    query: initial,
  }
}

test("open() resets a stale menuscope category view", () => {
  const body = fnBody("open")
  assert.ok(body.includes("root.menuScope ="), "open() must reset menuScope")
})

test("open() syncs query directly instead of relying on onTextChanged", () => {
  const body = fnBody("open")
  assert.ok(body.includes("root.query = initial"), "open() must set root.query")
})

test("open() cancels a pending picker request", () => {
  const body = fnBody("open")
  assert.ok(body.includes("finishRequest(null)"), "open() must cancel pending request")
})

test("close() resets category view state", () => {
  const body = fnBody("close")
  for (const line of ["root.menuScope =", "root.appsExpanded =", "root.systemExpanded =", "root.primedQuery ="]) {
    assert.ok(body.includes(line), "close() must contain " + line)
  }
})

test("dismiss() delegates to close() so Esc/click-outside also resets", () => {
  const body = fnBody("dismiss")
  assert.ok(body.includes("root.close()"), "dismiss() must call root.close()")
})

test("stale Install scope shadows System without the reset", () => {
  assert.equal(idleView({ menuScope: "install" }), "scope:install")
  assert.equal(idleView({ menuScope: "", systemExpanded: true }), "system")
})

test("summon after browsing Install shows the summoned view", () => {
  // Previously: menuScope stayed "install", so idleView() returned
  // "scope:install" for every keybind. Now open() clears it first.
  assert.equal(idleView(nextOpenState('{"menu":"root"}')), "categories")
  assert.equal(idleView(nextOpenState('{"menu":"system"}')), "system")
  assert.equal(idleView(nextOpenState('{"menu":"apps"}')), "apps")
})

test("query-primed routes still prime after the reset", () => {
  assert.deepEqual(nextOpenState('{"menu":"capture"}').query, "screenshot")
  assert.deepEqual(nextOpenState('{"menu":"toggle"}').query, "toggle")
})
