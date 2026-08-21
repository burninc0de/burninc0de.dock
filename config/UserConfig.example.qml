import QtQuick

QtObject {
  property bool showOnFloating: true

  property var apps: [
    {
      name: "Chromium",
      icon: "chromium",
      cmd: "chromium",
      appId: "chromium",
      order: 0,
    },
    {
      name: "Terminal",
      icon: "foot",
      cmd: "foot",
      appId: "foot",
      order: 1,
    },
    {
      name: "Files",
      icon: "system-file-manager",
      cmd: "nautilus",
      appId: "org.gnome.Nautilus",
      order: 2,
    },
    {
      name: "Neovim",
      icon: "nvim",
      cmd: "foot --app-id=foot-nvim -e nvim",
      appId: "foot-nvim",
      order: 3,
    },
  ]
}
