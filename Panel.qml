import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Dropdown for Ollama Cloud API cost. Reads the record update.py writes to
// $XDG_STATE_HOME/ollama-cost/overview.json: credit usage against the plan's
// included grant, the reset date, which keys feed it, and period requests.

Panel {
  id: root
  moduleName: "ollama.cost"
  ipcTarget: "ollama.cost"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string overviewPath: stateHome + "/ollama-cost/overview.json"
  readonly property string updater: home + "/.config/omarchy/plugins/ollama.cost/update.py"

  property var overview: null

  readonly property var monthRec: root.overview && root.overview.month ? root.overview.month : null
  readonly property var limit: root.overview && root.overview.limit ? root.overview.limit : null
  readonly property var err: root.overview ? (root.overview.error ? String(root.overview.error) : "") : "no-data"
  readonly property string updatedText: root.overview ? String(root.overview.updatedAt || "").slice(0, 19).replace("T", " ") : ""

  readonly property string planText: root.overview && root.overview.plan
    ? String(root.overview.plan).toUpperCase() : "PLAN UNKNOWN"
  readonly property string requestText: root.overview && root.overview.requests !== undefined && root.overview.requests !== null
    ? String(root.overview.requests) : "0"
  readonly property int keyCount: root.overview && root.overview.keys ? Number(root.overview.keys) : 0
  readonly property int accountCount: root.overview && root.overview.accounts ? Number(root.overview.accounts) : 0

  // Which keys feed this number. Several keys can share ONE Ollama account, in
  // which case usage is counted once (not summed) — hence "N keys · M account(s)".
  function keysText() {
    var o = root.overview
    if (!o || !o.keys) return ""
    var labels = []
    if (o.keyInfo) {
      for (var i = 0; i < o.keyInfo.length; i++) {
        if (o.keyInfo[i] && o.keyInfo[i].label) labels.push(String(o.keyInfo[i].label))
      }
    }
    var n = root.keyCount
    var accts = root.accountCount
    var head = n + (n === 1 ? " key" : " keys")
    if (accts > 0 && accts !== n) head += " \u00b7 " + accts + (accts === 1 ? " account" : " accounts")
    return labels.length > 0 ? head + ": " + labels.join(", ") : head
  }
  readonly property bool limitAlarming: root.limit ? (Number(root.limit.percent || 0) >= 90) === true : false
  readonly property bool limitKnown: root.limit !== null && root.limit !== undefined
  readonly property bool limitReached: root.limit ? (root.limit.reached === true || Number(root.limit.percent || 0) >= 100) : false
  readonly property string resetLabel: root.fmtReset(root.limit ? root.limit.resetAt : "")

  // With no known credit grant there is no dollar scale; show the meter itself.
  readonly property bool dollarsKnown: root.monthRec !== null && root.monthRec.cost !== null && root.monthRec.cost !== undefined

  function pct(frac) {
    return (Number(frac || 0) * 100).toFixed(1) + "%"
  }

  function fmtCost(v) {
    if (v === null || v === undefined) return "—"
    var n = Number(v || 0)
    if (n === 0) return "$0.00"
    if (n < 0.01) return "$" + n.toFixed(4)
    return "$" + n.toFixed(2)
  }

  function fmtReset(iso) {
    if (!iso) return ""
    var d = new Date(String(iso))
    if (isNaN(d.getTime())) return ""
    var M = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
             "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return M[d.getMonth()] + " " + d.getDate()
  }

  // Credit row: dollars when the grant is known, otherwise the raw fraction.
  function limitUsedText() {
    if (!root.limitKnown) return "—"
    if (root.dollarsKnown) return root.fmtCost(root.limit.used) + " / " + root.fmtCost(root.limit.amount)
    return root.pct(root.limit.usedFraction) + " of " + root.limit.amount.toFixed(0)
  }

  function limitRemainingText() {
    if (!root.limitKnown) return ""
    var tail = root.resetLabel !== "" ? "resets " + root.resetLabel : "resets at period end"
    if (root.dollarsKnown) return root.pct(root.limit.usedFraction) + " used · " + root.fmtCost(root.limit.remaining) + " left · " + tail
    return root.pct(root.limit.usedFraction) + " used · " + tail
  }

  function statusText() {
    if (root.err === "no-api-key")
      return "No Ollama key found — set OLLAMA_API_KEY (or ~/.config/ollama-cost/key)."
    if (root.err === "no-data")
      return "No data yet — run update.py once."
    if (root.err !== "")
      return "Ollama error: " + root.err
    if (!root.limitKnown)
      return "Credit grant unknown — set monthly_credits in ~/.config/ollama-cost/conf.json"
    if (root.limitReached)
      return "Included usage exhausted — requests are blocked until it resets "
             + (root.resetLabel !== "" ? "on " + root.resetLabel : "at the end of the period") + "."
    if (root.overview && root.overview.plan)
      return "Live from ollama.com · " + String(root.overview.plan).toUpperCase()
             + (root.resetLabel !== "" ? " · period resets " + root.resetLabel : "")
    return "Live from ollama.com/api/usage"
  }

  FileView {
    path: root.overviewPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.overview = null
  }

  function parse(content) {
    try {
      root.overview = JSON.parse(String(content || ""))
    } catch (e) {
      console.warn("ollama.cost", "bad overview", e)
      root.overview = null
    }
  }

  function refresh() {
    if (root.bar) root.bar.run(root.updater)
  }

  // A note on scale: the API reports the FRACTION of included credits used, not
  // dollars, so the meter is the only thing collected locally (see `meter` in
  // the record and `usedFraction` on the limit).
  Timer {
    interval: 60 * 1000
    running: root.opened === true
    repeat: true
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------------------ popup
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    contentWidth: Math.max(280, Math.min(360, panel.availableCardWidth))
    contentHeight: Math.max(120, col.implicitHeight + panel.verticalContentInset + 16)

    Flickable {
      id: scroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: col.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: col
        width: scroll.width
        spacing: 6

        // ---- header
        Row {
          width: parent.width
          spacing: 8
          Text {
            text: "Ollama Cost"
            font.family: root.fontFamily
            font.pixelSize: 13
            font.bold: true
            color: root.fg
          }
          Item { width: 100; height: 1 }
          Text {
            text: root.updatedText
            font.family: root.fontFamily
            font.pixelSize: 10
            color: root.dim
            verticalAlignment: Text.AlignVCenter
          }
        }

        // ---- included credits for the current month
        Rectangle { width: col.width; height: 2
          color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.25) }

        Item { width: col.width; height: 28; visible: root.limitKnown
          Text { text: "Monthly credits · " + root.planText
            font.family: root.fontFamily; font.pixelSize: 12; font.bold: true
            color: root.fg; anchors.verticalCenter: parent.verticalCenter }
          Text { text: root.limitUsedText()
            font.family: root.fontFamily; font.pixelSize: 11
            color: root.limitAlarming ? "tomato" : root.dim
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter }
        }
        Rectangle { width: col.width; height: 5; radius: 2; visible: root.limitKnown
          color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.2)
          Rectangle { width: parent.width * ((root.limitKnown ? Number(root.limit.percent || 0) : 0) / 100)
            height: parent.height; radius: 2
            color: root.limitAlarming ? "tomato" : root.accent }
        }
        Item { width: col.width; height: 24; visible: root.limitKnown
          Text { text: root.limitRemainingText()
            font.family: root.fontFamily; font.pixelSize: 10; color: root.dim
            anchors.verticalCenter: parent.verticalCenter }
        }

        // ---- which keys feed this number
        Item { width: col.width; height: 20; visible: root.keysText() !== ""
          Text { text: root.keysText()
            font.family: root.fontFamily; font.pixelSize: 10; color: root.dim
            elide: Text.ElideRight; width: parent.width
            anchors.verticalCenter: parent.verticalCenter } }

        // ---- requests for the current period
        Rectangle { width: col.width; height: 2
          color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.25) }
        Item { width: col.width; height: 26
          Text { text: "This period · " + root.requestText + " requests"
            font.family: root.fontFamily; font.pixelSize: 12; font.bold: true
            color: root.fg; anchors.verticalCenter: parent.verticalCenter } }

        // ---- status + actions
        Rectangle { width: col.width; height: 2
          color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.25) }
        Text { width: col.width; wrapMode: Text.WordWrap; font.family: root.fontFamily
          font.pixelSize: 10; color: root.dim; text: root.statusText() }

        Item { width: 1; height: 2 }
        Row {
          width: col.width; spacing: 8
          Rectangle {
            width: refreshLabel.implicitWidth + 16; height: 22; radius: 4
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.15)
            Text { id: refreshLabel; anchors.centerIn: parent
              text: "Refresh"; font.family: root.fontFamily; font.pixelSize: 11
              color: root.accent }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
              onClicked: root.refresh() }
          }
          Text { text: "Data: ollama.com/api/usage"; font.family: root.fontFamily
            font.pixelSize: 9; color: root.dim; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 90 }
        }
      }
    }
  }
}
