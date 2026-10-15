# Android Mirror for Omarchy

> Fork of [omarchy-android-mirror](https://github.com/ayandexyz/omarchy-android-mirror)

Mirror and control your Android phone from the Omarchy bar. USB or Wi-Fi,
keyboard and mouse, ~35–70 ms latency, no root, nothing to install on the
phone. A native Omarchy panel over [`adb`](https://developer.android.com/tools/adb)
and [`scrcpy`](https://github.com/Genymobile/scrcpy).

<p align="center">
  <img src="preview.png" alt="The Android Mirror panel next to a mirrored phone on the Omarchy desktop" width="720">
</p>

## Features

- Bar icon shows whether a phone is ready / mirroring
- Left click: panel with every connected phone and one-click **Mirror**
- Right click the icon: mirror the first ready phone (or stop the running mirror)
- **Install** button for the two packages it needs; finds the Android SDK's adb by itself
- **Enable Wi-Fi** on a USB-connected phone in one click, then unplug the cable
- **Pair** an Android 11+ phone over Wi-Fi with the pairing code — no cable, ever
- Connect to a remembered `ip:port`
- Turn the phone screen off while mirroring, keep it awake, forward audio (Android 11+)
- Plain scrcpy window (class `scrcpy`, title `Android Mirror`) — place it with your own Hyprland rules
- All scrcpy knobs (max size, bitrate, extra args) in the widget settings

## Install — three steps

1. **Add the plugin** (it lands in your bar automatically):

   ```sh
   omarchy plugin add https://github.com/Kylar514/omarchy-android-mirror.git --enable
   ```

2. **Click the Android icon → Install.** A terminal opens and runs
   `omarchy pkg add scrcpy android-tools android-udev` (asks for your password).
   Skip this if you already have adb + scrcpy; the plugin also finds the
   Android SDK's `~/Android/Sdk/platform-tools/adb` on its own.

3. **On the phone**, turn on _Settings → Developer options → USB debugging_
   (tap _Build number_ 7 times under _About phone_ if Developer options is
   hidden), plug in with USB, and tap **Allow** on the prompt.

Click **Mirror**. The window is a plain scrcpy window; to float, size or pin
it, add a Hyprland rule matching class `scrcpy` and title `Android Mirror`.

### Going wireless

With the phone still on USB, press the **Wi-Fi** button on its row (or `w`).
Wait for "Wi-Fi ready … you can unplug the cable", unplug, and click Mirror
on the Wi-Fi row. This lasts until the phone reboots.

Cable-free from the start (Android 11+): _Developer options → Wireless
debugging → Pair device with pairing code_, then **Pair a new phone** in the
panel and type the address and code shown.

### Saved devices

Wireless debugging keeps its pairing but picks a new port every time it
restarts. Select a connected Wi-Fi device and press `s` to save it under a name
of your choice (stored in `~/.local/state/omarchy/android-mirror.json`: name,
ip and last port, never a pairing code). Later, select it under **Saved** and
press `enter`: the plugin tries the last port, then scans that one ip with
`nmap` (ports 30000-50000 first, then the rest) and runs `adb connect` on what
it finds. `e` renames, `x` forgets, `c` cancels a running scan. The phone's ip
should not change, so give it a DHCP reservation on your router.

### Wi-Fi is slower than USB — tuning

Over Wi-Fi the plugin automatically uses a lighter profile (800 px, 2 Mbps,
30 fps, no audio, screen kept on) because the phone's _uplink_ is the
bottleneck. If it still lags: move both devices to **5 GHz** (biggest win),
get the phone closer to the router, and on the phone set _Keep Wi-Fi on during
sleep: Always_. Tweak the Wi-Fi values in the widget settings.

### Troubleshooting

- _tap Allow on the phone_ → the USB debugging prompt is waiting on the phone.
- _udev: no USB permission_ → `sudo usermod -aG adbusers $USER`, then log out and in.
- Phone not listed at all → the USB mode is "charge only"; switch to _File transfer_.
- On vivo/OPPO/Xiaomi, also enable _USB debugging (Security settings)_ or
  keyboard/mouse input is blocked.

## Remove

```sh
omarchy plugin remove omarchy-android-mirror
```

That deletes the plugin and its bar entry. It leaves the packages it
installed (`scrcpy`, `android-tools`, `android-udev`) in place — remove them
with `sudo pacman -Rs scrcpy android-tools android-udev` if you no longer want
them. Nothing else is written: the plugin never edits your Hyprland or shell
config.

## Dependencies

| Dependency | Package (Arch)  | Used for                              |
| ---------- | --------------- | ------------------------------------- |
| `adb`      | `android-tools` | listing phones, Wi-Fi pairing/connect |
| `scrcpy`   | `scrcpy`        | the mirror window, keyboard and mouse |
| udev rules | `android-udev`  | USB access without root               |
| `nmap`      | `nmap`          | finding a saved phone's new port      |

The **Install** button runs `omarchy pkg add scrcpy android-tools android-udev`
in a terminal, which uses `sudo` (you are asked for your password). No other
privileged action exists in the plugin. Nothing is downloaded from anywhere
but the Arch repositories.

## Keyboard

Inside the panel:

- `j` / `k` or arrows: select a phone
- `enter` / `space`: mirror the selected phone (or stop)
- `w`: enable Wi-Fi on the first USB phone
- `p`: show / hide pairing
- `r`: refresh
- `esc`: close

## IPC

```sh
omarchy-shell omarchy-android-mirror mirror   # mirror first ready phone
omarchy-shell omarchy-android-mirror stop
omarchy-shell omarchy-android-mirror install  # open the package install terminal
omarchy-shell omarchy-android-mirror toggle   # open/close the panel
```

Bind `mirror` to a key in `~/.config/hypr/bindings.conf` if you like.

## Layout

```
manifest.json      plugin identity + settings schema
Panel.qml          bar icon + panel UI (the `barWidget` entry point)
MirrorBackend.qml  adb / scrcpy processes and state
Model.js           pure parsing + argument building (tested)
tests/             node --test tests/
```

## Development

```sh

omarchy plugin add "$PWD" --enable     # or rsync into ~/.config/omarchy/plugins/<id>/
omarchy plugin validate ~/.config/omarchy/plugins/omarchy-android-mirror
node --test tests/
```

## License

MIT
