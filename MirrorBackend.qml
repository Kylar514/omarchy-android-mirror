pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Process boundary for the panel. Nothing here does anything you could not
// type yourself: `adb devices -l` to list, `adb tcpip` / `adb connect` /
// `adb pair` for Wi-Fi, and one long-lived `scrcpy -s <serial>` for the
// mirror window. Binaries run by absolute path (default or configured), never
// by PATH lookup, because a shell plugin runs unsandboxed as the user.
Item {
  id: root
  visible: false

  property var settings: ({})

  // --- state the panel reads ---------------------------------------------
  property var devices: []
  property bool loading: false
  property string fetchError: ""
  property double lastSuccessAt: 0

  property bool adbMissing: false
  property bool scrcpyMissing: false
  readonly property bool toolsMissing: adbMissing || scrcpyMissing

  // One adb action at a time (pair / connect / tcpip / disconnect).
  property bool actionBusy: false
  property string actionName: ""
  property string actionLabel: ""
  property string actionMessage: ""
  property bool actionOk: true

  // The device being mirrored, or null. scrcpy owns the window; when the
  // user closes it the process exits and this clears.
  property var mirroring: null
  property string mirrorError: ""

  readonly property int refreshIntervalSec: Math.round(Model.clamp(setting("refreshIntervalSec", 10), 3, 300))
  readonly property string adbPath: String(setting("adbPath", "")).trim() || Model.DEFAULT_ADB
  readonly property string scrcpyPath: String(setting("scrcpyPath", "")).trim() || Model.DEFAULT_SCRCPY

  signal refreshed()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // --- tool presence --------------------------------------------------------
  // Re-checked whenever the configured path changes, and on every refresh
  // while a tool is reported missing so installing it heals the panel.
  onAdbPathChanged: checkTools()
  onScrcpyPathChanged: checkTools()
  Component.onCompleted: { checkTools(); loadProc.running = true }

  function checkTools() { toolCheck.running = true }

  // The adb actually used: the configured one, else /usr/bin/adb, else the
  // Android SDK's platform-tools copy (Android Studio users have that one).
  property string resolvedAdb: ""

  Process {
    id: toolCheck
    command: ["/usr/bin/sh", "-c",
      "adb=''; for c in \"$1\" \"$3\"; do [ -n \"$c\" ] && [ -x \"$c\" ] && { adb=$c; break; }; done; " +
      "test -x \"$2\"; s=$?; printf '%s\\t%s\\n' \"$adb\" \"$s\"",
      "_", root.adbPath, root.scrcpyPath, Model.SDK_ADB.replace("~", Quickshell.env("HOME"))]
    stdout: StdioCollector {
      onStreamFinished: {
        var parts = String(text).trim().split("\t")
        root.resolvedAdb = parts[0] || ""
        root.adbMissing = root.resolvedAdb === ""
        root.scrcpyMissing = parts[1] !== "0"
        if (root.adbMissing) root.loading = false
        else root.refresh()
      }
    }
  }

  // While something is missing, re-check every few seconds so the panel
  // heals itself as soon as the install terminal finishes.
  Timer {
    interval: 3000
    running: root.toolsMissing
    repeat: true
    onTriggered: root.checkTools()
  }

  // --- install -------------------------------------------------------------
  property bool installLaunched: false

  function installTools() {
    if (installProc.running) return
    installLaunched = true
    installProc.running = true
  }

  Process {
    id: installProc
    command: ["/usr/bin/omarchy-launch-floating-terminal-with-presentation",
      "omarchy pkg add scrcpy android-tools android-udev"]
    onExited: root.checkTools()
  }

  // --- device list ------------------------------------------------------------
  function refresh() {
    if (devicesProc.running) return
    // Nothing to poll without adb; re-check so installing it heals the panel.
    if (adbMissing) { checkTools(); return }
    loading = true
    devicesProc.running = true
  }

  Process {
    id: devicesProc
    command: [root.resolvedAdb, "devices", "-l"]
    stdout: StdioCollector { id: devicesOut }
    stderr: StdioCollector { id: devicesErr }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0) {
        root.fetchError = String(devicesErr.text || "").trim() || ("adb devices exited " + exitCode)
        return
      }
      root.fetchError = ""
      root.devices = Model.parseDevices(devicesOut.text)
      root.lastSuccessAt = Date.now()
      root.refreshed()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: !root.adbMissing
    repeat: true
    onTriggered: root.refresh()
  }

  // --- one-shot adb actions -------------------------------------------------
  // `steps` is a queue of {name, args, stdin?, onDone(stdout, stderr, code) -> bool}
  // so "enable Wi-Fi" can chain tcpip → ip lookup → connect. `stdin` is a
  // line written to the process once it starts, for input that must not be
  // on the command line.
  property var steps: []
  property var stepOut: ({})

  function runSteps(name, list) {
    if (actionBusy) return
    actionBusy = true
    actionOk = true
    actionName = name
    actionLabel = ""
    actionMessage = ""
    steps = list
    stepOut = {}
    nextStep()
  }

  function nextStep() {
    if (steps.length === 0) {
      actionBusy = false
      actionName = ""
      actionLabel = ""
      refresh()
      return
    }
    var step = steps[0]
    if (step.label) actionLabel = step.label
    // A step runs adb, or any other absolute-path command given as `cmd`.
    // args may be a function so a later step can use what an earlier one found.
    var args = typeof step.args === "function" ? step.args() : step.args
    actionProc.command = step.cmd ? step.cmd : [root.resolvedAdb].concat(args)
    actionProc.secret = step.stdin || ""
    actionProc.stdinEnabled = actionProc.secret !== ""
    actionProc.running = true
  }

  function cancelAction() {
    if (!actionBusy) return
    steps = []
    retryTimer.stop()
    if (actionProc.running) actionProc.signal(15)
    actionBusy = false
    actionName = ""
    actionLabel = ""
    actionOk = false
    actionMessage = "Cancelled"
  }

  function finishSteps(ok, message) {
    steps = []
    actionOk = ok
    actionMessage = message
    nextStep()
  }

  Process {
    id: actionProc
    // Written to stdin on start and dropped; never stored, logged or shown.
    property string secret: ""
    stdout: StdioCollector { id: actionOut }
    stderr: StdioCollector { id: actionErr }
    onStarted: {
      if (secret !== "") write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      var step = root.steps[0]
      if (!step) return
      var verdict = step.onDone(String(actionOut.text || ""), String(actionErr.text || ""), exitCode)
      if (verdict === "retry" && step.retries > 0) {
        step.retries -= 1
        retryTimer.interval = step.retryDelayMs || 500
        retryTimer.start()
        return
      }
      root.steps = root.steps.slice(1)
      if (verdict === "retry") root.finishSteps(false, "The phone did not come back after switching adb to TCP. Replug it and try again.")
      else if (verdict !== false) root.nextStep()
    }
  }

  Timer {
    id: retryTimer
    repeat: false
    onTriggered: root.nextStep()
  }

  // Android 11+ wireless debugging: phone shows an ip:port + 6-digit code
  // under Developer options → Wireless debugging → Pair device with code.
  // The code answers adb's "Enter pairing code:" prompt over stdin; argv is
  // world-readable in /proc, a private pipe is not.
  function pair(endpointText, code) {
    var ep = Model.parseEndpoint(endpointText, 0)
    var c = String(code || "").trim()
    if (!ep) { actionOk = false; actionMessage = "Enter the pairing address as ip:port"; return }
    if (!/^\d{6}$/.test(c)) { actionOk = false; actionMessage = "Pairing code is 6 digits"; return }
    runSteps("pair", [{
      args: ["pair", ep.address],
      stdin: c,
      onDone: function(out, err, code) {
        var v = Model.pairVerdict(out, err, code)
        root.finishSteps(v.ok, v.message)
        return false
      }
    }])
  }

  function connect(endpointText) {
    var ep = Model.parseEndpoint(endpointText, Model.WIFI_PORT)
    if (!ep) { actionOk = false; actionMessage = "Enter the address as ip[:port]"; return }
    runSteps("connect", [{
      args: ["connect", ep.address],
      onDone: function(out, err, code) {
        var v = Model.connectVerdict(out, err, code)
        if (v.ok) root.rememberPort(ep.host, ep.port)
        root.finishSteps(v.ok, v.message)
        return false
      }
    }])
  }

  function disconnect(serial) {
    runSteps("disconnect", [{
      args: ["disconnect", serial],
      onDone: function(out, err, code) {
        root.finishSteps(code === 0, code === 0 ? "Disconnected " + serial : String(err || out).trim())
        return false
      }
    }])
  }

  // Classic path for any Android version: with the phone on USB, switch adbd
  // to TCP, read the phone's wlan IP, and connect to it. After this the cable
  // can come out. Survives until the phone reboots.
  function enableWifi(serial) {
    var ip = ""
    runSteps("wifi", [
      {
        args: ["-s", serial, "tcpip", String(Model.WIFI_PORT)],
        onDone: function(out, err, code) {
          if (code !== 0) { root.finishSteps(false, String(err || out).trim() || "adb tcpip failed"); return false }
          return true
        }
      },
      {
        // tcpip restarts adbd on the phone, so for a few seconds the shell
        // answers "error: closed" (wait-for-device returns before it even
        // drops off the bus). Retry until it is back.
        args: ["-s", serial, "shell", "ip route; ip -f inet addr show wlan0"],
        retries: 20,
        retryDelayMs: 500,
        onDone: function(out, err, code) {
          if (code !== 0) return "retry"
          ip = Model.parseWlanIp(out, out)
          if (ip === "") { root.finishSteps(false, "Could not read the phone's Wi-Fi address. Is Wi-Fi on?"); return false }
          return true
        }
      },
      {
        args: function() { return ["connect", ip + ":" + Model.WIFI_PORT] },
        onDone: function(out, err, code) {
          var v = Model.connectVerdict(out, err, code)
          root.finishSteps(v.ok, v.ok ? "Wi-Fi ready at " + ip + ":" + Model.WIFI_PORT + " — you can unplug the cable" : v.message)
          return false
        }
      }
    ])
  }

  // --- saved devices ------------------------------------------------------------
  // A wireless-debugging phone keeps its pairing but gets a new port whenever
  // it reconnects. Remember its ip, and find the port again by scanning.
  property var saved: []
  readonly property string savedPath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/android-mirror.json"

  Process {
    id: loadProc
    command: ["/usr/bin/cat", root.savedPath]
    stdout: StdioCollector {
      onStreamFinished: root.saved = Model.parseSaved(text)
    }
  }

  Process { id: saveProc }

  function persist(list) {
    saved = list
    saveProc.command = ["/usr/bin/sh", "-c",
      "mkdir -p \"$(dirname \"$2\")\" && printf '%s' \"$1\" > \"$2.tmp\" && mv \"$2.tmp\" \"$2\"",
      "_", Model.serializeSaved(list), root.savedPath]
    saveProc.running = true
  }

  function saveDevice(name, ip, port) {
    if (!Model.isIPv4(ip)) return false
    persist(Model.upsertSaved(saved, { name: String(name || "").trim() || ip, ip: ip, lastPort: port || 0 }))
    return true
  }

  function renameSaved(index, name) {
    var d = saved[index]
    if (d) persist(Model.upsertSaved(saved, { name: String(name || "").trim() || d.ip, ip: d.ip, lastPort: d.lastPort }))
  }

  function forgetSaved(index) {
    persist(saved.filter(function(d, i) { return i !== index }))
  }

  function rememberPort(ip, port) {
    for (var i = 0; i < saved.length; i++) {
      if (saved[i].ip === ip && saved[i].lastPort !== port) {
        persist(Model.upsertSaved(saved, { name: saved[i].name, ip: ip, lastPort: port }))
        return
      }
    }
  }

  // Last known port first, then every open port nmap finds on that ip:
  // 30000-50000 (where Android usually picks), then the rest of the range.
  // Each candidate is tried with `adb connect`; the first to answer wins.
  function reconnect(entry) {
    var ip = entry.ip
    function connectStep(port) {
      return {
        args: ["connect", ip + ":" + port],
        onDone: function(out, err, code) {
          if (!Model.connectVerdict(out, err, code).ok) return true
          root.rememberPort(ip, port)
          root.finishSteps(true, "Connected to " + entry.name + " (" + ip + ":" + port + ")")
          return false
        }
      }
    }
    function scanStep(label, range) {
      return {
        label: label,
        cmd: [Model.NMAP, "-Pn", "-n", "-T4", "--max-retries", "1", "--host-timeout", "90s",
          "--open", "-p", range, "-oG", "-", ip],
        onDone: function(out, err, code) {
          if (code !== 0) { root.finishSteps(false, String(err || out).trim() || "nmap failed"); return false }
          var found = Model.parseNmapPorts(out, entry.lastPort).map(connectStep)
          root.steps = [root.steps[0]].concat(found, root.steps.slice(1))
          return true
        }
      }
    }
    var list = []
    if (entry.lastPort > 0) list.push(connectStep(entry.lastPort))
    list.push({
      label: "Checking for nmap…",
      cmd: ["/usr/bin/test", "-x", Model.NMAP],
      onDone: function(out, err, code) {
        if (code === 0) return true
        root.finishSteps(false, "Could not connect on the last port, and nmap is not installed (omarchy pkg add nmap)")
        return false
      }
    })
    list.push(scanStep("Scanning " + ip + " ports 30000-50000…", Model.SCAN_PRIMARY))
    list.push(scanStep("Scanning " + ip + " remaining ports…", Model.SCAN_REST))
    list.push({
      cmd: ["/usr/bin/true"],
      onDone: function() {
        root.finishSteps(false, "No open adb port found at " + ip + ". Is Wireless debugging on, and is this phone paired with this PC?")
        return false
      }
    })
    runSteps("reconnect", list)
  }

  // --- mirroring ----------------------------------------------------------------
  function mirror(device) {
    if (!device || !device.ready) return
    if (mirrorProc.running) stopMirror()
    mirrorError = ""
    mirroring = device
    mirrorProc.command = [root.scrcpyPath].concat(Model.scrcpyArgs(device.serial, {
      // These fallbacks must match barWidget.defaults in manifest.json: the panel
      // passes only the user's own overrides here, so a stale number in this
      // object silently wins over the manifest default.
      maxSize: setting("maxSize", 0),
      bitrateMbps: setting("bitrateMbps", 8),
      wifiMaxSize: setting("wifiMaxSize", 800),
      wifiBitrateMbps: setting("wifiBitrateMbps", 2),
      wifiMaxFps: setting("wifiMaxFps", 30),
      turnScreenOff: setting("turnScreenOff", true),
      stayAwake: setting("stayAwake", true),
      audio: setting("audio", true),
      extraArgs: setting("extraArgs", "")
    }, device.transport))
    // The panel passes only the user's own overrides, so this line is the only
    // honest record of which flags actually reached scrcpy:
    //   journalctl --user -b | grep android-mirror
    console.log("[android-mirror] " + mirrorProc.command.join(" "))
    mirrorProc.running = true
  }

  // Android Home key on the given device (what scrcpy's MOD+h does in its window).
  function goHome(device) {
    homeProc.command = [root.resolvedAdb, "-s", device.serial, "shell", "input", "keyevent", "3"]
    homeProc.running = true
  }

  Process { id: homeProc }

  function stopMirror() {
    if (mirrorProc.running) mirrorProc.signal(15)
  }

  Process {
    id: mirrorProc
    stderr: StdioCollector { id: mirrorErr }
    onExited: function(exitCode, exitStatus) {
      var was = root.mirroring
      root.mirroring = null
      // 0 is the user closing the window; SIGTERM from stopMirror is fine too.
      if (exitCode !== 0 && exitStatus === 0) {
        var text = String(mirrorErr.text || "").trim().split("\n")
        // scrcpy's last ERROR/WARN line is the useful one.
        var last = ""
        for (var i = text.length - 1; i >= 0; i--) if (/ERROR|WARN/.test(text[i])) { last = text[i]; break }
        root.mirrorError = last || ("scrcpy exited " + exitCode + (was ? " for " + was.serial : ""))
      }
    }
  }
}
