import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
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
import "lib/Menu.js" as Menu
import "lib/Categories.js" as Categories
import "lib/System.js" as System

// OmaRay — a Raycast-shaped command palette for Omarchy.
//
// One overlay, many providers. Each provider turns the query into rows; the
// rows are plain data carrying a `kind`, and activate() is the only place that
// turns a kind into an effect. Nothing from the query is ever evaluated: the
// calculator has its own parser and every command runs through an argv vector.
Item {
  id: root

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

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
  property bool dmenuMultiple: false
  property var dmenuSelected: []
  property var dmenuSaved: []
  property var dmenuOnChange: []
  property string dmenuChangeKey: ""
  property string selectionFile: ""
  property string doneFile: ""
  property bool requestActive: false
  property int dmenuWidth: 300
  property int dmenuMaxHeight: 0

  // Stock-menu browsing state: the merged install/remove tree, guard
  // answers, and the scope currently open ("" = front page).
  property var menuItems: ({})
  property var menuOrder: []
  property var menuGuards: ({})
  property var menuChecked: ({})
  property var menuDisabled: ({})
  property var menuCatalogLabels: ({})
  property string menuScope: ""

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
  // High-resolution icon map (scalable > 512 > 256 > ...) so multi-size
  // hicolor icons like Steam resolve to 256x256 instead of 16x16.
  property var iconMap: ({})

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
  // True when opened directly via the `apps` route (Super+Alt+Space) rather
  // than drilled into from the Categories front page.
  property bool appsRouteDirect: false
  property var dockPinned: ({})
  property var appMenuTarget: null
  // True while the System category is open; cleared on every open.
  property bool systemExpanded: false
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

  // ------------------------------------------------------------- preview pane
  // Right-side preview for file search, clipboard history, color picker,
  // emoji picker, calculator/units and reminder/event intent rows. Only
  // previewable selections expand the card; everything else keeps the
  // single-column width. File bodies/snippets come from the bounded
  // `file-preview` helper op with a single-entry cache (never a map — this
  // process is keepLoaded). Clipboard stays title-only by design.
  property string previewKindStr: ""
  property string previewForPath: ""
  property var previewInfo: null
  readonly property bool showPreview: !root.dmenuActive && !root.appsExpanded && root.previewKindStr !== ""
  readonly property int previewWidth: Style.space(360)
  readonly property int wideCardWidth: Style.space(1120)
  readonly property int baseCardWidth: Style.space(750)
  readonly property int gridColumns: 7
  readonly property int gridVisibleRows: 4
  readonly property int gridCellWidth: Style.space(124)
  readonly property int gridCellHeight: Style.space(116)
  readonly property int gridIconSize: Style.space(52)
  readonly property int gridCardWidth: gridColumns * gridCellWidth + listPadding * 2
  readonly property int gridListHeight: gridVisibleRows * gridCellHeight

  function previewKindFor(r) {
    if (!r || !r.key) return ""
    var key = String(r.key)
    var kind = String(r.kind || "")
    if (kind === "file") return "file"
    if (kind === "clipcopy") return "clipboard"
    if (kind === "reminder" && key.indexOf("reminder.create") === 0) return "reminder"
    if (kind === "event") return "event"
    if (key === "calc") return "calc"
    if (key === "unit") return "unit"
    if (key.indexOf("color:") === 0) return "color"
    if (key.indexOf("emoji:") === 0) return "emoji"
    return ""
  }

  function previewKindLabel() {
    var k = root.previewKindStr
    if (k === "file") return strings.t("acc.file", "File")
    if (k === "clipboard") return strings.t("section.clipboard", "Clipboard")
    if (k === "color") return strings.t("acc.color", "Color")
    if (k === "emoji") return strings.t("section.emoji", "Emoji")
    if (k === "calc") return strings.t("section.calculator", "Calculator")
    if (k === "unit") return strings.t("section.conversion", "Conversion")
    if (k === "reminder") return strings.t("section.reminder", "Reminder")
    if (k === "event") return strings.t("section.calendar", "Calendar")
    return ""
  }

  function formatPreviewBytes(n) {
    var v = Number(n)
    if (!isFinite(v) || v < 0) return ""
    if (v < 1024) return v + " B"
    if (v < 1024 * 1024) return (Math.round(v / 102.4) / 10) + " KB"
    if (v < 1024 * 1024 * 1024) return (Math.round(v / 104857.6) / 10) + " MB"
    return (Math.round(v / 107374182.4) / 10) + " GB"
  }

  function formatPreviewMtime(epoch) {
    var t = Number(epoch)
    if (!isFinite(t) || t <= 0) return ""
    try {
      var d = new Date(t * 1000)
      return Qt.formatDateTime(d, "yyyy-MM-dd hh:mm")
    } catch (e) {
      return ""
    }
  }

  function updatePreview() {
    var r = root.selectedRow()
    var k = root.previewKindFor(r)
    if (k !== root.previewKindStr) root.previewKindStr = k
    if (k === "file" && r && r.payload && r.payload.path) {
      root.requestFilePreview(String(r.payload.path))
    } else {
      previewDebounce.stop()
      if (k !== "file") {
        root.previewForPath = ""
        root.previewInfo = null
      }
    }
  }

  function requestFilePreview(path) {
    if (!path || path.length > root.maxTitleChars + 512) return
    if (root.previewForPath === path && root.previewInfo) return
    previewDebounce.forPath = path
    previewDebounce.restart()
  }

  function loadFilePreview(raw, forPath) {
    var sel = root.selectedRow()
    if (!sel || sel.kind !== "file" || !sel.payload || sel.payload.path !== forPath) return
    var reply = root.helperReply(raw)
    var info = (reply && reply.preview && typeof reply.preview === "object") ? reply.preview : null
    if (!info) info = { path: forPath, unavailable: true }
    root.previewInfo = info
    root.previewForPath = forPath
  }

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
    var routeSystem = false
    var routeScope = ""
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
      }
      else if (resolved && resolved.kind === "apps") routeApps = true
      else if (resolved && resolved.kind === "system") routeSystem = true
      else if (resolved && resolved.kind === "scope") routeScope = String(resolved.scope || "")
    } catch (e) {
      initial = ""
      routeArgv = null
      routeApps = false
      routeSystem = false
      routeScope = ""
      routeQuery = ""
    }

    // Leaves run without the panel ever opening — the summon that named
    // them stays a plain action, the way the stock menu runs leaf routes.
    if (routeArgv) {
      if (Array.isArray(routeArgv) && routeArgv.length > 0) Util.execArgv(routeArgv)
      root.dismiss()
      return
    }

    if (root.requestActive) root.finishRequest(null)
    root.dmenuMode = ""
    root.dmenuOptions = []
    root.selectionFile = ""
    root.doneFile = ""
    root.requestActive = false
    // Every summon starts from a clean view. menuScope must reset here:
    // rebuild() prefers it over systemExpanded/appsExpanded/categories,
    // so a stale scope (e.g. Install) would shadow the next Super+Space,
    // Super+Esc or Super+Alt+Space summon. A route may name one of its
    // own, so the reset is the route's scope rather than an unconditional "".
    root.menuScope = routeScope
    // The Apps category: the full frecency app list instead of the
    // categories front page. Reset on every open.
    root.appsExpanded = routeApps
    root.appsRouteDirect = routeApps
    root.appMenuTarget = null
    root.systemExpanded = routeSystem
    root.primedQuery = routeQuery
    root.opened = true
    root.armedKey = ""
    root.rows = []
    root.pinnedKey = ""
    // Sync the query directly: when input.text already equals initial
    // (usually "" after browsing a category) onTextChanged does not fire
    // and root.query would keep its stale value.
    root.query = initial
    input.text = initial
    input.cursorPosition = input.text.length
    root.selectedIndex = 0
    root.cursorActive = true
    root.suggestionRows = []
    root.suggestionFor = ""
    root.fileRows = []
    root.fileFor = ""
    root.previewKindStr = ""
    root.previewForPath = ""
    root.previewInfo = null
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
    root.refreshMenuTree()
    root.refreshDockPinned()
    root.refreshIconMap()
    root.rebuild()
    pointerGate.reset()
    Qt.callLater(function() {
      input.forceActiveFocus()
      resultList.positionViewAtBeginning()
      appGrid.positionViewAtBeginning()
    })
  }

  function close() {
    if (root.requestActive) root.finishRequest(null)
    root.dmenuMode = ""
    root.dmenuOptions = []
    root.selectionFile = ""
    root.doneFile = ""
    root.requestActive = false
    // Defensive reset so a hide without a following open() never leaves a
    // stale category view behind. open() re-asserts all of these anyway.
    root.menuScope = ""
    root.appsExpanded = false
    root.appsRouteDirect = false
    root.appMenuTarget = null
    root.systemExpanded = false
    root.primedQuery = ""
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
    root.menuScope = ""
    root.appsExpanded = false
    root.appsRouteDirect = false
    root.appMenuTarget = null
    root.systemExpanded = false
    root.primedQuery = ""
    root.dmenuMode = payload.mode === "input" ? "input" : "select"
    root.dmenuPrompt = String(payload.prompt || (root.dmenuMode === "input" ? "Input" : "Select"))
    var opts = Array.isArray(payload.options) ? payload.options : []
    root.dmenuOptions = opts.slice(0, Dmenu.MAX_OPTIONS)
    root.dmenuMultiple = root.dmenuMode === "select" && payload.multiple === true
    root.dmenuOnChange = root.dmenuMultiple && Array.isArray(payload.onChange)
      && payload.onChange.every(function(arg) { return typeof arg === "string" }) ? payload.onChange.slice(0, 16) : []
    root.dmenuChangeKey = String(payload.changeKey || JSON.stringify(root.dmenuOnChange)).slice(0, 256)
    var initSelected = Array.isArray(payload.selected) ? payload.selected.map(function(v) { return String(v || "") }) : []
    root.dmenuSelected = Dmenu.selections(root.dmenuOptions, initSelected, root.dmenuOnChange.length > 0)
    root.dmenuSaved = root.dmenuSelected
    root.selectionFile = String(payload.selectionFile || "")
    root.doneFile = String(payload.doneFile || "")
    root.requestActive = root.doneFile.length > 0
    root.dmenuWidth = Dmenu.clampWidth(payload.width)
    root.dmenuMaxHeight = Dmenu.clampMaxHeight(payload.maxHeight)
    root.opened = true
    root.armedKey = ""
    root.rows = []
    root.pinnedKey = ""
    root.query = ""
    input.text = ""
    input.cursorPosition = 0
    root.selectedIndex = 0
    root.cursorActive = true
    root.suggestionRows = []
    root.suggestionFor = ""
    root.fileRows = []
    root.fileFor = ""
    root.clipboardRows = []
    root.previewKindStr = ""
    root.previewForPath = ""
    root.previewInfo = null
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
    previewDebounce.stop()
    suggestProc.running = false
    fileProc.running = false
    clipboardProc.running = false
    pasteProc.running = false
    previewProc.running = false
    emojiProc.running = false
    hotkeysProc.running = false
    root.clipboardRows = []
    root.previewKindStr = ""
    root.previewForPath = ""
    root.previewInfo = null
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

  function refreshIconMap() {
    if (iconsProc.running) return
    iconsProc.command = root.helperArgv(["read-icons"])
    iconsProc.running = true
  }

  function loadIconMap(raw) {
    var reply = root.helperReply(raw)
    var icons = (reply && reply.icons && typeof reply.icons === "object") ? reply.icons : null
    if (!icons) return
    var next = ({})
    for (var k in icons) {
      if (typeof icons[k] === "string" && icons[k].charAt(0) === "/") next[k] = icons[k]
    }
    root.iconMap = next
    if (root.opened) root.rebuild()
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

  // The stock install/remove tree, live from Omarchy's own data (plus user
  // extensions). Read on every open; guards follow in one batch.
  function refreshMenuTree() {
    menuTreeProc.running = false
    menuTreeProc.command = root.helperArgv(["menu-tree"])
    menuTreeProc.running = true
  }

  function loadMenuTree(raw) {
    var reply = root.helperReply(raw)
    var list = (reply && Array.isArray(reply.items)) ? reply.items : []
    var items = ({})
    var order = []
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (!e || typeof e.id !== "string" || !e.id) continue
      items[e.id] = {
        id: e.id,
        parent: String(e.parent || ""),
        kind: String(e.kind || "menu"),
        icon: String(e.icon || ""),
        iconFont: String(e.iconFont || ""),
        label: String(e.label || e.id),
        target: String(e.target || ""),
        action: String(e.action || ""),
        when: String(e.when || ""),
        checked: String(e.checked || ""),
        disabled: String(e.disabled || ""),
        provider: String(e.provider || ""),
        description: String(e.description || ""),
        aliases: Array.isArray(e.aliases) ? e.aliases.filter(function(a) {
          return typeof a === "string" && a
        }).slice(0, 20) : []
      }
      order.push(e.id)
    }
    var labels = (reply && reply.labels && typeof reply.labels === "object") ? reply.labels : {}
    var nextLabels = ({})
    for (var lk in labels) {
      if (typeof labels[lk] === "string" && labels[lk]) nextLabels[lk] = labels[lk]
    }
    root.menuCatalogLabels = nextLabels
    root.menuItems = items
    root.menuOrder = order
    root.refreshMenuGuards()
    root.refreshMenuProviders()
    if (root.opened) root.rebuild()
  }

  function refreshMenuGuards() {
    var wanted = {}
    var count = 0
    function want(id, when, checked, disabled) {
      if (!when && !checked && !disabled) return
      if (wanted[id] === undefined) count++
      wanted[id] = {
        when: String(when || ""),
        checked: String(checked || ""),
        disabled: String(disabled || "")
      }
    }
    for (var i = 0; i < root.menuOrder.length; i++) {
      var e = root.menuItems[root.menuOrder[i]]
      if (e && (e.when || e.checked || e.disabled)) want(e.id, e.when, e.checked, e.disabled)
    }
    var sysDefs = System.defs()
    for (var j = 0; j < sysDefs.length; j++) want(sysDefs[j].key, sysDefs[j].when, "", "")
    if (count === 0) {
      root.menuGuards = ({})
      root.menuChecked = ({})
      root.menuDisabled = ({})
      return
    }
    menuGuardsProc.stdinEnabled = true
    menuGuardsProc.command = root.helperArgv(["menu-guards"])
    menuGuardsProc.running = true
    menuGuardsProc.write(JSON.stringify(wanted))
    menuGuardsProc.stdinEnabled = false
  }

  function loadMenuGuards(raw) {
    var reply = root.helperReply(raw)
    var guards = (reply && reply.guards && typeof reply.guards === "object") ? reply.guards : {}
    var checked = (reply && reply.checked && typeof reply.checked === "object") ? reply.checked : {}
    var disabled = (reply && reply.disabled && typeof reply.disabled === "object") ? reply.disabled : {}
    var nextGuards = ({})
    var nextChecked = ({})
    var nextDisabled = ({})
    for (var k in guards) nextGuards[k] = guards[k] === true
    for (var ck in root.menuChecked) {
      var existing = root.menuItems[ck]
      if (existing && existing.providerMenu) nextChecked[ck] = root.menuChecked[ck] === true
    }
    for (var c in checked) nextChecked[c] = checked[c] === true
    for (var d in disabled) nextDisabled[d] = disabled[d] === true
    root.menuGuards = nextGuards
    root.menuChecked = nextChecked
    root.menuDisabled = nextDisabled
    if (root.opened) root.rebuild()
  }

  function refreshMenuProviders() {
    var wanted = {}
    var count = 0
    for (var i = 0; i < root.menuOrder.length; i++) {
      var e = root.menuItems[root.menuOrder[i]]
      if (!e || !e.provider || e.provider === "apps") continue
      wanted[e.id] = e.provider
      count++
    }
    if (count === 0) return
    menuProvidersProc.running = false
    menuProvidersProc.stdinEnabled = true
    menuProvidersProc.command = root.helperArgv(["menu-providers"])
    menuProvidersProc.running = true
    menuProvidersProc.write(JSON.stringify(wanted))
    menuProvidersProc.stdinEnabled = false
  }

  function loadMenuProviders(raw) {
    var reply = root.helperReply(raw)
    var list = (reply && Array.isArray(reply.items)) ? reply.items : []
    var byMenu = ({})
    var nextChecked = ({})
    for (var ck in root.menuChecked) {
      var prev = root.menuItems[ck]
      if (!prev || !prev.providerMenu) nextChecked[ck] = root.menuChecked[ck] === true
    }
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (!e || typeof e.id !== "string" || !e.id || !e.parent) continue
      if (!byMenu[e.parent]) byMenu[e.parent] = []
      byMenu[e.parent].push(e)
      if (e.isChecked === true) nextChecked[e.id] = true
    }
    var items = root.menuItems
    var order = root.menuOrder
    for (var mid in byMenu) {
      var swapped = Menu.swapProviderRows(items, order, mid, byMenu[mid])
      items = swapped.items
      order = swapped.order
    }
    root.menuItems = items
    root.menuOrder = order
    root.menuChecked = nextChecked
    if (root.opened) root.rebuild()
  }

  // Escape and successful activations go through here so the shell's
  // openPanelIds stays in step — otherwise the next toggle would try to hide
  // an overlay that is already gone.
  function dismiss() {
    root.close()
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

  // A `copy` row's text is user data, and the helper is the only crossing that
  // can keep it off argv: /proc/<pid>/cmdline is readable by any local user on
  // a system not mounted with hidepid, so a result left there is readable for
  // as long as the process lives. Fire-and-forget for the same reason
  // dmenuFinishProc is — dismiss() has already run, and stopQueryWork must not
  // tear this one down mid-write or the copy is silently lost.
  function copyText(text) {
    if (!text) return
    copyProc.running = false
    copyProc.stdinEnabled = true
    copyProc.command = root.helperArgv(["copy-text"])
    copyProc.running = true
    copyProc.write(text)
    copyProc.stdinEnabled = false
  }

  // Explicit paste routes through the helper's bounded `paste-text`
  // subcommand (PASTE_BYTES + PASTE_DEADLINE) instead of QClipboard, so a
  // slow or oversized Wayland clipboard offer cannot stall or exhaust the
  // shared shell process.
  function pasteClipboard() {
    if (!root.opened) return
    pasteProc.running = false
    pasteProc.command = root.helperArgv(["paste-text"])
    pasteProc.running = true
  }

  function prevCharPos(str, pos) {
    var s = String(str || "")
    var p = Math.max(0, Math.min(s.length, Number(pos) || 0))
    if (p <= 0) return 0
    if (p >= 2) {
      var hi = s.charCodeAt(p - 2)
      var lo = s.charCodeAt(p - 1)
      if (hi >= 0xd800 && hi <= 0xdbff && lo >= 0xdc00 && lo <= 0xdfff) return p - 2
    }
    return p - 1
  }

  function nextCharPos(str, pos) {
    var s = String(str || "")
    var p = Math.max(0, Math.min(s.length, Number(pos) || 0))
    if (p >= s.length) return s.length
    if (p + 1 < s.length) {
      var hi = s.charCodeAt(p)
      var lo = s.charCodeAt(p + 1)
      if (hi >= 0xd800 && hi <= 0xdbff && lo >= 0xdc00 && lo <= 0xdfff) return p + 2
    }
    return p + 1
  }

  function prevWordPos(str, pos) {
    var s = String(str || "")
    var p = Math.max(0, Math.min(s.length, Number(pos) || 0))
    return s.slice(0, p).replace(/\s+$/, "").replace(/\S+$/, "").length
  }

  function nextWordPos(str, pos) {
    var s = String(str || "")
    var p = Math.max(0, Math.min(s.length, Number(pos) || 0))
    var m = s.slice(p).match(/^\s*\S+/)
    return m ? p + m[0].length : s.length
  }

  function insertQueryText(fragment) {
    var clean = String(fragment || "").replace(/[\x00-\x1f\x7f]+/g, " ")
    if (!clean) return
    var cur = String(input.text || "")
    var pos = Math.max(0, Math.min(cur.length, Number(input.cursorPosition) || 0))
    var room = root.maxQueryChars - cur.length
    if (room <= 0) return
    var slice = clean.slice(0, room)
    var next = cur.slice(0, pos) + slice + cur.slice(pos)
    var nextPos = pos + slice.length
    input.text = next
    input.cursorPosition = nextPos
  }

  function loadPaste(raw) {
    if (!root.opened) return
    var reply = root.helperReply(raw)
    if (!reply || typeof reply.text !== "string" || !reply.text) return
    root.insertQueryText(reply.text)
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
      iconFont: String(spec.iconFont || "").slice(0, 64),
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
        payload: {
          text: calc.text.replace(/\s/g, ""),
          expr: q.replace(/^=/, "").trim(),
          value: calc.value,
          display: calc.text
        }
      }))
    }

    var unit = Units.convert(q)
    if (unit) {
      out.push(root.row({
        key: "unit", section: "Conversion", kind: "copy",
        title: unit.text, subtitle: unit.detail,
        accessory: unit.family, icon: "󰑤", mono: true,
        primaryLabel: "Copy result",
        payload: {
          text: unit.text.replace(/\s/g, ""),
          detail: unit.detail,
          family: unit.family,
          value: unit.value,
          display: unit.text
        }
      }))
    }

    // Date maths sits with the other direct answers, between the conversion
    // and the reminder: a count or a resolved date, before anything that
    // merely matches the words.
    var dateMath = root.dateMathRows(q)
    for (var d = 0; d < dateMath.length; d++) out.push(dateMath[d])

    var reminder = NaturalTime.parseReminder(q)
    if (reminder && !reminder.needsTime && reminder.message) {
      out.push(root.row({
        key: "reminder.create", section: "Reminder", kind: "reminder",
        title: reminder.message,
        subtitle: "Notify " + reminder.label + " · in " + NaturalTime.formatDuration(reminder.minutes),
        accessory: "Reminder", icon: "󰢌",
        primaryLabel: "Set reminder",
        payload: {
          minutes: reminder.minutes,
          message: reminder.message,
          label: reminder.label,
          query: q
        }
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
          end: NaturalTime.toUtcBasic(event.end),
          label: event.label,
          durationMinutes: event.durationMinutes,
          query: q
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

  // Date maths: "days until dec 25", "today + 90 days", "friday", "now",
  // "1790000000". One row per copyable form of the answer — the count, the
  // date, unix time, ISO — so Enter always puts something useful on the
  // clipboard, whichever row the cursor is on. The parser only answers a query
  // that is nothing but a date question, so nothing here can take the cursor
  // off an app or a command the query was aimed at.
  function dateMathRows(q) {
    var answer = NaturalTime.parseDateMath(q, new Date())
    if (!answer || !Array.isArray(answer.values)) return []
    var out = []
    for (var i = 0; i < answer.values.length; i++) {
      var v = answer.values[i]
      out.push(root.row({
        key: "date." + answer.kind + ":" + i, section: "Date maths", kind: "copy",
        title: v.text, subtitle: answer.subtitle,
        accessory: v.label, icon: "󰸗", mono: v.mono === true,
        primaryLabel: "Copy result",
        payload: {
          text: v.text,
          label: v.label,
          display: v.text,
          form: answer.kind,
          query: String(q || "")
        }
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
    var value = String(icon || "").trim()
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    if (root.iconMap[value]) return Util.fileUrl(root.iconMap[value])
    if (root.appLibrary) return root.appLibrary.iconSource(value)
    var themed = Quickshell.iconPath(value, true)
    if (themed && themed.length > 0) return themed
    return "file://" + Quickshell.env("HOME") + "/.local/share/icons/hicolor/256x256/apps/" + value + ".png"
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

  function uninstallApp(appId, name) {
    var id = String(appId || "")
    if (!id) return
    root.dismiss()
    if (root.appLibrary) {
      root.appLibrary.remove(id, String(name || id))
      return
    }
    var base = root.omarchyPath || "/usr/share/omarchy"
    Util.execArgv([base.replace(/\/$/, "") + "/bin/omarchy-remove-launcher-entry", id, String(name || id)])
  }

  function refreshDockPinned() {
    dockPinnedProc.running = false
    dockPinnedProc.command = root.helperArgv(["dock-pinned"])
    dockPinnedProc.running = true
  }

  function loadDockPinned(raw) {
    var reply = root.helperReply(raw)
    var list = (reply && Array.isArray(reply.pinned)) ? reply.pinned : []
    var next = ({})
    for (var i = 0; i < list.length; i++) {
      var id = String(list[i] || "").trim()
      if (id) next[id] = true
    }
    root.dockPinned = next
  }

  function isAppPinned(appId) {
    var id = String(appId || "").replace(/\.desktop$/, "")
    return root.dockPinned[id] === true
  }

  function toggleAppDockPin(appId) {
    var id = String(appId || "").replace(/\.desktop$/, "")
    if (!id) return
    var pinned = root.isAppPinned(id)
    var next = ({})
    for (var k in root.dockPinned) if (k !== id) next[k] = root.dockPinned[k]
    if (!pinned) next[id] = true
    root.dockPinned = next
    root.appMenuTarget = null
    Util.execArgv(["omarchy-dock", pinned ? "unpin" : "pin", id])
  }

  function appRows(q) {
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

    var limit = root.appsExpanded ? root.maxAppCandidates
      : (q ? Util.clamp(root.settings.maxApps, 3, root.maxAppRows) : root.maxExpandedAppRows)
    var out = []
    for (var j = 0; j < candidates.length && out.length < limit; j++) {
      var c = candidates[j]
      out.push(root.row({
        key: c.key,
        section: strings.t("section.applications", "Applications"), kind: "app",
        title: root.appName(c.entry),
        subtitle: root.appSubtext(c.entry),
        accessory: strings.t("acc.application", "Application"),
        image: root.appIcon(c.entry.icon),
        primaryLabel: strings.t("apps.open", "Open"),
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
        section: strings.t("section.openWindows", "Open Windows"), kind: "window",
        title: scored[j].hit.title, subtitle: scored[j].hit.subtitle,
        accessory: strings.t("acc.window", "Window"), icon: "󰖯",
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
        section: c.kind === "url" ? strings.t("section.quicklinks", "Quicklinks") : strings.t("section.commands", "Commands"),
        kind: c.kind,
        title: c.title, subtitle: c.subtitle,
        accessory: c.kind === "url" ? strings.t("acc.link", "Link") : strings.t("acc.command", "Command"),
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
          payload: {
            text: v.text,
            label: v.label,
            swatch: parsed.swatch,
            values: parsed.values
          }
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

  // Idle front page: the ten stock categories from lib/Categories.js. Rows
  // drill into scopes, expand Apps, prime queries or run leaves; Esc closes
  // as usual, and Left arrow steps back to categories while the query is
  // empty.
  function categoryRows() {
    if (root.appsExpanded) return []
    return root.categoryRowList(Categories.defs())
  }

  function localizedCategoryDefs() {
    var base = Categories.defs()
    var out = []
    for (var i = 0; i < base.length; i++) {
      var d = base[i]
      var menuId = d.key.slice(4)
      var trTitle = root.menuCatalogLabels[menuId]
        || (root.menuItems[menuId] && root.menuItems[menuId].label)
        || d.title
      var trSubtitle = strings.t(d.key + ".subtitle", d.subtitle)
      var copy = {}
      for (var k in d) copy[k] = d[k]
      copy.title = trTitle
      copy.subtitle = trSubtitle
      if (trTitle !== d.title) copy.keywords = d.keywords + " " + d.title + " " + trTitle
      out.push(copy)
    }
    return out
  }

  // Categories stay visible while searching, ranked above everything but
  // direct answers — typing "app" must offer Apps before any hotkey.
  function categorySearchRows(q) {
    var query = String(q || "").trim()
    if (!query) return []
    var list = root.localizedCategoryDefs()
    var scored = []
    for (var i = 0; i < list.length; i++) {
      var s = root.fuzzyScore({ title: list[i].title, keywords: list[i].keywords }, query)
      if (s < 0) continue
      scored.push({ def: list[i], score: s, order: i })
    }
    scored.sort(function(a, b) {
      if (b.score !== a.score) return b.score - a.score
      return a.order - b.order
    })
    var matches = []
    for (var j = 0; j < scored.length && matches.length < 5; j++) matches.push(scored[j].def)
    return root.categoryRowList(matches)
  }

  function categoryRowList(defs) {
    var out = []
    var sec = strings.t("section.categories", "Categories")
    var acc = strings.t("acc.category", "Category")
    for (var i = 0; i < defs.length; i++) {
      var d = defs[i]
      var menuId = String(d.key || "").slice(4)
      var title = root.menuCatalogLabels[menuId]
        || (root.menuItems[menuId] && root.menuItems[menuId].label)
        || d.title
      var subtitle = strings.t(d.key + ".subtitle", d.subtitle)
      if (d.kind === "shell") {
        out.push(root.row({
          key: d.key, section: sec, kind: "shell",
          title: title, subtitle: subtitle,
          accessory: acc, icon: d.icon,
          primaryLabel: "Open",
          payload: { argv: d.argv }
        }))
      } else if (d.kind === "expand") {
        out.push(root.row({
          key: d.key, section: sec, kind: "expand",
          title: title, subtitle: subtitle,
          accessory: acc, icon: d.icon,
          primaryLabel: "Browse",
          payload: {}
        }))
      } else if (d.kind === "system") {
        out.push(root.row({
          key: d.key, section: sec, kind: "system",
          title: title, subtitle: subtitle,
          accessory: acc, icon: d.icon,
          primaryLabel: "Browse",
          payload: {}
        }))
      } else if (d.kind === "menuscope") {
        out.push(root.row({
          key: d.key, section: sec, kind: "menuscope",
          title: title, subtitle: subtitle,
          accessory: acc, icon: d.icon,
          primaryLabel: "Browse",
          payload: { scope: d.scope }
        }))
      } else {
        out.push(root.row({
          key: d.key, section: sec, kind: "prime",
          title: title, subtitle: subtitle,
          accessory: acc, icon: d.icon,
          primaryLabel: "Browse",
          payload: { query: d.query }
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
      key: "learn.keybinds", section: strings.t("section.learn", "Learn"), kind: "shell",
      title: strings.t("learn.keybindsTitle", "Keybinds"),
      subtitle: strings.t("learn.keybindsSubtitle", "Browse every Omarchy keybinding"),
      accessory: strings.t("acc.category", "Category"), icon: "",
      primaryLabel: "Open",
      payload: { argv: ["omarchy", "menu", "keybindings"] }
    })]
  }

  // Stock install/remove browsing: the children of the open scope, leaves
  // running their stock actions, submenus drilling deeper. Guarded-out rows
  // stay hidden; while guards are still in flight everything shows. Typing
  // narrows by label, the way pickers narrow options.
  function menuScopeRows() {
    var scope = root.menuScope
    if (!scope) return []
    if (scope === "appearance" && !root.menuItems["appearance"] && root.menuItems["style"]) scope = "style"
    else if (scope === "style" && !root.menuItems["style"] && root.menuItems["appearance"]) scope = "appearance"
    var q = String(root.query || "").trim().toLowerCase()
    var merged = { items: root.menuItems, order: root.menuOrder }
    var kids = Menu.childrenOf(merged, scope)
    var head = root.menuItems[scope]
    var section = (head && head.label) ? head.label : "Menu"
    // Stock matching: per-term substring admission over label and leaf id,
    // ascending tiers, file order breaking ties.
    var scored = []
    for (var i = 0; i < kids.length; i++) {
      var e = kids[i]
      if (!Menu.isVisible(merged, root.menuGuards, e)) continue
      var s = Menu.matchScore({
        id: e.id, label: e.label, aliases: e.aliases, description: e.description || ""
      }, q)
      if (s < 0) continue
      scored.push({ entry: e, score: s, order: i })
    }
    scored.sort(function(a, b) {
      if (a.score !== b.score) return a.score - b.score
      return a.order - b.order
    })
    var out = []
    for (var j = 0; j < scored.length; j++) {
      var m = scored[j].entry
      var title = Menu.labelFor(m, root.menuChecked, root.menuDisabled)
      var disabled = Menu.isDisabled(root.menuDisabled, m)
      var iconFont = m.iconFont || ""
      if (disabled) {
        out.push(root.row({
          key: "menu:" + m.id, section: section, kind: "noop",
          title: title, subtitle: "",
          accessory: strings.t("acc.installed", "Installed"), icon: m.icon, iconFont: iconFont,
          primaryLabel: "",
          payload: {}
        }))
      } else if (m.kind === "action" && m.action) {
        out.push(root.row({
          key: "menu:" + m.id, section: section, kind: "menuaction",
          title: title, subtitle: "",
          accessory: section, icon: m.icon, iconFont: iconFont,
          primaryLabel: "Run",
          payload: { action: m.action }
        }))
      } else {
        var target = m.kind === "link" && m.target ? m.target : m.id
        out.push(root.row({
          key: "menu:" + m.id, section: section, kind: "menuscope",
          title: title, subtitle: "",
          accessory: section, icon: m.icon, iconFont: iconFont,
          primaryLabel: "Open",
          payload: { scope: target }
        }))
      }
    }
    return out
  }

  // Global search over the whole stock tree — every category, subcategory
  // and option — so "aur" finds the installer and "vpn" the VPN rows, the
  // way the stock menu searches everything. Application rows are pushed
  // earlier in rebuild, so apps still rank on top. Leaves run, submenus
  // drill in, guarded-out rows stay hidden. Skipped: the root itself and
  // the Apps node, whose children are provider-driven, not data.
  readonly property int maxMenuSearchRows: 7

  function menuSearchRows(q) {
    var query = String(q || "").trim()
    if (!query) return []
    var merged = { items: root.menuItems, order: root.menuOrder }
    var scored = []
    for (var i = 0; i < root.menuOrder.length; i++) {
      var id = root.menuOrder[i]
      if (id === "root" || id === "apps") continue
      var e = root.menuItems[id]
      if (!e) continue
      if (!Menu.isVisible(merged, root.menuGuards, e)) continue
      if (Menu.isDisabled(root.menuDisabled, e)) continue
      var s = Menu.matchScore({
        id: e.id, label: e.label,
        keywords: "", aliases: e.aliases, description: e.description || ""
      }, query)
      if (s < 0) continue
      scored.push({ entry: e, score: s, order: i })
    }
    scored.sort(function(a, b) {
      if (a.score !== b.score) return a.score - b.score
      return a.order - b.order
    })
    var out = []
    var menuSec = strings.t("section.menu", "Menu")
    var menuAcc = strings.t("acc.menu", "Menu")
    for (var j = 0; j < scored.length && out.length < root.maxMenuSearchRows; j++) {
      var m = scored[j].entry
      var path = Menu.menuPath(root.menuItems, m.id)
      if (Commons.I18n.rightToLeft) path = path.replace(/ › /g, " ‹ ")
      var title = Menu.labelFor(m, root.menuChecked, root.menuDisabled)
      var iconFont = m.iconFont || ""
      if (m.kind === "action" && m.action) {
        out.push(root.row({
          key: "menu:" + m.id, section: menuSec, kind: "menuaction",
          title: title, subtitle: path,
          accessory: menuAcc, icon: m.icon, iconFont: iconFont,
          primaryLabel: "Run",
          payload: { action: m.action }
        }))
      } else {
        var target = m.kind === "link" && m.target ? m.target : m.id
        out.push(root.row({
          key: "menu:" + m.id, section: menuSec, kind: "menuscope",
          title: title, subtitle: path,
          accessory: menuAcc, icon: m.icon, iconFont: iconFont,
          primaryLabel: "Open",
          payload: { scope: target }
        }))
      }
    }
    return out
  }

  // The System category: stock system.* rows verbatim, guarded like menu
  // scope rows (Suspend hides when disabled, Hibernate without support).
  function systemRows() {
    var defs = System.defs()
    var out = []
    var sysSec = root.menuCatalogLabels["system"] || strings.t("section.system", "System")
    var sysAcc = root.menuCatalogLabels["system"] || strings.t("acc.system", "System")
    for (var i = 0; i < defs.length; i++) {
      var d = defs[i]
      if (d.when && root.menuGuards[d.key] === false) continue
      var trTitle = root.menuCatalogLabels[d.key]
        || (root.menuItems[d.key] && root.menuItems[d.key].label)
        || d.title
      out.push(root.row({
        key: d.key, section: sysSec, kind: "menuaction",
        title: trTitle, subtitle: "",
        accessory: sysAcc, icon: d.icon,
        primaryLabel: d.confirm ? "Confirm" : "Run",
        confirm: d.confirm,
        payload: { action: d.action }
      }))
    }
    return out
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
        section: strings.t("section.clipboard", "Clipboard History"), kind: "clipcopy",
        title: ranked[i].title, subtitle: "",
        accessory: strings.t("acc.copy", "Copy"), icon: "󰅌", mono: true,
        primaryLabel: "Copy to clipboard",
        payload: {
          index: ranked[i].index,
          title: ranked[i].title,
          bytes: ranked[i].bytes || 0
        }
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
        key: scored[j].key, section: strings.t("section.emoji", "Emoji"), kind: "copy",
        title: Emoji.title(s.k), subtitle: "",
        accessory: strings.t("acc.copy", "Copy"), icon: s.e,
        primaryLabel: "Copy emoji",
        payload: {
          text: s.e,
          keywords: s.k,
          glyphIndex: s.index,
          title: Emoji.title(s.k)
        }
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
    var hkSec = strings.t("section.hotkeys", "Hotkeys")
    for (var j = 0; j < scored.length; j++) {
      var sp = scored[j].spec
      if (sp.runnable) {
        out.push(root.row({
          key: scored[j].key, section: hkSec, kind: "shell",
          title: sp.label, subtitle: sp.subtitle,
          accessory: sp.accessory, icon: "",
          primaryLabel: "Run",
          payload: { argv: Hotkeys.dispatchArgv(root.omarchyPath, sp.dispatcher, sp.arg) }
        }))
      } else {
        out.push(root.row({
          key: scored[j].key, section: hkSec, kind: "noop",
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
    if (root.dmenuMultiple && root.dmenuOnChange.length === 0) {
      out.push(root.row({
        key: "dmenu.apply", section: root.dmenuPrompt || Commons.I18n.t("menu.selectPrompt", "Select"), kind: "dmenu-apply",
        title: Commons.I18n.t("common.apply", "Apply"),
        subtitle: Commons.I18n.tn("menu.selectedCount", root.dmenuSelected.length, "%1 selected").arg(Commons.I18n.formatNumber(root.dmenuSelected.length)),
        accessory: strings.t("acc.confirm", "Confirm"), icon: "󰄬",
        primaryLabel: Commons.I18n.t("common.apply", "Apply"),
        payload: {}
      }))
    }
    for (var i = 0; i < found.length; i++) {
      var f = found[i]
      var isSel = root.dmenuMultiple && root.dmenuSelected.indexOf(f.value) !== -1
      out.push(root.row({
        key: "dmenu:" + f.index, section: root.dmenuPrompt || Commons.I18n.t("menu.selectPrompt", "Select"), kind: "dmenu",
        title: f.label, subtitle: f.detail,
        accessory: root.dmenuMultiple ? (isSel ? strings.t("acc.selected", "Selected") : "") : "",
        icon: root.dmenuMultiple ? (isSel ? "✓" : "○") : f.icon,
        primaryLabel: root.dmenuMultiple ? (isSel ? "Deselect" : "Select") : "Select",
        payload: { value: f.value }
      }))
    }
    return out
  }

  function reminderListRows(q) {
    if (!/^reminders?$/i.test(String(q || "").trim())) return []
    var remSec = strings.t("section.reminders", "Reminders")
    if (root.reminderRows.length === 0) {
      return [root.row({
        key: "reminder.none", section: remSec, kind: "noop",
        title: strings.t("reminders.none", "No active reminders"),
        subtitle: strings.t("reminders.tryHint", "Try “remind me in 20m to …”"),
        accessory: "", icon: "󰢌", primaryLabel: ""
      })]
    }
    var out = []
    for (var i = 0; i < root.reminderRows.length && i < root.maxReminderRows; i++) {
      var r = root.reminderRows[i]
      out.push(root.row({
        key: "reminder.active." + i,
        section: remSec, kind: "noop",
        title: String(r.label || ""),
        subtitle: "in " + String(r.remaining || "") + " · at " + String(r.atTime || ""),
        accessory: strings.t("acc.active", "Active"), icon: "󰔟", primaryLabel: ""
      }))
    }
    out.push(root.row({
      key: "reminder.clear", section: remSec, kind: "shell",
      title: strings.t("reminders.clearAll", "Clear all reminders"),
      subtitle: strings.tn("reminders.activeCount", root.reminderRows.length, "%1 active").arg(Commons.I18n.formatNumber(root.reminderRows.length)),
      accessory: strings.t("acc.command", "Command"), icon: "󰩹",
      primaryLabel: "Clear", payload: { argv: ["omarchy", "reminder", "clear"] }
    }))
    return out
  }

  function fileResultRows(q) {
    if (root.fileRows.length === 0) return []
    var out = []
    var fileSec = strings.t("section.files", "Files")
    for (var i = 0; i < root.fileRows.length && i < root.maxFileRows; i++) {
      var f = root.fileRows[i]
      out.push(root.row({
        key: "file:" + f.path,
        section: fileSec, kind: "file",
        title: f.name, subtitle: f.dir,
        accessory: f.isDir ? strings.t("acc.folder", "Folder") : strings.t("acc.file", "File"),
        icon: f.isDir ? "󰉋" : "󰈔",
        primaryLabel: "Open",
        secondaryLabel: "Open folder",
        payload: {
          path: f.path,
          dir: f.dir,
          name: f.name,
          isDir: f.isDir === true
        }
      }))
    }
    return out
  }

  function suggestionResultRows(q) {
    if (root.suggestionRows.length === 0) return []
    var engine = String(root.settings.searchEngine || "g")
    var out = []
    var suggSec = strings.t("section.webSuggestions", "Web Suggestions")
    for (var i = 0; i < root.suggestionRows.length; i++) {
      var s = root.suggestionRows[i]
      out.push(root.row({
        key: "sugg:" + s,
        section: suggSec, kind: "url",
        title: s, subtitle: "",
        accessory: Web.engineName(engine),
        icon: Web.engineIcon(engine),
        primaryLabel: strings.t("web.searchEngine", "Search %1").arg(Web.engineName(engine)),
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
      key: "web.fallback", section: strings.t("section.searchWeb", "Search the Web"), kind: "url",
      title: strings.t("web.searchFor", "Search %1 for “%2”").arg(Web.engineName(engine)).arg(q),
      subtitle: "",
      accessory: Web.engineName(engine),
      icon: Web.engineIcon(engine),
      primaryLabel: strings.t("web.searchEngine", "Search %1").arg(Web.engineName(engine)),
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
          rowIconFont: "",
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

    // Dedicated App Launcher grid mode: stays in the app grid even while
    // typing so Super+Alt+Space (or the Apps category) filters apps in-place.
    if (root.appsExpanded) {
      root.appMenuTarget = null
      push(root.appRows(q))
      root.rows = next
      root.finishRebuild(next)
      return
    }

    // Idle is the categories front page only; System shows its seven rows,
    // Install/Remove/Appearance open the stock subtrees. Any keystroke leaves
    // for full search.
    if (!q) {
      if (root.menuScope) push(root.menuScopeRows())
      else if (root.systemExpanded) push(root.systemRows())
      else push(root.categoryRows())
      root.rows = next
      root.finishRebuild(next)
      return
    }

    push(root.intentRows(q))
    push(root.categorySearchRows(q))
    push(root.learnRows(q))
    push(root.colorRows(q))
    push(root.settingsRows(q))
    push(root.clipboardResultRows(q))
    push(root.reminderListRows(q))
    push(root.appRows(q))
    push(root.windowRows(q))
    push(root.emojiRows(q))
    push(root.bangRows(q))
    push(root.commandRows(q))
    push(root.menuSearchRows(q))
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
        rowIconFont: r.iconFont,
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
    root.updatePreview()
    Qt.callLater(function() {
      if (displayModel.count > 0) {
        if (root.appsExpanded) appGrid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
        else resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
      }
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
    root.updatePreview()
  }

  // Steps over "noop" rows (hints, reminder listings) so the cursor only ever
  // rests somewhere Enter means something.
  function select(delta) {
    var count = root.rows.length
    if (count === 0) return
    root.appMenuTarget = null
    var index = root.selectedIndex
    if (root.appsExpanded) {
      if (Math.abs(delta) === 1) {
        index = (index + delta + count) % count
      } else {
        var nextIdx = index + delta
        if (nextIdx >= 0 && nextIdx < count) index = nextIdx
      }
      root.selectedIndex = index
      root.pinnedKey = root.selectedRowKey()
      root.cursorActive = true
      root.armedKey = ""
      pointerGate.reset()
      appGrid.positionViewAtIndex(index, GridView.Contain)
      return
    }
    for (var step = 0; step < count; step++) {
      index = (index + delta + count) % count
      if (root.rows[index] && root.rows[index].kind !== "noop") break
    }
    root.selectedIndex = index
    root.pinnedKey = root.selectedRowKey()
    root.cursorActive = true
    root.armedKey = ""
    pointerGate.reset()
    root.updatePreview()
    resultList.positionViewAtIndex(index, ListView.Contain)
  }

  function selectPage(delta) {
    var count = root.rows.length
    if (count === 0) return
    root.appMenuTarget = null
    if (root.appsExpanded) {
      var pageStep = root.gridColumns * root.gridVisibleRows
      var gIndex = Math.max(0, Math.min(count - 1, root.selectedIndex + delta * pageStep))
      root.selectedIndex = gIndex
      root.pinnedKey = root.selectedRowKey()
      root.cursorActive = true
      root.armedKey = ""
      pointerGate.reset()
      appGrid.positionViewAtIndex(gIndex, GridView.Contain)
      return
    }
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
    root.updatePreview()
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

    if (root.appsExpanded && r.kind === "app" && root.armedKey === "uninstall:" + r.key) {
      root.armedKey = ""
      root.uninstallApp(r.payload.appId, r.payload.name)
      return
    }

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
      // Over stdin, never argv: /proc/<pid>/cmdline is world-readable on any
      // system not mounted with hidepid, so the text of the result would sit in
      // the process arguments in the clear for anyone to poll ps for.
      root.copyText(String(r.payload.text || ""))
      break

    case "clipcopy":
      root.dismiss()
      // The body was never loaded, so the helper is told which entry to copy
      // rather than what to copy. It re-reads the history under the same
      // bounds, re-identifies the row by the title the user actually saw — the
      // list may have shifted since — and pipes it to wl-copy itself.
      //
      // The index alone is an argv operand; the title is a clipboard prefix, so
      // for a short entry it is the secret itself and goes in on stdin.
      clipCopyProc.running = false
      clipCopyProc.stdinEnabled = true
      clipCopyProc.command = root.helperArgv([
        "clipboard-copy", String(r.payload.index)])
      clipCopyProc.running = true
      clipCopyProc.write(String(r.payload.title || ""))
      clipCopyProc.stdinEnabled = false
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

    case "dmenu-apply":
      root.finishRequest(JSON.stringify(Dmenu.selections(root.dmenuOptions, root.dmenuSelected, false)))
      root.dismiss()
      break

    case "dmenu":
      if (root.dmenuMultiple) {
        var nextSel = Dmenu.toggleSelection(root.dmenuSelected, String(r.payload.value || ""))
        root.dmenuSelected = Dmenu.selections(root.dmenuOptions, nextSel, root.dmenuOnChange.length > 0)
        root.pinnedKey = r.key
        root.rebuild()
        if (root.dmenuOnChange.length > 0) {
          root.runDmenuOnChange(root.dmenuSelected)
        } else {
          root.dmenuSaved = root.dmenuSelected
        }
      } else {
        root.finishRequest(String(r.payload.value || ""))
        root.dismiss()
      }
      break

    case "prime":
      // A category tap becomes the query it names; the rebuild that follows
      // is the drill-in. The cursor lands at the end, ready to narrow.
      root.primedQuery = String(r.payload.query || "")
      input.text = String(r.payload.query || "")
      input.cursorPosition = input.text.length
      break

    case "expand":
      root.appsExpanded = true
      root.appsRouteDirect = false
      root.appMenuTarget = null
      root.primedQuery = ""
      input.text = ""
      root.rebuild()
      break

    case "system":
      root.systemExpanded = true
      root.primedQuery = ""
      input.text = ""
      root.rebuild()
      break

    case "menuscope":
      // Drilling in clears the query: the scope browses unfiltered, the
      // way tapping a category from the front page does.
      var nextScope = String(r.payload.scope || "")
      root.menuScope = nextScope
      root.primedQuery = ""
      input.text = ""
      if (root.menuItems[nextScope] && root.menuItems[nextScope].provider) {
        root.refreshMenuProviders()
      }
      root.rebuild()
      break

    case "menuaction":
      // Stock menu actions are shell strings, run exactly the way the stock
      // menu runs them. The data is first-party packaged (root-owned) plus
      // the user's own extensions — the same trust the menu itself has.
      root.dismiss()
      if (String(r.payload.action || "")) Util.execDetached(String(r.payload.action))
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
      out.push({
        index: Util.clamp(item.index, 0, 1000),
        title: item.title,
        bytes: isFinite(item.bytes) ? Math.max(0, Math.min(8 * 1024 * 1024, item.bytes)) : 0
      })
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
      && !NaturalTime.isDateQuery(q)
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

  Timer {
    id: previewDebounce
    interval: 120
    property string forPath: ""
    onTriggered: {
      var path = previewDebounce.forPath
      if (!path) return
      // Single-entry cache: a repeat selection reuses previewInfo.
      if (root.previewForPath === path && root.previewInfo) return
      previewProc.running = false
      previewProc.forPath = path
      previewProc.command = root.helperArgv(["file-preview", path])
      previewProc.running = true
    }
  }

  Process {
    id: previewProc
    property string forPath: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadFilePreview(text, previewProc.forPath)
    }
  }

  Process { id: clipCopyProc }

  Process { id: copyProc }

  Process {
    id: pasteProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadPaste(text)
    }
  }

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

  function runDmenuOnChange(selected) {
    if (!root.dmenuActive || root.dmenuOnChange.length === 0) return
    dmenuChangeProc.running = false
    dmenuChangeProc.changeKey = root.dmenuChangeKey
    dmenuChangeProc.stdinEnabled = true
    dmenuChangeProc.command = root.helperArgv(["dmenu-onchange"])
    dmenuChangeProc.running = true
    dmenuChangeProc.write(JSON.stringify({
      command: root.dmenuOnChange,
      selected: selected
    }))
    dmenuChangeProc.stdinEnabled = false
  }

  function loadDmenuOnChange(raw, changeKey) {
    if (!root.dmenuActive || changeKey !== root.dmenuChangeKey) return
    var reply = root.helperReply(raw)
    if (reply && Array.isArray(reply.applied)) {
      root.dmenuSelected = Dmenu.selections(root.dmenuOptions, reply.applied, true)
      root.dmenuSaved = root.dmenuSelected
    } else {
      root.dmenuSelected = root.dmenuSaved
    }
    if (root.opened) root.rebuild()
  }

  Process {
    id: menuTreeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadMenuTree(text)
    }
  }

  Process {
    id: menuGuardsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadMenuGuards(text)
    }
  }

  Process {
    id: menuProvidersProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadMenuProviders(text)
    }
  }

  Process {
    id: dmenuChangeProc
    property string changeKey: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadDmenuOnChange(text, dmenuChangeProc.changeKey)
    }
  }

  Process {
    id: dmenuFinishProc
  }

  Process {
    id: dockPinnedProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadDockPinned(text)
    }
  }

  Process {
    id: hidesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadHides(text)
    }
  }

  Process {
    id: iconsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadIconMap(text)
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
    root.refreshIconMap()
  }

  // Unloading the plugin must not leave a reader behind. Each helper run has
  // its own deadline as a backstop, but the processes are terminated here so
  // teardown does not depend on one.
  Component.onDestruction: {
    root.stopQueryWork()
    clipCopyProc.running = false
    copyProc.running = false
    pasteProc.running = false
    previewProc.running = false
    remindersProc.running = false
    settingsProc.running = false
    settingsWriteProc.running = false
    emojiProc.running = false
    hotkeysProc.running = false
    menuTreeProc.running = false
    menuGuardsProc.running = false
    menuProvidersProc.running = false
    dmenuChangeProc.running = false
    dockPinnedProc.running = false
    hidesProc.running = false
    iconsProc.running = false
    usageReadProc.running = false
    usageWriteProc.running = false
    icsProc.running = false
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() { if (root.opened) root.rebuild() }
  }

  Connections {
    target: Commons.I18n
    function onLanguageChanged() {
      root.refreshMenuTree()
      root.refreshHotkeys(true)
      if (root.opened) root.rebuild()
    }
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

      readonly property int listHeight: root.appsExpanded
        ? root.gridListHeight
        : Math.min(root.maxListHeight, root.contentHeight)
      readonly property bool hasResults: root.appsExpanded || displayModel.count > 0

      // Picker callers size the card: width honors their --width inside
      // the panel, and the list scrolls inside maxListHeight. Previewable
      // selections widen to list + preview; everything else stays narrow.
      width: root.dmenuActive
        ? Math.min(Style.space(root.dmenuWidth), panel.width - Style.space(48))
        : (root.appsExpanded
          ? Math.min(root.gridCardWidth, panel.width - Style.space(48))
          : (root.showPreview
            ? Math.min(root.wideCardWidth, panel.width - Style.space(48))
            : Math.min(root.baseCardWidth, panel.width - Style.space(48))))
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
      Behavior on width {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }

      // Swallow clicks so they don't reach the dismiss MouseArea behind.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.appMenuTarget = null
      }

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

        // A plain Item rather than a native TextInput: in Qt 6.12.0,
        // QQuickTextInput connects QClipboard::dataChanged in its constructor
        // to q_canPasteChanged(), which synchronously reads mimeData->text()
        // without a byte cap and resets its 1s wait on every chunk. Keeping
        // the search field off QQuickTextInput means clipboard changes never
        // touch the selection, and explicit paste routes through the helper's
        // bounded `paste-text` subcommand.
        Item {
          id: input
          anchors.left: searchGlyph.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.rightMargin: root.gutter
          anchors.verticalCenter: parent.verticalCenter
          height: root.searchHeight

          property string text: ""
          property int cursorPosition: 0
          // A query is a line someone typed, and every provider fans out from
          // it — the web fallback interpolates it into a row title, the file
          // search hands it to fd. Bounding it here bounds all of them.
          readonly property int maximumLength: root.maxQueryChars
          readonly property real caretX: prefixMetrics.advanceWidth
          readonly property real scrollX: width > 0 ? Math.max(0, caretX - width + Style.space(4)) : 0

          clip: true
          focus: true
          activeFocusOnTab: false

          onTextChanged: {
            if (text.length > maximumLength) {
              text = text.slice(0, maximumLength)
              return
            }
            if (cursorPosition > text.length) cursorPosition = text.length
            else if (cursorPosition < 0) cursorPosition = 0
            root.query = text
          }

          TextMetrics {
            id: prefixMetrics
            font.family: root.fontFamily
            font.pixelSize: root.searchFontSize
            text: input.text.slice(0, Math.max(0, Math.min(input.text.length, input.cursorPosition)))
          }

          Text {
            anchors.fill: parent
            visible: input.text.length === 0
            text: root.dmenuActive && root.dmenuPrompt.length > 0
              ? root.dmenuPrompt
              : (root.appsExpanded ? strings.t("search.appsPlaceholder", "Search applications…") : strings.t("search.placeholder", "Search for apps and commands…"))
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.38
            font.family: root.fontFamily
            font.pixelSize: root.searchFontSize
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
          }

          Text {
            x: -input.scrollX
            height: parent.height
            visible: input.text.length > 0
            text: input.text
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.searchFontSize
            verticalAlignment: Text.AlignVCenter
          }

          Rectangle {
            x: Math.max(0, input.caretX - input.scrollX)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(1, Style.space(2))
            height: Math.round(root.searchFontSize * 1.15)
            color: root.accent
            visible: input.activeFocus && root.opened
          }

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            typingGuard.restart()
            if (event.key === Qt.Key_Delete && root.appsExpanded) {
              var delSel = root.selectedRow()
              if (delSel && delSel.kind === "app" && delSel.payload) {
                var armKey = "uninstall:" + delSel.key
                if (root.armedKey === armKey) {
                  root.armedKey = ""
                  root.uninstallApp(delSel.payload.appId, delSel.payload.name)
                } else {
                  root.armedKey = armKey
                }
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              // A pristine category prime exits outright — Left is the way
              // back to categories. Anything typed stays two-step.
              if (root.appMenuTarget) {
                root.appMenuTarget = null
              } else if (root.armedKey.length > 0) {
                root.armedKey = ""
              } else if (input.text.length > 0
                  && (root.primedQuery === "" || input.text !== root.primedQuery)) {
                input.text = ""
                input.cursorPosition = 0
              } else if (root.appsExpanded && !root.appsRouteDirect) {
                root.appsExpanded = false
                root.rebuild()
              } else {
                root.dismiss()
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Backspace
                && root.appsExpanded && !root.appsRouteDirect
                && input.text.length === 0) {
              root.appsExpanded = false
              root.rebuild()
              event.accepted = true
            } else if (event.key === Qt.Key_Down
                || (event.key === Qt.Key_N && event.modifiers === Qt.ControlModifier)) {
              root.select(root.appsExpanded ? root.gridColumns : 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up
                || (event.key === Qt.Key_P && event.modifiers === Qt.ControlModifier)) {
              root.select(root.appsExpanded ? -root.gridColumns : -1)
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
              if (sel && sel.kind === "app") {
                input.text = sel.title
                input.cursorPosition = input.text.length
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Left
                && event.modifiers === Qt.NoModifier && !root.dmenuActive) {
              // In the App Grid, Left/Right step across tiles; in list mode,
              // Left climbs out of scopes, System, or a pristine category prime.
              if (root.appsExpanded) {
                if (displayModel.count > 0) root.select(-1)
                else if (!root.appsRouteDirect && input.text.length === 0) {
                  root.appsExpanded = false
                  root.rebuild()
                }
                event.accepted = true
              } else if (root.menuScope) {
                root.menuScope = Menu.parentScope(root.menuScope)
                root.rebuild()
                event.accepted = true
              } else if (root.systemExpanded && input.text.length === 0) {
                root.systemExpanded = false
                root.rebuild()
                event.accepted = true
              } else if (root.primedQuery !== "" && input.text === root.primedQuery
                  && input.cursorPosition === input.text.length) {
                root.primedQuery = ""
                input.text = ""
                input.cursorPosition = 0
                event.accepted = true
              }
            } else if (event.key === Qt.Key_Right
                && event.modifiers === Qt.NoModifier && !root.dmenuActive) {
              // Right steps forward in the App Grid, or opens the selected
              // category on an empty query.
              if (root.appsExpanded) {
                if (displayModel.count > 0) root.select(1)
                event.accepted = true
              } else if (input.text.length === 0) {
                var cat = root.selectedRow()
                if (cat && cat.key && String(cat.key).indexOf("cat.") === 0) {
                  root.activate(root.selectedIndex, false)
                  event.accepted = true
                }
              }
            }

            if (event.accepted) return

            var cur = String(input.text || "")
            var pos = Math.max(0, Math.min(cur.length, Number(input.cursorPosition) || 0))
            var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
            var shift = (event.modifiers & Qt.ShiftModifier) !== 0
            var altOrMeta = (event.modifiers & (Qt.AltModifier | Qt.MetaModifier)) !== 0

            if ((event.key === Qt.Key_V && ctrl && !altOrMeta)
                || (event.key === Qt.Key_Insert && shift && !altOrMeta)
                || event.key === Qt.Key_Paste) {
              root.pasteClipboard()
              event.accepted = true
            } else if (event.key === Qt.Key_U && event.modifiers === Qt.ControlModifier) {
              input.text = ""
              input.cursorPosition = 0
              event.accepted = true
            } else if (event.key === Qt.Key_K && event.modifiers === Qt.ControlModifier) {
              input.text = cur.slice(0, pos)
              input.cursorPosition = pos
              event.accepted = true
            } else if (event.key === Qt.Key_Backspace
                || (event.key === Qt.Key_W && event.modifiers === Qt.ControlModifier)) {
              if (!altOrMeta && pos > 0) {
                var backTo = (ctrl || event.key === Qt.Key_W)
                  ? root.prevWordPos(cur, pos)
                  : root.prevCharPos(cur, pos)
                input.text = cur.slice(0, backTo) + cur.slice(pos)
                input.cursorPosition = backTo
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Delete) {
              if (!altOrMeta && pos < cur.length) {
                var fwdTo = ctrl ? root.nextWordPos(cur, pos) : root.nextCharPos(cur, pos)
                input.text = cur.slice(0, pos) + cur.slice(fwdTo)
                input.cursorPosition = pos
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Left && !altOrMeta) {
              input.cursorPosition = ctrl ? root.prevWordPos(cur, pos) : root.prevCharPos(cur, pos)
              event.accepted = true
            } else if (event.key === Qt.Key_Right && !altOrMeta) {
              input.cursorPosition = ctrl ? root.nextWordPos(cur, pos) : root.nextCharPos(cur, pos)
              event.accepted = true
            } else if (event.key === Qt.Key_Home
                || (event.key === Qt.Key_A && event.modifiers === Qt.ControlModifier)) {
              input.cursorPosition = 0
              event.accepted = true
            } else if (event.key === Qt.Key_End
                || (event.key === Qt.Key_E && event.modifiers === Qt.ControlModifier)) {
              input.cursorPosition = cur.length
              event.accepted = true
            } else if (!ctrl && !altOrMeta && event.text && event.text.length > 0) {
              root.insertQueryText(event.text)
              event.accepted = true
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
      // Single column by default; previewable selections split into
      // list + right-side preview pane. The cursor stays list-only.
      Item {
        id: resultsWrap
        anchors {
          top: searchDivider.bottom
          left: parent.left
          right: parent.right
        }
        anchors.topMargin: root.listPadding
        anchors.bottomMargin: root.listPadding
        height: card.listHeight
        visible: card.hasResults

        Row {
          id: resultsRow
          anchors.fill: parent
          spacing: 0

          Item {
            id: listWrap
            width: root.showPreview
              ? Math.max(160, resultsWrap.width - root.previewWidth - root.hairline)
              : resultsWrap.width
            height: parent.height

            ListView {
              id: resultList
              anchors.fill: parent
              visible: !root.appsExpanded
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
            required property string rowIconFont
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
              font.family: resultRow.rowIconFont.length > 0 ? resultRow.rowIconFont : root.fontFamily
              font.pixelSize: Style.font.icon
              width: Style.space(20)
              horizontalAlignment: Text.AlignHCenter
              anchors.left: rowSurface.left
              anchors.leftMargin: root.rowInset
              anchors.verticalCenter: rowSurface.verticalCenter
            }

            Text {
              id: accessoryText
              text: resultRow.armed ? strings.t("confirm.pressAgain", "Press ↵ again to confirm") : resultRow.rowAccessory
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
                root.pinnedKey = root.selectedRowKey()
                root.updatePreview()
                root.activate(resultRow.index, (mouse.modifiers & Qt.ShiftModifier) ? true : false)
              }
            }
          }
            }

            // ----------------------------------------------- app launcher grid
            Item {
              id: appGridContainer
              anchors.fill: parent
              visible: root.appsExpanded

              GridView {
                id: appGrid
                width: root.gridColumns * root.gridCellWidth
                height: parent.height
                anchors.horizontalCenter: parent.horizontalCenter
                model: displayModel
                clip: true
                cellWidth: root.gridCellWidth
                cellHeight: root.gridCellHeight
                boundsBehavior: Flickable.StopAtBounds
                currentIndex: root.selectedIndex
                highlightMoveDuration: 0

                delegate: Item {
                  id: gridCell
                  required property int index
                  required property int rowIndex
                  required property string rowTitle
                  required property string rowImage

                  readonly property bool hasCursor: root.cursorActive && gridCell.index === root.selectedIndex
                  readonly property bool armed: root.armedKey.length > 0
                    && root.rows[gridCell.rowIndex]
                    && root.armedKey === "uninstall:" + root.rows[gridCell.rowIndex].key

                  width: root.gridCellWidth
                  height: root.gridCellHeight

                  Rectangle {
                    id: cellSurface
                    anchors.fill: parent
                    anchors.margins: Style.space(4)
                    radius: root.rowRadius
                    color: gridCell.armed
                      ? Util.alpha(Color.urgent, 0.24)
                      : (gridCell.hasCursor ? root.selectedBackground : "transparent")
                    border.width: gridCell.hasCursor || gridCell.armed ? root.hairline : 0
                    border.color: gridCell.armed
                      ? Color.urgent
                      : Util.alpha(root.accent, 0.45)
                  }

                  Image {
                    id: cellIcon
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: Style.space(14)
                    width: root.gridIconSize
                    height: root.gridIconSize
                    sourceSize: Qt.size(root.gridIconSize * 2, root.gridIconSize * 2)
                    source: gridCell.rowImage
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    mipmap: true
                  }

                  Text {
                    id: cellLabel
                    anchors.top: cellIcon.bottom
                    anchors.topMargin: Style.space(8)
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - Style.space(16)
                    textFormat: Text.PlainText
                    text: gridCell.armed ? strings.t("confirm.pressToUninstall", "Press ↵ to uninstall") : gridCell.rowTitle
                    color: gridCell.armed
                      ? Color.urgent
                      : (gridCell.hasCursor ? root.selectedText : root.foreground)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.weight: gridCell.hasCursor || gridCell.armed ? Font.Medium : Font.Normal
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignTop
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    id: cellMouse
                    anchors.fill: cellSurface
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onEntered: root.selectFromPointer(gridCell.index, gridCell, {
                      x: cellMouse.mouseX,
                      y: cellMouse.mouseY
                    })
                    onPositionChanged: function(mouse) {
                      root.selectFromPointer(gridCell.index, gridCell, mouse)
                    }
                    onClicked: function(mouse) {
                      root.cursorActive = true
                      root.selectedIndex = gridCell.index
                      root.pinnedKey = root.selectedRowKey()
                      var rowObj = root.rows[gridCell.rowIndex]
                      if (mouse.button === Qt.RightButton) {
                        if (rowObj && rowObj.payload && rowObj.payload.appId) {
                          var pt = cellMouse.mapToItem(appGridContainer, mouse.x, mouse.y)
                          root.appMenuTarget = {
                            index: gridCell.index,
                            key: rowObj.key,
                            appId: String(rowObj.payload.appId),
                            name: String(rowObj.payload.name || gridCell.rowTitle),
                            x: pt.x,
                            y: pt.y
                          }
                        }
                        return
                      }
                      root.appMenuTarget = null
                      root.activate(gridCell.index, (mouse.modifiers & Qt.ShiftModifier) ? true : false)
                    }
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                visible: displayModel.count === 0
                textFormat: Text.PlainText
                text: root.query.trim().length > 0
                  ? strings.t("apps.noMatch", "No applications match “%1”").arg(root.query.trim())
                  : strings.t("apps.empty", "No applications found")
                color: root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }

              // Right-click context menu on an app tile (Open, Keep/Remove in Dock, Uninstall)
              Rectangle {
                id: appContextMenu
                visible: root.appMenuTarget !== null
                z: 20
                width: Style.space(184)
                height: appMenuCol.height + Style.space(12)
                x: root.appMenuTarget
                  ? Math.max(Style.space(8), Math.min(root.appMenuTarget.x, appGridContainer.width - width - Style.space(8)))
                  : 0
                y: root.appMenuTarget
                  ? Math.max(Style.space(8), Math.min(root.appMenuTarget.y, appGridContainer.height - height - Style.space(8)))
                  : 0
                radius: root.rowRadius
                color: root.glassBackground
                border.width: root.hairline
                border.color: root.glassBorder

                Column {
                  id: appMenuCol
                  width: parent.width - Style.space(12)
                  anchors.centerIn: parent
                  spacing: Style.space(2)

                  Rectangle {
                    width: parent.width
                    height: Style.space(32)
                    radius: Style.space(6)
                    color: openItemMouse.containsMouse ? root.selectedBackground : "transparent"
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)
                      textFormat: Text.PlainText
                      text: strings.t("apps.open", "Open")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    MouseArea {
                      id: openItemMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var t = root.appMenuTarget
                        root.appMenuTarget = null
                        if (t) root.activate(t.index, false)
                      }
                    }
                  }

                  Rectangle {
                    width: parent.width
                    height: Style.space(32)
                    radius: Style.space(6)
                    color: pinItemMouse.containsMouse ? root.selectedBackground : "transparent"
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)
                      textFormat: Text.PlainText
                      text: (root.appMenuTarget && root.isAppPinned(root.appMenuTarget.appId))
                        ? strings.t("apps.removeFromDock", "Remove from Dock")
                        : strings.t("apps.keepInDock", "Keep in Dock")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    MouseArea {
                      id: pinItemMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (root.appMenuTarget) root.toggleAppDockPin(root.appMenuTarget.appId)
                      }
                    }
                  }

                  Rectangle {
                    width: parent.width
                    height: Style.space(32)
                    radius: Style.space(6)
                    color: uninstallItemMouse.containsMouse ? Util.alpha(Color.urgent, 0.22) : "transparent"
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)
                      textFormat: Text.PlainText
                      text: strings.t("apps.uninstall", "Uninstall")
                      color: uninstallItemMouse.containsMouse ? Color.urgent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    MouseArea {
                      id: uninstallItemMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var t = root.appMenuTarget
                        root.appMenuTarget = null
                        if (t) root.uninstallApp(t.appId, t.name)
                      }
                    }
                  }
                }
              }
            }
          }

          Rectangle {
            id: previewDivider
            visible: root.showPreview
            width: root.hairline
            height: parent.height
            color: root.dividerColor
          }

          // ------------------------------------------------- preview pane
          Item {
            id: previewWrap
            visible: root.showPreview
            width: root.showPreview ? root.previewWidth : 0
            height: parent.height
            clip: true

            Flickable {
              id: previewFlick
              anchors.fill: parent
              anchors.leftMargin: root.listPadding
              anchors.rightMargin: root.listPadding
              anchors.topMargin: Style.space(4)
              anchors.bottomMargin: Style.space(4)
              contentHeight: previewCol.height
              contentWidth: width
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: previewCol
                width: previewFlick.width
                spacing: Style.space(8)

                Text {
                  text: root.previewKindLabel()
                  textFormat: Text.PlainText
                  color: root.foreground
                  opacity: 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.weight: Font.Medium
                }

                // ---------- file ----------
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.previewKindStr === "file"

                  Item {
                    width: parent.width
                    height: Style.space(72)
                    visible: root.previewKindStr === "file"

                    // Image thumbnail when the helper says image; folder /
                    // file glyph otherwise. file:// is safe here: the path
                    // came from fd output the user already selected.
                    Image {
                      id: previewThumb
                      visible: root.previewInfo && root.previewInfo.isImage === true
                      source: (root.previewInfo && root.previewInfo.isImage === true
                        && root.previewInfo.path) ? Util.fileUrl(root.previewInfo.path) : ""
                      width: Style.space(56)
                      height: Style.space(56)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      cache: false
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      visible: !(root.previewInfo && root.previewInfo.isImage === true)
                      text: (root.selectedRow() && root.selectedRow().payload
                        && root.selectedRow().payload.isDir) ? "󰉋" : "󰈔"
                      textFormat: Text.PlainText
                      color: root.foreground
                      opacity: 0.85
                      font.family: root.fontFamily
                      font.pixelSize: 40
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                      text: (root.selectedRow() && root.selectedRow().payload
                        && root.selectedRow().payload.name) || ""
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      font.weight: Font.Medium
                      elide: Text.ElideRight
                      wrapMode: Text.Wrap
                      maximumLineCount: 2
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(66)
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Text {
                    width: parent.width
                    text: (root.selectedRow() && root.selectedRow().payload
                      && root.selectedRow().payload.dir) || ""
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.65
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    text: {
                      var info = root.previewInfo
                      if (!info) return "Loading…"
                      if (info.unavailable) return "No preview available"
                      if (info.isDir) {
                        var c = Number(info.childCount || 0)
                        var t = info.childTruncated ? "+" : ""
                        return c + t + " entries · " + root.formatPreviewMtime(info.mtime)
                      }
                      var parts = []
                      if (info.size !== undefined) parts.push(root.formatPreviewBytes(info.size))
                      if (info.ext) parts.push(String(info.ext).toUpperCase())
                      var mt = root.formatPreviewMtime(info.mtime)
                      if (mt) parts.push(mt)
                      if (info.kind === "binary") parts.push("Binary")
                      return parts.join(" · ")
                    }
                  }
                  Rectangle {
                    width: parent.width
                    height: previewSnippet.visible ? previewSnippet.height + Style.space(16) : 0
                    visible: root.previewInfo && !root.previewInfo.isDir
                      && !root.previewInfo.unavailable
                      && root.previewInfo.isImage !== true
                      && root.previewInfo.kind !== "binary"
                      && root.previewInfo.snippet
                    color: Util.alpha(root.foreground, 0.06)
                    radius: root.rowRadius
                    Text {
                      id: previewSnippet
                      anchors.fill: parent
                      anchors.margins: Style.space(8)
                      text: (root.previewInfo && root.previewInfo.snippet) || ""
                      textFormat: Text.PlainText
                      color: root.foreground
                      opacity: 0.85
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      wrapMode: Text.Wrap
                      maximumLineCount: 14
                      elide: Text.ElideRight
                    }
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    text: {
                      if (root.previewInfo && root.previewInfo.truncated) return "Truncated preview"
                      if (root.previewInfo && root.previewInfo.isImage === true) return "Image thumbnail"
                      return ""
                    }
                    visible: text.length > 0
                  }
                  Text {
                    text: "↵ Open · ⇧↵ Open folder"
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                // ---------- clipboard (title-only) ----------
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.previewKindStr === "clipboard"
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    text: (root.selectedRow() && root.selectedRow().title) || ""
                  }
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    text: {
                      var r = root.selectedRow()
                      if (!r || !r.payload) return ""
                      var idx = r.payload.index
                      var b = root.formatPreviewBytes(r.payload.bytes || 0)
                      return "Entry #" + idx + (b ? " · " + b : "")
                    }
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    text: "Full text stays on disk — Enter copies via the helper."
                  }
                  Text {
                    text: "↵ Copy to clipboard"
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                // ---------- color ----------
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.previewKindStr === "color"
                  Rectangle {
                    width: parent.width
                    height: Style.space(72)
                    radius: root.rowRadius
                    border.width: root.hairline
                    border.color: root.dividerColor
                    color: {
                      var r = root.selectedRow()
                      var s = (r && r.payload && r.payload.swatch) || ""
                      return s || "transparent"
                    }
                  }
                  Repeater {
                    model: {
                      var r = root.selectedRow()
                      if (r && r.payload && Array.isArray(r.payload.values)) return r.payload.values
                      if (r) return [{ label: r.subtitle, text: r.title }]
                      return []
                    }
                    delegate: Row {
                      required property var modelData
                      width: previewCol.width
                      spacing: Style.space(8)
                      Text {
                        text: (modelData && modelData.label) || ""
                        textFormat: Text.PlainText
                        color: root.foreground
                        opacity: 0.5
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        width: Style.space(44)
                      }
                      Text {
                        text: (modelData && modelData.text) || ""
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                        width: parent.width - Style.space(52)
                      }
                    }
                  }
                  Text {
                    text: "↵ Copy color"
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                // ---------- emoji ----------
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.previewKindStr === "emoji"
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    font.pixelSize: 56
                    text: (root.selectedRow() && root.selectedRow().payload
                      && root.selectedRow().payload.text) || ""
                  }
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.weight: Font.Medium
                    wrapMode: Text.Wrap
                    text: (root.selectedRow() && root.selectedRow().payload
                      && root.selectedRow().payload.title) || ""
                  }
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    text: (root.selectedRow() && root.selectedRow().payload
                      && root.selectedRow().payload.keywords) || ""
                  }
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "↵ Copy emoji"
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                // ---------- calculator / conversion ----------
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.previewKindStr === "calc" || root.previewKindStr === "unit"
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: 26
                    font.weight: Font.Medium
                    text: {
                      var r = root.selectedRow()
                      if (!r) return ""
                      if (r.payload && r.payload.display) return String(r.payload.display)
                      return String(r.title || "")
                    }
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.6
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    text: {
                      var r = root.selectedRow()
                      if (!r || !r.payload) return ""
                      if (root.previewKindStr === "calc") return String(r.payload.expr || r.subtitle || "")
                      return String(r.payload.detail || r.subtitle || "")
                    }
                  }
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    visible: root.previewKindStr === "unit"
                    text: {
                      var r = root.selectedRow()
                      if (r && r.payload && r.payload.family) return "Family · " + String(r.payload.family)
                      return ""
                    }
                  }
                  Text {
                    text: "↵ Copy result"
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                // ---------- reminder / event ----------
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: root.previewKindStr === "reminder" || root.previewKindStr === "event"
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.weight: Font.Medium
                    text: (root.selectedRow() && root.selectedRow().title) || ""
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    text: (root.selectedRow() && root.selectedRow().subtitle) || ""
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    text: {
                      var r = root.selectedRow()
                      if (!r || !r.payload) return ""
                      if (root.previewKindStr === "reminder" && r.payload.label)
                        return "Notify " + String(r.payload.label)
                      if (root.previewKindStr === "event" && r.payload.label)
                        return String(r.payload.label)
                      return ""
                    }
                    visible: text.length > 0
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    text: root.previewKindStr === "event"
                      ? "↵ Add to Google Calendar · ⇧↵ Save .ics"
                      : "↵ Set reminder"
                  }
                }
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

        Row {
          anchors.left: parent.left
          anchors.leftMargin: root.gutter
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            text: "\ue900"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.5
            font.family: "omarchy"
            font.pixelSize: Style.font.caption
          }

          Text {
            text: "Omarchy"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.35
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          text: root.appsExpanded
            ? (root.armedKey.indexOf("uninstall:") === 0
              ? strings.t("footer.appsConfirmHint", "↵ / Del Confirm uninstall · Esc Cancel")
              : strings.t("footer.appsHint", "↵ Open · Del Uninstall · Right-click Dock"))
            : ((root.manifest && root.manifest.version) ? String(root.manifest.version) : "")
          visible: text.length > 0
          textFormat: Text.PlainText
          color: (root.appsExpanded && root.armedKey.indexOf("uninstall:") === 0) ? Color.urgent : root.foreground
          opacity: (root.appsExpanded && root.armedKey.indexOf("uninstall:") === 0) ? 0.9 : 0.35
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.right: parent.right
          anchors.rightMargin: root.gutter
          anchors.verticalCenter: parent.verticalCenter
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
