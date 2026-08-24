import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons
import "config"
import Quickshell.Io

PanelWindow {
  id: root

  required property var screen

  anchors.bottom: true
  anchors.left: true
  anchors.right: true
  WlrLayershell.namespace: "quickshelldock"
  WlrLayershell.layer: WlrLayer.Top
  exclusiveZone: -1
  color: "transparent"
  focusable: false

  mask: Region {
    Region { item: triggerStrip }
    Region { item: dockBar }
    Region { item: contextMenu }
    Region { item: windowMenu }
    Region { item: pinMenu }
  }

  // The window is intentionally oversized so menus have room to grow above
  // the dock bar without clipping or dynamic height flicker. exclusiveZone
  // is -1 either way, so nothing on screen gets pushed around.
  // 320 fits ~8 pin rows (8*26+7*1+16 = 231) + dock bar (78) + gap/margin (9).
  implicitHeight: 320

  readonly property int dockHeight: 68
  readonly property real gap: 6
  readonly property real elevationMargin: -3

  readonly property int itemSize: 54
  readonly property int itemSpacing: 12
  readonly property real itemPitch: itemSize + itemSpacing

  property bool dockVisible: true
  property bool mouseOverDockArea: triggerHover.hovered || dockHover.hovered || contextHover.hovered || windowMenuHover.hovered || pinMenuHover.hovered
  property bool workspaceEmpty: true
  property string clientsJson: ""
  property int _badgeTick: 0

  // Byte ceilings for everything whose length the dock doesn't control:
  // state files are user-writable and hyprctl output scales with open
  // windows, so neither may reach this long-lived process unbounded. Both
  // are orders of magnitude above any legitimate data.
  readonly property int maxStateBytes: 65536
  readonly property int maxClientsBytes: 1048576

  // Drag-to-reorder state. Only one icon can be dragged at a time, so this
  // lives on the root rather than in the delegates.
  property string dragName: ""
  property real dragPointerX: 0
  property real dragGrabOffset: 0
  readonly property bool dragging: dragName !== ""

  // Icon order survives restarts here. Kept out of the config dir so a
  // git pull never fights with it. State lives under XDG_STATE_HOME/omarchy/burninc0de.dock
  // (i.e. ~/.local/state/omarchy/burninc0de.dock) — namespaced under omarchy/
  // and using the plugin id so it's 100% collision-free.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/burninc0de.dock"
  // Legacy locations before the final burninc0de.dock namespacing — migrated on startup.
  readonly property string legacyStateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/quickshelldock"
  readonly property string legacyStateDir2: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/dock"
  readonly property string legacyStateDir3: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/stealthdock"
  readonly property string orderPath: stateDir + "/order.json"
  readonly property string pinsPath: stateDir + "/pins.json"
  readonly property string hiddenPath: stateDir + "/hidden.json"
  // Resolved relative to this file, NOT Quickshell.shellDir: Omarchy loads
  // plugins into its own shell instance, so shellDir points at
  // /usr/share/omarchy/shell and every execDetached would silently no-op.
  readonly property string pinTool: {
    const u = Qt.resolvedUrl("./bin/quickshelldock-pin").toString()
    return decodeURIComponent(u.replace(/^file:\/\//, ""))
  }
  property var savedOrder: []
  property var pinnedApps: []
  property var hiddenApps: []

  // Right-click context menu state.
  property bool contextOpen: false
  property string contextKey: ""
  property var contextAppData: null
  property bool contextRunning: false
  property real contextAnchorX: 0

  // Hover window list state.
  property bool hoverMenuOpen: false
  property string hoverMenuKey: ""
  property var hoverMenuWindows: []
  property real hoverMenuAnchorX: 0

  // Right-click-on-empty-space menu: running apps not already on the dock.
  property bool pinMenuOpen: false
  property var pinCandidates: []
  property real pinMenuAnchorX: 0
  // Show-more pagination: keep the card bounded (~5 rows) and expand on demand.
  // The window is already oversized, so expanding does not resize the surface.
  readonly property int pinMenuPageSize: 5
  property bool pinMenuExpanded: false
  readonly property bool pinMenuHasMore: pinCandidates.length > pinMenuPageSize
  readonly property var pinMenuVisibleCandidates: pinMenuExpanded ? pinCandidates : pinCandidates.slice(0, pinMenuPageSize)
  // Lazy one-time desktop Name cache: class/appId/host (lowercased) → Name.
  // Built on first pin-menu open so the menu is synchronous after. Null =
  // not yet loaded.
  property var desktopNameMap: null
  property bool desktopMapLoading: false
  property real pendingPinAnchorX: 0
  property bool pendingPinOpen: false

  // Matches what other docks offer: GNOME's dash-to-dock, the macOS Dock and
  // KDE's task manager all agree on new-window / pin-unpin / quit. Window
  // lists and "App Details" are deliberately left out — out of scope here.
  readonly property var contextActions: {
    let actions = [{ label: "Open new window", act: "new" }]
    if (root.contextRunning) actions.push({ label: "Quit", act: "quit" })
    actions.push({ label: "Unpin from dock", act: "unpin" })
    return actions
  }

  Process {
    id: clientsProcess
    // Piped through head -c so the collector's buffer is capped even for a
    // pathological client list. Truncation is unreachable below ~2000
    // windows; if it ever happened, JSON.parse fails and the workspace
    // counts as empty — degraded cosmetics, not a ballooning shell.
    command: ["sh", "-c", "hyprctl clients -j | head -c " + root.maxClientsBytes]
    stdout: StdioCollector {
      onStreamFinished: { root.clientsJson = this.text }
    }
  }

  Process {
    id: mkdirProcess
    // Ensures the new state dir exists and migrates any files from legacy
    // locations (quickshelldock, omarchy/dock, omarchy/stealthdock). Only copies
    // files that don't already exist so a fresh install never clobbers data.
    command: ["sh", "-c", "mkdir -p \"$1\"; for legacy in \"$2\" \"$3\" \"$4\"; do if [ -d \"$legacy\" ]; then for f in order.json pins.json hidden.json; do [ -f \"$legacy/$f\" ] && [ ! -e \"$1/$f\" ] && cp -n -- \"$legacy/$f\" \"$1/$f\" 2>/dev/null; done; fi; done", "sh", root.stateDir, root.legacyStateDir, root.legacyStateDir2, root.legacyStateDir3]
    running: true
  }

  // State files are user-writable, so their byte length is untrusted: the
  // dock never loads them through FileView (which buffers whole files) but
  // reads through head -c. The FileViews below are watchers only —
  // preload: false keeps them from buffering any text while still firing
  // fileChanged. bin/quickshelldock-pin renames fully-written temp files
  // into place, so a read started by fileChanged always sees complete JSON.
  Process {
    id: stateReader
    property string kind: ""
    // Reads requested while one is in flight drain here, oldest first. A
    // single slot would drop every request but the last: startup fires all
    // three reads back-to-back and pins would lose to hidden.
    property var pendingQueue: []
    stdout: StdioCollector {
      onStreamFinished: root.consumeStateFile(stateReader.kind, this.text)
    }
    // Missing files at first boot are normal; keep head's stderr out of the log.
    stderr: StdioCollector {}
    onExited: {
      if (stateReader.pendingQueue.length === 0) return
      const next = stateReader.pendingQueue.shift()
      root.readStateFile(next.kind, next.path)
    }
  }

  function readStateFile(kind, path) {
    if (stateReader.running) {
      stateReader.pendingQueue.push({ kind: kind, path: path })
      return
    }
    stateReader.kind = kind
    stateReader.command = ["head", "-c", String(root.maxStateBytes), "--", path]
    stateReader.running = true
  }

  function parseJsonArray(raw, label) {
    try {
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed : []
    } catch (e) {
      if (raw.length >= root.maxStateBytes)
        console.warn("quickshelldock:", label, "is at or over the",
          root.maxStateBytes, "byte read ceiling; ignoring it")
      return []
    }
  }

  function consumeStateFile(kind, raw) {
    if (kind === "order") savedOrder = parseJsonArray(raw, "order.json")
    else if (kind === "pins") pinnedApps = parseJsonArray(raw, "pins.json")
    else if (kind === "hidden") hiddenApps = parseJsonArray(raw, "hidden.json")
    else return
    if (!dragging) rebuildModel()
  }

  // Write-only handle for drag order. Never loaded, so nothing from disk is
  // buffered here either.
  FileView {
    id: orderFile
    path: root.orderPath
    preload: false
    printErrors: false
    atomicWrites: true
  }

  // Config apps removed from the dock. Suppressed here rather than by
  // rewriting UserConfig.qml, which is the user's to own.
  FileView {
    id: hiddenFile
    path: root.hiddenPath
    preload: false
    printErrors: false
    watchChanges: true
    onFileChanged: readStateFile("hidden", root.hiddenPath)
  }

  // Written by bin/quickshelldock-pin, never by the dock. Watching it is what
  // makes a pin from the Omarchy menu show up without a restart.
  FileView {
    id: pinsFile
    path: root.pinsPath
    preload: false
    printErrors: false
    watchChanges: true
    onFileChanged: readStateFile("pins", root.pinsPath)
  }


  ListModel { id: appModel }

  function normalizeApp(app, pinned) {
    return {
      // Desktop entry id, only present on pinned apps. It is the key the
      // pin tool unpins by.
      entryId: app.id ?? "",
      pinned: pinned === true,
      name: app.name ?? "",
      icon: app.icon ?? "",
      cmd: app.cmd ?? "",
      // `match` is a reserved-ish name on the QML side, so the role is renamed.
      matchTitle: app.match ?? "",
      appId: app.appId ?? "",
      minimizable: app.minimizable !== false,
    }
  }

  // Declaration order in the config is the baseline; anything the user has
  // dragged wins over it. Apps added to the config after the last drag land
  // at the end.
  function rebuildModel() {
    let apps = []
    for (const app of DockApps.apps) apps.push(normalizeApp(app, false))

    // Pins append after the configured apps. An app already declared in
    // UserConfig.qml wins, so pinning something that is already on the dock
    // is a no-op rather than a duplicate icon.
    for (const pin of pinnedApps) {
      const entry = normalizeApp(pin, true)
      let duplicate = false
      for (const app of apps) {
        if (app.name === entry.name || (app.cmd && app.cmd === entry.cmd)) {
          duplicate = true
          break
        }
      }
      if (!duplicate) apps.push(entry)
    }

    if (savedOrder.length > 0) {
      let byName = {}
      for (const app of apps) byName[app.name] = app
      let sorted = []
      for (const name of savedOrder) {
        if (byName[name]) {
          sorted.push(byName[name])
          delete byName[name]
        }
      }
      for (const app of apps) if (byName[app.name]) sorted.push(app)
      apps = sorted
    }

    appModel.clear()
    for (const app of apps) {
      if (hiddenApps.indexOf(app.name) >= 0) continue
      if (app.entryId && hiddenApps.indexOf(app.entryId) >= 0) continue
      appModel.append(app)
    }
  }

  function persistOrder() {
    let names = []
    for (var i = 0; i < appModel.count; i++) names.push(appModel.get(i).name)
    savedOrder = names
    orderFile.setText(JSON.stringify(names, null, 2) + "\n")
  }

  // Called on every pointer move during a drag: figure out which slot the
  // dragged icon is currently over and shuffle the model if it changed.
  function updateDragTarget(fromIndex) {
    const desiredLeft = dragPointerX - dragGrabOffset
    let target = Math.round(desiredLeft / itemPitch)
    if (target < 0) target = 0
    if (target > appModel.count - 1) target = appModel.count - 1
    if (target !== fromIndex) appModel.move(fromIndex, target, 1)
  }

  function checkWorkspaceEmpty() {
    const wsId = Hyprland.focusedWorkspace?.id
    if (wsId == null) return true
    try {
      const clients = JSON.parse(clientsJson)
      for (const c of clients) {
        if (c.workspace?.id !== wsId) continue
        if (DockApps.showOnFloating && c.floating) continue
        return false
      }
    } catch (e) {}
    return true
  }

  function updateWorkspaceEmpty() {
    const wsId = Hyprland.focusedWorkspace?.id
    if (wsId == null) return

    var hasToplevels = false
    for (const tl of Hyprland.toplevels.values) {
      if (tl.workspace?.id === wsId) {
        hasToplevels = true
        break
      }
    }

    if (!hasToplevels) {
      if (workspaceEmpty !== true) workspaceEmpty = true
      return
    }

    if (!DockApps.showOnFloating) {
      if (workspaceEmpty !== false) workspaceEmpty = false
      return
    }

    if (!clientsProcess.running) {
      clientsJson = ""
      clientsProcess.running = true
    }
  }

  onClientsJsonChanged: {
    if (clientsJson.length === 0) return
    const empty = checkWorkspaceEmpty()
    if (empty !== workspaceEmpty) workspaceEmpty = empty
  }

  // Tokenizes an XDG desktop-entry Exec value per the freedesktop spec:
  // split on unquoted whitespace, honor double quotes (where \ escapes
  // " \ $ `), single quotes (fully literal), and backslash escapes.
  // A plain split(/\s+/) corrupts any argument containing a quoted space.
  function execTokenize(exec) {
    const parts = []
    let cur = "", has = false, i = 0
    while (i < exec.length) {
      const c = exec[i]
      if (c === " " || c === "\t") {
        if (has) { parts.push(cur); cur = ""; has = false }
        i++
        continue
      }
      if (c === '"') {
        has = true; i++
        while (i < exec.length && exec[i] !== '"') {
          if (exec[i] === "\\" && '"\\$`'.includes(exec[i + 1] ?? "")) i++
          cur += exec[i++] ?? ""
        }
        i++
        continue
      }
      if (c === "'") {
        has = true; i++
        while (i < exec.length && exec[i] !== "'") cur += exec[i++]
        i++
        continue
      }
      if (c === "\\" && exec[i + 1]) { cur += exec[i + 1]; i += 2; has = true; continue }
      cur += c; has = true; i++
    }
    if (has) parts.push(cur)
    return parts
  }

  function getUnreadCount(toplevels) {
    for (const tl of toplevels) {
      const title = tl.toplevel?.title || ""
      const m = title.match(/Inbox \((\d[\d,]*)\)/)
      if (m) {
        const n = parseInt(m[1].replace(/,/g, ""), 10)
        if (!isNaN(n) && n > 0) return n
      }
    }
    return 0
  }

  function getToplevelsForApp(app) {
    let results = []
    for (const tl of Hyprland.toplevels.values) {
      let matched = false
      if (app.match) {
        const title = tl.title.toLowerCase()
        if (title.includes(app.match.toLowerCase())) matched = true
      } else if (app.appId) {
        const appId = (tl.wayland?.appId ?? "").toLowerCase()
        if (appId.includes(app.appId.toLowerCase())) matched = true
      } else {
        const exe = root.execTokenize(app.cmd)[0].split("/").pop().replace(/\.[^/.]+$/, "").toLowerCase()
        const appId = (tl.wayland?.appId ?? "").toLowerCase()
        const cls = (tl.lastIpcObject?.class ?? "").toLowerCase()
        if (appId.includes(exe) || cls.includes(exe) || (cls && exe.includes(cls))) matched = true
      }
      if (matched) {
        results.push({ toplevel: tl, pid: tl.lastIpcObject?.pid ?? -1 })
      }
    }
    return results
  }

  function openContextMenu(item) {
    if (root.contextOpen && root.contextKey === (item.entryId || item.name)) {
      root.closeContextMenu()
      return
    }
    root.closePinMenu()
    // Pinned apps unpin by desktop id; config apps have none, so they unpin by
    // name and the pin tool suppresses them instead of editing UserConfig.qml.
    root.contextKey = item.entryId || item.name
    root.contextAppData = item.appData
    root.contextRunning = item.isRunning
    root.contextAnchorX = dockBar.mapFromItem(item, item.width / 2, 0).x
    root.contextOpen = true
  }

  function closeContextMenu() {
    root.contextOpen = false
    if (!root.mouseOverDockArea) root.scheduleHide()
  }

  // Running apps that no dock icon claims, deduped by class/appId. A toplevel
  // counts as claimed when any configured or pinned app matches it. Labels
  // are resolved synchronously via desktopNameMap (cached) so the menu
  // opens with correct names and no flash.
  function buildPinCandidates() {
    let claimed = []
    for (let i = 0; i < appModel.count; i++) {
      const m = appModel.get(i)
      const tls = root.getToplevelsForApp({ match: m.matchTitle, appId: m.appId, cmd: m.cmd })
      for (const t of tls) claimed.push(t.toplevel)
    }
    const seen = {}
    const out = []
    const map = root.desktopNameMap
    for (const tl of Hyprland.toplevels.values) {
      if (claimed.indexOf(tl) >= 0) continue
      const cls = tl.lastIpcObject?.class ?? ""
      const aid = tl.wayland?.appId ?? ""
      const key = cls || aid
      if (!key || seen[key]) continue
      seen[key] = true
      let label = key
      if (map) {
        const lower = key.toLowerCase()
        // Direct class/appId match
        if (map[lower]) label = map[lower]
        else {
          // For chrome-host webapps also try host substring (e.g. google.com)
          const m = lower.match(/chrome-([^_]+)/)
          if (m && map[m[1]]) label = map[m[1]]
        }
        // Final fallback: window title is more readable than raw class
        if (label === key) {
          const title = (tl.title || "").trim()
          if (title && title.length < 60) label = title
        }
      }
      out.push({ label: label, cls: cls, appId: aid })
    }
    // Stable alphabetical order so the list does not reshuffle after resolve.
    out.sort((a, b) => a.label.toLowerCase().localeCompare(b.label.toLowerCase()))
    return out
  }

  // Resolves an icon name for the pin menu. Webapps report a synthetic class
  // like chrome-web.whatsapp.com__-Default which has no icon theme entry;
  // the host's second-level domain (whatsapp) does. Fall back to that so the
  // menu doesn't show a blank icon while the pinned dock icon (resolved via
  // the desktop file) will be correct.
  function pinCandidateIcon(entry) {
    if (entry.empty) return ""
    const raw = entry.cls || entry.appId || ""
    if (!raw) return ""
    const lower = raw.toLowerCase()
    const m = lower.match(/chrome-([^_]+)/)
    if (m) {
      const host = m[1]
      const parts = host.split(".")
      const ignore = ["www", "com", "net", "org", "io", "co", "app", "chrome"]
      for (let i = parts.length - 1; i >= 0; i--) {
        const p = parts[i]
        if (!p || ignore.includes(p)) continue
        return p
      }
    }
    return raw
  }

  function openPinMenu(xInBar) {
    if (root.pinMenuOpen) {
      root.closePinMenu()
      return
    }
    root.closeContextMenu()
    root.closeHoverMenu()
    // Lazy one-time map: first open builds the cache, then reopens.
    if (root.desktopNameMap === null) {
      if (!root.desktopMapLoading) {
        root.desktopMapLoading = true
        root.pendingPinAnchorX = xInBar
        root.pendingPinOpen = true
        desktopMapProcess.running = true
      } else {
        // Already loading (started at init) — queue this open.
        root.pendingPinAnchorX = xInBar
        root.pendingPinOpen = true
      }
      return
    }
    root.pinCandidates = root.buildPinCandidates()
    root.pinMenuAnchorX = xInBar
    root.pinMenuExpanded = false
    root.pinMenuOpen = true
    // Cache miss fallback: a desktop file created after the map was built
    // will still have a raw label; resolve just those in background.
    if (root.pinCandidates.length > 0) {
      var misses = []
      for (var i = 0; i < root.pinCandidates.length; i++) {
        var c = root.pinCandidates[i]
        var key = c.cls || c.appId
        if (key && c.label === key) misses.push(key)
      }
      if (misses.length > 0) {
        resolveProcess.command = [root.pinTool, "--resolve-windows"].concat(misses)
        resolveProcess.running = true
      }
    }
  }

  function closePinMenu() {
    root.pinMenuOpen = false
    root.pinMenuExpanded = false
    if (!root.mouseOverDockArea) root.scheduleHide()
  }

  // One-time desktop Name cache. Built at startup so first pin-menu open
  // is synchronous (no flash, no stutter). Also used as fallback if a
  // later menu opens before the map is ready.
  Process {
    id: desktopMapProcess
    command: [root.pinTool, "--dump-map"]
    stdout: StdioCollector {
      onStreamFinished: {
        const map = {}
        for (const line of this.text.trim().split("\n")) {
          if (!line) continue
          const parts = line.split("\t")
          if (parts.length >= 2) map[parts[0]] = parts[1]
        }
        root.desktopNameMap = map
        root.desktopMapLoading = false
        if (root.pendingPinOpen) {
          root.pendingPinOpen = false
          root.pinCandidates = root.buildPinCandidates()
          root.pinMenuAnchorX = root.pendingPinAnchorX
          root.pinMenuExpanded = false
          root.pinMenuOpen = true
        }
      }
    }
  }

  // Fallback per-open resolver for cache misses (e.g. a desktop file
  // created after the map was built). Kept for correctness, rarely hit.
  Process {
    id: resolveProcess
    stdout: StdioCollector {
      onStreamFinished: {
        const lines = this.text.trim().split("\n")
        const resolved = {}
        for (const line of lines) {
          const parts = line.split("\t")
          if (parts.length >= 2) resolved[parts[1]] = parts[0]
        }
        const updated = []
        for (const c of root.pinCandidates) {
          const name = resolved[c.cls] || resolved[c.appId] || c.label
          updated.push({ label: name, cls: c.cls, appId: c.appId })
        }
        root.pinCandidates = updated
        // Also backfill the cache so next open is instant.
        if (root.desktopNameMap) {
          for (const k in resolved) root.desktopNameMap[k.toLowerCase()] = resolved[k]
        }
      }
    }
  }

  function runPinAction(entry) {
    root.closePinMenu()
    const key = entry.cls || entry.appId
    if (!key) return
    Quickshell.execDetached([root.pinTool, "--pin-window", key])
    if (!root.workspaceEmpty) root.dockVisible = false
  }

  function runContextAction(act) {
    const app = root.contextAppData
    root.closeContextMenu()
    if (!app) return

    if (act === "new") {
      Quickshell.execDetached(root.execTokenize(app.cmd))
    } else if (act === "quit") {
      for (const t of root.getToplevelsForApp(app)) {
        let addr = t.toplevel.lastIpcObject?.address
        if (!addr || addr === "0") addr = "0x" + t.toplevel.address
        if (addr && addr !== "0x0") {
          Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + addr + '" })')
        }
      }
    } else if (act === "unpin" && root.contextKey) {
      // The CLI owns pins.json and hidden.json; the watchers pick the change up.
      Quickshell.execDetached([root.pinTool, "--unpin", root.contextKey])
      // The icon is gone and the pointer sits on now-empty bar; without this
      // the hover handoff keeps the dock up indefinitely.
      if (!root.workspaceEmpty) root.dockVisible = false
    }
  }

  function focusWindow(address) {
    if (!address || address === "0x0") return
    Hyprland.dispatch('hl.dsp.focus({ window = "address:' + address + '" })')
  }

  function showDockBar() {
    hideTimer.stop()
    dockVisible = true
  }

  function scheduleHide() {
    if (!workspaceEmpty) hideTimer.restart()
  }

  onMouseOverDockAreaChanged: {
    if (mouseOverDockArea) {
      contextCloseTimer.stop()
      hoverCloseTimer.stop()
      pinMenuCloseTimer.stop()
    } else {
      contextCloseTimer.restart()
      hoverCloseTimer.restart()
      pinMenuCloseTimer.restart()
    }
  }

  onWorkspaceEmptyChanged: {
    if (workspaceEmpty) showDockBar()
    else scheduleHide()
  }

  onContextOpenChanged: {
    if (contextOpen) closeHoverMenu()
  }

  onDockVisibleChanged: {
    if (!dockVisible) closeHoverMenu()
  }

  Component.onCompleted: {
    readStateFile("order", root.orderPath)
    readStateFile("pins", root.pinsPath)
    readStateFile("hidden", root.hiddenPath)
    rebuildModel()
    updateWorkspaceEmpty()
    // Build desktop Name cache in background so first pin-menu open is
    // synchronous (no flash, no stutter).
    if (root.desktopNameMap === null && !root.desktopMapLoading) {
      root.desktopMapLoading = true
      desktopMapProcess.running = true
    }
  }

  Connections {
    target: DockApps
    function onAppsChanged() {
      if (!root.dragging) root.rebuildModel()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (["workspace", "workspacev2", "activewindow", "activewindowv2",
           "createworkspace", "createworkspacev2",
            "destroyworkspace", "destroyworkspacev2"].includes(event.name)) {
        updateWorkspaceEmpty()
        closeHoverMenu()
        closePinMenu()
      }
      if (event.name === "windowtitle") {
        root._badgeTick++
      }
    }
  }

  Rectangle {
    id: triggerStrip
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: dockBar.horizontalCenter
    // hot area plus some fat finger margin
    width: dockBar.width + 80
    height: 4
    color: "transparent"

    HoverHandler {
      id: triggerHover
      onHoveredChanged: hovered ? root.showDockBar() : root.scheduleHide()
    }
  }

  Timer {
    id: hideTimer
    interval: 500
    repeat: false
    onTriggered: {
      if (root.workspaceEmpty || root.mouseOverDockArea || root.dragging || root.contextOpen || root.hoverMenuOpen || root.pinMenuOpen) return
      root.dockVisible = false
    }
  }

  Rectangle {
    id: dockBar
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: root.gap - root.dockHeight - 20

    implicitWidth: row.implicitWidth + 24
    implicitHeight: row.implicitHeight + 24

    color: Color.bar.background
    radius: 18
    border.color: Qt.alpha(Color.foreground, 0.18)
    border.width: 1

    states: State {
      name: "visible"
      when: root.dockVisible
      PropertyChanges {
        target: dockBar
        anchors.bottomMargin: root.elevationMargin + root.gap
      }
    }

    transitions: Transition {
      NumberAnimation {
        property: "anchors.bottomMargin"
        duration: 200
        easing.type: Easing.InOutQuad
      }
    }

    Rectangle {
      anchors.fill: parent
      anchors.topMargin: 4
      radius: 18
      color: "#000000"
      opacity: 0.3
      z: -1
    }

    HoverHandler {
      id: dockHover
      onHoveredChanged: hovered ? hideTimer.stop() : root.scheduleHide()
    }

    TapHandler {
      acceptedButtons: Qt.RightButton
      gesturePolicy: TapHandler.ReleaseWithinBounds
      onSingleTapped: root.openPinMenu(point.position.x)
    }

    Row {
      id: row
      anchors.centerIn: parent
      spacing: root.itemSpacing

      // Icons displaced by a drag slide to their new slot. Set duration to 0
      // for fully instant reordering.
      move: Transition {
        NumberAnimation { properties: "x"; duration: 120; easing.type: Easing.OutCubic }
      }

      Repeater {
        id: appRepeater
        model: appModel

        delegate: Item {
          id: appItem

          required property int index
          required property string entryId
          required property bool pinned
          required property string name
          required property string icon
          required property string cmd
          required property string matchTitle
          required property string appId
          required property bool minimizable

          readonly property var appData: ({
            name: appItem.name,
            icon: appItem.icon,
            cmd: appItem.cmd,
            match: appItem.matchTitle,
            appId: appItem.appId,
            minimizable: appItem.minimizable,
          })

          readonly property bool isDragged: root.dragName === appItem.name

          width: root.itemSize
          height: root.itemSize
          z: isDragged ? 10 : 0

          // Glued to the pointer while dragged. Because this reads appItem.x,
          // it re-solves whenever the Row re-lays the icon out mid-drag, so
          // the icon stays under the cursor through a reorder.
          transform: Translate {
            x: appItem.isDragged ? root.dragPointerX - root.dragGrabOffset - appItem.x : 0
          }

          property bool busy: false

          readonly property var toplevels: root.getToplevelsForApp(appItem.appData)
          readonly property bool isRunning: toplevels.length > 0
          readonly property int pid: isRunning ? toplevels[0].pid : 0
          readonly property int unreadCount: {
            var _ = root._badgeTick
            if (!isRunning) return 0
            return root.getUnreadCount(toplevels)
          }

          HoverHandler {
            id: itemHover
            onHoveredChanged: {
              if (hovered) {
                if (appItem.toplevels.length >= 2 && !root.contextOpen && !root.pinMenuOpen) {
                  root.hoverMenuKey = appItem.name
                  root.hoverMenuWindows = appItem.toplevels.map(t => ({
                    title: t.toplevel.title || appItem.name,
                    address: t.toplevel.lastIpcObject?.address || ("0x" + t.toplevel.address)
                  }))
                  root.hoverMenuAnchorX = row.mapFromItem(appItem, appItem.width / 2, 0).x
                  hoverDelayTimer.restart()
                }
              } else {
                hoverCloseTimer.restart()
              }
            }
          }

          Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: 12
            color: Color.foreground
            opacity: appItem.isDragged ? 0.22 : (itemHover.hovered ? 0.15 : 0)
            Behavior on opacity { NumberAnimation { duration: 150 } }
          }

          DragHandler {
            id: dragHandler
            target: null
            yAxis.enabled: false

            onActiveChanged: {
              if (active) {
                hideTimer.stop()
                root.closeHoverMenu()
                const p = row.mapFromItem(null, centroid.scenePosition.x, centroid.scenePosition.y)
                root.dragPointerX = p.x
                root.dragGrabOffset = p.x - appItem.x
                root.dragName = appItem.name
              } else {
                root.dragName = ""
                root.persistOrder()
                if (!root.mouseOverDockArea) root.scheduleHide()
              }
            }

            onCentroidChanged: {
              if (!active) return
              const p = row.mapFromItem(null, centroid.scenePosition.x, centroid.scenePosition.y)
              root.dragPointerX = p.x
              root.updateDragTarget(appItem.index)
            }
          }

          TapHandler {
            acceptedButtons: Qt.RightButton
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onSingleTapped: {
              root.closeHoverMenu()
              root.openContextMenu(appItem)
            }
          }

          TapHandler {
            acceptedButtons: Qt.LeftButton
            // Releases the press to the DragHandler once the pointer moves
            // past the drag threshold, so a drag never fires a launch.
            gesturePolicy: TapHandler.DragThreshold
            onSingleTapped: {
              root.closeHoverMenu()
              if (root.contextOpen) {
                root.closeContextMenu()
                return
              }
              var cmdParts = root.execTokenize(appItem.cmd)
              if (appItem.isRunning) {
                var minimizable = appItem.minimizable
                if (minimizable) {
                  var anyOnCurrent = false
                  var anyOnSpecial = false
                  var ws = Hyprland.focusedWorkspace?.id
                  for (var _i = 0; _i < appItem.toplevels.length; _i++) {
                    var tws = appItem.toplevels[_i].toplevel.workspace?.id
                    if (tws === ws) anyOnCurrent = true
                    if (tws != null && tws < 0) anyOnSpecial = true
                  }

                  if (anyOnCurrent) {
                    for (var _j = 0; _j < appItem.toplevels.length; _j++) {
                      var tl = appItem.toplevels[_j].toplevel
                      if (tl.workspace?.id !== ws) continue
                      var addr = tl.lastIpcObject?.address
                      if (!addr || addr === "0") addr = "0x" + tl.address
                      if (addr && addr !== "0x0") {
                        Hyprland.dispatch('hl.dsp.window.move({ workspace = "special:dock_minimize", follow = false, window = "address:' + addr + '" })')
                      }
                    }
                    if (!root.workspaceEmpty) root.dockVisible = false
                    return
                  }

                  if (anyOnSpecial) {
                    for (var _k = 0; _k < appItem.toplevels.length; _k++) {
                      var tl = appItem.toplevels[_k].toplevel
                      if (tl.workspace?.id == null || tl.workspace.id >= 0) continue
                      var addr = tl.lastIpcObject?.address
                      if (!addr || addr === "0") addr = "0x" + tl.address
                      if (addr && addr !== "0x0") {
                        Hyprland.dispatch('hl.dsp.window.move({ workspace = ' + (ws ?? 1) + ', window = "address:' + addr + '" })')
                      }
                    }
                    var addr = appItem.toplevels[0].toplevel.lastIpcObject?.address
                    if (!addr || addr === "0") addr = "0x" + appItem.toplevels[0].toplevel.address
                    if (addr && addr !== "0x0") {
                      Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })')
                    } else {
                      var cls = appItem.toplevels[0].toplevel.lastIpcObject?.class
                      if (cls) Hyprland.dispatch('hl.dsp.focus({ window = "class:' + cls + '" })')
                    }
                    return
                  }
                }

                var addr = appItem.toplevels[0].toplevel.lastIpcObject?.address
                if (!addr || addr === "0") addr = "0x" + appItem.toplevels[0].toplevel.address
                if (addr && addr !== "0x0") {
                  Hyprland.dispatch('hl.dsp.focus({ window = "address:' + addr + '" })')
                } else {
                  var cls = appItem.toplevels[0].toplevel.lastIpcObject?.class
                  if (cls) Hyprland.dispatch('hl.dsp.focus({ window = "class:' + cls + '" })')
                }
                if (!root.workspaceEmpty) root.dockVisible = false
              } else if (!appItem.busy) {
                appItem.busy = true
                Quickshell.execDetached(cmdParts)
              }
            }
          }

          onIsRunningChanged: {
            if (isRunning) busy = false
          }

          Image {
            id: iconImg
            anchors.centerIn: parent
            source: Quickshell.iconPath(appItem.icon, true)
            width: 40
            height: 40
            fillMode: Image.PreserveAspectFit
            opacity: appItem.isDragged ? 0.85 : 1
          }

          Rectangle {
            visible: appItem.isRunning
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: -6
            width: 4
            height: 4
            radius: 2
            color: Color.bar.text
          }

          Rectangle {
            visible: appItem.unreadCount > 0
            anchors.top: parent.top
            anchors.topMargin: -4
            anchors.right: parent.right
            anchors.rightMargin: -4
            width: Math.max(18, badgeText.implicitWidth + 10)
            height: 18
            radius: 9
            color: "#ea4335"
            border.color: Color.bar.background
            border.width: 1.5

            Text {
              id: badgeText
              anchors.centerIn: parent
              text: appItem.unreadCount > 99 ? "99+" : appItem.unreadCount.toString()
              // Numeric today, but derived from titles — keep it plain.
              textFormat: Text.PlainText
              color: "#ffffff"
              font.pixelSize: 10
              font.bold: true
            }
          }
        }
      }
    }
  }

  Timer {
    id: contextCloseTimer
    interval: 180
    repeat: false
    onTriggered: if (!root.mouseOverDockArea) root.closeContextMenu()
  }

  Timer {
    id: hoverDelayTimer
    interval: 300
    repeat: false
    onTriggered: {
      if (!root.contextOpen && !root.pinMenuOpen) root.hoverMenuOpen = true
    }
  }

  Timer {
    id: hoverCloseTimer
    interval: 180
    repeat: false
    onTriggered: {
      if (!root.mouseOverDockArea && !windowMenuHover.hovered) root.closeHoverMenu()
    }
  }

  // The pin menu has no click-outside path (input outside the mask passes
  // through the layer surface), so leaving the dock area is the close signal,
  // same idiom as contextCloseTimer/hoverCloseTimer.
  Timer {
    id: pinMenuCloseTimer
    interval: 180
    repeat: false
    onTriggered: if (!root.mouseOverDockArea) root.closePinMenu()
  }

  function closeHoverMenu() {
    hoverDelayTimer.stop()
    hoverCloseTimer.stop()
    hoverMenuOpen = false
    if (!root.mouseOverDockArea) root.scheduleHide()
  }

  Item {
    id: contextMenu

    // Collapsed to nothing when closed so it contributes no input region.
    width: root.contextOpen ? contextCard.width : 0
    height: root.contextOpen ? contextCard.height : 0
    visible: root.contextOpen

    anchors.bottom: dockBar.top
    anchors.bottomMargin: 2
    x: Math.max(0, Math.min(dockBar.x + root.contextAnchorX - width / 2, root.width - width))

    HoverHandler { id: contextHover }

    Rectangle {
      id: contextCard

      implicitWidth: Math.max(150, widthProbe.implicitWidth + 24)
      implicitHeight: contextColumn.implicitHeight + 16

      color: Color.menu.background
      radius: 10
      border.color: Qt.alpha(Color.foreground, 0.18)
      border.width: 1

      Column {
        id: contextColumn
        anchors.centerIn: parent
        spacing: 1

        Repeater {
          model: root.contextActions

          delegate: Rectangle {
            required property var modelData

            width: contextCard.width - 8
            height: 26
            radius: 6
            color: rowHover.hovered ? Color.menu.selectedBackground : "transparent"

            HoverHandler { id: rowHover }

            TapHandler {
              acceptedButtons: Qt.LeftButton
              onSingleTapped: root.runContextAction(modelData.act)
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: 8
              text: modelData.label
              color: Color.menu.text
              font.pixelSize: 12
            }
          }
        }
      }

      // Sizes the card without reading the Column back, which would be a
      // polish loop since the rows take their width from the card.
      Text {
        id: widthProbe
        visible: false
        text: "Open new window"
        font.pixelSize: 12
      }
    }
  }

  Item {
    id: windowMenu

    width: root.hoverMenuOpen ? windowCard.width : 0
    height: root.hoverMenuOpen ? windowCard.height : 0
    visible: root.hoverMenuOpen

    anchors.bottom: dockBar.top
    anchors.bottomMargin: 2
    x: Math.max(0, Math.min(dockBar.x + root.hoverMenuAnchorX - width / 2, root.width - width))

    HoverHandler { id: windowMenuHover }

    Rectangle {
      id: windowCard

      // Capped so long titles elide instead of stretching the menu; the
      // probe alone would size the card to the longest title in full.
      implicitWidth: Math.max(150, Math.min(windowWidthProbe.implicitWidth + 24, 320))
      implicitHeight: windowColumn.implicitHeight + 16

      color: Color.menu.background
      radius: 10
      border.color: Qt.alpha(Color.foreground, 0.18)
      border.width: 1

      Column {
        id: windowColumn
        anchors.centerIn: parent
        spacing: 1

        Repeater {
          model: root.hoverMenuWindows

          delegate: Rectangle {
            required property var modelData

            width: windowCard.width - 8
            height: 26
            radius: 6
            color: windowRowHover.hovered ? Color.menu.selectedBackground : "transparent"

            HoverHandler { id: windowRowHover }

            TapHandler {
              acceptedButtons: Qt.LeftButton
              onSingleTapped: {
                root.focusWindow(modelData.address)
                root.closeHoverMenu()
                if (!root.workspaceEmpty) root.dockVisible = false
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: 8
              text: modelData.title
              // Titles are app-controlled; AutoText would sniff markup and
              // let <img> etc. pull resources into the shell.
              textFormat: Text.PlainText
              color: Color.menu.text
              font.pixelSize: 12
              elide: Text.ElideRight
              width: parent.width - 16
            }
          }
        }
      }

      Text {
        id: windowWidthProbe
        visible: false
        // Same untrusted titles as the rows above; invisible still parses.
        textFormat: Text.PlainText
        text: {
          var longest = ""
          for (var i = 0; i < root.hoverMenuWindows.length; i++) {
            if (root.hoverMenuWindows[i].title.length > longest.length) {
              longest = root.hoverMenuWindows[i].title
            }
          }
          return longest
        }
        font.pixelSize: 12
      }
    }
  }

  Item {
    id: pinMenu

    width: root.pinMenuOpen ? pinCard.width : 0
    height: root.pinMenuOpen ? pinCard.height : 0
    visible: root.pinMenuOpen

    anchors.bottom: dockBar.top
    anchors.bottomMargin: 2
    x: Math.max(0, Math.min(dockBar.x + root.pinMenuAnchorX - width / 2, root.width - width))

    HoverHandler { id: pinMenuHover }

    Rectangle {
      id: pinCard

      // +42 covers the app-icon column and the right-aligned pin glyph;
      // capped like the other cards so long names elide instead of stretching.
      implicitWidth: Math.max(150, Math.min(pinWidthProbe.implicitWidth + 24 + 42, 320))
      implicitHeight: pinFlick.height + 16

      color: Color.menu.background
      radius: 10
      border.color: Qt.alpha(Color.foreground, 0.18)
      border.width: 1

      Flickable {
        id: pinFlick
        anchors.centerIn: parent
        width: pinCard.width - 8
        // Cap at 8 rows (8*26+7*1 = 215) so the card never outgrows the
        // oversized window. Collapsed state shows 5 + "Show more" and fits
        // without scrolling.
        height: Math.min(pinColumn.implicitHeight, 215)
        clip: true
        contentHeight: pinColumn.implicitHeight
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds

        WheelHandler {
          onWheel: event => {
            if (pinFlick.contentHeight > pinFlick.height) {
              const dy = event.angleDelta.y > 0 ? -40 : 40
              pinFlick.contentY = Math.max(0, Math.min(pinFlick.contentHeight - pinFlick.height, pinFlick.contentY + dy))
              event.accepted = true
            }
          }
        }

        Column {
          id: pinColumn
          width: parent.width
          spacing: 1

          Repeater {
            model: root.pinCandidates.length > 0
              ? root.pinMenuVisibleCandidates
              : [{ label: "No unpinned apps running", empty: true }]

            delegate: Rectangle {
              required property var modelData

              width: pinColumn.width
              height: 26
              radius: 6
              color: !modelData.empty && pinRowHover.hovered ? Color.menu.selectedBackground : "transparent"

              HoverHandler { id: pinRowHover }

              TapHandler {
                acceptedButtons: Qt.LeftButton
                enabled: !modelData.empty
                onSingleTapped: root.runPinAction(modelData)
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                x: 8
                spacing: 8

                Image {
                  source: modelData.empty ? "" : Quickshell.iconPath(root.pinCandidateIcon(modelData), true)
                  width: 16
                  height: 16
                  visible: !modelData.empty
                  anchors.verticalCenter: parent.verticalCenter
                  fillMode: Image.PreserveAspectFit
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label
                  // Labels are window class/appId, i.e. outside data.
                  textFormat: Text.PlainText
                  color: modelData.empty ? Color.muted : Color.menu.text
                  font.pixelSize: 12
                  elide: Text.ElideRight
                  // Reserve room for the pin glyph only on pinnable rows; the
                  // empty-state row has no icon column either.
                  width: modelData.empty ? pinCard.width - 40 : pinCard.width - 64
                }
              }

              Text {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                // Same glyph the pin tool uses for its notifications.
                text: "󰐃"
                color: pinRowHover.hovered ? Color.menu.text : Color.muted
                font.pixelSize: 13
                visible: !modelData.empty
              }
            }
          }

          Rectangle {
            visible: !root.pinMenuExpanded && root.pinMenuHasMore
            width: pinColumn.width
            height: visible ? 26 : 0
            radius: 6
            color: showMoreHover.hovered ? Color.menu.selectedBackground : "transparent"

            HoverHandler { id: showMoreHover }

            TapHandler {
              acceptedButtons: Qt.LeftButton
              onSingleTapped: root.pinMenuExpanded = true
            }

            Text {
              anchors.centerIn: parent
              text: "Show " + (root.pinCandidates.length - root.pinMenuPageSize) + " more…"
              textFormat: Text.PlainText
              color: Color.muted
              font.pixelSize: 12
            }
          }
        }
      }

      Text {
        id: pinWidthProbe
        visible: false
        text: "No unpinned apps running"
        font.pixelSize: 12
      }
    }
  }
}

