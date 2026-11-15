# Architecture

**English** | [简体中文](zh-CN/ARCHITECTURE.md)

The driver is a single Swift file (`M14tTouch/main.swift`) that runs as a menu bar app. It needs no kernel extension.

```
M14t touch controller ──USB HID──▶ IOHIDManager (input report callback)
                                        │ parse up to 5 contacts
                                        ▼
                                  Gestures state machine ──▶ CGEvent (mouse / scroll / keyboard) ──▶ macOS
                                        │                  └▶ AXUIElement (press window buttons, move windows)
                                        ▼
                                  Overlay window (touch points, ripples, big traffic lights)
```

## 1. Reading touch input

- `IOHIDManager` matches `VID 0x2D1F / PID 0x524C` and registers an input report callback. This needs the **Input Monitoring** permission (`IOHIDRequestAccess`).
- Report format (Report ID 12, 40 bytes):

  | Offset | Contents |
  |---|---|
  | 0 | Report ID = 12 |
  | 2 | Number of contacts in this frame |
  | 3 + 7·i | Contact i: `flags` (bit 0 = touching), `id` u16, `X` u16 (0–12372), `Y` u16 (0–6960) |
  | 38–39 | Scan time |

- Coordinates are mapped linearly to global coordinates using the `CGDisplayBounds` of the M14t's screen. The screen is the `NSScreen` whose name contains "M14t". It is looked up again whenever the screen configuration changes.

## 2. Gesture state machine

`Gestures.update()` receives all current contacts every frame and dispatches on the largest number of fingers seen during the current touch:

| Mode | Meaning |
|---|---|
| `idle` | No fingers |
| `undecided` | Just touched down, has not moved past the threshold (10 pt) yet |
| `armed` | Long-pressed for 0.5 s; waiting for lift (right-click) or a drag |
| `drag` / `windowDrag` | Dragging with the mouse button held / moving a window |
| `scroll` | Continuous scrolling |
| `pinch` | Two-finger zoom |
| `edge` | A gesture that started at a screen edge |
| `lights` | Big traffic lights |
| `done` | A one-shot action already fired; ignore the rest of this touch |

Note: special modes set in `begin()` (`lights`, iPhone Mirroring) must be kept when the first finger is counted, or they get reset to `undecided`.

The main thresholds are at the top of the file (`TAP_MOVE`, `LONG_PRESS`, `EDGE`, `MOMENTUM_DECAY`, and so on).

## 3. Event output

- All events are created with `CGEventSource(.hidSystemState)`, posted to `.cghidEventTap`, and tagged with `0x4D313474` ("M14t") in `eventSourceUserData` so the driver can tell its own events apart.
- **Scrolling**: pixel units, continuous (`isContinuous = 1`), with `scrollPhase` (field 99) and `momentumPhase` (field 123). Apps treat this like trackpad scrolling, including rubber-band bounce.
- **Momentum**: after lift, momentum-phase events are sent at 60 Hz, with the speed multiplied by 0.94 each frame.
- **Showing the Dock**: sends 20 downward `mouseMoved` events (with deltaY) at the bottom edge, like pushing the mouse against the bottom of the screen.
- **Hiding the pointer**: a background app normally can't hide the pointer. The driver calls the private `CGSSetConnectionProperty(..., "SetsCursorInBackground", true)` and then `CGDisplayHideCursor`. A timer checks `CGCursorIsVisible`, because the app that was clicked may show the pointer again.

## 4. Accessibility

- `AXUIElementCopyElementAtPosition` finds the element under the finger.
- **Snapping**: samples 8 directions on rings of 12 / 22 / 32 pt, finds the nearest clickable element (button, checkbox, menu item, link, and so on), and clicks its center.
- **Traffic lights**: reads the window's `AXCloseButton` / `AXMinimizeButton` / `AXZoomButton` and runs them with `AXPress`.
- **Window tiling**: sets the window's `AXPosition` / `AXSize`.

## 5. Overlay

A transparent window covers the whole M14t screen. It ignores the mouse and sits at the `screenSaver` level. It draws touch points, tap ripples, the snapping highlight, and the traffic lights. The buttons spring out from the real small buttons with a damped spring `1 − e^(−9t)·cos(15t)`, and the button under the finger smoothly grows to 1.28×.

## 6. iPhone Mirroring

- `CGWindowListCopyWindowInfo` finds the window under the finger. If it belongs to the app with bundle id `com.apple.ScreenContinuity`, the driver switches to mirroring mode.
- iPhone Mirroring ignores trackpad-style continuous scrolling and doesn't treat a mouse drag as a swipe. It only accepts **wheel-style (non-continuous) scrolling**.
- Finger movement is accumulated first, then sent as whole pixels by a 120 Hz timer at a steady rate. Small scattered events would otherwise be read as taps.
- The driver's own momentum is off in mirroring mode, or iOS behaves as if the finger never lifted.

## 7. Signing and permissions (TCC)

macOS privacy permissions (TCC) are tied to the code signature. An ad-hoc signature changes on every build, which invalidates the permissions. `build.sh` prefers a self-signed code-signing certificate named `M14tTouch Local Signing` in the keychain, with the fixed identifier `local.m14t.touch`, so permissions stay valid after a rebuild.

To create the certificate: Keychain Access → Certificate Assistant → Create a Certificate → name `M14tTouch Local Signing`, identity type "Self-Signed Root", certificate type "Code Signing".
