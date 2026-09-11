// The ten stock categories: definitions, fuzzy matching for search, and
// row specs. The QML side maps specs onto rows; the scorer is injected
// (scoreFn(candidate, query)) because this file is unit-tested by node and
// cannot import the QML-side Fuzzy.js. The caller passes Fuzzy.score.

function defs() {
  return [
    { key: "cat.apps", title: "Apps", subtitle: "Your applications",
      icon: "󰀻", kind: "expand",
      keywords: "applications programs software apps" },
    { key: "cat.learn", title: "Learn", subtitle: "Docs, wikis, keybindings",
      icon: "󰖟", kind: "menuscope", scope: "learn",
      keywords: "learn docs documentation manual wiki help keybindings" },
    { key: "cat.trigger", title: "Trigger", subtitle: "Emoji, capture, tools",
      icon: "󰩭", kind: "menuscope", scope: "trigger",
      keywords: "trigger screenshot capture record emoji tools" },
    { key: "cat.style", title: "Style", subtitle: "Theme, background, font",
      icon: "󰸌", kind: "menuscope", scope: "style",
      keywords: "style theme wallpaper background font appearance" },
    { key: "cat.setup", title: "Setup", subtitle: "Configure the system",
      icon: "󰒓", kind: "menuscope", scope: "setup",
      keywords: "setup configure configuration settings system" },
    { key: "cat.install", title: "Install", subtitle: "Add software, stock options",
      icon: "󰉋", kind: "menuscope", scope: "install",
      keywords: "install packages software aur add" },
    { key: "cat.remove", title: "Remove", subtitle: "Remove software, stock options",
      icon: "󰩹", kind: "menuscope", scope: "remove",
      keywords: "remove uninstall delete software" },
    { key: "cat.update", title: "Update", subtitle: "Update, upgrade, packages",
      icon: "󰚰", kind: "menuscope", scope: "update",
      keywords: "update upgrade packages" },
    { key: "cat.about", title: "About", subtitle: "This system",
      icon: "󰋼", kind: "shell", argv: ["omarchy", "launch", "about"],
      keywords: "about system info specs fastfetch" },
    { key: "cat.system", title: "System", subtitle: "Lock, log out, restart, shut down",
      icon: "󰐥", kind: "prime", query: "system", noApps: true,
      keywords: "system power lock logout reboot shutdown session" }
  ]
}

// Best `limit` matches first. Empty query matches nothing — the idle page
// lists every category without matching.
function match(query, scoreFn, limit) {
  var q = String(query || "").trim()
  if (!q) return []
  var max = limit > 0 ? limit : 5
  var scored = []
  var list = defs()
  for (var i = 0; i < list.length; i++) {
    var s = scoreFn({ title: list[i].title, keywords: list[i].keywords }, q)
    if (s < 0) continue
    scored.push({ def: list[i], score: s, order: i })
  }
  scored.sort(function(a, b) {
    if (b.score !== a.score) return b.score - a.score
    return a.order - b.order
  })
  var out = []
  for (var j = 0; j < scored.length && out.length < max; j++) out.push(scored[j].def)
  return out
}

if (typeof module !== "undefined") {
  module.exports = { defs: defs, match: match }
}
