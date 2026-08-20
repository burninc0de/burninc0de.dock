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

## Adding apps

Three ways, in increasing order of convenience.

**Edit the config.** `config/UserConfig.qml` is the declarative base and hot-reloads on save. Fields come straight out
of the app's `.desktop` file: `Icon=` → `icon`, `Exec=` → `cmd`, `StartupWMClass=` → `appId`.

**Pin from the command line.**

```sh
bin/quickshelldock-pin chromium        # pin by desktop entry id
bin/quickshelldock-pin --unpin chromium
bin/quickshelldock-pin --list
```

It reads the `.desktop` file for you, strips launcher field codes (`%U`, `%f`, …) out of `Exec=`, and appends the app
to `$XDG_STATE_HOME/quickshelldock/pins.json`. The dock watches that file, so the icon appears immediately. Symlink
the script into `~/.local/bin` to have it on `PATH`.

**Pin from the Omarchy menu (Super+Space).** Run `integration/install-omarchy-menu-rightclick` once, then right-click
any app in the menu to pin or unpin it. See [`integration/`](integration/) for what that touches and how to undo it.
Without the patch you can still add a `Dock › Pin app to dock` row to `~/.config/omarchy/extensions/omarchy-menu.jsonc`
pointing at `quickshelldock-pin --pick`, which needs no changes to Omarchy at all.

Pins layer on top of `UserConfig.qml` rather than replacing it, and an app already declared there is not duplicated.

## Right-click menu

Right-clicking a dock icon offers the three actions every other dock agrees on — GNOME's dash-to-dock, the macOS Dock
and KDE's task manager all share them:

| Action | Shown |
|--------|-------|
| Open new window | always |
| Quit | only while the app is running; closes all of its windows |
| Unpin from dock | always |

Window lists, thumbnails and "App Details" are deliberately absent — they belong to the scope this dock doesn't have.

Unpin works on every icon, wherever it came from. Apps pinned with the tool are dropped from `pins.json`; apps
declared in `UserConfig.qml` are recorded in `hidden.json` instead, because rewriting your hand-written QML isn't the
dock's business. A hidden app isn't on the dock any more, so bring it back with `--restore-pick` (or the
`Dock › Restore removed app` menu row):

```sh
bin/quickshelldock-pin --list-hidden
bin/quickshelldock-pin --restore Obsidian
```

Right-clicking the app in the Super+Space menu also restores it, as long as the dock's display name matches the
desktop entry's `Name=`. Where you renamed it in `UserConfig.qml` — a "foot" entry labelled "Terminal", say — use
`--restore` with the dock's name.

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
