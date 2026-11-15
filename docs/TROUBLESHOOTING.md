# Troubleshooting

**English** | [简体中文](zh-CN/TROUBLESHOOTING.md)

### Touch does nothing

1. If the menu bar shows `☝︎!`, open the menu and check which item on the first line has a ✗:
   - **输入监控 ✗** (Input Monitoring): turn on M14tTouch in Privacy & Security → Input Monitoring, then choose 「重新启动」 (Restart) from the menu.
   - **辅助功能 ✗** (Accessibility): turn on M14tTouch in Privacy & Security → Accessibility.
   - **未找到 M14t 屏幕** (M14t screen not found): check that the display is on.
   - **未找到触控设备** (touch device not found): unplug the M14t, plug it back in and wait a few seconds (the touch controller appears after the display). Make sure the switch on the back is set to **Windows**.
2. The status log `~/Library/Logs/M14tTouch.log` gets one line every 2 seconds:
   `hid=0x0` (Input Monitoring OK; `0xe00002e2` means the permission is missing), `ax=1` (Accessibility OK), `devices=` number of touch devices, `reports=` number of touch reports received. If `reports` doesn't go up while you touch, no data is coming in.

### Permissions stop working after a rebuild

An ad-hoc signature changes on every build, so macOS sees a new app. Create the fixed self-signed certificate described in [ARCHITECTURE.md](ARCHITECTURE.md#7-signing-and-permissions-tcc). If old entries are still listed in Settings but don't work:

```bash
tccutil reset ListenEvent local.m14t.touch
tccutil reset Accessibility local.m14t.touch
```

Then launch the app again and grant the permissions.

### The build hangs

The first time `codesign` uses the certificate, a keychain dialog appears. Enter your login password and click **Always Allow**.

### The pointer reappears after a tap

Some apps show the pointer again when clicked. The driver hides it again within about 0.1 s. To stop hiding it, turn off "Hide pointer while touching" (触摸时隐藏光标) in the menu.

### Swiping up from the bottom doesn't show the Dock

The Dock must be at the bottom of the screen. macOS moves the Dock to a display only when the pointer pushes against that display's bottom edge; the driver simulates this automatically.

### Scrolling in iPhone Mirroring is choppy

This is the current limit. See [RESEARCH.md](RESEARCH.md#iphone-mirroring) for why.

### Removing the display override file

```bash
sudo bash TouchUI/disable_touch_ui.sh
```
