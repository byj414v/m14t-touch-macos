// M14t 触控引导测试程序
// 读取 Lenovo M14t (Wacom 2D1F:524C) 的原始触控数据，按步骤引导测试，并记录日志。
// 编译: swiftc -O main.swift -o M14tTouchTest -framework AppKit -framework IOKit
// 运行: ./M14tTouchTest [日志路径]

import AppKit
import IOKit.hid

let VID = 0x2d1f, PID = 0x524c
let TOUCH_MAX_X = 12372.0, TOUCH_MAX_Y = 6960.0

struct Step { let title: String; let detail: String }
let steps: [Step] = [
    Step(title: "单指点按", detail: "用一根手指在屏幕不同位置点按 5 次"),
    Step(title: "单指拖动", detail: "一根手指按住，慢慢画一个大圆圈"),
    Step(title: "长按", detail: "一根手指按住不动 2 秒，然后抬起，重复 2 次"),
    Step(title: "双指滑动", detail: "两根手指并拢，一起上下滑动几次"),
    Step(title: "双指点按", detail: "两根手指同时点一下，重复 3 次"),
    Step(title: "双指缩放", detail: "两根手指捏合、再张开，重复 2 次"),
    Step(title: "三指左右滑", detail: "三根手指一起左右滑动几次"),
]

struct Slot { var tip = 0; var id = 0; var x = 0; var y = 0; var t = Date.distantPast }

final class State {
    var slots: [String: Slot] = [:]
    var contactCount = 0
    var step = 0
    var stepRaw = 0, stepSys = 0, stepMaxContacts = 0
    var totalRaw = 0, totalSys = 0
    var summary: [Int: String] = [:]
    var lastSys: NSPoint? = nil
    var deviceCount = 0
    var openResult: IOReturn = 0
    weak var view: TouchView?
    var log: FileHandle?
    let start = Date()

    func w(_ s: String) {
        let line = String(format: "%8.3f ", Date().timeIntervalSince(start)) + s + "\n"
        log?.write(line.data(using: .utf8)!)
    }
    func closeStep() {
        summary[step] = "STEP \(step + 1) \(steps[step].title): 原始数据包=\(stepRaw) 系统鼠标事件=\(stepSys) 最大触点数=\(stepMaxContacts)"
    }
    func beginStep(_ i: Int) {
        step = i; stepRaw = 0; stepSys = 0; stepMaxContacts = 0
        w("=== STEP \(i + 1) \(steps[i].title) ===")
    }
}
let state = State()

// MARK: - HID

func slotKey(_ e: IOHIDElement, _ parent: IOHIDElement) -> String {
    let dev = IOHIDElementGetDevice(e)
    return "\(Unmanaged.passUnretained(dev).toOpaque())-\(IOHIDElementGetCookie(parent))"
}

let valueCallback: IOHIDValueCallback = { _, _, _, value in
    let e = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e)
    let v = IOHIDValueGetIntegerValue(value)
    if page == 0x0d && usage == 0x54 {          // Contact Count
        state.contactCount = v
        state.stepMaxContacts = max(state.stepMaxContacts, v)
        state.view?.needsDisplay = true
        return
    }
    guard let parent = IOHIDElementGetParent(e),
          IOHIDElementGetUsagePage(parent) == 0x0d,
          IOHIDElementGetUsage(parent) == 0x22 else { return }   // Finger 集合
    let key = slotKey(e, parent)
    var s = state.slots[key] ?? Slot()
    switch (page, usage) {
    case (0x0d, 0x42): s.tip = v
    case (0x0d, 0x51): s.id = v
    case (0x01, 0x30): s.x = v
    case (0x01, 0x31): s.y = v
    default: return
    }
    s.t = Date()
    state.slots[key] = s
    state.view?.needsDisplay = true
}

let reportCallback: IOHIDReportCallback = { _, _, sender, _, rid, report, len in
    state.stepRaw += 1; state.totalRaw += 1
    if state.stepRaw <= 600 {
        let hex = (0..<len).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
        let dev = sender.map { String(UInt(bitPattern: $0) & 0xffff, radix: 16) } ?? "?"
        state.w("R dev=\(dev) rid=\(rid) len=\(len) \(hex)")
    }
    state.view?.needsDisplay = true
}

func setupHID() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID] as CFDictionary)
    IOHIDManagerRegisterInputValueCallback(mgr, valueCallback, nil)
    IOHIDManagerRegisterInputReportCallback(mgr, reportCallback, nil)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    state.openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
    state.deviceCount = devs.count
    state.w(String(format: "HID open=0x%x devices=%d", state.openResult, devs.count))
    // 记录元素布局，便于之后写驱动
    for (i, d) in devs.enumerated() {
        state.w("--- device \(i) ptr=\(String(UInt(bitPattern: Unmanaged.passUnretained(d).toOpaque()) & 0xffff, radix: 16))")
        for e in (IOHIDDeviceCopyMatchingElements(d, nil, 0) as? [IOHIDElement]) ?? [] {
            let t = IOHIDElementGetType(e)
            let kind = t == kIOHIDElementTypeCollection ? "coll" : t == kIOHIDElementTypeFeature ? "feat" : "in"
            let parent = IOHIDElementGetParent(e).map { IOHIDElementGetCookie($0) } ?? 0
            state.w(String(format: "E %@ cookie=%d parent=%d rid=%d page=0x%x usage=0x%x size=%d count=%d min=%d max=%d",
                           kind, IOHIDElementGetCookie(e), parent, IOHIDElementGetReportID(e),
                           IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e),
                           IOHIDElementGetReportSize(e), IOHIDElementGetReportCount(e),
                           IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e)))
        }
    }
    // 保持 manager 存活
    managerRef = mgr
}
var managerRef: IOHIDManager?

// MARK: - 视图

final class TouchView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue, .systemOrange, .systemPurple,
                             .systemTeal, .systemYellow, .systemPink, .systemBrown, .systemIndigo]

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        bounds.fill()
        let w = bounds.width, h = bounds.height
        let st = steps[state.step]

        func text(_ s: String, _ size: CGFloat, _ y: CGFloat, _ color: NSColor = .white, bold: Bool = false) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: color]
            let str = NSAttributedString(string: s, attributes: attrs)
            str.draw(at: NSPoint(x: (w - str.size().width) / 2, y: y))
        }
        text("第 \(state.step + 1) / \(steps.count) 步：\(st.title)", 34, 40, bold: true)
        text(st.detail, 24, 92, NSColor(calibratedWhite: 0.85, alpha: 1))
        let hidOK = state.openResult == 0 && state.deviceCount > 0
        let hidStatus = hidOK ? "触控设备已连接 (\(state.deviceCount))"
                              : String(format: "触控设备未打开 (0x%x)，请检查连接或输入监控权限", state.openResult)
        text(hidStatus, 16, 140, hidOK ? .systemGreen : .systemRed)
        text("本步原始数据包: \(state.stepRaw)    系统鼠标事件: \(state.stepSys)    当前触点数: \(state.contactCount)    本步最大触点数: \(state.stepMaxContacts)",
             18, 168, .systemYellow)
        text("完成后点「下一步」(或按空格 / →)，Esc 退出", 15, h - 120, NSColor(calibratedWhite: 0.6, alpha: 1))

        // 触点
        let now = Date()
        for (i, s) in state.slots.values.sorted(by: { $0.id < $1.id }).enumerated()
            where s.tip == 1 && now.timeIntervalSince(s.t) < 0.4 {
            let p = NSPoint(x: Double(s.x) / TOUCH_MAX_X * w, y: Double(s.y) / TOUCH_MAX_Y * h)
            let r: CGFloat = 36
            colors[i % colors.count].withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
            let label = NSAttributedString(string: "id \(s.id)", attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white])
            label.draw(at: NSPoint(x: p.x - label.size().width / 2, y: p.y - 8))
        }
        // 系统光标位置（用来对比 macOS 自己是否响应触控）
        if let p = state.lastSys {
            NSColor.white.setStroke()
            let path = NSBezierPath(); path.lineWidth = 2
            path.move(to: NSPoint(x: p.x - 15, y: p.y)); path.line(to: NSPoint(x: p.x + 15, y: p.y))
            path.move(to: NSPoint(x: p.x, y: p.y - 15)); path.line(to: NSPoint(x: p.x, y: p.y + 15))
            path.stroke()
        }
    }

    func sys(_ name: String, _ e: NSEvent, extra: String = "") {
        let p = convert(e.locationInWindow, from: nil)
        state.lastSys = p
        state.stepSys += 1; state.totalSys += 1
        state.w(String(format: "SYS %@ x=%.0f y=%.0f %@", name, p.x, p.y, extra))
        needsDisplay = true
    }
    override func mouseDown(with e: NSEvent) { sys("mouseDown", e, extra: "clicks=\(e.clickCount)") }
    override func mouseDragged(with e: NSEvent) { sys("mouseDragged", e) }
    override func mouseUp(with e: NSEvent) { sys("mouseUp", e) }
    override func rightMouseDown(with e: NSEvent) { sys("rightMouseDown", e) }
    override func scrollWheel(with e: NSEvent) { sys("scroll", e, extra: String(format: "dx=%.1f dy=%.1f", e.scrollingDeltaX, e.scrollingDeltaY)) }
    override func magnify(with e: NSEvent) { sys("magnify", e, extra: String(format: "%.3f", e.magnification)) }
    override func swipe(with e: NSEvent) { sys("swipe", e, extra: "dx=\(e.deltaX) dy=\(e.deltaY)") }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49, 124: (NSApp.delegate as? AppDelegate)?.next()
        case 123: (NSApp.delegate as? AppDelegate)?.prev()
        case 53: (NSApp.delegate as? AppDelegate)?.finish()
        default: break
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let view = TouchView()
    var nextBtn: NSButton!

    func applicationDidFinishLaunching(_ n: Notification) {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                 : FileManager.default.currentDirectoryPath + "/m14t_touch_log.txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        state.log = FileHandle(forWritingAtPath: path)
        state.w("M14t touch test log")
        state.view = view

        let screen = NSScreen.screens.first { $0.localizedName.contains("M14t") } ?? NSScreen.main!
        state.w("screen=\(screen.localizedName) frame=\(screen.frame)")
        window = NSWindow(contentRect: screen.visibleFrame, styleMask: [.titled, .closable],
                          backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.visibleFrame, display: true)
        window.title = "M14t 触控测试"
        window.contentView = view
        window.acceptsMouseMovedEvents = true

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded; b.controlSize = .large
            b.font = .systemFont(ofSize: 22)
            b.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(b)
            return b
        }
        let prevBtn = button("上一步", #selector(prev))
        nextBtn = button("下一步", #selector(next))
        let quitBtn = button("退出", #selector(finish))
        NSLayoutConstraint.activate([
            nextBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            nextBtn.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40),
            nextBtn.widthAnchor.constraint(equalToConstant: 200),
            prevBtn.trailingAnchor.constraint(equalTo: nextBtn.leadingAnchor, constant: -30),
            prevBtn.centerYAnchor.constraint(equalTo: nextBtn.centerYAnchor),
            quitBtn.leadingAnchor.constraint(equalTo: nextBtn.trailingAnchor, constant: 30),
            quitBtn.centerYAnchor.constraint(equalTo: nextBtn.centerYAnchor),
        ])

        setupHID()
        // 记录窗口收到的所有系统事件类型（含 macOS 27 的直接触摸事件）
        NSEvent.addLocalMonitorForEvents(matching: .any) { e in
            let t = e.type.rawValue
            if e.type != .mouseMoved && e.type != .keyDown && e.type != .keyUp && e.type != .appKitDefined
                && e.type != .systemDefined && e.type != .flagsChanged && e.type != .cursorUpdate {
                if ![1, 2, 6, 22].contains(Int(t)) {   // 鼠标按下/抬起/拖动/滚动由 TouchView 记录
                    state.stepSys += 1; state.totalSys += 1
                    state.w("EV type=\(t) \(e.type) subtype=\(e.subtype.rawValue)")
                }
            }
            return e
        }
        state.beginStep(0)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        // 定时刷新，让抬起的手指消失
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.view.needsDisplay = true }
    }

    @objc func next() {
        state.closeStep()
        if state.step + 1 >= steps.count { finish(); return }
        state.beginStep(state.step + 1)
        nextBtn.title = state.step + 1 == steps.count ? "完成" : "下一步"
        view.needsDisplay = true
    }
    @objc func prev() {
        guard state.step > 0 else { return }
        state.closeStep()
        state.beginStep(state.step - 1)
        nextBtn.title = "下一步"
        view.needsDisplay = true
    }
    @objc func finish() {
        state.closeStep()
        state.w("=== SUMMARY === raw=\(state.totalRaw) sys=\(state.totalSys)")
        for k in state.summary.keys.sorted() { state.w(state.summary[k]!) }
        try? state.log?.synchronize()
        NSApp.terminate(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { try? state.log?.synchronize() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
