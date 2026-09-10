import QtQuick
import qs.Ui

// Adapted from Omarchy's menu bar widget (the same ue900 glyph in the
// omarchy icon font). Toggling through `omarchy.menu` lets the registry
// route the call to whichever menu implementation is enabled, so this
// button keeps working if OmaRay is disabled.
BarWidget {
  id: root
  moduleName: "datbuiquoc035.omaray"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\ue900"
    fontFamily: "omarchy"
    horizontalMargin: 7.5
    onPressed: function(pressedButton) {
      if (!root.bar) return
      if (pressedButton === Qt.RightButton) root.bar.run("xdg-terminal-exec")
      else root.bar.run("omarchy-shell shell toggle omarchy.menu '{\"menu\":\"root\"}'")
    }
  }
}
