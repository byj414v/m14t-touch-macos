// M14tTouch — Lenovo ThinkVision M14t 的免费 macOS 触控驱动（用户态）
// 读取触控屏原始 HID 数据 (Wacom 2D1F:524C, report 12)，转换成鼠标 / 滚动 / 快捷键 / 窗口操作，
// 尽量模仿 2026 触屏 MacBook Pro 的触控交互。
//
// 手势（“iPad 式滚动”开启时）：
//   单指点按            → 左键单击（快速点两下 = 双击）
//   单指滑动            → 滚动内容（带惯性）
//   在窗口标题栏上滑动   → 拖动窗口；快速左右甩 → 窗口贴到屏幕左半 / 右半
//   长按 0.5 秒后松手    → 右键
//   长按 0.5 秒后拖动    → 左键拖动（选文字、拖文件）
//   双指滑动            → 滚动（带惯性）
//   双指点按            → 右键
//   双指捏合 / 张开      → 缩小 / 放大 (⌘- / ⌘=)
//   三指左右滑          → 切换桌面 (⌃← / ⌃→)
//   三指上滑 / 下滑      → 调度中心 / App 窗口 (⌃↑ / ⌃↓)
//   从顶部边缘下滑       → 聚焦搜索 (⌘空格)
//   从底部边缘上滑       → 呼出 Dock
//
// 需要权限：系统设置 → 隐私与安全性 → 输入监控、辅助功能，都勾选 M14tTouch。

import AppKit
import IOKit.hid
import ApplicationServices

let VID = 0x2d1f, PID = 0x524c
let TOUCH_MAX_X = 12372.0, TOUCH_MAX_Y = 6960.0
let REPORT_ID: UInt8 = 12

// 可调参数（单位：屏幕点 / 秒）
let TAP_MOVE = 10.0
let LONG_PRESS = 0.5
let DOUBLE_TAP_TIME = 0.35
let DOUBLE_TAP_DIST = 30.0
let TWO_TAP_TIME = 0.6
let PINCH_START = 50.0
let PINCH_STEP = 1.25
let SWIPE3_DIST = 80.0
let EDGE = 24.0
let EDGE_SWIPE = 60.0
let TITLEBAR_HEIGHT = 38.0
let FLICK_SPEED = 1400.0
let MOMENTUM_DECAY = 0.94
let MOMENTUM_MIN = 30.0

// 设置（保存在 App 自己的偏好里）
enum Pref: String, CaseIterable {
    case scrollMode = "单指滑动 = 滚动（iPad 式）"
    case showTouches = "显示触摸点"
    case momentum = "滚动惯性"
    case windowFlick = "甩动窗口分屏"
    case edgeGestures = "边缘手势（顶部搜索 / 底部 Dock）"
    case hideCursor = "触摸时隐藏光标"
    case iphoneDirect = "iPhone 镜像：直接触控"
    case bigLights = "放大红黄绿按钮"
    case snapTargets = "点按自动吸附到按钮 / 菜单项"
    var on: Bool {
        get { UserDefaults.standard.object(forKey: rawValue) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: rawValue) }
    }
}

struct Touch { let id: Int; let p: CGPoint }

func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
func centroid(_ t: [Touch]) -> CGPoint {
    CGPoint(x: t.map { $0.p.x }.reduce(0, +) / Double(t.count), y: t.map { $0.p.y }.reduce(0, +) / Double(t.count))
}
/// 主屏高度，用于 CG（左上原点）和 AppKit（左下原点）坐标互转
func mainHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
func cgRect(_ ns: NSRect) -> CGRect { CGRect(x: ns.minX, y: mainHeight() - ns.maxY, width: ns.width, height: ns.height) }
func nsPoint(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: mainHeight() - p.y) }

// MARK: - 事件输出

let src = CGEventSource(stateID: .hidSystemState)
/// 标记本驱动发出的事件，用来区分真实鼠标 / 触控板
let MAGIC: Int64 = 0x4D313474   // "M14t"
extension CGEvent {
    func postTagged() { setIntegerValueField(.eventSourceUserData, value: MAGIC); post(tap: .cghidEventTap) }
}

// MARK: - 光标隐藏

final class CursorHider {
    private(set) var hidden = false
    init() {
        // 允许后台 App 隐藏光标（私有 API，菜单栏工具常用做法）
        typealias MainConn = @convention(c) () -> Int32
        typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let h = dlopen(nil, RTLD_NOW)
        if let c = dlsym(h, "CGSMainConnectionID") ?? dlsym(h, "SLSMainConnectionID"),
           let s = dlsym(h, "CGSSetConnectionProperty") ?? dlsym(h, "SLSSetConnectionProperty") {
            let cid = unsafeBitCast(c, to: MainConn.self)()
            _ = unsafeBitCast(s, to: SetProp.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        }
    }
    /// 系统实际的光标可见状态（点击后 App 可能自己把光标显示回来，不能只信自己的标记）
    private let isVisibleFn: (@convention(c) () -> Int32)? = {
        guard let p = dlsym(dlopen(nil, RTLD_NOW), "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(p, to: (@convention(c) () -> Int32).self)
    }()
    var systemVisible: Bool { (isVisibleFn?() ?? 1) != 0 }
    private var timer: Timer?

    /// 进入触摸模式：隐藏，并每 0.1 秒检查一次，被别的 App 显示回来就再隐藏
    private var showToken = 0
    func hide() {
        showToken += 1                     // 取消待执行的"松手后显示"
        guard Pref.hideCursor.on else { return }
        hidden = true
        enforce()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.enforce() }
        }
    }
    private func enforce() {
        guard hidden, Pref.hideCursor.on else { return }
        if systemVisible { CGDisplayHideCursor(CGMainDisplayID()) }
    }
    /// 手指全部离开后稍等再显示（连续点按之间不闪烁）
    func showSoon(after delay: Double = 0.4) {
        showToken += 1
        let tok = showToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if let self, tok == self.showToken { self.show() }
        }
    }
    /// 退出触摸模式（松手，或真实鼠标 / 触控板动了）：完全显示
    func show() {
        guard hidden else { return }
        hidden = false
        timer?.invalidate(); timer = nil
        var n = 0
        repeat { CGDisplayShowCursor(CGMainDisplayID()); n += 1 } while !systemVisible && n < 20
    }
}
let cursor = CursorHider()
let F_SCROLL_PHASE = CGEventField(rawValue: 99)!      // kCGScrollWheelEventScrollPhase
let F_MOMENTUM_PHASE = CGEventField(rawValue: 123)!   // kCGScrollWheelEventMomentumPhase

var lastMousePos = CGPoint.zero
func mouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
    e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - lastMousePos.x).rounded()))
    e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - lastMousePos.y).rounded()))
    lastMousePos = p
    e.postTagged()
}
func click(_ p: CGPoint, clicks: Int) {
    mouse(.leftMouseDown, p, clicks: clicks); mouse(.leftMouseUp, p, clicks: clicks)
}
func rightClick(_ p: CGPoint) {
    mouse(.mouseMoved, p)
    mouse(.rightMouseDown, p, button: .right); mouse(.rightMouseUp, p, button: .right)
}
/// phase: 1 开始 2 变化 4 结束；momentum: 1 开始 2 继续 3 结束
func dbg(_ m: String) {
    return   // 调试日志已关闭
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/M14tTouch-debug.log")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write("\(Date()) \(m)\n".data(using: .utf8)!); try? h.close() }
}
var discreteSent = 0
/// iPhone 镜像：把零碎的手指位移累积起来，按 60Hz 匀速发出（太碎或有停顿会被当成点按）
final class MirrorScroller {
    static let shared = MirrorScroller()
    var ax = 0.0, ay = 0.0
    var timer: Timer?
    var idleTicks = 0
    func add(dx: Double, dy: Double) {
        ax += dx; ay += dy
        if timer == nil {
            idleTicks = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }
    func tick() {
        let ix = ax.rounded(.towardZero), iy = ay.rounded(.towardZero)
        if ix == 0 && iy == 0 {
            idleTicks += 1
            if idleTicks > 60 { timer?.invalidate(); timer = nil; ax = 0; ay = 0 }
            return
        }
        idleTicks = 0
        ax -= ix; ay -= iy
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.postTagged(); discreteSent += 1
    }
}
/// iPhone 镜像只认"滚轮式"滚动（非连续），不认触控板式连续滚动
var scrollDiscrete = false
func scroll(dx: Double, dy: Double, phase: Int64 = 2, momentum: Int64 = 0) {
    if scrollDiscrete { MirrorScroller.shared.add(dx: dx, dy: dy); return }
    guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                          wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(F_SCROLL_PHASE, value: momentum == 0 ? phase : 0)
    e.setIntegerValueField(F_MOMENTUM_PHASE, value: momentum)
    e.postTagged()
}
func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
    var f = flags
    if (123...126).contains(code) { f.insert([.maskSecondaryFn, .maskNumericPad]) }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
        e.flags = f
        e.postTagged()
    }
}

// MARK: - 窗口工具（辅助功能 API）

let MY_PID = ProcessInfo.processInfo.processIdentifier

/// 点 p 处最上层普通窗口（layer 0）的范围和所属进程
func windowInfo(at p: CGPoint) -> (rect: CGRect, pid: pid_t)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != MY_PID,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { continue }
        if r.contains(p) { return (r, pid) }
    }
    return nil
}
func windowBounds(at p: CGPoint) -> CGRect? { windowInfo(at: p)?.rect }

/// 手指是否落在 iPhone 镜像窗口里
func isIPhoneMirroring(_ p: CGPoint) -> Bool {
    guard let w = windowInfo(at: p) else { return false }
    return NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier == "com.apple.ScreenContinuity"
}

// MARK: - 辅助功能：命中测试 / 吸附 / 红黄绿按钮

func axAttr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let pv: AXValue = axAttr(el, kAXPositionAttribute), let sv: AXValue = axAttr(el, kAXSizeAttribute) else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(pv, .cgPoint, &pos); AXValueGetValue(sv, .cgSize, &size)
    return CGRect(origin: pos, size: size)
}
/// p 处的辅助功能元素（排除本驱动自己的窗口）
func axElement(at p: CGPoint) -> AXUIElement? {
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success,
          let el else { return nil }
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid == MY_PID ? nil : el
}
let ACTIONABLE_ROLES: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem",
                                     "AXPopUpButton", "AXMenuButton", "AXLink", "AXDisclosureTriangle", "AXComboBox"]
func actionable(_ el: AXUIElement) -> Bool {
    guard let role: String = axAttr(el, kAXRoleAttribute) else { return false }
    if let enabled: Bool = axAttr(el, kAXEnabledAttribute), !enabled { return false }
    return ACTIONABLE_ROLES.contains(role)
}
/// 点偏了时，在附近找最近的可点控件，返回它的中心和范围
func snapTarget(_ p: CGPoint) -> (point: CGPoint, frame: CGRect)? {
    if let el = axElement(at: p), actionable(el) { return nil }      // 已经点中，不用吸附
    var best: (point: CGPoint, frame: CGRect, d: Double)?
    for r in [12.0, 22.0, 32.0] {
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            let q = CGPoint(x: p.x + r * cos(a), y: p.y + r * sin(a))
            guard let el = axElement(at: q), actionable(el), let f = axFrame(el), f.width < 400, f.height < 120 else { continue }
            let c = CGPoint(x: f.midX, y: f.midY)
            let d = dist(c, p)
            if best == nil || d < best!.d { best = (c, f, d) }
        }
        if best != nil { break }
    }
    return best.map { ($0.point, $0.frame) }
}
/// 窗口左上角的红黄绿按钮（关闭 / 最小化 / 缩放）
func trafficLights(near p: CGPoint) -> [AXUIElement]? {
    guard let w = windowInfo(at: p), p.x - w.rect.minX < 90, p.y - w.rect.minY < TITLEBAR_HEIGHT,
          let win = axWindow(at: p) else { return nil }
    let names = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute]
    let btns = names.compactMap { (n: String) -> AXUIElement? in axAttr(win, n) }
    return btns.count == 3 ? btns : nil
}
func isTitleBar(_ p: CGPoint) -> Bool {
    guard let r = windowBounds(at: p) else { return false }
    return p.y - r.minY < TITLEBAR_HEIGHT
}
func axWindow(at p: CGPoint) -> AXUIElement? {
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success,
          let el else { return nil }
    var win: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &win) == .success, let win {
        return (win as! AXUIElement)
    }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    return (role as? String) == kAXWindowRole as String ? el : nil
}
/// 把 p 处的窗口贴到所在屏幕的左半 / 右半
func tileWindow(at p: CGPoint, left: Bool) {
    guard let w = axWindow(at: p),
          let screen = NSScreen.screens.first(where: { cgRect($0.frame).contains(p) }) else { return }
    let r = cgRect(screen.visibleFrame)
    var pos = CGPoint(x: left ? r.minX : r.midX, y: r.minY)
    var size = CGSize(width: r.width / 2, height: r.height)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
}

// MARK: - 触摸点显示

final class OverlayView: NSView {
    var points: [CGPoint] = []      // 本视图坐标
    var armed = false
    var ripples: [(p: CGPoint, t: Date)] = []
    var lights: [NSPoint] = []      // 放大的红黄绿按钮中心（本视图坐标）
    var hotLight = -1
    var lightOrigins: [NSPoint] = []  // 原始小按钮的位置（从这里弹出）
    var lightsShownAt = Date(), lightsHideAt: Date?
    var lightScales: [CGFloat] = [1, 1, 1]
    var highlight: (rect: NSRect, t: Date)?
    static let LIGHT_R: CGFloat = 20
    override func draw(_ r: NSRect) {
        NSColor.clear.setFill(); bounds.fill()
        // 放大的红黄绿按钮
        if !lights.isEmpty {
            let now = Date()
            let t = now.timeIntervalSince(lightsShownAt)
            // 阻尼弹簧：0 → 1，略微过冲后回弹
            let sp = CGFloat(max(0, 1 - exp(-t * 9) * cos(t * 15)))
            var alpha: CGFloat = min(1, CGFloat(t) / 0.08)
            var shrink: CGFloat = 1
            if let h = lightsHideAt {
                let k = CGFloat(min(1, now.timeIntervalSince(h) / 0.16))
                alpha *= 1 - k; shrink = 1 - 0.35 * k
            }
            for i in 0..<3 {
                let target: CGFloat = i == hotLight ? 1.28 : 1
                lightScales[i] += (target - lightScales[i]) * 0.35
            }
            let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
            let glyphs = ["✕", "−", "+"]
            let R = OverlayView.LIGHT_R
            let pos = lights.indices.map { i -> NSPoint in
                let o = i < lightOrigins.count ? lightOrigins[i] : lights[i]
                return NSPoint(x: o.x + (lights[i].x - o.x) * sp, y: o.y + (lights[i].y - o.y) * sp)
            }
            let pad = (R + 10) * shrink * (0.4 + 0.6 * sp)
            let bg = NSRect(x: pos[0].x - pad, y: pos[0].y - pad, width: pos[2].x - pos[0].x + 2 * pad, height: 2 * pad)
            NSColor.black.withAlphaComponent(0.35 * alpha).setFill()
            NSBezierPath(roundedRect: bg, xRadius: pad, yRadius: pad).fill()
            for (i, c) in pos.enumerated() {
                let rr = R * (0.3 + 0.7 * sp) * lightScales[i] * shrink
                colors[i].withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)).fill()
                if i == hotLight {
                    NSColor.white.withAlphaComponent(0.7 * alpha).setStroke()
                    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rr - 3, y: c.y - rr - 3, width: 2 * rr + 6, height: 2 * rr + 6))
                    ring.lineWidth = 2; ring.stroke()
                }
                let g = NSAttributedString(string: glyphs[i], attributes: [.font: NSFont.boldSystemFont(ofSize: max(1, rr * 0.9)),
                                                                         .foregroundColor: NSColor.black.withAlphaComponent(0.6 * alpha)])
                g.draw(at: NSPoint(x: c.x - g.size().width / 2, y: c.y - g.size().height / 2))
            }
        }
        // 吸附目标高亮
        if let h = highlight {
            let k = Date().timeIntervalSince(h.t) / 0.35
            if k < 1 {
                NSColor.controlAccentColor.withAlphaComponent(0.9 * (1 - k)).setStroke()
                let p = NSBezierPath(roundedRect: h.rect.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6); p.lineWidth = 3; p.stroke()
            } else { highlight = nil }
        }
        for p in points {
            let c: NSColor = armed ? .systemOrange : .white
            c.withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)).fill()
            c.withAlphaComponent(0.8).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)); ring.lineWidth = 2; ring.stroke()
        }
        let now = Date()
        ripples.removeAll { now.timeIntervalSince($0.t) > 0.35 }
        for rp in ripples {
            let k = now.timeIntervalSince(rp.t) / 0.35, rad = 24 + 30 * k
            NSColor.white.withAlphaComponent(0.6 * (1 - k)).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: rp.p.x - rad, y: rp.p.y - rad, width: 2 * rad, height: 2 * rad)); ring.lineWidth = 2; ring.stroke()
        }
    }
}

final class Overlay {
    var window: NSWindow?
    let view = OverlayView()
    func attach(to screen: NSScreen?) {
        window?.orderOut(nil); window = nil
        guard let screen else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.contentView = view
        w.orderFrontRegardless()
        window = w
    }
    func show(_ pts: [CGPoint], armed: Bool) {
        guard Pref.showTouches.on, let w = window else { if !view.points.isEmpty { view.points = []; view.needsDisplay = true }; return }
        view.points = pts.map { let n = nsPoint($0); return NSPoint(x: n.x - w.frame.minX, y: n.y - w.frame.minY) }
        view.armed = armed
        view.needsDisplay = true
    }
    func local(_ p: CGPoint) -> NSPoint {
        guard let w = window else { return .zero }
        let n = nsPoint(p); return NSPoint(x: n.x - w.frame.minX, y: n.y - w.frame.minY)
    }
    func localRect(_ r: CGRect) -> NSRect {
        let a = local(CGPoint(x: r.minX, y: r.maxY))
        return NSRect(x: a.x, y: a.y, width: r.width, height: r.height)
    }
    /// 显示放大的红黄绿按钮（centers 为 CG 坐标）
    var animTimer: Timer?
    func showLights(_ centers: [CGPoint], hot: Int, origins: [CGPoint]? = nil) {
        if view.lights.isEmpty || view.lightsHideAt != nil {      // 新弹出
            view.lightsShownAt = Date(); view.lightsHideAt = nil; view.lightScales = [1, 1, 1]
            view.lightOrigins = (origins ?? centers).map { local($0) }
        }
        view.lights = centers.map { local($0) }; view.hotLight = hot
        startAnim()
    }
    func hideLights() {
        guard !view.lights.isEmpty, view.lightsHideAt == nil else { return }
        view.lightsHideAt = Date(); view.hotLight = -1
        startAnim()
    }
    private func startAnim() {
        view.needsDisplay = true
        guard animTimer == nil else { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let v = self.view
            if let h = v.lightsHideAt, Date().timeIntervalSince(h) > 0.17 {
                v.lights = []; v.lightsHideAt = nil
            }
            v.needsDisplay = true
            let settled = Date().timeIntervalSince(v.lightsShownAt) > 0.8 && v.lightScales.enumerated().allSatisfy { i, sc in
                abs(sc - (i == v.hotLight ? 1.28 : 1)) < 0.005 }
            if v.lights.isEmpty || (settled && v.lightsHideAt == nil) { t.invalidate(); self.animTimer = nil }
        }
    }
    func flash(_ frame: CGRect) {
        view.highlight = (localRect(frame), Date())
        for i in 1...8 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { self.view.needsDisplay = true } }
    }
    func ripple(_ p: CGPoint) {
        guard Pref.showTouches.on, let w = window else { return }
        let n = nsPoint(p)
        view.ripples.append((NSPoint(x: n.x - w.frame.minX, y: n.y - w.frame.minY), Date()))
        for i in 1...8 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { self.view.needsDisplay = true } }
    }
}

// MARK: - 惯性滚动

final class Momentum {
    var vx = 0.0, vy = 0.0
    var timer: Timer?
    func start(vx: Double, vy: Double) {
        stop(sendEnd: false)
        guard Pref.momentum.on, hypot(vx, vy) > MOMENTUM_MIN * 4 else { return }
        self.vx = vx; self.vy = vy
        var first = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.vx *= MOMENTUM_DECAY; self.vy *= MOMENTUM_DECAY
            if hypot(self.vx, self.vy) < MOMENTUM_MIN { self.stop(sendEnd: true); return }
            scroll(dx: self.vx / 60, dy: self.vy / 60, momentum: first ? 1 : 2)
            first = false
        }
    }
    func stop(sendEnd: Bool = true) {
        if timer != nil && sendEnd { scroll(dx: 0, dy: 0, momentum: 3) }
        timer?.invalidate(); timer = nil
    }
}

// MARK: - 手势识别

enum Mode { case idle, undecided, armed, drag, windowDrag, scroll, pinch, edge, direct, lights, done }

final class Gestures {
    var mode = Mode.idle
    var maxFingers = 0
    var start = CGPoint.zero, last = CGPoint.zero
    var startTime = Date()
    var lastClickTime = Date.distantPast, lastClickPos = CGPoint.zero, clickCount = 1
    var longPressToken = 0
    var multiStart = CGPoint.zero, lastCentroid = CGPoint.zero
    var pinchRef = 0.0, pinchBase = 0.0
    var screen = CGRect.zero
    var edgeTop = false, edgeBottom = false
    var samples: [(p: CGPoint, t: TimeInterval)] = []
    let momentum = Momentum()
    let overlay = Overlay()
    var lightBtns: [AXUIElement] = []
    var lightCenters: [CGPoint] = []
    var lightsSticky = false, lightsToken = 0
    var mirror = false
    func dismissLights() { lightsSticky = false; lightsToken += 1; overlay.hideLights() }
    func hotIndex(_ p: CGPoint) -> Int {
        guard let i = lightCenters.indices.min(by: { dist(lightCenters[$0], p) < dist(lightCenters[$1], p) }),
              dist(lightCenters[i], p) < 30 else { return -1 }
        return i
    }

    func velocity() -> CGVector {
        guard let a = samples.first, let b = samples.last, b.t - a.t > 0.01 else { return .zero }
        return CGVector(dx: (b.p.x - a.p.x) / (b.t - a.t), dy: (b.p.y - a.p.y) / (b.t - a.t))
    }
    func sample(_ p: CGPoint) {
        let t = ProcessInfo.processInfo.systemUptime
        samples.append((p, t))
        samples.removeAll { t - $0.t > 0.08 }
    }

    func update(_ touches: [Touch]) {
        overlay.show(touches.map { $0.p }, armed: mode == .armed || mode == .drag)
        let n = touches.count
        if n == 0 { end(); return }
        if mode == .idle { begin(touches) }
        if n > maxFingers {
            let firstFinger = maxFingers == 0
            if maxFingers == 1 {
                if mode == .drag || mode == .windowDrag || mode == .direct { mouse(.leftMouseUp, last) }
                if mode == .lights { dismissLights() }
                if mode == .scroll { scroll(dx: 0, dy: 0, phase: 4) }
            }
            maxFingers = n
            longPressToken += 1
            multiStart = centroid(touches); lastCentroid = multiStart
            samples = []
            if n == 2 { pinchBase = dist(touches[0].p, touches[1].p); pinchRef = pinchBase }
            // 第一根手指落下时保留 begin() 设定的特殊模式
            if mode != .done && !(firstFinger && (mode == .direct || mode == .lights)) { mode = .undecided }
        }
        if maxFingers == 1 { one(touches[0].p) }
        else if maxFingers == 2 && n == 2 { two(touches) }
        else if maxFingers >= 3 && n >= 3 { three(touches) }
    }

    func begin(_ t: [Touch]) {
        cursor.hide()
        momentum.stop()
        mode = .undecided; maxFingers = 0
        start = t[0].p; last = start; startTime = Date(); samples = []
        edgeTop = Pref.edgeGestures.on && start.y < screen.minY + EDGE
        edgeBottom = Pref.edgeGestures.on && start.y > screen.maxY - EDGE
        mouse(.mouseMoved, start)
        longPressToken += 1
        // 放大的红黄绿按钮已停留在屏幕上：这一下点按用来选择或关闭
        if lightsSticky {
            let i = hotIndex(start)
            dismissLights()
            if i >= 0 { AXUIElementPerformAction(lightBtns[i], kAXPressAction as CFString); overlay.ripple(lightCenters[i]) }
            mode = .done
            return
        }
        // iPhone 镜像：一对一直接触控（按下 / 拖动 / 松开）
        // （滑动 → 触控板连续滚动，iPhone 会当成手指滑动；长按后拖动 → 按住拖动）
        mirror = Pref.iphoneDirect.on && !edgeTop && !edgeBottom && isIPhoneMirroring(start)
        scrollDiscrete = mirror
        dbg("begin p=\(start) mirror=\(mirror) win=\(windowInfo(at: start).map { "\($0.pid) \($0.rect)" } ?? "nil") edge=\(edgeTop)/\(edgeBottom)")
        // 窗口左上角：放大的红黄绿按钮
        if !mirror, Pref.bigLights.on, let btns = trafficLights(near: start) {
            let frames = btns.compactMap(axFrame)
            if frames.count == 3 {
                lightBtns = btns
                let anchor = CGPoint(x: frames[0].midX + 14, y: frames[0].midY + 16)
                lightCenters = (0..<3).map { CGPoint(x: anchor.x + Double($0) * 52, y: anchor.y) }
                mode = .lights
                overlay.showLights(lightCenters, hot: hotIndex(start), origins: frames.map { CGPoint(x: $0.midX, y: $0.midY) })
                return
            }
        }
        let token = longPressToken
        DispatchQueue.main.asyncAfter(deadline: .now() + LONG_PRESS) { [self] in
            if token == longPressToken && mode == .undecided && maxFingers == 1 && mirror {
                mode = .drag                       // iPhone 长按：按住不放，可再拖动
                mouse(.leftMouseDown, last)
                overlay.show([last], armed: true)
            } else if token == longPressToken && mode == .undecided && maxFingers == 1 {
                mode = .armed
                overlay.show([last], armed: true)
            }
        }
    }

    func one(_ p: CGPoint) {
        let prev = last
        last = p
        sample(p)
        switch mode {
        case .undecided where dist(p, start) > TAP_MOVE:
            longPressToken += 1
            if edgeTop || edgeBottom { mode = .edge; return }
            if !Pref.scrollMode.on && !mirror {
                mode = .drag; mouse(.leftMouseDown, start); mouse(.leftMouseDragged, p)
            } else if !mirror && isTitleBar(start) {
                mode = .windowDrag; mouse(.leftMouseDown, start); mouse(.leftMouseDragged, p)
            } else {
                mode = .scroll
                mouse(.mouseMoved, start)
                scroll(dx: 0, dy: 0, phase: 1)
                scroll(dx: p.x - start.x, dy: p.y - start.y)
            }
        case .armed where dist(p, start) > TAP_MOVE:
            mode = .drag
            mouse(.leftMouseDown, start)
            mouse(.leftMouseDragged, p)
        case .drag, .windowDrag, .direct:
            mouse(.leftMouseDragged, p)
        case .lights:
            overlay.showLights(lightCenters, hot: hotIndex(p))
        case .scroll:
            scroll(dx: p.x - prev.x, dy: p.y - prev.y)
        case .edge:
            if edgeTop && p.y - start.y > EDGE_SWIPE { mode = .done; key(49, .maskCommand) }          // ⌘空格
            else if edgeBottom && start.y - p.y > EDGE_SWIPE {                                        // 呼出 Dock
                mode = .done; summonDock(x: p.x)
            }
        default: break
        }
    }

    /// 把 Dock 拉到 M14t：光标贴住底边，连续向下“推”约 0.5 秒（macOS 靠这个动作把 Dock 移到另一块屏幕）
    func summonDock(x: CGFloat) {
        let bottom = CGPoint(x: min(max(x, screen.minX + 40), screen.maxX - 40), y: screen.maxY - 1)
        mouse(.mouseMoved, CGPoint(x: bottom.x, y: bottom.y - 40))
        for i in 1...20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.025) {
                guard let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                                      mouseCursorPosition: bottom, mouseButton: .left) else { return }
                e.setIntegerValueField(.mouseEventDeltaY, value: 8)
                e.postTagged()
            }
        }
    }

    func two(_ t: [Touch]) {
        let c = centroid(t), d = dist(t[0].p, t[1].p)
        sample(c)
        if mode == .undecided {
            if abs(d - pinchBase) > PINCH_START { mode = .pinch; pinchRef = d }
            else if dist(c, multiStart) > TAP_MOVE {
                mode = .scroll; mouse(.mouseMoved, c); scroll(dx: 0, dy: 0, phase: 1)
            }
        }
        if mode == .scroll {
            scroll(dx: c.x - lastCentroid.x, dy: c.y - lastCentroid.y)
        } else if mode == .pinch {
            if d / pinchRef > PINCH_STEP { key(24, .maskCommand); pinchRef = d }        // ⌘=
            else if pinchRef / d > PINCH_STEP { key(27, .maskCommand); pinchRef = d }   // ⌘-
        }
        lastCentroid = c
    }

    func three(_ t: [Touch]) {
        guard mode == .undecided else { return }
        let c = centroid(t), dx = c.x - multiStart.x, dy = c.y - multiStart.y
        guard hypot(dx, dy) > SWIPE3_DIST else { return }
        mode = .done
        if abs(dx) > abs(dy) { key(dx < 0 ? 124 : 123, .maskControl) }   // 左滑→右边的桌面
        else { key(dy < 0 ? 126 : 125, .maskControl) }                   // 上滑→调度中心
    }

    func end() {
        dbg("end mode=\(mode) fingers=\(maxFingers) discreteSent=\(discreteSent)"); discreteSent = 0
        longPressToken += 1
        let dur = Date().timeIntervalSince(startTime)
        let v = velocity()
        if maxFingers == 1 {
            switch mode {
            case .undecided:
                var target = start
                if Pref.snapTargets.on && !mirror, let s = snapTarget(start) { target = s.point; overlay.flash(s.frame) }
                if Date().timeIntervalSince(lastClickTime) < DOUBLE_TAP_TIME && dist(target, lastClickPos) < DOUBLE_TAP_DIST {
                    clickCount += 1
                } else { clickCount = 1; lastClickPos = target }
                click(lastClickPos, clicks: clickCount)
                lastClickTime = Date()
                overlay.ripple(start)
            case .armed:
                rightClick(start); overlay.ripple(start)
            case .drag, .direct:
                mouse(.leftMouseUp, last)
            case .lights where dist(last, start) < TAP_MOVE:
                // 轻点：按钮留在屏幕上，下一次点按选择；4 秒不点自动消失
                lightsSticky = true; lightsToken += 1
                overlay.showLights(lightCenters, hot: -1)
                let tok = lightsToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in if tok == lightsToken { dismissLights() } }
            case .lights:
                // 按住滑到某个按钮上松开：直接执行
                let i = hotIndex(last)
                dismissLights()
                if i >= 0 { AXUIElementPerformAction(lightBtns[i], kAXPressAction as CFString); overlay.ripple(lightCenters[i]) }
            case .windowDrag:
                mouse(.leftMouseUp, last)
                if Pref.windowFlick.on && abs(v.dx) > FLICK_SPEED && abs(v.dx) > abs(v.dy) * 1.5 {
                    let p = last
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tileWindow(at: p, left: v.dx < 0) }
                }
            case .scroll:
                scroll(dx: 0, dy: 0, phase: 4)
                if !mirror { momentum.start(vx: v.dx, vy: v.dy) }   // iPhone 镜像由 iOS 自己做惯性
            default: break
            }
        } else if maxFingers == 2 {
            if mode == .undecided && dur < TWO_TAP_TIME {
                rightClick(multiStart); overlay.ripple(multiStart)
            } else if mode == .scroll {
                scroll(dx: 0, dy: 0, phase: 4)
                if !mirror { momentum.start(vx: v.dx, vy: v.dy) }   // iPhone 镜像由 iOS 自己做惯性
            }
        }
        mode = .idle; maxFingers = 0
        overlay.show([], armed: false)
        cursor.showSoon()                  // 只在手指按着屏幕时隐藏光标
    }
}

// MARK: - HID 输入

final class Driver {
    let g = Gestures()
    var manager: IOHIDManager?
    var openResult: IOReturn = -1
    var devices = 0
    var onStatus: (() -> Void)?

    func findScreen() {
        let s = NSScreen.screens.first { $0.localizedName.contains("M14t") }
        if let s, let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            g.screen = CGDisplayBounds(CGDirectDisplayID(num.uint32Value))
        } else {
            g.screen = .zero
        }
        g.overlay.attach(to: s)
        onStatus?()
    }

    func map(_ x: Int, _ y: Int) -> CGPoint {
        let r = g.screen
        return CGPoint(x: r.minX + Double(x) / TOUCH_MAX_X * r.width,
                       y: r.minY + Double(y) / TOUCH_MAX_Y * r.height)
    }

    var reports = 0
    func handle(_ rep: UnsafeMutablePointer<UInt8>, _ len: Int) {
        reports += 1
        guard len >= 40, rep[0] == REPORT_ID, g.screen != .zero else { return }
        let count = min(Int(rep[2]), 5)
        var touches: [Touch] = []
        for i in 0..<count {
            let o = 3 + 7 * i
            guard rep[o] & 1 == 1 else { continue }          // Tip Switch
            let id = Int(rep[o + 1]) | Int(rep[o + 2]) << 8
            let x = Int(rep[o + 3]) | Int(rep[o + 4]) << 8
            let y = Int(rep[o + 5]) | Int(rep[o + 6]) << 8
            touches.append(Touch(id: id, p: map(x, y)))
        }
        touches.sort { $0.id < $1.id }
        g.update(touches)
    }

    func start() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(m, { ctx, _, _, _, _, rep, len in
            Unmanaged<Driver>.fromOpaque(ctx!).takeUnretainedValue().handle(rep, len)
        }, ctx)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, _ in
            let d = Unmanaged<Driver>.fromOpaque(ctx!).takeUnretainedValue(); d.devices += 1; d.onStatus?()
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, _ in
            let d = Unmanaged<Driver>.fromOpaque(ctx!).takeUnretainedValue(); d.devices = max(0, d.devices - 1); d.onStatus?()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        openResult = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        findScreen()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.findScreen() }
    }
}

// MARK: - 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate {
    let driver = Driver()
    var item: NSStatusItem!
    var statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var prefItems: [Pref: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        for p in Pref.allCases {
            let mi = NSMenuItem(title: p.rawValue, action: #selector(toggle(_:)), keyEquivalent: "")
            mi.representedObject = p.rawValue
            mi.state = p.on ? .on : .off
            prefItems[p] = mi
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "打开「输入监控」设置", action: #selector(openInput), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开「辅助功能」设置", action: #selector(openAX), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新启动", action: #selector(restart), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 M14tTouch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        driver.onStatus = { [weak self] in self?.refresh() }
        driver.start()
        // 真实鼠标 / 触控板一动，就把光标显示回来（本驱动发出的事件带 MAGIC 标记，忽略）
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                                     .leftMouseDragged, .scrollWheel, .otherMouseDown]) { e in
            if e.cgEvent?.getIntegerValueField(.eventSourceUserData) != MAGIC { cursor.show() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    @objc func toggle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = Pref(rawValue: raw) else { return }
        p.on.toggle()
        sender.state = p.on ? .on : .off
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let hid = driver.openResult == kIOReturnSuccess
        let scr = driver.g.screen != .zero
        let ok = ax && hid && scr && driver.devices > 0
        item.button?.title = ok ? "☝︎" : "☝︎!"
        var s: [String] = []
        s.append(hid ? "输入监控 ✓" : "输入监控 ✗（授权后点「重新启动」）")
        s.append(ax ? "辅助功能 ✓" : "辅助功能 ✗")
        s.append(scr ? "M14t 屏幕 ✓" : "未找到 M14t 屏幕")
        s.append(driver.devices > 0 ? "触控 ✓" : "未找到触控设备")
        statusLine.title = s.joined(separator: "  ")
        let line = String(format: "%@ hid=0x%x ax=%d screen=%@ devices=%d reports=%d\n",
                          Date().description, driver.openResult, ax ? 1 : 0, "\(driver.g.screen)", driver.devices, driver.reports)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/M14tTouch.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    @objc func openInput() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func restart() {
        let path = Bundle.main.bundlePath
        let p = Process(); p.launchPath = "/bin/sh"; p.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
