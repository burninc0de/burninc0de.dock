import Quickshell
import QtQuick

Item {
  Variants {
    model: Quickshell.screens

    DockPanel {
      required property var modelData
      screen: modelData
    }
  }
}
