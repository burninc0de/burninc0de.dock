pragma Singleton
import QtQuick

QtObject {
  id: config

  property bool showOnFloating: true

  property var apps: [
    { name: "Chromium", icon: "chromium", cmd: "chromium", appId: "chromium" },
    { name: "Terminal", icon: "foot", cmd: "foot", appId: "foot" },
    { name: "Files", icon: "system-file-manager", cmd: "nautilus", appId: "org.gnome.Nautilus" },
    { name: "Neovim", icon: "nvim", cmd: "foot --app-id=foot-nvim -e nvim", appId: "foot-nvim" },
  ]

  Component.onCompleted: {
    var comp = Qt.createComponent("UserConfig.qml")
    if (comp.status === Component.Ready) {
      var obj = comp.createObject(null)
      if (obj) {
        if (obj.showOnFloating !== undefined)
          config.showOnFloating = obj.showOnFloating
        if (obj.apps !== undefined && obj.apps.length > 0)
          config.apps = obj.apps
        obj.destroy()
      }
    }
  }
}
