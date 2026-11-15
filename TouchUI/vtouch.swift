// 验证：创建一个声明为"内置 + 屏幕集成"的虚拟触摸屏，看 macOS 是否允许、BackBoard 怎么归类它。
// 用法: vtouch [秒数]   创建后在屏幕中心点按 3 次，然后保持设备存在若干秒再退出。
import Foundation
import IOKit.hid

typealias UDev = OpaquePointer
let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
typealias CreateFn = @convention(c) (CFAllocator?, CFDictionary, IOOptionBits) -> UDev?
typealias ReportFn = @convention(c) (UDev, UnsafePointer<UInt8>, CFIndex) -> IOReturn
let create = unsafeBitCast(dlsym(iokit, "IOHIDUserDeviceCreateWithProperties")!, to: CreateFn.self)
let handle = unsafeBitCast(dlsym(iokit, "IOHIDUserDeviceHandleReport")!, to: ReportFn.self)

// 单指触摸屏描述符：Report ID 1 = [tip+pad][contactID][X lo hi][Y lo hi][contactCount]
let desc: [UInt8] = [
    0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01,             // Digitizer / Touch Screen / Application
    0x85, 0x01,
    0x09, 0x22, 0xA1, 0x02,                         //   Finger / Logical
    0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,   // Tip Switch
    0x95, 0x07, 0x81, 0x03,                         //   padding
    0x09, 0x51, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,               // Contact ID
    0x05, 0x01, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x01,
    0x09, 0x30, 0x81, 0x02, 0x09, 0x31, 0x81, 0x02, // X, Y
    0xC0,
    0x05, 0x0D, 0x09, 0x54, 0x25, 0x0A, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,   // Contact Count
    0xC0,
]

let props: [String: Any] = [
    kIOHIDReportDescriptorKey: Data(desc),
    kIOHIDVendorIDKey: 0x05AC,
    kIOHIDProductIDKey: 0x7777,
    kIOHIDProductKey: "Virtual Built-In Touch Screen",
    kIOHIDTransportKey: "SPU",
    "Built-In": true,
    "DisplayIntegrated": true,
]
guard let dev = create(kCFAllocatorDefault, props as CFDictionary, 0) else {
    print("CREATE FAILED: 系统不允许创建虚拟 HID 设备（很可能需要 com.apple.developer.hid.virtual.device 授权）")
    exit(1)
}
print("CREATED virtual touch screen")
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8
sleep(2)
func report(tip: Bool, x: UInt16, y: UInt16) {
    let r: [UInt8] = [1, tip ? 1 : 0, 1, UInt8(x & 0xff), UInt8(x >> 8), UInt8(y & 0xff), UInt8(y >> 8), 1]
    let rc = r.withUnsafeBufferPointer { handle(dev, $0.baseAddress!, r.count) }
    print(String(format: "report tip=%d rc=0x%x", tip ? 1 : 0, rc))
}
for _ in 0..<3 {
    report(tip: true, x: 16384, y: 16384); usleep(80_000)
    report(tip: false, x: 16384, y: 16384); usleep(400_000)
}
Thread.sleep(forTimeInterval: seconds)
print("done")
