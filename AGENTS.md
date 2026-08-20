# quickshelldock

Hyprland dock panel built with Quickshell (QML). No build step — loaded directly by the Quickshell runtime.

## Structure

- `shell.qml` — entrypoint, instantiates `DockPanel` per screen via `Variants`
- `DockPanel.qml` — the dock UI: auto-hide, bounce-on-launch, Hyprland toplevel matching, window focus
- `config/DockApps.qml` — singleton defining the ordered app list (name, icon, cmd, optional `match`)

## Pinning

- `bin/quickshelldock-pin` is the only writer of `pins.json`; the dock shells out to it (via `Quickshell.shellDir`)
  rather than editing the file itself, so there is one code path for pin state
- `FileView.reload()` is async — merge pins on `onTextChanged`, not on `onFileChanged`, or you read back stale text
  and the dock silently ignores the change
- Pins merge after config apps and dedupe on name or cmd, so pinning something already in `UserConfig.qml` is a no-op
- Some packaged `.desktop` files ship an unsubstituted `StartupWMClass` placeholder (Chromium's is
  `@@startup_wm_class`); the pin tool drops those so matching falls back to the binary name
- Desktop ids are stored without the `.desktop` suffix but must not be blindly stripped — `org.telegram.desktop` is a
  real id

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
- The dock uses `WlrLayershell.layer: Top` and `exclusiveZone: -1` (no exclusive zone)
- Show/hide is a plain `anchors.bottomMargin` binding with no Transition, and `hideTimer.interval` is `0` — the timer
  only exists so the triggerStrip/dockBar hover handoff doesn't flicker
- Layer namespace is `quickshelldock`

## Dock visibility

- Empty workspace → dock always visible
- Workspace with windows → dock auto-hides (shows on hover at bottom edge)
- `showOnFloating` config flag (default: `false`) — when `true`, floating-only workspaces are treated as empty
- Detection: fast path iterates `Hyprland.toplevels` for the common cases (empty workspace, `showOnFloating` disabled); only falls back to `hyprctl clients -j` when `showOnFloating` is true and there are windows on the workspace
- Relevant Hyprland events: `workspace`, `workspacev2`, `activewindow`, `activewindowv2`, `createworkspace`, `createworkspacev2`, `destroyworkspace`, `destroyworkspacev2`
