import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Ollama Cloud API cost tracker: one bar icon next to the OpenRouter tracker,
// with a dropdown showing plan usage, remaining credit and the reset date.
// Data comes from the record update.py writes to
// $XDG_STATE_HOME/ollama-cost/overview.json, watched live.

BarWidget {
  id: root
  moduleName: "ollama.cost"

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string overviewPath: stateHome + "/ollama-cost/overview.json"

  property var overview: null

  readonly property string updater: home + "/.config/omarchy/plugins/ollama.cost/update.py"

  // Shape contract for the bar's popup routing (see clock BarWidget).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // Bar label: the Ollama mark (omarchy font U+E907), or a glyph for error /
  // missing data. Limit reached shows the mark in the urgent colour.
  readonly property string barText: root.barButtonText()
  readonly property bool isMark: root.barText === "\ue907"
  readonly property bool limitReached: !!(root.overview && root.overview.limit
    && (root.overview.limit.reached === true || Number(root.overview.limit.percent || 0) >= 100))

  function barButtonText() {
    var o = root.overview;
    if (o && o.error === "no-api-key") { return "⚠"; }
    if (o && o.error !== null && o.error !== undefined && o.error !== "") { return "!"; }
    return "\ue907";
  }

  function parse(content) {
    try {
      root.overview = JSON.parse(String(content || ""))
    } catch (e) {
      root.overview = null
    }
  }

  FileView {
    path: root.overviewPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.overview = null
  }

  // First paint: if nothing has been collected yet, run the updater once.
  // (Component.onCompleted can fire before `bar` exists — refreshData retries.)
  Component.onCompleted: root.refreshData()

  // Keep the numbers fresh every few minutes even if the panel sits open.
  Timer {
    interval: 5 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refreshData()
  }

  // A running bar may not have handed us `bar` yet at Component.onCompleted
  // (observed: bar is null then), and the 5-minute Timer only starts counting
  // from construction — so run the updater as soon as the bar handle arrives,
  // and retry briefly if it is still missing.
  property bool firstRunDone: false

  function refreshData() {
    if (!root.bar) return
    if (!root.firstRunDone) {
      root.firstRunDone = true
      console.warn("ollama.cost: initial fetch -> " + root.updater)
    }
    root.bar.run(root.updater)
  }

  Timer {
    id: startupRetry
    interval: 2000
    running: !root.firstRunDone
    repeat: true
    onTriggered: root.refreshData()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    fontFamily: root.isMark ? "omarchy" : (root.bar ? root.bar.fontFamily : Style.font.family)
    active: root.isMark && root.limitReached
    tooltipText: "Ollama Cloud plan usage — click for credits used and reset date"
    onPressed: function(b) {
      if (b === Qt.LeftButton) {
        root.refreshData()
        root.togglePanel()
      }
    }
  }
}
