import QtQuick

QtObject {
  property bool showOnFloating: true

  property var apps: [
    {
      name: "Chromium",
      icon: "chromium",
      cmd: "chromium",
      appId: "chromium",
    },
    {
      name: "Terminal",
      icon: "foot",
      cmd: "foot",
      appId: "foot",
    },
    {
      name: "Files",
      icon: "system-file-manager",
      cmd: "nautilus",
      appId: "org.gnome.Nautilus",
    },
    {
      name: "Neovim",
      icon: "nvim",
      cmd: "foot --app-id=foot-nvim -e nvim",
      appId: "foot-nvim",
    },
  ]
}
