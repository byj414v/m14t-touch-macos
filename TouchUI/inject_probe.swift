// 实验：伪造 macOS 27 的"直接触摸"事件（WindowServer 类型 59），看 App 是否收到 NSEvent.directTouch。
// 用法: inject_probe <pid> <x> <y>   （x, y 为 CG 全局坐标）
import Foundation
import CoreGraphics

typealias HIDEvent = UnsafeMutableRawPointer
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
func sym<T>(_ h: UnsafeMutableRawPointer?, _ n: String, _ t: T.Type) -> T {
    guard let p = dlsym(h, n) else { fatalError("missing \(n)") }
    return unsafeBitCast(p, to: t)
}
typealias CreateDigitizer = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
                                           Double, Double, Double, Double, Double, DarwinBoolean, DarwinBoolean, UInt32) -> HIDEvent?
typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32,
                                        Double, Double, Double, Double, Double, DarwinBoolean, DarwinBoolean, UInt32) -> HIDEvent?
typealias Append = @convention(c) (HIDEvent, HIDEvent, UInt32) -> Void
typealias SetInt = @convention(c) (HIDEvent, UInt32, Int) -> Void
typealias SetHID = @convention(c) (CGEvent, HIDEvent) -> Void
typealias SetType = @convention(c) (CGEvent, UInt32) -> Void

let createDigitizer = sym(iokit, "IOHIDEventCreateDigitizerEvent", CreateDigitizer.self)
let createFinger = sym(iokit, "IOHIDEventCreateDigitizerFingerEvent", CreateFinger.self)
let append = sym(iokit, "IOHIDEventAppendEvent", Append.self)
let setInt = sym(iokit, "IOHIDEventSetIntegerValue", SetInt.self)
let slSetHID = sym(sky, "SLEventSetIOHIDEvent", SetHID.self)
let setType = sym(dlopen(nil, RTLD_NOW), "CGEventSetType", SetType.self)
let DIRECT_TOUCH: UInt32 = sym(sky, "kSLSHIDEventTypeDirectTouch", UnsafeMutablePointer<UInt32>.self).pointee

let FIELD_DISPLAY_INTEGRATED: UInt32 = (11 << 16) | 26   // kIOHIDEventFieldDigitizerIsDisplayIntegrated

let args = CommandLine.arguments
let pid = pid_t(args[1])!
let px = Double(args[2])!, py = Double(args[3])!
let disp = CGDisplayBounds(CGMainDisplayID())
_ = disp

func make(touch: Bool, normX: Double, normY: Double) -> CGEvent? {
    let ts = mach_absolute_time()
    let mask: UInt32 = touch ? 0x7 : 0x3          // range | touch | position
    guard let hand = createDigitizer(nil, ts, 3, 0, 0, mask, 0, normX, normY, 0, 0, 0,
                                     DarwinBoolean(touch), DarwinBoolean(touch), 0),
          let finger = createFinger(nil, ts, 1, 2, mask, normX, normY, 0, touch ? 1 : 0, 0,
                                    DarwinBoolean(touch), DarwinBoolean(touch), 0) else { return nil }
    setInt(hand, FIELD_DISPLAY_INTEGRATED, 1)
    setInt(finger, FIELD_DISPLAY_INTEGRATED, 1)
    append(hand, finger, 0)
    guard let e = CGEvent(source: nil) else { return nil }
    setType(e, DIRECT_TOUCH)
    e.location = CGPoint(x: px, y: py)
    slSetHID(e, hand)
    return e
}

// 找出 (px,py) 所在显示器，计算归一化坐标
var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
CGGetActiveDisplayList(8, &ids, &n)
let r = ids.prefix(Int(n)).map { CGDisplayBounds($0) }.first { $0.contains(CGPoint(x: px, y: py)) } ?? CGDisplayBounds(CGMainDisplayID())
let nx = (px - r.minX) / r.width, ny = (py - r.minY) / r.height
print("type=\(DIRECT_TOUCH) display=\(r) norm=(\(nx), \(ny))")

for (label, touch) in [("down", true), ("up", false)] {
    if let e = make(touch: touch, normX: nx, normY: ny) {
        e.post(tap: .cgSessionEventTap); e.post(tap: .cgAnnotatedSessionEventTap); e.postToPid(pid)
        print("posted \(label) to pid \(pid), event type now \(e.type.rawValue)")
    } else { print("failed to create \(label)") }
    usleep(120_000)
}
// 也试一次走系统事件流
for touch in [true, false] {
    make(touch: touch, normX: nx, normY: ny)?.post(tap: .cghidEventTap)
    usleep(120_000)
}
print("done")
