import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "lib/Calc.js" as Calc
import "lib/Units.js" as Units
import "lib/NaturalTime.js" as NaturalTime
import "lib/Web.js" as Web
import "lib/Fuzzy.js" as Fuzzy
import "lib/Frecency.js" as Frecency
import "lib/Commands.js" as Commands
import "lib/Apps.js" as Apps
import "lib/Emoji.js" as Emoji
import "lib/Colors.js" as Colors
import "lib/Hotkeys.js" as Hotkeys
import "lib/Settings.js" as Settings
import "lib/Routes.js" as Routes
import "lib/Dmenu.js" as Dmenu

// OmaRay — a Raycast-shaped command palette for Omarchy.
//
// One overlay, many providers. Each provider turns the query into rows; the
// rows are plain data carrying a `kind`, and activate() is the only place that
// turns a kind into an effect. Nothing from the query is ever evaluated: the
// calculator has its own parser and every command runs through an argv vector.
Item {
  id: root

  // ------------------------------------------------------------- injected
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  onShellChanged: root.refreshHides()
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "datbuiquoc035.omaray"
  // The shell's own application library, when the host hands one over.
  //
  // Omarchy 4.0.3 gates it behind a manifest kind of "menu" — which this
  // manifest now declares — but the manifest that gate reads has been through
  // an Instantiator model by the time it arrives, and a QVariantMap round trip
  // leaves `kinds` an array that no longer answers to Array.isArray. The
  // check inside manifestHasKind() therefore cannot pass for any third-party
  // plugin, whatever it declares. Applications come from DesktopEntries
  // instead while that holds; the moment the host starts handing the library
  // over again, every path below switches back to it on its own.
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
  readonly property string home: Quickshell.env("HOME")

  // OmaRay is `keepLoaded`, so it lives inside the long-running
  // omarchy-shell process rather than being torn down with the overlay.
  // Nothing it reads may therefore be open-ended: a file, a process output or
  // a network response that is unbounded at the point of reading stays
  // resident for the life of the session. Every one of those crossings goes
  // through bin/omaray-helper, which caps the bytes, imposes its own
  // wall-clock deadline with a process-group teardown, and hands back a
  // normalised, count-limited projection. No FileView, no raw subprocess.
  readonly property string helper: decodeURIComponent(
    String(Qt.resolvedUrl("bin/omaray-helper")).replace(/^file:\/\//, ""))

  function helperArgv(args) {
    return ["python3", root.helper].concat(args)
  }

  // Every helper call answers with a single JSON object carrying an `ok` flag.
  // A refusal is not an error path here — the caller keeps its defaults, which
  // is what failing closed looks like for a launcher.
  function helperReply(raw) {
    try {
      var text = String(raw || "")
      if (text.length > root.maxHelperPayloadChars) return null
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object" && parsed.ok === true) return parsed
    } catch (e) {
    }
    return null
  }

  // ------------------------------------------------------------- state
  property bool opened: false
  property string query: ""
  property int selectedIndex: 0
  property bool cursorActive: true

  // Rows currently on screen, as plain JS objects. displayModel mirrors only
  // the display fields; the payload stays here and is read back by index, so
  // ListModel never has to hold a nested object.
  property var rows: []

  // Async provider caches. Each is refreshed by its own Process and triggers a
  // rebuild when it lands, so a slow provider never blocks the fast ones.
  property var suggestionRows: []
  property string suggestionFor: ""
  property var fileRows: []
  property string fileFor: ""
  property var reminderRows: []
  property var clipboardRows: []
  // First-party emoji catalogue ([{e, k}]), read on every open.
  property var emojis: []
  // Parsed omarchy-menu-keybindings records, refreshed on open at most
  // every 30 seconds — the script caches on hyprctl binds itself.
  property var hotkeyBinds: []
  property real hotkeysLoadedAt: 0

  // Dmenu select/input requests from `omarchy-menu-select` and friends.
  // A pending request owns the panel: palette providers stay out while one
  // is active, and any close cancels it so the caller is always released.
  property string dmenuMode: ""
  readonly property bool dmenuActive: root.dmenuMode === "select" || root.dmenuMode === "input"
  property string dmenuPrompt: ""
  property var dmenuOptions: []
  property string selectionFile: ""
  property string doneFile: ""
  property bool requestActive: false
  property int dmenuWidth: 300
  property int dmenuMaxHeight: 0

  // Destructive commands need a second Enter. Holds the row key that is armed.
  property string armedKey: ""

  // The row the user deliberately put the cursor on — arrow keys, or a pointer
  // that actually moved. Empty means "whatever is top right now", and that is
  // the rule that makes Enter safe while async rows are still landing: a late
  // rebuild can reshuffle the list without the cursor ever drifting off the
  // best answer onto a web suggestion.
  property string pinnedKey: ""

  // Desktop ids Omarchy keeps out of its own launcher. AppLibrary applies this
  // list itself, so it is read only when the fallback source is the one
  // building the list.
  property var appHides: Apps.hiddenMap([])

  // Decayed launch counts, keyed by row key. See lib/Frecency.js.
  property var usage: Frecency.emptyMap()

  // Frecency is a bonus on top of the match score, never a replacement for it.
  // Both caps sit under the smallest gap between two match tiers (500 in the
  // shell's AppSearch, 500 in Fuzzy), so usage reorders rows that matched
  // equally well and can never lift a weak match over a name that starts with
  // what was typed.
  readonly property int appFrecencyBoost: 450
  readonly property int commandFrecencyBoost: 400
  // With no query there is no match score to respect, so frecency owns the
  // order outright and the alphabetical fallback only breaks its ties.
  readonly property int idleFrecencyBoost: 100000
  // Cap on remembered keys. Everything past it is the tail nothing ranks by.
  // The helper enforces the same number on the way in and on the way out, so
  // the store cannot grow past it by being edited by hand either.
  readonly property int usageKeepCount: 400

  // Hard ceilings on everything the model will hold, applied where the rows
  // are built rather than after. maxApps is a user setting, so it is clamped
  // rather than trusted; the rest bound lists that arrive from outside.
  readonly property int maxAppRows: 24
  // The Apps category shows the full list instead.
  readonly property int maxExpandedAppRows: 60
  // True while the Apps category is expanded; cleared on every open.
  property bool appsExpanded: false
  // A primed query that hides app results (the System category view).
  // Compared by value, so typing the same query by hand shows the same
  // view; any other query, or none, restores apps.
  property string primedNoAppsQuery: ""
  // The query a category tap or route last primed, untouched since. Left
  // backs out of exactly such a view; edited queries keep caret duty.
  property string primedQuery: ""
  // The helper returns at most 40 hits; the list shows the first 10 of them.
  readonly property int maxFileRows: 10
  readonly property int maxClipboardRows: 8
  readonly property int maxReminderRows: 50
  readonly property int maxQueryChars: 512
  // Summon payloads carry whole option lists (228 keybinding records are
  // ~22KB; timezone/file pickers are bigger), so this must clear them with
  // headroom — unlike query text, which stays at 512. Downstream bounds
  // still apply: Dmenu caps option count and length on ingest, and option
  // strings are sliced again on the way into rows.
  readonly property int maxPayloadChars: 262144
  readonly property int maxHelperPayloadChars: 524288
  readonly property int maxAppCandidates: 512
  readonly property int maxWindowCandidates: 256
  readonly property int maxTitleChars: 512
  readonly property int maxSubtitleChars: 1024

  property var settings: ({
    webSuggestions: false,
    searchEngine: "g",
    fileSearch: true,
    maxApps: 8,
    maxSuggestions: 4
  })

  // ------------------------------------------------------------- theme
  // Shares the [menu] surface tokens, so any theme that styles the Omarchy
  // menu styles this too. The card is deliberately translucent: the frost is
  // Hyprland's, applied to this layer's namespace.
  readonly property color foreground: Color.menu.text
  readonly property color accent: Color.accent
  // Solid card, no compositor blur needed: fully opaque menu background
  // with a theme-accent border doing the framing instead of frost.
  readonly property color glassBackground: Color.menu.background
  readonly property color glassBorder: Util.alpha(Color.accent, 0.5)
  readonly property color glassSheen: Util.alpha("#ffffff", 0.07)
  readonly property color scrim: Util.alpha(Color.menu.scrim, 0.25)
  readonly property color selectedBackground: Util.alpha(Color.foreground, 0.12)
  readonly property color selectedText: Color.menu.selectedText
  readonly property color dividerColor: Util.alpha(Color.foreground, 0.10)
  readonly property string fontFamily: Style.font.menuFamily

  // One left rail at `gutter`. The search glyph, every row icon and every
  // section header align to it; a row is inset by `listPadding` and carries
  // the remainder internally, so the rail survives the inset.
  readonly property int gutter: Style.space(24)
  readonly property int listPadding: Style.space(10)
  readonly property int rowInset: gutter - listPadding

  // Square card, no rounding on the block itself.
  readonly property int cardRadius: 0
  readonly property int rowRadius: Style.space(8)
  readonly property int searchHeight: Style.space(56)
  readonly property int rowHeight: Style.space(40)
  readonly property int sectionHeight: Style.space(30)
  readonly property int footerHeight: Style.space(36)
  readonly property int maxListHeight: Style.space(400)
  readonly property int hairline: Style.spacing.hairline

  // Between heading (16) and display (24): a hero input that is still an
  // input. Scales with the user's font size rather than being pinned to 18px.
  readonly property int searchFontSize: Math.round(Style.font.baseSize * 1.5)

  // Fixing the top edge at the position the *fully expanded* panel would need
  // to sit centred means the panel grows downward into the middle of the
  // screen instead of shoving the search field around as results arrive.
  readonly property int maxCardHeight: searchHeight + hairline
    + listPadding * 2 + maxListHeight + hairline + footerHeight

  // ------------------------------------------------------------- lifecycle
  // The payload may carry {"query": "..."} so a keybind can summon OmaRay
  // already primed, e.g. bound to open straight into "remind me ".
  function open(payloadJson) {
    var initial = ""
    var routeArgv = null
    var routeApps = false
    var routeNoApps = false
    var routeQuery = ""
    try {
      var rawPayload = String(payloadJson || "{}")
      if (rawPayload.length > root.maxPayloadChars) rawPayload = "{}"
      var payload = JSON.parse(rawPayload)
      // Picker requests own the panel outright; a pending one is cancelled.
      if (payload && (payload.mode === "select" || payload.mode === "input")) {
        root.openDmenu(payload)
        return
      }
      if (payload && typeof payload.query === "string")
        initial = payload.query.slice(0, root.maxQueryChars)
      var route = payload ? (payload.initialMenu || payload.menu || "") : ""
      var resolved = Routes.resolve(route)
      if (resolved && resolved.kind === "exec" && resolved.argv) routeArgv = resolved.argv
      else if (resolved && resolved.kind === "query" && !initial) {
        initial = resolved.query
        routeQuery = resolved.query
        if (resolved.noApps) routeNoApps = true
      }
      else if (resolved && resolved.kind === "apps") routeApps = true
    } catch (e) {
      initial = ""
      routeArgv = null
      routeApps = false
      routeNoApps = false
      routeQuery = ""
    }

    // Leaves run without the panel ever opening — the summon that named
    // them stays a plain action, the way the stock menu runs leaf routes.
    if (routeArgv) {
      if (Array.isArray(routeArgv) && routeArgv.length > 0) Util.execArgv(routeArgv)
      root.dismiss()
      return
    }

    root.dmenuMode = ""
    // The Apps category: the full frecency app list instead of the
    // categories front page. Reset on every open.
    root.appsExpanded = routeApps
    root.primedNoAppsQuery = routeNoApps ? initial : ""
    root.primedQuery = routeQuery
    root.opened = true
    root.armedKey = ""
    root.rows = []
    root.pinnedKey = ""
    input.text = initial
    input.cursorPosition = input.text.length
    root.selectedIndex = 0
    root.cursorActive = true
    root.suggestionRows = []
    root.suggestionFor = ""
    root.fileRows = []
    root.fileFor = ""
    // The panel appears under wherever the pointer already is. Hold the cursor
    // for the same beat a keystroke would, so opening over a row does not hand
    // it the selection before the first character is typed.
    typingGuard.restart()
    if (root.appLibrary) root.appLibrary.refreshIcons()
    // Settings are re-read on every open rather than watched. A watcher on a
    // predictable path is a standing invitation to whatever can write it; one
    // bounded read when the user asks for the launcher costs nothing and picks
    // up an edit just as promptly.
    root.refreshSettings()
    root.refreshReminders()
    root.refreshEmojis()
    root.refreshHotkeys(false)
    root.rebuild()
    pointerGate.reset()
    Qt.callLater(function() {
      input.forceActiveFocus()
      resultList.positionViewAtBeginning()
    })
  }

  function close() {
    if (root.requestActive) root.finishRequest(null)
    root.dmenuMode = ""
    root.dmenuOptions = []
    root.selectionFile = ""
    root.doneFile = ""
    root.opened = false
    root.armedKey = ""
    root.stopQueryWork()
  }

  // `omarchy menu refresh` re-reads what an open re-reads; `ping` is the
  // health check the same call path uses. Both arrive via `shell call`.
  function refresh() {
    root.refreshSettings()
    root.refreshUsage()
    root.refreshReminders()
    root.refreshEmojis()
    root.refreshHotkeys(true)
  }

  function ping() { return "ok" }

  // Picker flows: list plus text input, honoring the caller's width and
  // maxHeight. A new request cancels a pending one so two Install/Remove
  // style callers can never both wait on the same panel.
  function openDmenu(payload) {
    if (root.requestActive) root.finishRequest(null)
    root.stopQueryWork()
    root.dmenuMode = payload.mode === "input" ? "input" : "select"
    root.dmenuPrompt = String(payload.prompt || (root.dmenuMode === "input" ? "Input" : "Select"))
    var opts = Array.isArray(payload.options) ? payload.options : []
    root.dmenuOptions = opts.slice(0, Dmenu.MAX_OPTIONS)
    root.selectionFile = String(payload.selectionFile || "")
    root.doneFile = String(payload.doneFile || "")
    root.requestActive = root.doneFile.length > 0
    root.dmenuWidth = Dmenu.clampWidth(payload.width)
    root.dmenuMaxHeight = Dmenu.clampMaxHeight(payload.maxHeight)
    root.opened = true
    root.armedKey = ""
    root.rows = []
    root.pinnedKey = ""
    input.text = ""
    input.cursorPosition = 0
    root.selectedIndex = 0
    root.cursorActive = true
    root.suggestionRows = []
    root.suggestionFor = ""
    root.fileRows = []
    root.fileFor = ""
    root.clipboardRows = []
    typingGuard.restart()
    root.rebuild()
    pointerGate.reset()
    Qt.callLater(function() {
      input.forceActiveFocus()
      resultList.positionViewAtBeginning()
    })
  }

  // Empty stdin is a cancellation: the selection file stays empty and the
  // done file still appears, releasing the caller's poll loop either way.
  // Fire-and-forget by design: stopQueryWork and onDestruction must never
  // stop dmenuFinishProc, or the close that started it would SIGTERM the
  // helper before it writes and strand the caller forever.
  function finishRequest(selection) {
    if (!root.requestActive || !root.doneFile) return
    var selPath = root.selectionFile, donePath = root.doneFile
    root.requestActive = false
    root.selectionFile = ""
    root.doneFile = ""
    var text = (selection === null || selection === undefined) ? "" : String(selection)
    dmenuFinishProc.stdinEnabled = true
    dmenuFinishProc.command = root.helperArgv(["dmenu-finish", selPath, donePath])
    dmenuFinishProc.running = true
    if (text.length > 0) dmenuFinishProc.write(text)
    dmenuFinishProc.stdinEnabled = false
  }

  // Nothing that was started for a query outlives the overlay it was typed
  // into: the debounces stop, the readers are terminated, and the rows they
  // were filling are dropped rather than left resident.
  function stopQueryWork() {
    suggestDebounce.stop()
    fileDebounce.stop()
    clipboardDebounce.stop()
    suggestProc.running = false
    fileProc.running = false
    clipboardProc.running = false
    emojiProc.running = false
    hotkeysProc.running = false
    root.clipboardRows = []
  }

  function refreshSettings() {
    settingsProc.running = false
    settingsProc.command = root.helperArgv(["read-settings"])
    settingsProc.running = true
  }

  function refreshUsage() {
    usageReadProc.running = false
    usageReadProc.command = root.helperArgv(["read-usage"])
    usageReadProc.running = true
  }

  // Read once, when the host injects its shell: the file is packaged and only
  // an Omarchy update changes it, which restarts the shell anyway.
  function refreshHides() {
    if (!root.shell || root.shell.appLibrary) return
    hidesProc.running = false
    hidesProc.command = root.helperArgv(["read-hides"])
    hidesProc.running = true
  }

  function loadHides(raw) {
    var reply = root.helperReply(raw)
    root.appHides = Apps.hiddenMap(reply ? reply.hides : null)
  }

  function refreshReminders() {
    remindersProc.running = false
    remindersProc.command = root.helperArgv(["reminders"])
    remindersProc.running = true
  }

  function refreshEmojis() {
    emojiProc.running = false
    emojiProc.command = root.helperArgv(["read-emojis"])
    emojiProc.running = true
  }

  // The script keeps its own cache keyed on `hyprctl binds`, so a reload is
  // a hash and a cat; still, once per open (and at most every 30 seconds)
  // is often enough.
  function refreshHotkeys(force) {
    if (hotkeysProc.running) return
    if (!force && root.hotkeysLoadedAt > 0 && Date.now() - root.hotkeysLoadedAt < 30000) return
    hotkeysProc.running = false
    hotkeysProc.command = root.helperArgv(["hotkeys"])
    hotkeysProc.running = true
  }

  // Escape and successful activations go through here so the shell's
  // openPanelIds stays in step — otherwise the next toggle would try to hide
  // an overlay that is already gone.
  function dismiss() {
    root.opened = false
    root.armedKey = ""
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ------------------------------------------------------------- usage
  // Only keys that still mean the same thing next week are worth remembering.
  // A web suggestion, a file hit or a window is spelled out of the query that
  // produced it and is never looked up again, so counting one only grows the
  // file.
  function trackable(key) {
    var k = String(key || "")
    return k.indexOf("app:") === 0 || k.indexOf("cmd:") === 0 || k.indexOf("bang.") === 0
      || k.indexOf("win:") === 0 || k.indexOf("emoji:") === 0 || k.indexOf("hotkey:") === 0
  }

  function bumpUsage(key) {
    if (!root.trackable(key)) return
    var now = Date.now()
    var next = Frecency.prune(Frecency.bump(root.usage, key, now), root.usageKeepCount, now)
    root.usage = next
    root.persistUsage(JSON.stringify(next))
  }

  function loadUsage(raw) {
    var reply = root.helperReply(raw)
    // adopt() rebuilds the store as a null-prototype map. The helper has
    // already dropped anything that is not one of our own keys, and this is
    // the second half of the same guarantee: on an ordinary object a key of
    // `__proto__` is an assignment to the prototype rather than an entry, so
    // one such line in the file would quietly reshape every lookup after it.
    root.usage = Frecency.adopt(reply ? reply.usage : null)
  }

  // Writes go through the helper too: a locked, atomic 0600 replacement inside
  // a directory it has verified it owns. Only one write is ever in flight, and
  // a bump that lands during one is folded into the next.
  property string pendingUsage: ""

  function persistUsage(json) {
    root.pendingUsage = json
    root.flushUsage()
  }

  function flushUsage() {
    if (usageWriteProc.running || !root.pendingUsage) return
    var payload = root.pendingUsage
    root.pendingUsage = ""
    usageWriteProc.stdinEnabled = true
    usageWriteProc.command = root.helperArgv(["write-usage"])
    usageWriteProc.running = true
    usageWriteProc.write(payload)
    usageWriteProc.stdinEnabled = false
  }

  // One settings write is ever in flight; the helper answers with the
  // normalized settings, which become the new on-screen values.
  property string pendingSettings: ""

  function persistSettings(json) {
    root.pendingSettings = json
    root.flushSettings()
  }

  function flushSettings() {
    if (settingsWriteProc.running || !root.pendingSettings) return
    var payload = root.pendingSettings
    root.pendingSettings = ""
    settingsWriteProc.stdinEnabled = true
    settingsWriteProc.command = root.helperArgv(["write-settings"])
    settingsWriteProc.running = true
    settingsWriteProc.write(payload)
    settingsWriteProc.stdinEnabled = false
  }

  // Enter toggles a boolean or steps an enum/number forward, Shift+Enter
  // steps backward. The panel stays open so the new value is visible.
  function applySetting(key, direction) {
    var opt = Settings.find(key)
    if (!opt) return
    var values = {}
    var defs = Settings.options()
    for (var i = 0; i < defs.length; i++) values[defs[i].key] = root.settings[defs[i].key]
    values[key] = Settings.nextValue(opt, values[key], direction)
    root.persistSettings(JSON.stringify(values))
  }

  function loadWrittenSettings(raw) {
    root.loadSettings(raw)
    if (root.opened) root.rebuild()
  }

  // Settings arrive already type-checked and clamped. The one thing the helper
  // cannot judge is whether the engine key names an engine that exists, so
  // that is settled here against the table that will be asked for it.
  function loadSettings(raw) {
    var reply = root.helperReply(raw)
    var parsed = (reply && reply.settings) ? reply.settings : {}
    root.settings = {
      webSuggestions: parsed.webSuggestions === true,
      searchEngine: Web.hasEngine(parsed.searchEngine) ? parsed.searchEngine : "g",
      fileSearch: parsed.fileSearch !== false,
      maxApps: isFinite(parsed.maxApps)
        ? Util.clamp(parsed.maxApps, 3, root.maxAppRows) : 8,
      maxSuggestions: isFinite(parsed.maxSuggestions)
        ? Util.clamp(parsed.maxSuggestions, 0, 8) : 4
    }
  }

  // ------------------------------------------------------------- providers
  function row(spec) {
    return {
      key: String(spec.key || "").slice(0, 2048),
      section: String(spec.section || "").slice(0, 128),
      kind: String(spec.kind || "noop").slice(0, 32),
      title: String(spec.title || "").slice(0, root.maxTitleChars),
      subtitle: String(spec.subtitle || "").slice(0, root.maxSubtitleChars),
      accessory: String(spec.accessory || "").slice(0, 128),
      icon: String(spec.icon || "").slice(0, 128),
      image: String(spec.image || "").slice(0, 2048),
      mono: spec.mono === true,
      primaryLabel: spec.primaryLabel || "Open",
      secondaryLabel: spec.secondaryLabel || "",
      confirm: spec.confirm === true,
      payload: spec.payload || ({})
    }
  }

  // Calculator, unit conversion, reminders, calendar, URLs and bangs. These
  // are the rows that answer the query directly, so they sort above search.
  function intentRows(q) {
    var out = []

    var calc = Calc.evaluate(q)
    if (calc) {
      out.push(root.row({
        key: "calc", section: "Calculator", kind: "copy",
        title: calc.text, subtitle: q.replace(/^=/, "").trim(),
        accessory: "Copy", icon: "󰃬", mono: true,
        primaryLabel: "Copy result",
        payload: { text: calc.text.replace(/\s/g, "") }
      }))
    }

    var unit = Units.convert(q)
    if (unit) {
      out.push(root.row({
        key: "unit", section: "Conversion", kind: "copy",
        title: unit.text, subtitle: unit.detail,
        accessory: unit.family, icon: "󰑤", mono: true,
        primaryLabel: "Copy result",
        payload: { text: unit.text.replace(/\s/g, "") }
      }))
    }

    var reminder = NaturalTime.parseReminder(q)
    if (reminder && !reminder.needsTime && reminder.message) {
      out.push(root.row({
        key: "reminder.create", section: "Reminder", kind: "reminder",
        title: reminder.message,
        subtitle: "Notify " + reminder.label + " · in " + NaturalTime.formatDuration(reminder.minutes),
        accessory: "Reminder", icon: "󰢌",
        primaryLabel: "Set reminder",
        payload: { minutes: reminder.minutes, message: reminder.message }
      }))
    } else if (reminder && reminder.needsTime) {
      out.push(root.row({
        key: "reminder.hint", section: "Reminder", kind: "noop",
        title: reminder.message || "Set a reminder",
        subtitle: "Add a time — “in 20m”, “at 15:30”, “tomorrow at 9”",
        accessory: "Needs a time", icon: "󰢌",
        primaryLabel: ""
      }))
    }

    var event = NaturalTime.parseEvent(q)
    if (event) {
      out.push(root.row({
        key: "event.create", section: "Calendar", kind: "event",
        title: event.title,
        subtitle: event.label + " · " + NaturalTime.formatDuration(event.durationMinutes),
        accessory: "Google Calendar", icon: "󰸗",
        primaryLabel: "Add to Google Calendar",
        secondaryLabel: "Save .ics file",
        payload: {
          title: event.title,
          start: NaturalTime.toUtcBasic(event.start),
          end: NaturalTime.toUtcBasic(event.end)
        }
      }))
    }

    var url = Web.detectUrl(q)
    if (url) {
      out.push(root.row({
        key: "url.open", section: "Open", kind: "url",
        title: url.replace(/^https?:\/\//, ""), subtitle: url,
        accessory: "Website", icon: "󰖟",
        primaryLabel: "Open in browser",
        payload: { url: url }
      }))
    }

    return out
  }

  // A bare bang is a prefix, not a sigil — "gh quickshell" is a GitHub search.
  // That makes it a trap for any application whose name starts with an engine
  // key and carries a space, "docker desktop" being the obvious one, so the
  // bang row is built here and pushed below the applications rather than
  // taking the cursor off them.
  function bangRows(q) {
    var bang = Web.bang(q)
    if (!bang) return []
    return [root.row({
      key: "bang." + bang.key, section: "Search", kind: "url",
      title: bang.query, subtitle: "Search " + bang.engine.name,
      accessory: bang.engine.name, icon: bang.engine.icon,
      primaryLabel: "Search " + bang.engine.name,
      payload: { url: Web.searchUrl(bang.query, bang.key) }
    })]
  }

  // Both sources answer with the same [{entry, score}] shape, so nothing below
  // has to know which one produced the list.
  function appEntries(q) {
    if (root.appLibrary) {
      var ranked = root.appLibrary.sortedEntries(q) || []
      return ranked.slice(0, root.maxAppCandidates)
    }
    var values = []
    try { values = DesktopEntries.applications.values || [] } catch (e) { return [] }
    return Apps.sortedEntries(values, q, root.appHides,
      root.maxAppCandidates, root.maxAppCandidates * 8)
  }

  function appName(entry) {
    return root.appLibrary ? root.appLibrary.entryName(entry) : Apps.entryName(entry)
  }

  function appSubtext(entry) {
    return root.appLibrary ? root.appLibrary.entrySubtext(entry) : Apps.entrySubtext(entry)
  }

  // AppLibrary keeps its own index of icons installed after the shell started,
  // because this process's themed-icon cache never re-scans. Without it, the
  // themed lookup is what there is, and an app installed since login falls
  // back to the generic icon rather than showing none.
  function appIcon(icon) {
    if (root.appLibrary) return root.appLibrary.iconSource(icon)
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var themed = Quickshell.iconPath(value, true)
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  // The launch Omarchy itself performs, minus its OSD: gtk-launch resolves the
  // desktop id — including ids with spaces and ones UWSM rejects — and
  // uwsm-app puts the app under app-graphical.slice rather than leaving it a
  // child of the shell's own unit.
  function launchApp(appId, name) {
    if (root.appLibrary) {
      root.appLibrary.launch(appId, name)
      return
    }
    var id = String(appId || "")
    if (!id) return
    Util.execArgv(["uwsm-app", "--", "gtk-launch", id + ".desktop"])
  }

  function appRows(q) {
    // The System category view (and any query primed with noApps) shows
    // Commands, Hotkeys and web search only — never applications.
    if (q && root.primedNoAppsQuery !== "" && q === root.primedNoAppsQuery) return []
    var entries = root.appEntries(q)
    var now = Date.now()
    var candidates = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i].entry
      var key = "app:" + String(entry.id || "")
      // sortedEntries scored the match as well as ordering it, and keeping
      // that number instead of the position is what lets frecency stay a
      // bounded bonus. Flattened to a rank position, "the name starts with the
      // query" and "one letter of the acronym matched" sit a single point
      // apart, so any usage at all was enough to swap them.
      candidates.push({
        key: key,
        entry: entry,
        order: i,
        score: (q ? (Number(entries[i].score) || 0) : 0)
          + Frecency.weight(root.usage[key], now) * (q ? root.appFrecencyBoost : root.idleFrecencyBoost)
      })
    }
    candidates.sort(function(a, b) {
      if (b.score !== a.score) return b.score - a.score
      return a.order - b.order
    })

    var limit = q ? Util.clamp(root.settings.maxApps, 3, root.maxAppRows)
      : root.maxExpandedAppRows
    var out = []
    for (var j = 0; j < candidates.length && out.length < limit; j++) {
      var c = candidates[j]
      out.push(root.row({
        key: c.key,
        section: "Applications", kind: "app",
        title: root.appName(c.entry),
        subtitle: root.appSubtext(c.entry),
        accessory: "Application",
        image: root.appIcon(c.entry.icon),
        primaryLabel: "Open",
        payload: { appId: String(c.entry.id || ""), name: root.appName(c.entry) }
      }))
    }
    return out
  }

  // Open windows, so "switch to that Slack window" is one query away.
  function windowRows(q) {
    if (!q) return []
    var candidates = []
    var values = []
    try { values = ToplevelManager.toplevels.values || [] } catch (e) { return [] }

    for (var i = 0; i < values.length && i < root.maxWindowCandidates; i++) {
      var t = values[i]
      if (!t) continue
      var title = String(t.title || "").slice(0, root.maxTitleChars)
      var appId = String(t.appId || "").slice(0, 256)
      if (!title && !appId) continue
      candidates.push({
        title: title || appId,
        subtitle: appId,
        keywords: "window switch focus " + appId,
        toplevel: t
      })
    }

    var ranked = Fuzzy.rank(candidates, q, 8)
    // Usage reorders within the matched set, the same bounded bonus the
    // commands use — a focused window is still a deliberate match away.
    var now = Date.now()
    var scored = []
    for (var k = 0; k < ranked.length; k++) {
      var wkey = "win:" + ranked[k].subtitle + ":" + ranked[k].title
      scored.push({
        hit: ranked[k], key: wkey,
        score: Fuzzy.score(ranked[k], q) + Frecency.weight(root.usage[wkey], now) * root.commandFrecencyBoost
      })
    }
    scored.sort(function(a, b) { return b.score - a.score })
    var out = []
    for (var j = 0; j < scored.length && j < 5; j++) {
      out.push(root.row({
        key: scored[j].key,
        section: "Open Windows", kind: "window",
        title: scored[j].hit.title, subtitle: scored[j].hit.subtitle,
        accessory: "Window", icon: "󰖯",
        primaryLabel: "Focus window",
        secondaryLabel: "Close window",
        payload: { toplevel: scored[j].hit.toplevel }
      }))
    }
    return out
  }

  function commandRows(q) {
    if (!q) return []
    var catalogue = Commands.commands().concat(Commands.quicklinks())
    var ranked = Fuzzy.rank(catalogue, q, 40)

    // Usage reorders within the matched set without overriding a strong
    // title match, hence the bonus being added to the fuzzy score.
    var now = Date.now()
    var scored = []
    for (var i = 0; i < ranked.length; i++) {
      var key = "cmd:" + ranked[i].key
      scored.push({
        cmd: ranked[i],
        score: Fuzzy.score(ranked[i], q) + Frecency.weight(root.usage[key], now) * root.commandFrecencyBoost,
        order: i
      })
    }
    scored.sort(function(a, b) {
      if (b.score !== a.score) return b.score - a.score
      return a.order - b.order
    })

    var out = []
    for (var j = 0; j < scored.length && j < 7; j++) {
      var c = scored[j].cmd
      out.push(root.row({
        key: "cmd:" + c.key,
        section: c.kind === "url" ? "Quicklinks" : "Commands",
        kind: c.kind,
        title: c.title, subtitle: c.subtitle,
        accessory: c.kind === "url" ? "Link" : "Command",
        icon: c.icon,
        primaryLabel: c.kind === "url" ? "Open in browser" : "Run",
        confirm: c.confirm === true,
        payload: { argv: c.argv || [], id: c.id || "", url: c.url || "" }
      }))
    }
    return out
  }

  // "#ff6644" answers directly; anything naming the picker gets the
  // eyedropper row. Both sit with the other intent rows, above search.
  function colorRows(q) {
    var query = String(q || "")
    if (!query) return []
    var out = []
    var picker = {
      title: "Pick a Color", subtitle: "",
      keywords: "color picker eyedropper screen hex sample pixel", accessory: ""
    }
    if (Fuzzy.score(picker, query) >= 0) {
      out.push(root.row({
        key: "color.pick", section: "Colors", kind: "shell",
        title: "Pick a Color", subtitle: "Sample any pixel on your screen",
        accessory: "Eyedropper", icon: "",
        primaryLabel: "Pick color",
        payload: { argv: ["hyprpicker", "-a"] }
      }))
    }
    var parsed = Colors.parse(query)
    if (parsed) {
      for (var i = 0; i < parsed.values.length; i++) {
        var v = parsed.values[i]
        out.push(root.row({
          key: "color:" + parsed.swatch + ":" + i, section: "Colors", kind: "copy",
          title: v.text, subtitle: v.label,
          accessory: "Color", icon: "●", mono: true,
          primaryLabel: "Copy color",
          payload: { text: v.text }
        }))
      }
    }
    return out
  }

  // "settings" lists one row per option with its live value; "settings web"
  // narrows to the matching ones. Enter toggles/steps, Shift+Enter reverses.
  function settingsRows(q) {
    var m = String(q || "").match(/^settings?(?:\s+(.*))?$/i)
    if (!m) return []
    var filter = (m[1] || "").trim()
    var defs = Settings.options()
    var out = []
    for (var i = 0; i < defs.length; i++) {
      var opt = defs[i]
      if (filter && Fuzzy.score({ title: opt.label, keywords: opt.key }, filter) < 0) continue
      var value = root.settings[opt.key]
      out.push(root.row({
        key: "setting:" + opt.key, section: "Settings", kind: "setting",
        title: opt.label, subtitle: Settings.describe(opt, value),
        accessory: Settings.displayValue(opt, value), icon: "",
        primaryLabel: opt.type === "boolean" ? "Toggle" : "Next",
        secondaryLabel: opt.type === "boolean" ? "" : "Previous",
        payload: { key: opt.key }
      }))
    }
    return out
  }

  // Idle front page, named exactly like the stock menu root. Each row primes
  // its query (or runs, for the self-contained leaves) instead of drilling
  // into a submenu tree, which this palette deliberately does not have —
  // mixed/interactive submenus (Trigger's tools, Setup's editors, Install's
  // pickers) have no single flat answer, so they prime the closest query
  // and the rest stays a keystroke away in search. The Apps row expands the
  // full frecency app list in place; Esc closes as usual, and Left arrow
  // steps back to categories while the query is empty.
  function categoryRows() {
    if (root.appsExpanded) return []
    var defs = [
      { key: "cat.apps", title: "Apps", subtitle: "Your applications", icon: "󰀻", expand: true },
      { key: "cat.learn", title: "Learn", subtitle: "Docs and wikis", icon: "󰖟", query: "docs" },
      { key: "cat.trigger", title: "Trigger", subtitle: "Capture, record, tools", icon: "󰩭", query: "screenshot" },
      { key: "cat.style", title: "Style", subtitle: "Theme, wallpaper, font", icon: "󰸌", query: "theme" },
      { key: "cat.setup", title: "Setup", subtitle: "Configure the system", icon: "󰒓", query: "config" },
      { key: "cat.install", title: "Install", subtitle: "Add software", icon: "󰉋", argv: ["xdg-terminal-exec", "--app-id=org.omarchy.terminal", "omarchy-pkg-install"] },
      { key: "cat.remove", title: "Remove", subtitle: "Remove software", icon: "󰩹", argv: ["xdg-terminal-exec", "--app-id=org.omarchy.terminal", "omarchy-pkg-remove"] },
      { key: "cat.update", title: "Update", subtitle: "Omarchy and packages", icon: "󰚰", argv: ["omarchy", "launch", "tui", "omarchy-update"] },
      { key: "cat.about", title: "About", subtitle: "This system", icon: "󰋼", argv: ["omarchy", "launch", "about"] },
      { key: "cat.system", title: "System", subtitle: "Lock, log out, restart, shut down", icon: "󰐥", query: "system", noApps: true }
    ]
    var out = []
    for (var i = 0; i < defs.length; i++) {
      var d = defs[i]
      if (d.argv) {
        out.push(root.row({
          key: d.key, section: "Categories", kind: "shell",
          title: d.title, subtitle: d.subtitle,
          accessory: "Category", icon: d.icon,
          primaryLabel: "Open",
          payload: { argv: d.argv }
        }))
      } else if (d.expand) {
        out.push(root.row({
          key: d.key, section: "Categories", kind: "expand",
          title: d.title, subtitle: d.subtitle,
          accessory: "Category", icon: d.icon,
          primaryLabel: "Browse",
          payload: {}
        }))
      } else {
        out.push(root.row({
          key: d.key, section: "Categories", kind: "prime",
          title: d.title, subtitle: d.subtitle,
          accessory: "Category", icon: d.icon,
          primaryLabel: "Browse",
          payload: { query: d.query, noApps: d.noApps === true }
        }))
      }
    }
    return out
  }

  // The Learn category's subcategory: alongside the doc links, a row that
  // opens the full keybindings list (same viewer as Super+K, through the
  // dmenu select protocol back into this panel).
  function learnRows(q) {
    if (String(q || "").trim().toLowerCase() !== "docs") return []
    return [root.row({
      key: "learn.keybinds", section: "Learn", kind: "shell",
      title: "Keybinds", subtitle: "Browse every Omarchy keybinding",
      accessory: "Category", icon: "",
      primaryLabel: "Open",
      payload: { argv: ["omarchy", "menu", "keybindings"] }
    })]
  }

  function clipboardQuery(q) {
    var m = String(q || "").match(/^(?:cb|clip|clipboard)\s+(\S.*)$/i)
    return m ? m[1].trim() : ""
  }

  // Only the one-line titles are held here. A clipboard history is the last
  // thing that should be resident in a process that outlives the query — it is
  // where tokens and passwords end up — so the bodies stay on disk and the
  // helper pipes the chosen one straight into wl-copy without it ever crossing
  // back into the shell.
  function clipboardResultRows(q) {
    var needle = root.clipboardQuery(q)
    if (!needle) return []
    var ranked = Fuzzy.rank(root.clipboardRows, needle, root.maxClipboardRows)
    var out = []
    for (var i = 0; i < ranked.length; i++) {
      out.push(root.row({
        key: "clip:" + ranked[i].index,
        section: "Clipboard History", kind: "clipcopy",
        title: ranked[i].title, subtitle: "",
        accessory: "Copy", icon: "󰅌", mono: true,
        primaryLabel: "Copy to clipboard",
        payload: { index: ranked[i].index, title: ranked[i].title }
      }))
    }
    return out
  }

  function emojiQuery(q) {
    var s = String(q || "")
    if (s.charAt(0) !== ":") return null
    return s.slice(1).trim()
  }

  // ":smile" searches the first-party catalogue; usage reorders within the
  // matched set the same way commands do. Enter copies the glyph.
  function emojiRows(q) {
    var needle = root.emojiQuery(q)
    if (needle === null || root.emojis.length === 0) return []
    var found = Emoji.search(root.emojis, needle, 24)
    var now = Date.now()
    var scored = []
    for (var i = 0; i < found.length; i++) {
      var f = found[i]
      var key = "emoji:" + f.index
      scored.push({
        found: f, key: key,
        score: f.score + Frecency.weight(root.usage[key], now) * root.commandFrecencyBoost
      })
    }
    scored.sort(function(a, b) { return b.score - a.score })
    var out = []
    for (var j = 0; j < scored.length; j++) {
      var s = scored[j].found
      out.push(root.row({
        key: scored[j].key, section: "Emoji", kind: "copy",
        title: Emoji.title(s.k), subtitle: "",
        accessory: "Copy", icon: s.e,
        primaryLabel: "Copy emoji",
        payload: { text: s.e }
      }))
    }
    return out
  }

  // The Super+K binds, searchable by what they do. Runnable binds dispatch
  // through the same script the menu uses; keyboard-only ones (Lua closures
  // such as Close window) show greyed so the keys can still be learned.
  function fuzzyScore(candidate, query) {
    return Fuzzy.score(candidate, query)
  }

  function hotkeyRows(q) {
    var query = String(q || "").trim()
    if (!query || root.hotkeyBinds.length === 0) return []
    var specs = Hotkeys.rows(query, root.hotkeyBinds,
      { limit: 7, keyboardOnly: true }, root.fuzzyScore)
    var now = Date.now()
    var scored = []
    for (var i = 0; i < specs.length; i++) {
      var key = "hotkey:" + specs[i].id
      scored.push({
        spec: specs[i], key: key,
        score: specs[i].score + Frecency.weight(root.usage[key], now) * root.commandFrecencyBoost
      })
    }
    scored.sort(function(a, b) { return b.score - a.score })
    var out = []
    for (var j = 0; j < scored.length; j++) {
      var sp = scored[j].spec
      if (sp.runnable) {
        out.push(root.row({
          key: scored[j].key, section: "Hotkeys", kind: "shell",
          title: sp.label, subtitle: sp.subtitle,
          accessory: sp.accessory, icon: "",
          primaryLabel: "Run",
          payload: { argv: Hotkeys.dispatchArgv(root.omarchyPath, sp.dispatcher, sp.arg) }
        }))
      } else {
        out.push(root.row({
          key: scored[j].key, section: "Hotkeys", kind: "noop",
          title: sp.label, subtitle: sp.subtitle,
          accessory: sp.accessory, icon: "",
          primaryLabel: ""
        }))
      }
    }
    return out
  }

  // Picker rows: the caller's options in the caller's order, narrowed by
  // substring. The glyph shows; the returned value is the label alone, or
  // label-plus-subtext when the caller gave rows same-named keys.
  function dmenuRows() {
    if (root.dmenuMode === "input") return []
    var q = String(root.query || "").trim()
    var found = Dmenu.filterOptions(root.dmenuOptions, q)
    var out = []
    for (var i = 0; i < found.length; i++) {
      var f = found[i]
      out.push(root.row({
        key: "dmenu:" + f.index, section: root.dmenuPrompt || "Select", kind: "dmenu",
        title: f.label, subtitle: f.detail,
        accessory: "", icon: f.icon,
        primaryLabel: "Select",
        payload: { value: f.value }
      }))
    }
    return out
  }

  function reminderListRows(q) {
    if (!/^reminders?$/i.test(String(q || "").trim())) return []
    if (root.reminderRows.length === 0) {
      return [root.row({
        key: "reminder.none", section: "Reminders", kind: "noop",
        title: "No active reminders", subtitle: "Try “remind me in 20m to …”",
        accessory: "", icon: "󰢌", primaryLabel: ""
      })]
    }
    var out = []
    for (var i = 0; i < root.reminderRows.length && i < root.maxReminderRows; i++) {
      var r = root.reminderRows[i]
      out.push(root.row({
        key: "reminder.active." + i,
        section: "Reminders", kind: "noop",
        title: String(r.label || ""),
        subtitle: "in " + String(r.remaining || "") + " · at " + String(r.atTime || ""),
        accessory: "Active", icon: "󰔟", primaryLabel: ""
      }))
    }
    out.push(root.row({
      key: "reminder.clear", section: "Reminders", kind: "shell",
      title: "Clear all reminders", subtitle: root.reminderRows.length + " active",
      accessory: "Command", icon: "󰩹",
      primaryLabel: "Clear", payload: { argv: ["omarchy", "reminder", "clear"] }
    }))
    return out
  }

  function fileResultRows(q) {
    if (root.fileRows.length === 0) return []
    var out = []
    for (var i = 0; i < root.fileRows.length && i < root.maxFileRows; i++) {
      var f = root.fileRows[i]
      out.push(root.row({
        key: "file:" + f.path,
        section: "Files", kind: "file",
        title: f.name, subtitle: f.dir,
        accessory: f.isDir ? "Folder" : "File",
        icon: f.isDir ? "󰉋" : "󰈔",
        primaryLabel: "Open",
        secondaryLabel: "Open folder",
        payload: { path: f.path, dir: f.dir }
      }))
    }
    return out
  }

  function suggestionResultRows(q) {
    if (root.suggestionRows.length === 0) return []
    var engine = String(root.settings.searchEngine || "g")
    var out = []
    for (var i = 0; i < root.suggestionRows.length; i++) {
      var s = root.suggestionRows[i]
      out.push(root.row({
        key: "sugg:" + s,
        section: "Web Suggestions", kind: "url",
        title: s, subtitle: "",
        accessory: Web.engineName(engine),
        icon: Web.engineIcon(engine),
        primaryLabel: "Search " + Web.engineName(engine),
        payload: { url: Web.searchUrl(s, engine) }
      }))
    }
    return out
  }

  function webFallbackRows(q) {
    if (!q) return []
    if (Web.detectUrl(q)) return []
    var engine = String(root.settings.searchEngine || "g")
    return [root.row({
      key: "web.fallback", section: "Search the Web", kind: "url",
      title: "Search " + Web.engineName(engine) + " for “" + q + "”",
      subtitle: "",
      accessory: Web.engineName(engine),
      icon: Web.engineIcon(engine),
      primaryLabel: "Search " + Web.engineName(engine),
      payload: { url: Web.searchUrl(q, engine) }
    })]
  }

  // ------------------------------------------------------------- assembly
  function rebuild() {
    // A pending picker owns the list: narrowing options is the whole UI,
    // and palette rows must never steal the cursor from it.
    if (root.dmenuActive) {
      var picked = root.dmenuRows()
      root.rows = picked
      displayModel.clear()
      for (var d = 0; d < picked.length; d++) {
        var pd = picked[d]
        displayModel.append({
          rowIndex: d,
          section: pd.section,
          rowTitle: pd.title,
          rowSubtitle: pd.subtitle,
          rowAccessory: pd.accessory,
          rowIcon: pd.icon,
          rowImage: pd.image,
          rowMono: pd.mono,
          selectable: pd.kind !== "noop"
        })
      }
      var prestored = root.pinnedKey ? root.indexOfKey(root.pinnedKey) : -1
      if (root.pinnedKey && prestored < 0) root.pinnedKey = ""
      root.selectedIndex = prestored >= 0 ? prestored : root.firstSelectableIndex()
      root.cursorActive = picked.length > 0
      pointerGate.reset()
      Qt.callLater(function() {
        if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
      })
      return
    }

    var q = String(root.query || "").trim()

    var next = []
    function push(list) { for (var i = 0; i < list.length; i++) next.push(list[i]) }

    // Idle is the categories front page only; the Apps category (or the
    // apps route) swaps in the full app list instead. Any keystroke leaves
    // for full search.
    if (!q) {
      push(root.categoryRows())
      if (root.appsExpanded) push(root.appRows(q))
      root.rows = next
      root.finishRebuild(next)
      return
    }

    push(root.intentRows(q))
    push(root.colorRows(q))
    push(root.settingsRows(q))
    push(root.clipboardResultRows(q))
    push(root.reminderListRows(q))
    push(root.appRows(q))
    push(root.windowRows(q))
    push(root.emojiRows(q))
    push(root.bangRows(q))
    push(root.commandRows(q))
    push(root.learnRows(q))
    push(root.hotkeyRows(q))
    push(root.fileResultRows(q))
    push(root.suggestionResultRows(q))
    push(root.webFallbackRows(q))

    root.finishRebuild(next)
  }

  function finishRebuild(next) {
    root.rows = next

    displayModel.clear()
    for (var j = 0; j < next.length; j++) {
      var r = next[j]
      displayModel.append({
        rowIndex: j,
        section: r.section,
        rowTitle: r.title,
        rowSubtitle: r.subtitle,
        rowAccessory: r.accessory,
        rowIcon: r.icon,
        rowImage: r.image,
        rowMono: r.mono,
        selectable: r.kind !== "noop"
      })
    }

    // A deliberate cursor is restored by key, so an async refresh cannot move
    // it. Everything else follows the top row on every single rebuild: a key
    // that outlives the query it was built for — the web-search fallback, a
    // suggestion still on screen while its replacement is in flight — must
    // never inherit the cursor and turn the next Enter into a web search.
    var restored = root.pinnedKey ? root.indexOfKey(root.pinnedKey) : -1
    if (root.pinnedKey && restored < 0) root.pinnedKey = ""
    root.selectedIndex = restored >= 0 ? restored : root.firstSelectableIndex()
    root.cursorActive = next.length > 0
    pointerGate.reset()
    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function selectedRowKey() {
    var r = root.rows[root.selectedIndex]
    return r ? r.key : ""
  }

  function indexOfKey(key) {
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].key === key) return i
    return -1
  }

  function firstSelectableIndex() {
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].kind !== "noop") return i
    return 0
  }

  function selectedRow() {
    return root.rows[root.selectedIndex] || null
  }

  // Only a pointer that actually moved may move the cursor, and not while the
  // keyboard is still mid-thought. The card animates its height as rows
  // arrive, so a pointer resting anywhere over the list has rows sliding under
  // it on every keystroke; hover winning that race is how "stea" ends up
  // selecting a web suggestion instead of Steam.
  function selectFromPointer(index, item, mouse) {
    if (typingGuard.running) return
    if (!root.rows[index] || root.rows[index].kind === "noop") return
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
    root.pinnedKey = root.selectedRowKey()
    root.armedKey = ""
  }

  // Steps over "noop" rows (hints, reminder listings) so the cursor only ever
  // rests somewhere Enter means something.
  function select(delta) {
    var count = root.rows.length
    if (count === 0) return
    var index = root.selectedIndex
    for (var step = 0; step < count; step++) {
      index = (index + delta + count) % count
      if (root.rows[index] && root.rows[index].kind !== "noop") break
    }
    root.selectedIndex = index
    root.pinnedKey = root.selectedRowKey()
    root.cursorActive = true
    root.armedKey = ""
    pointerGate.reset()
    resultList.positionViewAtIndex(index, ListView.Contain)
  }

  function selectPage(delta) {
    var count = root.rows.length
    if (count === 0) return
    var visible = Math.max(1, Math.floor(resultList.height / root.rowHeight))
    var index = Math.max(0, Math.min(count - 1, root.selectedIndex + delta * visible))
    while (index >= 0 && index < count && root.rows[index] && root.rows[index].kind === "noop")
      index += delta > 0 ? 1 : -1
    if (index < 0 || index >= count) index = delta > 0 ? count - 1 : 0
    root.selectedIndex = index
    root.pinnedKey = root.selectedRowKey()
    root.cursorActive = true
    root.armedKey = ""
    pointerGate.reset()
    resultList.positionViewAtIndex(index, ListView.Contain)
  }

  // ------------------------------------------------------------- actions
  function openUrl(url) {
    if (!url) return
    Util.execArgv(["omarchy-launch-browser", String(url)])
  }

  // Enter comes through here rather than going straight at selectedIndex.
  // With no deliberate cursor the intent is always "the best row for what I
  // typed", and resolving that at the keystroke closes the window between a
  // rebuild landing and the cursor settling onto it.
  function activateSelection(secondary) {
    // Text input has no rows: Enter finishes the request with what was typed.
    if (root.dmenuActive && root.dmenuMode === "input") {
      root.finishRequest(root.query)
      root.dismiss()
      return
    }
    root.activate(root.pinnedKey ? root.selectedIndex : root.firstSelectableIndex(), secondary)
  }

  function activate(index, secondary) {
    var r = root.rows[index]
    if (!r || r.kind === "noop") return

    // One confirmation for the rows that end the session.
    if (r.confirm && !secondary && root.armedKey !== r.key) {
      root.armedKey = r.key
      return
    }
    root.armedKey = ""

    switch (r.kind) {
    case "app":
      root.bumpUsage(r.key)
      root.dismiss()
      root.launchApp(r.payload.appId, r.payload.name)
      break

    case "shell":
      root.bumpUsage(r.key)
      root.dismiss()
      // execArgv, not execDetached: the catalogue holds argv vectors rather
      // than command lines, so nothing here is ever re-tokenized by a shell.
      if (Array.isArray(r.payload.argv) && r.payload.argv.length > 0)
        Util.execArgv(r.payload.argv)
      break

    case "url":
      root.bumpUsage(r.key)
      root.dismiss()
      root.openUrl(r.payload.url)
      break

    case "summon":
      root.bumpUsage(r.key)
      root.dismiss()
      if (root.shell && typeof root.shell.summon === "function")
        root.shell.summon(r.payload.id, "{}")
      break

    case "copy":
      root.bumpUsage(r.key)
      root.dismiss()
      // wl-copy over argv, never a shell string: the text is user data.
      Util.execArgv(["wl-copy", "--", String(r.payload.text || "")])
      break

    case "clipcopy":
      root.dismiss()
      // The body was never loaded, so the helper is told which entry to copy
      // rather than what to copy. It re-reads the history under the same
      // bounds, re-identifies the row by the title the user actually saw — the
      // list may have shifted since — and pipes it to wl-copy itself.
      clipCopyProc.running = false
      clipCopyProc.command = root.helperArgv([
        "clipboard-copy", String(r.payload.index), String(r.payload.title || "")])
      clipCopyProc.running = true
      break

    case "reminder":
      root.dismiss()
      Util.execArgv(["omarchy-reminder", String(r.payload.minutes), String(r.payload.message || "")])
      break

    case "event":
      root.dismiss()
      if (secondary) root.saveIcs(r.payload)
      else root.openUrl("https://calendar.google.com/calendar/render?action=TEMPLATE"
        + "&text=" + encodeURIComponent(r.payload.title)
        + "&dates=" + r.payload.start + "/" + r.payload.end)
      break

    case "window":
      root.bumpUsage(r.key)
      root.dismiss()
      try {
        if (secondary) r.payload.toplevel.close()
        else r.payload.toplevel.activate()
      } catch (e) {
        console.warn("omaray: window action failed:", e)
      }
      break

    case "file":
      root.dismiss()
      if (secondary) Util.execArgv(["xdg-open", String(r.payload.dir || "")])
      else Util.execArgv(["xdg-open", String(r.payload.path || "")])
      break

    case "setting":
      // The panel stays open: the row rebuilds with the new value.
      root.applySetting(String(r.payload.key || ""), secondary ? -1 : 1)
      break

    case "dmenu":
      root.finishRequest(String(r.payload.value || ""))
      root.dismiss()
      break

    case "prime":
      // A category tap becomes the query it names; the rebuild that follows
      // is the drill-in. The cursor lands at the end, ready to narrow.
      root.primedNoAppsQuery = r.payload.noApps === true ? String(r.payload.query || "") : ""
      root.primedQuery = String(r.payload.query || "")
      input.text = String(r.payload.query || "")
      input.cursorPosition = input.text.length
      break

    case "expand":
      root.appsExpanded = true
      root.primedQuery = ""
      root.rebuild()
      break
    }
  }

  // Writes the event as an .ics next to the user's downloads and hands it to
  // the desktop.
  //
  // The path is predictable, which is the whole problem with writing one: a
  // shell redirect follows whatever symlink is already sitting at that name,
  // so anything able to drop a file in ~/Downloads first picks the target. The
  // helper creates the file O_EXCL|O_NOFOLLOW relative to a directory
  // descriptor it has verified it owns, so an existing name — symlink or not —
  // is stepped over rather than written through, and it reports back the path
  // it actually used.
  function saveIcs(payload) {
    var stamp = String(payload.start).replace(/[^0-9TZ]/g, "").slice(0, 32)
    if (!stamp) return
    var ics = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Omarchy//OmaRay//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH",
      "BEGIN:VEVENT",
      "UID:omaray-" + stamp + "@omarchy",
      "DTSTAMP:" + payload.start,
      "DTSTART:" + payload.start,
      "DTEND:" + payload.end,
      "SUMMARY:" + String(payload.title).replace(/([,;\\])/g, "\\$1").slice(0, 400),
      "END:VEVENT",
      "END:VCALENDAR",
      ""
    ].join("\r\n")

    icsProc.running = false
    icsProc.stdinEnabled = true
    icsProc.command = root.helperArgv(["write-ics", stamp])
    icsProc.running = true
    icsProc.write(ics)
    icsProc.stdinEnabled = false
  }

  // ------------------------------------------------------------- async data
  function loadSuggestions(raw, forQuery) {
    if (forQuery !== String(root.query || "").trim()) return
    var reply = root.helperReply(raw)
    var list = (reply && Array.isArray(reply.suggestions)) ? reply.suggestions : []
    var limit = Util.clamp(root.settings.maxSuggestions, 0, 8)
    var lower = forQuery.toLowerCase()
    var out = []
    var seen = Object.create(null)
    for (var i = 0; i < list.length && out.length < limit; i++) {
      var text = String(list[i] || "").trim()
      if (!text) continue
      var k = text.toLowerCase()
      if (k === lower || seen[k]) continue
      seen[k] = true
      out.push(text)
    }
    root.suggestionRows = out
    root.suggestionFor = forQuery
    root.rebuild()
  }

  function fileSearchTarget(q) {
    var s = String(q || "").trim()
    var m = s.match(/^(?:f|file|files)\s+(\S.*)$/i)
    if (m) return { pattern: m[1].trim(), dir: root.home }
    if (/^~\//.test(s) || /^\//.test(s)) {
      var slash = s.lastIndexOf("/")
      var dir = s.slice(0, slash + 1).replace(/^~/, root.home)
      var pattern = s.slice(slash + 1)
      return { pattern: pattern || ".", dir: dir }
    }
    return null
  }

  function loadFiles(raw, forQuery) {
    if (forQuery !== String(root.query || "").trim()) return
    var reply = root.helperReply(raw)
    var list = (reply && Array.isArray(reply.files)) ? reply.files : []
    var out = []
    for (var i = 0; i < list.length && out.length < root.maxFileRows; i++) {
      var f = list[i]
      if (!f || !f.path) continue
      out.push({
        path: String(f.path),
        name: String(f.name || ""),
        dir: String(f.dir || "/"),
        isDir: f.isDir === true
      })
    }
    root.fileRows = out
    root.fileFor = forQuery
    root.rebuild()
  }

  function loadReminders(raw) {
    var reply = root.helperReply(raw)
    var list = (reply && Array.isArray(reply.reminders)) ? reply.reminders : []
    var out = []
    for (var i = 0; i < list.length && out.length < root.maxReminderRows; i++) {
      var r = list[i]
      if (!r) continue
      out.push({
        label: String(r.label || ""),
        remaining: String(r.remaining || ""),
        atTime: String(r.atTime || "")
      })
    }
    root.reminderRows = out
    if (root.opened) root.rebuild()
  }

  function loadClipboard(raw) {
    var reply = root.helperReply(raw)
    var list = (reply && Array.isArray(reply.items)) ? reply.items : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (!item || typeof item.title !== "string" || !item.title) continue
      out.push({ index: Util.clamp(item.index, 0, 1000), title: item.title })
    }
    root.clipboardRows = out
    if (root.opened) root.rebuild()
  }

  function loadEmojis(raw) {
    var reply = root.helperReply(raw)
    var list = (reply && Array.isArray(reply.emojis)) ? reply.emojis : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (!e || typeof e.e !== "string" || typeof e.k !== "string") continue
      if (!e.e || !e.k) continue
      out.push({ e: e.e, k: e.k })
    }
    root.emojis = out
    if (root.opened) root.rebuild()
  }

  function loadHotkeys(raw) {
    var reply = root.helperReply(raw)
    var parsed = Hotkeys.parse(reply ? reply.records : "")
    // A failed hyprctl prints nothing: keep the previous list rather than
    // an empty screen.
    if (parsed.length > 0 || root.hotkeyBinds.length === 0) root.hotkeyBinds = parsed
    root.hotkeysLoadedAt = Date.now()
    if (root.opened) root.rebuild()
  }

  // Query changes fan out to the async providers on a short debounce so a
  // fast typist does not spawn a process per keystroke.
  onQueryChanged: {
    root.armedKey = ""
    // A new query invalidates a deliberate cursor: the row it named may not
    // even be in the list any more.
    root.pinnedKey = ""
    typingGuard.restart()

    var q = String(root.query || "").trim()

    // The clipboard list is fetched while a clipboard query is on screen and
    // dropped the moment it is not, so the titles are resident for the length
    // of the query rather than the length of the session.
    if (root.clipboardQuery(q)) {
      clipboardDebounce.restart()
    } else {
      clipboardDebounce.stop()
      if (root.clipboardRows.length > 0) root.clipboardRows = []
    }

    var target = root.settings.fileSearch ? root.fileSearchTarget(q) : null
    if (target && target.pattern.length >= 1) {
      fileDebounce.pattern = target.pattern
      fileDebounce.dir = target.dir
      fileDebounce.forQuery = q
      fileDebounce.restart()
    } else {
      fileDebounce.stop()
      if (root.fileRows.length > 0) { root.fileRows = []; root.fileFor = "" }
    }

    var wantSuggestions = root.settings.webSuggestions && q.length >= 2
      && !Web.detectUrl(q) && !Web.bang(q) && !Calc.evaluate(q)
      && !NaturalTime.isReminderQuery(q) && !NaturalTime.isEventQuery(q)
      && !root.clipboardQuery(q) && !root.fileSearchTarget(q)
      && q.charAt(0) !== ":" && q.charAt(0) !== "#"
      && !/^settings?(\s|$)/i.test(q) && Colors.parse(q) === null
    if (wantSuggestions) {
      suggestDebounce.forQuery = q
      suggestDebounce.restart()
      // Suggestions go stale the moment the query stops being a continuation
      // of the one that fetched them. Keeping the ones the new query still
      // narrows is what stops the list collapsing on every keystroke; dropping
      // the rest is what stops "stea" offering what "ste" asked for.
      if (root.suggestionFor && q.indexOf(root.suggestionFor) !== 0) {
        root.suggestionRows = []
        root.suggestionFor = ""
      }
    } else {
      suggestDebounce.stop()
      if (root.suggestionRows.length > 0) { root.suggestionRows = []; root.suggestionFor = "" }
    }

    // Last, so the rows show the caches this pass just invalidated rather than
    // the ones it is about to.
    root.rebuild()
  }

  // A keystroke owns the cursor for a moment afterwards: long enough to cover
  // the card's height animation and the hover events it generates as rows
  // slide under a stationary pointer, short enough that reaching for the mouse
  // straight after typing still works.
  Timer {
    id: typingGuard
    interval: 400
  }

  Timer {
    id: suggestDebounce
    interval: 220
    property string forQuery: ""
    onTriggered: {
      suggestProc.running = false
      suggestProc.forQuery = suggestDebounce.forQuery
      suggestProc.command = root.helperArgv(["suggest", suggestDebounce.forQuery])
      suggestProc.running = true
    }
  }

  // The helper builds the endpoint itself and runs curl under a byte ceiling
  // and its own deadline, so neither a slow endpoint nor an oversized response
  // can hold or fill the shell process.
  Process {
    id: suggestProc
    property string forQuery: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadSuggestions(text, suggestProc.forQuery)
    }
  }

  Timer {
    id: fileDebounce
    interval: 160
    property string pattern: ""
    property string dir: ""
    property string forQuery: ""
    onTriggered: {
      fileProc.running = false
      fileProc.forQuery = fileDebounce.forQuery
      fileProc.command = root.helperArgv(["files", fileDebounce.dir, fileDebounce.pattern])
      fileProc.running = true
    }
  }

  // fd is bounded by --max-results, but a result count is not a time bound:
  // a deep or slow tree can keep it walking long after the query is stale.
  // The helper holds an independent wall-clock deadline over it and tears the
  // whole process group down when it expires.
  Process {
    id: fileProc
    property string forQuery: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadFiles(text, fileProc.forQuery)
    }
  }

  Timer {
    id: clipboardDebounce
    interval: 160
    onTriggered: {
      clipboardProc.running = false
      clipboardProc.command = root.helperArgv(["read-clipboard"])
      clipboardProc.running = true
    }
  }

  Process {
    id: clipboardProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadClipboard(text)
    }
  }

  Process { id: clipCopyProc }

  Process {
    id: remindersProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadReminders(text)
    }
  }

  Process {
    id: settingsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadSettings(text)
    }
  }

  Process {
    id: settingsWriteProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadWrittenSettings(text)
    }
    onExited: root.flushSettings()
  }

  Process {
    id: emojiProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadEmojis(text)
    }
  }

  Process {
    id: hotkeysProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadHotkeys(text)
    }
  }

  Process {
    id: dmenuFinishProc
  }

  Process {
    id: hidesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadHides(text)
    }
  }

  Process {
    id: usageReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadUsage(text)
    }
  }

  Process {
    id: usageWriteProc
    onExited: root.flushUsage()
  }

  Process {
    id: icsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = root.helperReply(text)
        if (reply && reply.path) Util.execArgv(["xdg-open", String(reply.path)])
      }
    }
  }

  Component.onCompleted: {
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.refreshSettings()
    root.refreshUsage()
  }

  // Unloading the plugin must not leave a reader behind. Each helper run has
  // its own deadline as a backstop, but the processes are terminated here so
  // teardown does not depend on one.
  Component.onDestruction: {
    root.stopQueryWork()
    clipCopyProc.running = false
    remindersProc.running = false
    settingsProc.running = false
    settingsWriteProc.running = false
    emojiProc.running = false
    hotkeysProc.running = false
    hidesProc.running = false
    usageReadProc.running = false
    usageWriteProc.running = false
    icsProc.running = false
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() { if (root.opened) root.rebuild() }
  }

  ListModel { id: displayModel }

  // A stationary pointer must not own the selection. Without this, opening
  // OmaRay with the cursor anywhere over the list hands the highlight to
  // whatever row happens to land under it, so Enter runs the wrong thing.
  PointerMoveGate {
    id: pointerGate
    referenceItem: pointerFrame
  }

  // ------------------------------------------------------------- surface
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    // The Hyprland layer rule that frosts this surface matches on this
    // namespace. Renaming it silently turns the glass off.
    WlrLayershell.namespace: "omarchy-omaray"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    // A screen-fixed frame for the pointer gate to measure against. The card
    // is the wrong reference: it animates its height and stays centred, so it
    // slides under a stationary pointer on every rebuild and every row that
    // maps into it reads as deliberate movement.
    Item {
      id: pointerFrame
      anchors.fill: parent
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Rectangle {
      id: card

      readonly property int listHeight: Math.min(root.maxListHeight, root.contentHeight)
      readonly property bool hasResults: displayModel.count > 0

      // Picker callers size the card: width honors their --width inside
      // the panel, and the list scrolls inside maxListHeight.
      width: root.dmenuActive
        ? Math.min(Style.space(root.dmenuWidth), panel.width - Style.space(48))
        : Math.min(Style.space(750), panel.width - Style.space(48))
      height: root.searchHeight
        + (hasResults ? root.hairline + root.listPadding * 2 + listHeight : 0)
        + root.hairline + root.footerHeight
      // Centred at whatever height it currently is, not just when full. The
      // height Behavior below drives y with it, so the panel grows and
      // shrinks symmetrically about the middle of the screen instead of
      // sitting high whenever a query returns only a few rows.
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter

      radius: root.cardRadius
      color: root.glassBackground
      border.width: root.hairline
      border.color: root.glassBorder
      antialiasing: true

      Behavior on height {
        NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
      }

      // Swallow clicks so they don't reach the dismiss MouseArea behind.
      MouseArea { anchors.fill: parent; onClicked: {} }

      // The 1px light line along the top edge is what makes a translucent
      // panel read as glass rather than as a flat tint.
      Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        anchors.margins: root.hairline
        height: root.hairline
        color: root.glassSheen
        radius: height
      }

      // ------------------------------------------------------- search row
      Item {
        id: searchRow
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: root.searchHeight

        Text {
          id: searchGlyph
          text: "󰍉"
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: root.searchFontSize
          anchors.left: parent.left
          anchors.leftMargin: root.gutter
          anchors.verticalCenter: parent.verticalCenter
        }

        TextInput {
          id: input
          anchors.left: searchGlyph.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.rightMargin: root.gutter
          anchors.verticalCenter: parent.verticalCenter

          color: root.foreground
          selectionColor: Util.alpha(root.accent, 0.35)
          selectedTextColor: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.searchFontSize
          // A query is a line someone typed, and every provider fans out from
          // it — the web fallback interpolates it into a row title, the file
          // search hands it to fd. Bounding it here bounds all of them.
          maximumLength: root.maxQueryChars
          clip: true
          focus: true
          activeFocusOnTab: false
          selectByMouse: true
          inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase

          onTextChanged: root.query = text

          Text {
            anchors.fill: parent
            visible: input.text.length === 0
            text: root.dmenuActive && root.dmenuPrompt.length > 0 ? root.dmenuPrompt : "Search for apps and commands…"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.38
            font.family: input.font.family
            font.pixelSize: input.font.pixelSize
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
          }

          // BeforeItem so navigation and activation win over text editing;
          // anything not handled here falls through to normal typing, which
          // keeps Ctrl+V, selection and caret movement intact.
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            typingGuard.restart()
            if (event.key === Qt.Key_Escape) {
              // A pristine category prime exits outright — Left is the way
              // back to categories. Anything typed stays two-step.
              if (input.text.length > 0
                  && (root.primedQuery === "" || input.text !== root.primedQuery))
                input.text = ""
              else root.dismiss()
              event.accepted = true
            } else if (event.key === Qt.Key_Down
                || (event.key === Qt.Key_N && event.modifiers === Qt.ControlModifier)) {
              root.select(1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up
                || (event.key === Qt.Key_P && event.modifiers === Qt.ControlModifier)) {
              root.select(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_PageDown) {
              root.selectPage(1)
              event.accepted = true
            } else if (event.key === Qt.Key_PageUp) {
              root.selectPage(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              var secondary = (event.modifiers & Qt.ShiftModifier) || (event.modifiers & Qt.ControlModifier)
              root.activateSelection(secondary ? true : false)
              event.accepted = true
            } else if (event.key === Qt.Key_Tab) {
              // Tab completes the query with the selected row's title, the way
              // a shell completes a path — handy for narrowing an app search.
              var sel = root.selectedRow()
              if (sel && sel.kind === "app") input.text = sel.title
              event.accepted = true
            } else if (event.key === Qt.Key_Left
                && event.modifiers === Qt.NoModifier && !root.dmenuActive) {
              // Left leaves a category view: the expanded Apps list on an
              // empty query, or a primed query still pristine since its tap
              // (same text, caret never moved). Anything edited or navigated,
              // and every picker field, keeps caret duty.
              if (root.appsExpanded && input.text.length === 0) {
                root.appsExpanded = false
                root.rebuild()
                event.accepted = true
              } else if (root.primedQuery !== "" && input.text === root.primedQuery
                  && input.cursorPosition === input.text.length) {
                root.primedQuery = ""
                root.primedNoAppsQuery = ""
                input.text = ""
                event.accepted = true
              }
            } else if (event.key === Qt.Key_Right
                && event.modifiers === Qt.NoModifier && !root.dmenuActive
                && input.text.length === 0) {
              // Right opens the selected category — the mirror of Left goes
              // back. Only cat.* rows answer; on an app, or with text to move
              // through, Right keeps its normal caret job.
              var cat = root.selectedRow()
              if (cat && cat.key && String(cat.key).indexOf("cat.") === 0) {
                root.activate(root.selectedIndex, false)
                event.accepted = true
              }
            }
          }
        }
      }

      Rectangle {
        id: searchDivider
        anchors { top: searchRow.bottom; left: parent.left; right: parent.right }
        anchors.leftMargin: root.hairline
        anchors.rightMargin: root.hairline
        height: root.hairline
        color: root.dividerColor
        visible: card.hasResults
      }

      // ------------------------------------------------------- results
      Item {
        anchors {
          top: searchDivider.bottom
          left: parent.left
          right: parent.right
        }
        anchors.topMargin: root.listPadding
        anchors.bottomMargin: root.listPadding
        height: card.listHeight
        visible: card.hasResults

        ListView {
          id: resultList
          anchors.fill: parent
          model: displayModel
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          currentIndex: root.selectedIndex
          highlightMoveDuration: 0

          section.property: "section"
          section.criteria: ViewSection.FullString
          section.delegate: Item {
            required property string section
            width: ListView.view.width
            height: root.sectionHeight

            // Sentence case, not caps: it is what Raycast does, and a
            // tracked-out all-caps label is the tell of a templated UI.
            Text {
              text: parent.section
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.Medium
              anchors.left: parent.left
              anchors.leftMargin: root.rowInset + root.listPadding
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(7)
            }
          }

          // The delegate root spans the full view width and is left where the
          // view puts it: a vertical ListView positions its delegates itself
          // and overwrites any `x` set here, which would push the whole inset
          // to one side. The padding belongs on the surface inside instead.
          delegate: Item {
            id: resultRow
            required property int index
            required property int rowIndex
            required property string rowTitle
            required property string rowSubtitle
            required property string rowAccessory
            required property string rowIcon
            required property string rowImage
            required property bool rowMono
            required property bool selectable

            readonly property bool hasCursor: root.cursorActive && resultRow.index === root.selectedIndex
            readonly property bool armed: root.armedKey.length > 0
              && root.rows[resultRow.rowIndex]
              && root.rows[resultRow.rowIndex].key === root.armedKey

            width: ListView.view.width
            height: root.rowHeight

            Rectangle {
              id: rowSurface
              anchors.fill: parent
              anchors.leftMargin: root.listPadding
              anchors.rightMargin: root.listPadding
              radius: root.rowRadius
              color: resultRow.armed
                ? Util.alpha(Color.urgent, 0.22)
                : (resultRow.hasCursor ? root.selectedBackground : "transparent")
            }

            Image {
              id: rowImageItem
              visible: resultRow.rowImage.length > 0
              source: resultRow.rowImage
              width: Style.space(20)
              height: Style.space(20)
              fillMode: Image.PreserveAspectFit
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              asynchronous: true
              anchors.left: rowSurface.left
              anchors.leftMargin: root.rowInset
              anchors.verticalCenter: rowSurface.verticalCenter
            }

            Text {
              id: rowGlyph
              visible: resultRow.rowImage.length === 0
              text: resultRow.rowIcon
              textFormat: Text.PlainText
              color: resultRow.hasCursor ? root.selectedText : root.foreground
              opacity: resultRow.hasCursor ? 1 : 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
              width: Style.space(20)
              horizontalAlignment: Text.AlignHCenter
              anchors.left: rowSurface.left
              anchors.leftMargin: root.rowInset
              anchors.verticalCenter: rowSurface.verticalCenter
            }

            Text {
              id: accessoryText
              text: resultRow.armed ? "Press ↵ again to confirm" : resultRow.rowAccessory
              textFormat: Text.PlainText
              color: resultRow.armed ? Color.urgent : root.foreground
              opacity: resultRow.armed ? 1 : 0.38
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.right: rowSurface.right
              anchors.rightMargin: root.rowInset
              anchors.verticalCenter: rowSurface.verticalCenter
            }

            Row {
              anchors.left: rowGlyph.right
              anchors.leftMargin: Style.space(10)
              anchors.right: accessoryText.left
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: rowSurface.verticalCenter
              spacing: Style.space(8)

              Text {
                id: titleText
                text: resultRow.rowTitle
                textFormat: Text.PlainText
                color: resultRow.hasCursor ? root.selectedText : root.foreground
                opacity: resultRow.selectable ? 1 : 0.75
                font.family: resultRow.rowMono ? Style.font.family : root.fontFamily
                font.pixelSize: Style.font.title
                font.weight: resultRow.hasCursor ? Font.Medium : Font.Normal
                elide: Text.ElideRight
                width: Math.min(implicitWidth, parent.width)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: resultRow.rowSubtitle
                textFormat: Text.PlainText
                visible: resultRow.rowSubtitle.length > 0 && parent.width - titleText.width > Style.space(60)
                color: root.foreground
                opacity: 0.42
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: Math.max(0, parent.width - titleText.width - Style.space(10))
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Fills the visible surface, not the delegate: the click target
            // should be exactly what the highlight shows.
            MouseArea {
              id: rowMouse
              anchors.fill: rowSurface
              hoverEnabled: true
              cursorShape: resultRow.selectable ? Qt.PointingHandCursor : Qt.ArrowCursor
              onEntered: root.selectFromPointer(resultRow.index, resultRow, {
                x: rowMouse.mouseX,
                y: rowMouse.mouseY
              })
              onPositionChanged: function(mouse) {
                root.selectFromPointer(resultRow.index, resultRow, mouse)
              }
              onClicked: function(mouse) {
                if (!resultRow.selectable) return
                root.cursorActive = true
                root.selectedIndex = resultRow.index
                root.activate(resultRow.index, (mouse.modifiers & Qt.ShiftModifier) ? true : false)
              }
            }
          }
        }
      }

      // ------------------------------------------------------- footer
      Rectangle {
        anchors { bottom: footer.top; left: parent.left; right: parent.right }
        anchors.leftMargin: root.hairline
        anchors.rightMargin: root.hairline
        height: root.hairline
        color: root.dividerColor
      }

      Item {
        id: footer
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        anchors.bottomMargin: root.hairline
        height: root.footerHeight

        Text {
          text: "󰣇  Omarchy"
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.35
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.left: parent.left
          anchors.leftMargin: root.gutter
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: root.gutter
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(14)

          Text {
            readonly property var sel: root.selectedRow()
            text: sel && sel.primaryLabel ? "↵  " + sel.primaryLabel : ""
            visible: text.length > 0
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            readonly property var sel: root.selectedRow()
            text: sel && sel.secondaryLabel ? "⇧↵  " + sel.secondaryLabel : ""
            visible: text.length > 0
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // Total height the result list wants, headers included. Driving the card
  // height off this is what gives the panel the Raycast grow/shrink feel.
  readonly property int contentHeight: {
    if (displayModel.count === 0) return 0
    var total = 0
    var lastSection = ""
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].section !== lastSection) {
        total += root.sectionHeight
        lastSection = root.rows[i].section
      }
      total += root.rowHeight
    }
    return total
  }
}
