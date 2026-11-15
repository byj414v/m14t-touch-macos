# M14t Touch for macOS

**English** | [简体中文](README.zh-CN.md)

A free touch driver that turns the **Lenovo ThinkVision M14t** portable touchscreen into an iPad-style touch display on a Mac. No paid software and no Apple Developer account needed. Tested on an M5 MacBook Pro with macOS 27.

## Features

- One-finger scroll with momentum, tap, double-tap, long-press for right-click, press-and-drag
- Two-finger scroll, pinch to zoom (⌘+ / ⌘−), two-finger tap for right-click
- Three-finger swipe to switch Spaces, swipe up for Mission Control
- Drag windows by the title bar; flick a window left or right to tile it to half the screen
- Swipe down from the top edge for Spotlight; swipe up from the bottom edge to show the Dock
- Hides the mouse pointer while you touch
- **Big traffic lights**: press or tap the top-left corner of a window to pop out large close / minimize / zoom buttons with a spring animation
- **Tap snapping**: a tap that misses a small control snaps to the nearest button or menu item
- **iPhone Mirroring**: tap, swipe between pages and scroll lists (scrolling is less smooth than a trackpad and pinch is not supported; see the research notes)
- Every feature can be turned on or off from the menu bar icon

## Install

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
cd M14tTouch
bash build.sh               # build, sign, install to ~/Applications and launch
bash install_autostart.sh   # optional: start at login
```

On first launch, open **System Settings → Privacy & Security** and turn on M14tTouch under:
- **Input Monitoring** (to read raw touch data from the screen)
- **Accessibility** (to send mouse and keyboard events and press window buttons)

> Tip: sign with a fixed self-signed code-signing certificate named `M14tTouch Local Signing`
> (create it in Keychain Access) so the permissions survive rebuilds. Without it, `build.sh` falls back to ad-hoc signing.

Set the switch on the back of the screen to **Windows** mode.

## Docs

- [Usage](docs/USAGE.md): all gestures, menu options, autostart and uninstall
- [Architecture](docs/ARCHITECTURE.md): HID parsing, gesture state machine, event output, signing and permissions
- [Research notes](docs/RESEARCH.md): experiments on the native macOS touch UI and iPhone Mirroring
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## Hardware notes

- Touch controller: Wacom "Pen and multitouch sensor", VID `0x2D1F`, PID `0x524C`
- Report: Report ID 12, 40 bytes, up to 5 contacts; X 0–12372, Y 0–6960

## Repository layout

| Folder | Contents |
|---|---|
| `M14tTouch/` | The driver (single Swift file) plus build and autostart scripts |
| `M14tTouchTest/` | Guided touch test tool (full screen, logs raw reports) |
| `TouchUI/` | Experiments to enable the native macOS touch UI (see below) |

## About the native macOS touch UI

macOS 27 adds a touch UI for the touchscreen MacBook Pro (traffic lights that grow when pressed, larger menus, and so on). What the experiments found:

- macOS does receive the M14t's touches, but BackBoard drops them because the device is not **built-in** (`BuiltIn: 0`):
  `ignoring digitizer event ... from unsupported service`
- Every method that keeps full security was tried and failed: a display override with `DisplaySupportsTouch`, changing properties with `hidutil`, creating a virtual built-in touchscreen (needs an Apple-granted entitlement), and faking direct-touch events.
- The only remaining route is a codeless kext (`TouchUI/M14tBuiltIn.kext`, untested). It requires lowering startup security in recoveryOS and is **not recommended**.

So the driver emulates some of these effects instead (big traffic lights, tap snapping).

## Disclaimer

Unofficial project, not affiliated with Apple, Lenovo or Wacom. Uses a few private APIs (hiding the pointer from a background app), which may break after a system update. Use at your own risk.
