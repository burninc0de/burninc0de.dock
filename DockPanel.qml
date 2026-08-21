import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
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

  // The window only grows tall enough for the context menu while one is open;
  // exclusiveZone is -1 either way, so nothing on screen gets pushed around.
  // Fixed height: dock bar (80) + max context card (3 rows × 26 + 2 gaps × 1 + 16 padding = 96) + 10 margin
  implicitHeight: 80 + 96 + 10

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

  // Drag-to-reorder state. Only one icon can be dragged at a time, so this
  // lives on the root rather than in the delegates.
  property string dragName: ""
  property real dragPointerX: 0
  property real dragGrabOffset: 0
  readonly property bool dragging: dragName !== ""

  // Icon order survives restarts here. Kept out of the config dir so a
  // git pull never fights with it.
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || (Quickshell.env("HOME") + "/.local/state")) + "/quickshelldock"
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
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: { root.clientsJson = this.text }
    }
  }

  Process {
    id: mkdirProcess
    command: ["mkdir", "-p", root.stateDir]
    running: true
  }

  FileView {
    id: orderFile
    path: root.orderPath
    blockLoading: true
    printErrors: false
    atomicWrites: true
  }

  // Config apps removed from the dock. Suppressed here rather than by
  // rewriting UserConfig.qml, which is the user's to own.
  FileView {
    id: hiddenFile
    path: root.hiddenPath
    blockLoading: true
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onTextChanged: {
      root.loadHidden()
      if (!root.dragging) root.rebuildModel()
    }
  }

  // Written by bin/quickshelldock-pin, never by the dock. Watching it is what
  // makes a pin from the Omarchy menu show up without a restart.
  FileView {
    id: pinsFile
    path: root.pinsPath
    blockLoading: true
    printErrors: false
    watchChanges: true
    // reload() is async, so the merge has to wait for the text to actually
    // land rather than reading it back on the fileChanged tick.
    onFileChanged: reload()
    onTextChanged: {
      root.loadPins()
      if (!root.dragging) root.rebuildModel()
    }
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
      order: app.order ?? 0,
    }
  }

  function loadHidden() {
    try {
      const raw = hiddenFile.text()
      hiddenApps = raw ? (JSON.parse(raw) || []) : []
    } catch (e) {
      hiddenApps = []
    }
  }

  function loadPins() {
    try {
      const raw = pinsFile.text()
      pinnedApps = raw ? (JSON.parse(raw) || []) : []
    } catch (e) {
      pinnedApps = []
    }
  }

  function loadSavedOrder() {
    try {
      const raw = orderFile.text()
      if (!raw) return
      const parsed = JSON.parse(raw)
      if (Array.isArray(parsed)) savedOrder = parsed
    } catch (e) {}
  }

  // Config order is the baseline; anything the user has dragged wins over it.
  // Apps added to the config after the last drag land at the end.
  function rebuildModel() {
    let apps = []
    for (const app of DockApps.apps) apps.push(normalizeApp(app, false))
    apps.sort((a, b) => a.order - b.order)

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
        const exe = app.cmd.split(/\s+/)[0].split("/").pop().replace(/\.[^/.]+$/, "").toLowerCase()
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
  }

  // Running apps that no dock icon claims, deduped by class/appId. A toplevel
  // counts as claimed when any configured or pinned app matches it.
  function buildPinCandidates() {
    let claimed = []
    for (let i = 0; i < appModel.count; i++) {
      const m = appModel.get(i)
      const tls = root.getToplevelsForApp({ match: m.matchTitle, appId: m.appId, cmd: m.cmd })
      for (const t of tls) claimed.push(t.toplevel)
    }
    const seen = {}
    const out = []
    for (const tl of Hyprland.toplevels.values) {
      if (claimed.indexOf(tl) >= 0) continue
      const cls = tl.lastIpcObject?.class ?? ""
      const aid = tl.wayland?.appId ?? ""
      const key = cls || aid
      if (!key || seen[key]) continue
      seen[key] = true
      out.push({ label: key, cls: cls, appId: aid })
    }
    return out
  }

  function openPinMenu(xInBar) {
    if (root.pinMenuOpen) {
      root.closePinMenu()
      return
    }
    root.closeContextMenu()
    root.closeHoverMenu()
    root.pinCandidates = root.buildPinCandidates()
    root.pinMenuAnchorX = xInBar
    root.pinMenuOpen = true
  }

  function closePinMenu() {
    root.pinMenuOpen = false
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
      Quickshell.execDetached(app.cmd.split(/\s+/))
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
    } else {
      contextCloseTimer.restart()
      hoverCloseTimer.restart()
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
    loadSavedOrder()
    loadPins()
    loadHidden()
    rebuildModel()
    updateWorkspaceEmpty()
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

    color: "#1e1e2e"
    radius: 18
    border.color: "#313244"
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
            color: "#cdd6f4"
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
              var cmdParts = appItem.cmd.split(/\s+/)
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
                bounceAnimation.start()
                Quickshell.execDetached(cmdParts)
              }
            }
          }

          onIsRunningChanged: {
            if (isRunning) busy = false
            bounceAnimation.stop()
            iconImg.y = 0
          }

          SequentialAnimation {
            id: bounceAnimation
            loops: Animation.Infinite
            NumberAnimation {
              target: iconImg
              property: "y"
              from: 0; to: -24; duration: 0
              easing.type: Easing.OutQuad
            }
            NumberAnimation {
              target: iconImg
              property: "y"
              to: 0; duration: 0
              easing.type: Easing.InQuad
            }
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
            color: "#ffffff"
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
            border.color: "#1e1e2e"
            border.width: 1.5

            Text {
              id: badgeText
              anchors.centerIn: parent
              text: appItem.unreadCount > 99 ? "99+" : appItem.unreadCount.toString()
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

  function closeHoverMenu() {
    hoverDelayTimer.stop()
    hoverCloseTimer.stop()
    hoverMenuOpen = false
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

      color: "#1e1e2e"
      radius: 10
      border.color: "#313244"
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
            color: rowHover.hovered ? "#313244" : "transparent"

            HoverHandler { id: rowHover }

            TapHandler {
              acceptedButtons: Qt.LeftButton
              onSingleTapped: root.runContextAction(modelData.act)
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: 8
              text: modelData.label
              color: "#cdd6f4"
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

      color: "#1e1e2e"
      radius: 10
      border.color: "#313244"
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
            color: windowRowHover.hovered ? "#313244" : "transparent"

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
              color: "#cdd6f4"
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

      // +26 leaves room for the icon column; capped like the other cards so
      // long class names elide instead of stretching the menu.
      implicitWidth: Math.max(150, Math.min(pinWidthProbe.implicitWidth + 24 + 26, 320))
      implicitHeight: pinColumn.implicitHeight + 16

      color: "#1e1e2e"
      radius: 10
      border.color: "#313244"
      border.width: 1

      Column {
        id: pinColumn
        anchors.centerIn: parent
        spacing: 1

        Repeater {
          model: root.pinCandidates.length > 0
            ? root.pinCandidates
            : [{ label: "No unpinned apps running", empty: true }]

          delegate: Rectangle {
            required property var modelData

            width: pinCard.width - 8
            height: 26
            radius: 6
            color: !modelData.empty && pinRowHover.hovered ? "#313244" : "transparent"

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
                source: modelData.empty ? "" : Quickshell.iconPath(modelData.cls || modelData.appId, true)
                width: 16
                height: 16
                visible: !modelData.empty
                anchors.verticalCenter: parent.verticalCenter
                fillMode: Image.PreserveAspectFit
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: modelData.empty ? "#6c7086" : "#cdd6f4"
                font.pixelSize: 12
                elide: Text.ElideRight
                // Card width minus row inset, icon, spacing and margins.
                width: pinCard.width - 48
              }
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

