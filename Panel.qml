import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Omarchy Cleaner — bar widget + popup panel.
//
// The QML only renders state and launches the bundled CLI
// (bin/omarchy-cleaner). Every scan, clean and maintenance action goes through
// that CLI with --json, so what the panel does is exactly what a script or an
// agent can do from a terminal. The latest scan lives in
// ~/.local/state/omarchy-cleaner/last-scan.json and is watched here, so
// scans run from anywhere (terminal, timer, IPC) update the bar immediately.
//
// IPC (see README "Remote control"):
//   omarchy-shell io.github.momostifler96.omarchy-cleaner open|close|toggle
//   omarchy-shell io.github.momostifler96.omarchy-cleaner scan
//   omarchy-shell io.github.momostifler96.omarchy-cleaner cleanDefaults
//   omarchy-shell io.github.momostifler96.omarchy-cleaner status
Panel {
  id: root
  moduleName: "io.github.momostifler96.omarchy-cleaner"
  ipcTarget: "io.github.momostifler96.omarchy-cleaner"
  // This panel owns its IpcHandler so it can expose scan/clean methods too.
  manageIpc: false

  // ---- Paths -------------------------------------------------------------
  readonly property string cliPath: decodeURIComponent(Qt.resolvedUrl("bin/omarchy-cleaner").toString().replace(/^file:\/\//, ""))
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string scanFile: stateHome + "/omarchy-cleaner/last-scan.json"

  // ---- Settings (inline in shell.json, see manifest barWidget.schema) ----
  readonly property bool showSize: setting("showSize", false) === true
  readonly property real autoScanHours: Number(setting("autoScanHours", 6)) || 0

  // ---- State -------------------------------------------------------------
  property var scan: null              // parsed last-scan.json
  property var picked: ({})            // module id -> bool (user's choice in this session)
  property var expanded: ({})          // module id -> bool (item list shown)
  property bool scanning: false
  property bool cleaning: false
  property bool maintaining: false
  property string statusText: ""
  property string errorText: ""
  property bool confirmOpen: false

  readonly property bool busy: scanning || cleaning || maintaining
  readonly property var modules: scan && scan.modules ? scan.modules : []
  readonly property var tasks: [
    { id: "font-cache", title: "Font cache" },
    { id: "desktop-db", title: "Launchers" },
    { id: "dns-flush", title: "DNS cache" },
    { id: "trim", title: "Trim SSD" },
    { id: "locate-db", title: "Search index" }
  ]

  readonly property var pickedIds: {
    var out = []
    for (var i = 0; i < modules.length; i++) {
      var m = modules[i]
      if (m.available && m.mode !== "report" && isPicked(m) && (m.count > 0)) out.push(m.id)
    }
    return out
  }

  readonly property real pickedBytes: {
    var total = 0
    for (var i = 0; i < modules.length; i++) {
      var m = modules[i]
      if (pickedIds.indexOf(m.id) !== -1) total += Number(m.bytes || 0)
    }
    return total
  }

  readonly property bool pickedNeedsRoot: {
    for (var i = 0; i < modules.length; i++)
      if (pickedIds.indexOf(modules[i].id) !== -1 && modules[i].requiresRoot) return true
    return false
  }

  // ---- Helpers -----------------------------------------------------------
  function humanBytes(bytes) {
    var b = Number(bytes || 0)
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (b >= 1024 && i < units.length - 1) { b /= 1024; i++ }
    return (i === 0 ? String(Math.round(b)) : b.toFixed(b >= 100 ? 0 : 1)) + " " + units[i]
  }

  function ago(iso) {
    if (!iso) return "never"
    var seconds = Math.max(0, (Date.now() - Date.parse(iso)) / 1000)
    if (!isFinite(seconds)) return "unknown"
    if (seconds < 90) return "just now"
    if (seconds < 5400) return Math.round(seconds / 60) + " min ago"
    if (seconds < 129600) return Math.round(seconds / 3600) + " h ago"
    return Math.round(seconds / 86400) + " days ago"
  }

  function isPicked(m) {
    return picked[m.id] !== undefined ? picked[m.id] === true : m.selected === true
  }

  function togglePick(m) {
    if (!m.available || m.mode === "report" || busy) return
    var next = Object.assign({}, picked)
    next[m.id] = !isPicked(m)
    picked = next
  }

  function toggleExpanded(id) {
    var next = Object.assign({}, expanded)
    next[id] = !expanded[id]
    expanded = next
  }

  function applyScan(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      if (parsed && parsed.modules) scan = parsed
    } catch (e) {
      // A half-written file is replaced atomically by the CLI; ignore.
    }
  }

  function runScan() {
    if (busy) return
    errorText = ""
    statusText = "Scanning…"
    scanning = true
    scanProc.command = ["nice", "-n", "10", cliPath, "scan", "--json", "--quiet"]
    scanProc.running = true
  }

  function requestClean() {
    if (busy || pickedIds.length === 0) return
    confirmOpen = true
  }

  function runClean(ids) {
    if (busy || !ids || ids.length === 0) return
    confirmOpen = false
    errorText = ""
    statusText = pickedNeedsRoot ? "Cleaning… (authentication may be requested)" : "Cleaning…"
    cleaning = true
    cleanProc.command = [cliPath, "clean"].concat(ids).concat(["--yes", "--json", "--quiet"])
    cleanProc.running = true
  }

  function runTask(id) {
    if (busy) return
    errorText = ""
    statusText = "Running " + id + "…"
    maintaining = true
    taskProc.command = [cliPath, "maintain", id, "--yes", "--json", "--quiet"]
    taskProc.running = true
  }

  function trashItem(path) {
    if (busy || !path) return
    errorText = ""
    statusText = "Moving to Trash…"
    maintaining = true
    taskProc.command = [cliPath, "trash", path, "--yes", "--json", "--quiet"]
    taskProc.running = true
  }

  function openLocation(path) {
    if (!path || path.charAt(0) !== "/") return
    var dir = path.replace(/\/[^\/]*$/, "") || "/"
    Quickshell.execDetached(["xdg-open", dir])
  }

  function parseResult(text, fallback) {
    try { return JSON.parse(String(text || "").trim().split("\n").pop()) } catch (e) { return fallback }
  }

  // ---- IPC (remote control) ---------------------------------------------
  IpcHandler {
    target: "io.github.momostifler96.omarchy-cleaner"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function scan(): void { root.runScan() }
    function cleanDefaults(): void {
      var ids = []
      for (var i = 0; i < root.modules.length; i++) {
        var m = root.modules[i]
        if (m.available && m.selected && m.mode !== "report" && m.count > 0) ids.push(m.id)
      }
      root.runClean(ids)
    }
    function status(): string {
      return JSON.stringify({
        busy: root.busy,
        status: root.statusText,
        error: root.errorText,
        generatedAt: root.scan ? root.scan.generatedAt : null,
        totalBytes: root.scan ? root.scan.totalBytes : 0,
        selectedBytes: root.scan ? root.scan.selectedBytes : 0
      })
    }
  }

  // ---- Data sources ------------------------------------------------------
  FileView {
    path: root.scanFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyScan(text())
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.parseResult(text, null)
        if (result && result.modules) root.scan = result
      }
    }
    onExited: function(exitCode) {
      root.scanning = false
      root.statusText = ""
      if (exitCode !== 0) root.errorText = "Scan failed (exit " + exitCode + ")"
    }
  }

  Process {
    id: cleanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.parseResult(text, null)
        if (!result) return
        if (result.error) root.errorText = result.error
        else root.statusText = "Freed about " + root.humanBytes(result.freedBytes)
          + (result.ok ? "" : " · some items failed")
      }
    }
    onExited: function(exitCode) {
      root.cleaning = false
      root.picked = ({})
      if (exitCode === 3) root.errorText = "Cleaning was not confirmed"
      else if (exitCode !== 0 && exitCode !== 4 && root.errorText === "") root.errorText = "Clean failed (exit " + exitCode + ")"
      statusClear.restart()
    }
  }

  Process {
    id: taskProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.parseResult(text, null)
        if (!result) return
        if (result.error) root.errorText = result.error
        else root.statusText = result.ok ? "Done" : "Finished with errors"
      }
    }
    onExited: function(exitCode) {
      root.maintaining = false
      if (exitCode !== 0 && root.errorText === "") root.errorText = "Action failed (exit " + exitCode + ")"
      statusClear.restart()
    }
  }

  Timer { id: statusClear; interval: 6000; onTriggered: if (!root.busy) root.statusText = "" }

  // Background scan: only when the cached scan is older than the interval.
  Timer {
    interval: 600000
    running: root.autoScanHours > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var age = root.scan && root.scan.generatedAt ? (Date.now() - Date.parse(root.scan.generatedAt)) : Infinity
      if (age > root.autoScanHours * 3600000) root.runScan()
    }
  }

  onOpenedChanged: if (opened) { confirmOpen = false; errorText = ""; if (!scan) runScan() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Bar button --------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-broom
    text: (root.showSize && !vertical && root.scan && root.scan.selectedBytes > 0)
      ? root.humanBytes(root.scan.selectedBytes) + " 󰃢"
      : "󰃢"
    slotSize: Style.bar.iconSlot * ((root.showSize && !vertical && root.scan && root.scan.selectedBytes > 0) ? 2.6 : 1)
    tooltipText: root.busy ? root.statusText
      : (root.scan ? root.humanBytes(root.scan.selectedBytes) + " can be freed" : "Cleaner")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.runScan()
      else root.toggle()
    }
  }

  // ---- Popup panel -------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.confirmOpen ? (root.confirmOpen = false) : root.close()
      onActivateRequested: if (root.confirmOpen) root.runClean(root.pickedIds)
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroSize.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰃢"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroSize.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Cleaner"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: (root.busy ? root.statusText
                : (root.scan ? "Scanned " + root.ago(root.scan.generatedAt) + " · " + root.humanBytes(root.scan.totalBytes) + " found" : "Not scanned yet")).toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroSize
            textFormat: Text.PlainText
            text: root.scan ? root.humanBytes(root.pickedBytes) : "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Modules ----------
        PanelSeparator { foreground: root.bar.foreground }

        PanelSectionHeader {
          text: "WHAT TO CLEAN"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Flickable {
          id: moduleScroll
          width: parent.width
          height: Math.min(moduleList.implicitHeight, Style.space(420))
          contentHeight: moduleList.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: moduleList
            width: moduleScroll.width
            spacing: Style.space(4)

            Text {
              visible: root.modules.length === 0
              text: root.scanning ? "Looking for reclaimable space…" : "Right-click the bar icon or press Rescan."
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.modules

              Column {
                id: moduleRow
                required property var modelData
                width: moduleList.width
                spacing: Style.space(2)
                opacity: modelData.available ? 1 : 0.45

                readonly property bool reviewOnly: modelData.mode === "report"

                Item {
                  width: parent.width
                  implicitHeight: Math.max(check.implicitHeight, rowText.implicitHeight) + Style.space(6)

                  Text {
                    id: check
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    // nf-md-checkbox_marked / checkbox_blank_outline / magnify
                    text: moduleRow.reviewOnly ? "󰍉"
                      : (root.isPicked(moduleRow.modelData) && moduleRow.modelData.available ? "󰄲" : "󰄱")
                    color: root.isPicked(moduleRow.modelData) && !moduleRow.reviewOnly ? Color.accent : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                  }

                  Column {
                    id: rowText
                    anchors.left: check.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: sizeText.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      textFormat: Text.PlainText
                      text: moduleRow.modelData.title
                        + (moduleRow.modelData.requiresRoot ? "  " : "")
                        + (moduleRow.modelData.risk === "high" ? "  · review" : (moduleRow.modelData.risk === "medium" ? "  · check first" : ""))
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                      width: parent.width
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: moduleRow.modelData.available ? moduleRow.modelData.description : moduleRow.modelData.reason
                      color: root.bar.foreground
                      opacity: 0.6
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                      maximumLineCount: 2
                      elide: Text.ElideRight
                      width: parent.width
                    }
                  }

                  Text {
                    id: sizeText
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: !moduleRow.modelData.available ? "n/a"
                      : (moduleRow.modelData.count === 0 ? "clean"
                      : (moduleRow.modelData.bytes > 0 ? root.humanBytes(moduleRow.modelData.bytes) : "size ?"))
                    color: root.bar.foreground
                    opacity: moduleRow.modelData.count > 0 ? 1 : 0.5
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: moduleRow.modelData.available ? Qt.PointingHandCursor : Qt.ArrowCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: function(mouse) {
                      if (!moduleRow.modelData.available) return
                      if (moduleRow.reviewOnly || mouse.button === Qt.RightButton) root.toggleExpanded(moduleRow.modelData.id)
                      else root.togglePick(moduleRow.modelData)
                    }
                  }
                }

                // Item preview (largest first). Review-only modules get
                // per-item "move to Trash" and "open folder" actions.
                Column {
                  visible: root.expanded[moduleRow.modelData.id] === true && moduleRow.modelData.items.length > 0
                  width: parent.width - Style.space(30)
                  x: Style.space(30)
                  spacing: Style.space(2)

                  Repeater {
                    model: moduleRow.modelData.items

                    Item {
                      required property var modelData
                      width: parent.width
                      implicitHeight: Math.max(itemLabel.implicitHeight, Style.space(22))

                      Text {
                        id: itemLabel
                        textFormat: Text.PlainText
                        anchors.left: parent.left
                        anchors.right: itemSize.left
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: root.bar.foreground
                        opacity: 0.75
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                      }

                      Text {
                        id: itemSize
                        textFormat: Text.PlainText
                        anchors.right: itemActions.left
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.humanBytes(modelData.bytes)
                        color: root.bar.foreground
                        opacity: 0.75
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Row {
                        id: itemActions
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(2)
                        visible: moduleRow.reviewOnly

                        PanelActionButton {
                          iconText: ""
                          tooltipText: "Open folder"
                          foreground: root.bar.foreground
                          fontFamily: root.bar.fontFamily
                          fontSize: Style.font.bodySmall
                          onClicked: root.openLocation(modelData.path)
                        }

                        PanelActionButton {
                          iconText: ""
                          tooltipText: "Move to Trash"
                          foreground: root.bar.foreground
                          fontFamily: root.bar.fontFamily
                          fontSize: Style.font.bodySmall
                          enabled: !root.busy
                          onClicked: root.trashItem(modelData.path)
                        }
                      }
                    }
                  }

                  Text {
                    visible: moduleRow.modelData.count > moduleRow.modelData.items.length
                    textFormat: Text.PlainText
                    text: "+ " + (moduleRow.modelData.count - moduleRow.modelData.items.length)
                      + " more · omarchy-cleaner scan " + moduleRow.modelData.id + " --details"
                    color: root.bar.foreground
                    opacity: 0.5
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }

        // ---------- Actions ----------
        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing) * 0.35
            text: root.scanning ? "Scanning…" : "Rescan"
            iconText: ""
            iconSpinning: root.scanning
            bordered: true
            enabled: !root.busy
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.runScan()
          }

          Button {
            width: (parent.width - parent.spacing) * 0.65
            text: root.cleaning ? "Cleaning…"
              : (root.pickedIds.length > 0 ? "Clean " + root.humanBytes(root.pickedBytes) : "Nothing selected")
            iconText: "󰃢"
            bordered: true
            active: root.pickedIds.length > 0 && !root.busy
            enabled: root.pickedIds.length > 0 && !root.busy
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.requestClean()
          }
        }

        // ---------- Maintenance ----------
        PanelSeparator { foreground: root.bar.foreground }

        PanelSectionHeader {
          text: "MAINTENANCE"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.tasks

            Button {
              required property var modelData
              text: modelData.title
              bordered: true
              enabled: !root.busy
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              onClicked: root.runTask(modelData.id)
            }
          }
        }

        Text {
          visible: root.errorText !== "" || (root.statusText !== "" && !root.busy)
          width: parent.width
          textFormat: Text.PlainText
          text: root.errorText !== "" ? "  " + root.errorText : root.statusText
          color: root.errorText !== "" ? root.bar.urgent : root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.confirmOpen
        message: "Clean " + root.pickedIds.length + " categor" + (root.pickedIds.length > 1 ? "ies" : "y")
          + " (about " + root.humanBytes(root.pickedBytes) + ")?"
          + (root.pickedNeedsRoot ? "\nSystem items will ask for your password." : "")
        confirmText: "Clean"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onCanceled: root.confirmOpen = false
        onConfirmed: root.runClean(root.pickedIds)
      }
    }
  }
}
