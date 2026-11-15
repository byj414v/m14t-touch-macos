# Research notes

**English** | [简体中文](zh-CN/RESEARCH.md)

These are notes from experiments during development. Setup: MacBook Pro 14" (M5), macOS 27.2.1, Lenovo ThinkVision M14t.

## Native touch UI

macOS 27 adds a touch UI for the touchscreen MacBook Pro: traffic lights that grow when pressed, larger menus, larger hit targets, and so on. The goal was to make the M14t trigger this UI too.

### How macOS handles the M14t's touches

The system log (`log stream`) shows that WindowServer's direct-touch processor receives every M14t touch, then drops it:

```
[com.apple.BackBoard:TouchEvents] ignoring digitizer event for display <main> from unsupported service:
  <BKIOHIDService ... eventSource: mouse; primaryUsagePage: 0xD; primaryUsage: 0x4;
   name: Pen and multitouch sensor; transport: USB> ... BuiltIn: 0
```

BackBoard only accepts a **built-in** touchscreen (`BuiltIn = 1`) bound to the main display. For an external USB touchscreen, the `Built-In` property is set by the IOKit driver when it matches, and user space can't change it.

### Methods tried

| Method | Lowers security? | Result |
|---|---|---|
| Display override file with `DisplaySupportsTouch = true` (`TouchUI/enable_touch_ui.sh`) | No (needs sudo) | CoreDisplay reports the display as touch-capable, but touches are still dropped |
| `hidutil property --set '{"Built-In":true}'` | No | Reports success, but reads back empty; the driver ignores it |
| Create a virtual built-in touchscreen with `IOHIDUserDeviceCreateWithProperties` (`TouchUI/vtouch.swift`) | No | Fails even as root; needs the Apple-granted `com.apple.developer.hid.virtual.device` entitlement |
| Fake direct-touch CGEvents (type 59 + IOHIDEvent, `TouchUI/inject_probe.swift`) | No | Apps don't receive them |
| Codeless kext that merges `Built-In = true` with `IOHIDProviderPropertyMerger` (`TouchUI/M14tBuiltIn.kext`) | **Yes**: lower startup security in recoveryOS and allow third-party extensions | Not tested |
| DriverKit driver | Needs an Apple-approved entitlement, or SIP turned off | Not tried |

Conclusion: the native touch UI can't be enabled without lowering security. Even if a kext set `Built-In` to 1, the log shows two more conditions, `eventSource: mouse` and the display binding (`<main>`), which may still not be met. For example, the M14t might need to be the main display (clamshell mode).

So the driver **emulates** some of these effects instead: big traffic lights and tap snapping.

## iPhone Mirroring

On the native touchscreen Mac, iPhone Mirroring supports direct touch (swipes that follow the finger, multi-finger gestures). How far an external touchscreen can get:

### Event tests

Different events were sent to the iPhone Mirroring window, with screenshots compared before and after:

| Event | Does the iPhone scroll? |
|---|---|
| Continuous scrolling (pixels, with phases, like a trackpad) | No |
| Continuous scrolling + synthetic gesture events (type 29, fields copied from a real trackpad) | No |
| Mouse drag with button held (with deltas) | No |
| **Wheel-style (non-continuous) scrolling** | **Yes** |
| **Exact replay of recorded real trackpad events** (`CGEvent(withData:)`) | The page follows, but stops halfway |

When real trackpad events are replayed, the iPhone receives "finger moving" but never "finger lifted". The page stops halfway and only snaps back when the next gesture starts. The lift signal isn't in the CGEvent stream (an event tap can't record it), so a third-party program can't send it.

### Conclusion

- In iPhone Mirroring the driver uses wheel-style scrolling. It scrolls and changes pages, but doesn't follow the finger as closely as a trackpad, and pinch isn't supported.
- The native touchscreen Mac most likely sends multi-touch directly over the private encrypted connection between iPhone Mirroring and the iPhone. Outside programs can't get in without injecting code into an Apple-signed process (which requires turning off SIP).
- Another route is WebDriverAgent (XCTest), which synthesizes real multi-touch on the iPhone. A free Apple ID is enough, but it can only replay a whole gesture after it finishes, so it doesn't follow the finger.

## M14t hardware

| Item | Value |
|---|---|
| Display | Vendor `0x30AE`, Product `0x62A3`, 1920×1080 |
| Touch controller | Wacom "Pen and multitouch sensor", USB VID `0x2D1F` PID `0x524C`, behind a Realtek USB 2.1 hub |
| Mode switch | Windows (used by this driver) / Android-Chrome |
| Touch report | Report ID 12, 40 bytes, 5 contacts, X 0–12372, Y 0–6960 |
| How macOS sees it | An external digitizer with `eventSource: mouse`; with no driver it only works as a mouse for single clicks |
