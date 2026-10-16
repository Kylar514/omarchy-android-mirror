pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui as Ui
import "Model.js" as Model

// Bar icon + panel for mirroring an Android phone with scrcpy.
//
// Left click: open the panel. Right click: mirror the first ready phone (or
// stop the running mirror). Middle click: refresh the device list.
Ui.Panel {
  id: root
  moduleName: "omarchy-android-mirror"
  ipcTarget: "omarchy-android-mirror"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var devices: Model.withSavedNames(backend.devices, backend.saved)
  readonly property var readyDevices: devices.filter(function(d) { return d.ready })
  readonly property var usbDevices: readyDevices.filter(function(d) { return d.transport === "usb" })
  readonly property string stateLabel: Model.stateLabel(devices, backend.mirroring)

  property int cursor: 0
  property bool showPairing: false
  property bool showKeys: false
  // Inline name editor shared by "save this device" and "rename a saved one".
  property string nameMode: ""      // "" | "save" | "rename"
  property var nameTarget: null     // device (save) or saved index (rename)
  property string nameDraft: ""
  property string pairEndpoint: ""
  property string pairCode: ""
  property string connectEndpoint: ""
  property double nowMs: Date.now()

  implicitWidth: iconButton.implicitWidth
  implicitHeight: iconButton.implicitHeight

  function refreshNow() { backend.refresh() }

  // Every keyboard stop in panel order: a row per device, then the Wi-Fi
  // controls. j/k walk this list; enter acts on the stop under the cursor.
  readonly property var stops: {
    if (backend.toolsMissing) return ["install"]
    var s = []
    for (var i = 0; i < devices.length; i++) s.push("dev:" + i)
    for (var j = 0; j < backend.saved.length; j++) s.push("saved:" + j)
    s.push("connect", "pairToggle")
    if (showPairing) s.push("pairAddr", "pairCode", "pairGo")
    return s
  }
  readonly property int cur: Math.max(0, Math.min(cursor, stops.length - 1))
  readonly property string stop: stops[cur]

  function goTo(name) {
    var i = stops.indexOf(name)
    if (i >= 0) cursor = i
  }

  function note(message, ok) {
    backend.actionOk = ok
    backend.actionMessage = message
  }

  function savedAtCursor() {
    return stop.indexOf("saved:") === 0 ? backend.saved[parseInt(stop.slice(6), 10)] : null
  }

  function startNaming(mode, target, draft) {
    nameMode = mode
    nameTarget = target
    nameDraft = draft
    Qt.callLater(function() { nameField.forceActiveFocus(); nameField.selectAll() })
  }

  function cancelNaming() {
    nameMode = ""
    keyCatcher.forceActiveFocus()
  }

  function commitName() {
    var name = nameDraft.trim()
    if (nameMode === "save") {
      var ep = Model.parseEndpoint(nameTarget.serial, 0)
      if (ep && backend.saveDevice(name, ep.host, ep.port)) note("Saved " + (name || ep.host), true)
      else note("Only Wi-Fi devices with an IPv4 address can be saved", false)
    } else if (nameMode === "rename") {
      backend.renameSaved(nameTarget, name)
    }
    cancelNaming()
  }

  function saveCursorDevice() {
    var d = stop.indexOf("dev:") === 0 ? devices[parseInt(stop.slice(4), 10)] : null
    var ep = d ? Model.parseEndpoint(d.serial, 0) : null
    if (!d || !d.ready || d.transport !== "wifi" || !ep) { note("s saves a connected Wi-Fi device", false); return }
    startNaming("save", d, d.model || ep.host)
  }

  function cursorDevice() {
    return stop.indexOf("dev:") === 0 ? devices[parseInt(stop.slice(4), 10)] : readyDevices[0]
  }

  function toggleMirror(d) {
    if (backend.mirroring) { backend.stopMirror(); return }
    if (d && d.ready) backend.mirror(d)
  }

  function mirrorSelected() { toggleMirror(cursorDevice()) }

  function goHome() {
    var d = backend.mirroring || cursorDevice()
    if (d && d.ready) { backend.goHome(d); note("Home sent to " + Model.deviceTitle(d), true) }
    else note("No ready device for Home", false)
  }

  function editField(field) {
    field.forceActiveFocus()
  }

  function activate() {
    switch (stop) {
    case "install": backend.installTools(); break
    case "connect": editField(connectField); break
    case "pairToggle": showPairing = !showPairing; break
    case "pairAddr": editField(pairEndpointField); break
    case "pairCode": editField(pairCodeField); break
    case "pairGo": backend.pair(pairEndpoint, pairCode); break
    default:
      var entry = savedAtCursor()
      if (entry) { backend.reconnect(entry); break }
      var d = cursorDevice()
      if (d && !d.ready) note(Model.stateHint(d.state), false)
      else mirrorSelected()
    }
  }

  function togglePairing() {
    showPairing = !showPairing
    if (!showPairing) return
    goTo("pairAddr")
    Qt.callLater(function() { pairEndpointField.forceActiveFocus() })
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.RightButton) { toggleMirror(readyDevices[0]); return }
    if (buttonCode === Qt.MiddleButton) { refreshNow(); return }
    toggle()
  }

  function moveCursor(delta) {
    cursor = (cur + delta + stops.length) % stops.length
  }

  MirrorBackend {
    id: backend
    settings: root.settings
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    // omarchy-shell shell ipc omarchy-android-mirror mirror
    function mirror(): string {
      if (root.readyDevices.length === 0) return "no device"
      root.toggleMirror(root.readyDevices[0])
      return "ok"
    }
    function stop(): string { backend.stopMirror(); return "ok" }
    function install(): string { backend.installTools(); return "ok" }
  }

  Ui.BarIconButton {
    id: iconButton
    anchors.fill: parent
    bar: root.bar
    text: "󰀲"
    active: backend.mirroring !== null
    tooltipText: "Android · " + root.stateLabel
    onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: iconButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    centerOnBar: true
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)
    gap: Math.max(0, Math.round((panel.screenH - panel.contentHeight) / 2 - panel.barH))

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (pairEndpointField.visible && pairEndpointField.activeFocus)
        || (pairCodeField.visible && pairCodeField.activeFocus)
        || (connectField.visible && connectField.activeFocus)
        || (nameField.visible && nameField.activeFocus)

      onActivateRequested: root.activate()
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onDeleteRequested: {
        var entry = root.savedAtCursor()
        if (entry) { backend.forgetSaved(root.cur - root.devices.length); root.note("Forgot " + entry.name, true); return }
        var d = root.cursorDevice()
        if (d && d.transport === "wifi") backend.disconnect(d.serial)
        else root.note("x disconnects a Wi-Fi device", false)
      }
      onTextKey: function(text) {
        if (text === "r") root.refreshNow()
        else if (text === "p") root.togglePairing()
        else if (text === "H") root.goHome()
        else if (text === "s") root.saveCursorDevice()
        else if (text === "c") backend.cancelAction()
        else if (text === "e") {
          var entry = root.savedAtCursor()
          if (entry) root.startNaming("rename", root.cur - root.devices.length, entry.name)
          else root.note("e renames a saved device", false)
        }
        else if (text === "?") root.showKeys = !root.showKeys
        else if (text === "/") { root.goTo("connect"); root.editField(connectField) }
        else if (text === "i") {
          if (root.stop === "connect") root.editField(connectField)
          else if (root.stop === "pairAddr") root.editField(pairEndpointField)
          else if (root.stop === "pairCode") root.editField(pairCodeField)
        }
        else if (text === "w") {
          if (root.usbDevices.length > 0) backend.enableWifi(root.usbDevices[0].serial)
          else root.note("w needs a USB-connected phone", false)
        }
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.spacing.lg

        Ui.PanelHero {
          width: parent.width
          foreground: root.foreground
          fontFamily: root.fontFamily
          title: "Android Mirror"
          meta: root.stateLabel
          detail: backend.mirroring ? "live" : ""
          iconComponent: Component {
            Text {
              text: "󰀲"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // Missing tools: the one thing fixed by a pacman command.
        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: backend.toolsMissing

          Text {
            width: parent.width
            text: (backend.adbMissing && backend.scrcpyMissing) ? "adb and scrcpy are not installed"
              : backend.adbMissing ? "adb is not installed" : "scrcpy is not installed"
            color: root.urgent
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.weight: Font.Medium
          }
          Ui.Button {
            text: backend.installLaunched ? "Install again" : "Install"
            iconText: "󰏔"
            bordered: true
            hasCursor: root.stop === "install"
            foreground: root.foreground
            fontFamily: root.fontFamily
            tooltipText: "Opens a terminal and asks for your password"
            onClicked: backend.installTools()
          }

          Text {
            width: parent.width
            text: "omarchy pkg add scrcpy android-tools android-udev\nOr point 'adb path' / 'scrcpy path' in the widget settings at your own binaries."
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Devices, one row each. Ready ones get a Mirror button.
        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: !backend.toolsMissing

          Ui.PanelSectionHeader {
            width: parent.width
            text: "Phones"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.devices.length === 0
            text: backend.loading && backend.lastSuccessAt <= 0 ? "Looking for phones…"
              : "Plug in a phone with USB debugging on, or connect over Wi-Fi below."
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.devices

            delegate: Item {
              id: row
              required property var modelData
              required property int index
              readonly property bool isMirroring: backend.mirroring && backend.mirroring.serial === modelData.serial
              readonly property bool selected: root.stop === "dev:" + index
              width: parent ? parent.width : 0
              height: rowText.implicitHeight + Style.spacing.sm

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: row.selected ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
              }

              Column {
                id: rowText
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.xs
                anchors.right: rowActions.left
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  width: parent.width
                  text: Model.deviceTitle(row.modelData)
                  color: row.modelData.ready ? root.foreground : root.dim
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.weight: Font.Medium
                }
                Text {
                  width: parent.width
                  text: Model.deviceSubtitle(row.modelData)
                  color: row.modelData.ready ? root.dim : root.urgent
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                id: rowActions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xs

                Ui.PanelActionButton {
                  visible: row.modelData.ready && row.modelData.transport === "usb"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  iconText: "󰖩"
                  tooltipText: "Enable Wi-Fi mirroring for this phone (adb tcpip), then unplug"
                  enabled: !backend.actionBusy
                  onClicked: backend.enableWifi(row.modelData.serial)
                }
                Ui.PanelActionButton {
                  visible: row.modelData.transport === "wifi"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  iconText: "󰅖"
                  tooltipText: "Disconnect"
                  enabled: !backend.actionBusy
                  onClicked: backend.disconnect(row.modelData.serial)
                }
                Ui.Button {
                  visible: row.modelData.ready
                  text: row.isMirroring ? "Stop" : "Mirror"
                  iconText: row.isMirroring ? "󰓛" : "󰐊"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: row.isMirroring ? backend.stopMirror() : backend.mirror(row.modelData)
                }
              }

              MouseArea {
                anchors.fill: parent
                anchors.rightMargin: rowActions.width
                onClicked: root.cursor = row.index
                onDoubleClicked: if (row.modelData.ready) backend.mirror(row.modelData)
              }
            }
          }
        }

        // Saved devices: pick one and the plugin finds its current port.
        Column {
          width: parent.width
          spacing: Style.spacing.xs
          visible: !backend.toolsMissing && (backend.saved.length > 0 || root.nameMode !== "")

          Ui.PanelSectionHeader {
            width: parent.width
            text: "Saved"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: backend.saved

            delegate: Item {
              id: savedRow
              required property var modelData
              required property int index
              readonly property bool selected: root.stop === "saved:" + index
              width: parent ? parent.width : 0
              height: savedText.implicitHeight + Style.spacing.sm

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: savedRow.selected ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
              }

              Column {
                id: savedText
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.xs
                anchors.right: reconnectButton.left
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  width: parent.width
                  text: savedRow.modelData.name
                  color: root.foreground
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.weight: Font.Medium
                }
                Text {
                  width: parent.width
                  text: savedRow.modelData.ip + (savedRow.modelData.lastPort > 0 ? " · last port " + savedRow.modelData.lastPort : " · port unknown")
                  color: root.dim
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Ui.Button {
                id: reconnectButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Reconnect"
                iconText: "󰑐"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !backend.actionBusy
                onClicked: backend.reconnect(savedRow.modelData)
              }

              MouseArea {
                anchors.fill: parent
                anchors.rightMargin: reconnectButton.width
                onClicked: root.cursor = root.devices.length + savedRow.index
                onDoubleClicked: backend.reconnect(savedRow.modelData)
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.nameMode !== ""
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.nameMode === "save" ? "Save as" : "Rename"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Ui.TextField {
              id: nameField
              width: parent.width - parent.spacing - 64
              placeholderText: "Name"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: root.nameDraft
              onTextChanged: if (text !== root.nameDraft) root.nameDraft = text
              onAccepted: root.commitName()
              Keys.onEscapePressed: root.cancelNaming()
            }
          }
        }

        // Wi-Fi: connect to a known address, or pair an Android 11+ phone
        // with the code from Wireless debugging (no cable ever needed).
        Column {
          width: parent.width
          spacing: Style.spacing.sm
          visible: !backend.toolsMissing

          Ui.PanelSectionHeader {
            width: parent.width
            text: "Wi-Fi"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm
            Ui.TextField {
              id: connectField
              width: parent.width - connectButton.width - parent.spacing
              placeholderText: "192.168.1.42:5555"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              enabled: !backend.actionBusy
              text: root.connectEndpoint
              onTextChanged: if (text !== root.connectEndpoint) root.connectEndpoint = text
              hasCursor: root.stop === "connect"
              onActiveFocusChanged: if (activeFocus) root.goTo("connect")
              onAccepted: { backend.connect(root.connectEndpoint); keyCatcher.forceActiveFocus() }
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }
            Ui.Button {
              id: connectButton
              text: "Connect"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.connectEndpoint.trim() !== "" && !backend.actionBusy
              onClicked: backend.connect(root.connectEndpoint)
            }
          }

          Ui.Button {
            text: root.showPairing ? "Hide pairing" : "Pair a new phone (Android 11+)"
            iconText: "󰌆"
            hasCursor: root.stop === "pairToggle"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.showPairing = !root.showPairing
          }

          Column {
            width: parent.width
            spacing: Style.spacing.xs
            visible: root.showPairing

            Text {
              width: parent.width
              text: "On the phone: Settings → Developer options → Wireless debugging → Pair device with pairing code. Enter what it shows."
              color: root.dim
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Row {
              width: parent.width
              spacing: Style.spacing.sm
              Ui.TextField {
                id: pairEndpointField
                width: (parent.width - parent.spacing * 2) * 0.55
                placeholderText: "192.168.1.42:37123"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                enabled: !backend.actionBusy
                text: root.pairEndpoint
                onTextChanged: if (text !== root.pairEndpoint) root.pairEndpoint = text
                hasCursor: root.stop === "pairAddr"
                onActiveFocusChanged: if (activeFocus) root.goTo("pairAddr")
                onAccepted: pairCodeField.forceActiveFocus()
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }
              Ui.TextField {
                id: pairCodeField
                width: (parent.width - parent.spacing * 2) * 0.25
                placeholderText: "123456"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                enabled: !backend.actionBusy
                text: root.pairCode
                onTextChanged: if (text !== root.pairCode) root.pairCode = text
                hasCursor: root.stop === "pairCode"
                onActiveFocusChanged: if (activeFocus) root.goTo("pairCode")
                onAccepted: { backend.pair(root.pairEndpoint, root.pairCode); keyCatcher.forceActiveFocus() }
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }
              Ui.Button {
                text: "Pair"
                bordered: true
                hasCursor: root.stop === "pairGo"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.pairEndpoint.trim() !== "" && root.pairCode.trim() !== "" && !backend.actionBusy
                onClicked: backend.pair(root.pairEndpoint, root.pairCode)
              }
            }
          }
        }

        // Feedback from the last action or the mirror process.
        Text {
          width: parent.width
          visible: text !== ""
          text: {
            if (backend.actionBusy) return (backend.actionLabel !== "" ? backend.actionLabel : "Running adb " + backend.actionName + "…") + "  (c cancels)"
            if (backend.actionMessage !== "") return backend.actionMessage
            if (backend.mirrorError !== "") return backend.mirrorError
            if (backend.fetchError !== "") return backend.fetchError
            return ""
          }
          color: backend.actionBusy ? root.foreground : ((backend.actionOk && backend.mirrorError === "" && backend.fetchError === "") ? Color.accent : root.urgent)
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: root.showKeys
          text: "Panel: j/k move · enter act (mirror / reconnect) · / connect · i edit field · esc back/close\n"
            + "  s save device · e rename saved · x disconnect / forget · c cancel · p pairing · w Wi-Fi (USB phone)\n"
            + "  H home · r refresh · ? this list\n"
            + "Mirror window: Alt+H home · Alt+B back · Alt+S app switch · Alt+P power · Alt+↑/↓ volume\n"
            + "Global: Super+Alt+A open this panel"
          color: root.dim
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Ui.PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        Item {
          width: parent.width
          height: Math.max(footerText.implicitHeight, footerActions.implicitHeight)

          Text {
            id: footerText
            anchors.left: parent.left
            anchors.right: footerActions.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              if (backend.lastSuccessAt <= 0) return backend.loading ? "Checking…" : "Not checked yet"
              return "Updated " + Model.elapsed(backend.lastSuccessAt, root.nowMs) + "  ·  j/k · enter · / · H · ? help"
            }
          }

          Row {
            id: footerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Ui.PanelActionButton {
              visible: backend.mirroring !== null
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconText: "󰓛"
              tooltipText: "Stop mirroring"
              onClicked: backend.stopMirror()
            }
            Ui.PanelActionButton {
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconText: "󰑐"
              tooltipText: "Refresh now"
              onClicked: root.refreshNow()
            }
          }
        }
      }
    }
  }

  onOpenedChanged: {
    nowMs = Date.now()
    if (opened) {
      refreshNow()
      backend.actionMessage = ""
    }
  }
}
