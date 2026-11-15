# Usage

**English** | [简体中文](zh-CN/USAGE.md)

## Setup

1. Set the mode switch on the back of the screen to **Windows** (the Android/Chrome mode uses a different report format).
2. Connect with USB-C (a Thunderbolt or full-featured cable is recommended) and make sure the screen lights up. The touch controller appears a few seconds after the display.
3. Run `M14tTouch/build.sh`, then in **System Settings → Privacy & Security** turn on **M14tTouch** under:
   - **Input Monitoring**: reads raw HID data from the touchscreen
   - **Accessibility**: sends mouse and keyboard events, reads and presses window buttons
4. A `☝︎` in the menu bar means the driver is running. `☝︎!` means a permission is missing or the touchscreen was not found. Open the menu: the first line shows the status.

## Gestures

### One finger

| Action | Result |
|---|---|
| Tap | Left click (snaps to a nearby button when snapping is on) |
| Tap twice quickly | Double-click |
| Swipe | Scroll (iPad style, with momentum); drag instead when "One-finger swipe = scroll" is off |
| Swipe on a title bar | Move the window |
| Flick a title bar left / right | Tile the window to the left / right half of the screen |
| Long-press 0.5 s, then lift | Right-click |
| Long-press 0.5 s, then drag | Press-and-drag (select text, drag files) |
| Swipe down from the top edge | Spotlight (⌘Space) |
| Swipe up from the bottom edge | Show the Dock |

### Top-left corner of a window (big traffic lights)

| Action | Result |
|---|---|
| Tap the top-left corner | Pops out three large buttons; tap one to use it. Tapping elsewhere, or waiting 4 s, hides them |
| Press the corner, slide onto a button, lift | Runs it directly: red close / yellow minimize / green zoom |

### Two fingers

| Action | Result |
|---|---|
| Swipe | Scroll (with momentum) |
| Pinch in / out | Zoom out / in (sends ⌘− / ⌘=) |
| Tap | Right-click |

### Three fingers

| Action | Result |
|---|---|
| Swipe left / right | Switch to the Space on the right / left |
| Swipe up / down | Mission Control / App Exposé |

### Inside the iPhone Mirroring window

| Action | Result |
|---|---|
| Tap | Tap |
| One- or two-finger swipe | Swipe, change pages, scroll lists (converted to scroll-wheel events) |
| Long-press | Long-press (mouse button held down) |
| Swipe up from the bottom edge, quick | Home Screen |
| Swipe up from the bottom edge, pause, then lift | App Switcher |
| Swipe down from the top-right corner | Control Center |

The edge zones are the bottom and top 45 pt of the mirroring window. These gestures run the commands in the iPhone Mirroring **View** menu.

For the limits, see [RESEARCH.md](RESEARCH.md#iphone-mirroring): no pinch, and swiping is less smooth than a trackpad.

## Menu options

The menu labels are in Chinese. In menu order:

| Menu label | English meaning | Default | Notes |
|---|---|---|---|
| 单指滑动 = 滚动（iPad 式） | One-finger swipe = scroll (iPad style) | On | When off, a one-finger swipe drags |
| 显示触摸点 | Show touch points | On | Draws circles at the touch points and a ripple on taps |
| 滚动惯性 | Scroll momentum | On | Keeps scrolling and slows down after you lift |
| 甩动窗口分屏 | Flick window to tile | On | Flick a title bar to tile to half the screen |
| 边缘手势（顶部搜索 / 底部 Dock） | Edge gestures (top: Spotlight / bottom: Dock) | On | |
| 触摸时隐藏光标 | Hide pointer while touching | On | Hidden only while a finger is on the screen; shown again 0.4 s after you lift |
| iPhone 镜像：直接触控 | iPhone Mirroring: direct touch | On | Uses the special mapping inside the iPhone Mirroring window |
| 放大红黄绿按钮 | Big traffic lights | On | See above |
| 点按自动吸附到按钮 / 菜单项 | Snap taps to buttons / menu items | On | A missed tap snaps to the nearest clickable element within 12–32 pt |

Settings are stored in the app's `UserDefaults` (domain `local.m14t.touch`). The key is the menu label.

## Autostart

```bash
bash M14tTouch/install_autostart.sh            # turn on
bash M14tTouch/install_autostart.sh --remove   # turn off
```

The LaunchAgent restarts the driver if it exits unexpectedly.

## Uninstall

```bash
bash M14tTouch/install_autostart.sh --remove
rm -rf ~/Applications/M14tTouch.app
```

Then remove M14tTouch from **Input Monitoring** and **Accessibility** in Privacy & Security.
