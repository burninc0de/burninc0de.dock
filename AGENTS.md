# quickshelldock

Hyprland dock panel built with Quickshell (QML). No build step — loaded directly by the Quickshell runtime.

## Structure

- `Dock.qml` — entrypoint, instantiates `DockPanel` per screen via `Variants`
- `DockPanel.qml` — the dock UI: auto-hide, bounce-on-launch, Hyprland toplevel matching, window focus
- `config/DockApps.qml` — singleton defining the ordered app list (name, icon, cmd, optional `match`)

## Pinning

- `bin/quickshelldock-pin` is the only writer of `pins.json`; the dock shells out to it (path resolved with
  `Qt.resolvedUrl` relative to `DockPanel.qml` — `Quickshell.shellDir` points at omarchy-shell's own dir when loaded
  as a plugin, not at the plugin folder)
  rather than editing the file itself, so there is one code path for pin state
- State files are read with byte ceilings: nothing is ever loaded through `FileView` (it buffers whole files and has
  no size cap). The FileViews for `pins.json`/`hidden.json` are watchers only (`preload: false`, `watchChanges`) —
  verified that they still emit `fileChanged` while never loading. All content goes through one shared Process running
  `head -c <maxStateBytes> -- <path>`; truncated output fails `JSON.parse` and degrades to an empty list. Reads
  requested mid-read queue in a FIFO (`pendingQueue`) and replay on `onExited` (`Process.running` flips
  synchronously, so back-to-back startup reads must queue — a single pending slot silently drops all but the
  last of them, which is how pins used to vanish at startup)
- The pin tool writes via temp-file + rename, so a watcher-triggered read always sees complete JSON; there is no
  partial-read race to guard against
- Pins merge after config apps and dedupe on name or cmd, so pinning something already in `UserConfig.qml` is a no-op
- Some packaged `.desktop` files ship an unsubstituted `StartupWMClass` placeholder (Chromium's is
  `@@startup_wm_class`); the pin tool drops those so matching falls back to the binary name
- Unpin is two mechanisms behind one verb: pinned apps leave `pins.json`, config apps enter `hidden.json`. The dock
  filters the merged list on both `name` and `entryId`
- The context menu passes `entryId || name` as the unpin key, so config apps (which have no desktop id) key by name
- Desktop ids are stored without the `.desktop` suffix but must not be blindly stripped — `org.telegram.desktop` is a
  real id
- The empty-space pin menu lists toplevels no dock app claims, deduped by class/appId; `--pin-window` resolves a
  class back to a desktop entry by file id, then `StartupWMClass`, then `Exec` basename, and pins blind (cmd = class)
  when nothing claims it

## Reordering

- The Repeater is backed by a `ListModel` (`appModel`), not a plain JS array — a `move()` keeps the delegates alive
  mid-drag, whereas reassigning an array model recreates them and kills the active `DragHandler`
- `DockApps.apps` is the baseline order; `order.json` under `Quickshell.env("XDG_STATE_HOME")` (falling back to
  `~/.local/state`) overrides it and is rewritten on drag release
- The dragged icon's `Translate.x` is bound to `dragPointerX - dragGrabOffset - appItem.x`. Reading the live,
  Row-assigned `appItem.x` is what keeps the icon under the cursor when a reorder relayouts the row mid-drag
- Pointer positions are read from `centroid.scenePosition` and mapped with `row.mapFromItem(null, ...)`;
  `centroid.position` is self-referential once the item carries a drag transform
- `TapHandler.gesturePolicy: DragThreshold` is what stops a drag from also launching the app

## Key conventions

- App matching: if `match` is set, matches against Hyprland toplevel `title`; if `appId` is set, matches against the Wayland `appId`; otherwise extracts the binary name from `cmd` and matches against `appId` or `class`
- `Quickshell.execDetached(cmdParts)` launches apps — always split `cmd` on whitespace
- Unread badge: hardcoded Gmail convention — counts `Inbox (N)` in window titles; `_badgeTick` bumps on Hyprland
  `windowtitle` events to re-evaluate the badge bindings without polling
- The dock uses `WlrLayershell.layer: Top` and `exclusiveZone: -1` (no exclusive zone)
- Show/hide animates `anchors.bottomMargin` via a `states` + `Transition` (200ms InOutQuad). `hideTimer.interval` is
  `500` — the delay exists so the triggerStrip/dockBar hover handoff doesn't flicker, not as a show/hide driver
- Menus (context + hover window list) must hide the dock explicitly on click
  (`if (!root.workspaceEmpty) root.dockVisible = false`) — focusing a window alone doesn't
- Menu cards are sized by hidden probe `Text` items; the width cap (`Math.min(..., 320)`) is what makes the rows'
  `elide` engage — an uncapped probe stretches the card to the longest title and elide never fires
- Every `Text` that renders non-literal data (window titles, class/appId labels, badge counts) declares
  `textFormat: Text.PlainText` — default AutoText sniffs markup, so a title like `<img src=...>` would parse as
  rich text and load resources into the long-lived shell. Invisible probes still parse their text and need it too
- Layer namespace is `quickshelldock`

## Dock visibility

- Empty workspace → dock always visible
- Workspace with windows → dock auto-hides (shows on hover at bottom edge)
- `showOnFloating` config flag (default: `true`) — when `true`, floating-only workspaces are treated as empty
- Detection: fast path iterates `Hyprland.toplevels` for the common cases (empty workspace, `showOnFloating` disabled); only falls back to `hyprctl clients -j` when `showOnFloating` is true and there are windows on the workspace
- Unbounded inputs are capped at ingestion (`maxStateBytes`, `maxClientsBytes`): the clients query is piped through
  `head -c`, so even a pathological window count can't balloon the shell; truncation fails JSON.parse and reads as
  "empty workspace"
- Relevant Hyprland events: `workspace`, `workspacev2`, `activewindow`, `activewindowv2`, `createworkspace`, `createworkspacev2`, `destroyworkspace`, `destroyworkspacev2`
