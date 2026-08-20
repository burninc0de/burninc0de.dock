# quickshelldock

Hyprland dock panel built with [Quickshell](https://quickshell.outfoxxed.me/). No build step — loaded directly by the Quickshell runtime.

## Usage

```sh
quickshell /path/to/quickshelldock
```

## Configuration

App list and options are in [`config/DockApps.qml`](config/DockApps.qml). To override without editing the defaults, create `config/UserConfig.qml` with the same structure:

```js
import QtQuick

QtObject {
  property bool showOnFloating: true

  property var apps: [
    { name: "Firefox", icon: "firefox", cmd: "firefox", order: 0 },
    { name: "Dolphin", icon: "system-file-manager", cmd: "dolphin", order: 1 },
  ]
}
```

### Per-app options

| Field         | Required | Description |
|---------------|----------|-------------|
| `name`        | yes      | Display name |
| `icon`        | yes      | Icon name (looked up via `Quickshell.iconPath`) |
| `cmd`         | yes      | Command to launch, split on whitespace |
| `order`       | yes      | Sort position in the dock |
| `match`       | no       | If set, matches against Hyprland toplevel `title` |
| `appId`       | no       | If set, matches against Wayland `appId` |
| `minimizable` | no       | Default `true`. When `false`, clicking a running app always focuses it instead of minimize/restore |

## Reordering

Drag an icon sideways to move it. The remaining icons shuffle out of the way as you go, and the order is written to
`$XDG_STATE_HOME/quickshelldock/order.json` (`~/.local/state/quickshelldock/order.json` by default) on release, so it
survives a restart.

The saved order takes priority over the `order` fields in the config. Apps added to the config afterwards are appended
to the end of the dock; apps removed from the config are dropped. Delete `order.json` to fall back to the config order.

## Show / hide

Show and hide are instant — the bar snaps into place with no slide animation, both when the workspace empties and when
you hover the bottom edge. The only easing left is the 120ms shuffle of icons displaced by a drag; set that
`NumberAnimation` duration to `0` in `DockPanel.qml` if you want reordering to snap too.

## Minimize / Restore

Since Hyprland has no native minimize, clicking a running app's dock icon hides it on the `special:dock_minimize` scratchpad workspace. Clicking again restores it to the current workspace.

This works for any app that has toplevels on the current workspace. Apps on other (non-special) workspaces are focused normally. Set `minimizable: false` per app to disable this behavior.
