# 研究笔记 Research notes

[English](../RESEARCH.md) | **简体中文**

这些是开发时的实验记录。环境：MacBook Pro 14"（M5），macOS 27.2.1，Lenovo ThinkVision M14t。

## 原生触屏界面 Native touch UI

macOS 27 为触屏 MacBook Pro 增加了触控界面：按下时放大的红黄绿按钮、更大的菜单、更大的点击区域等。目标是让 M14t 也触发这些界面。

### 系统怎么处理 M14t 的触摸

系统日志（`log stream`）显示，WindowServer 的直接触摸处理器收到了 M14t 的每一次触摸，但直接丢弃：

```
[com.apple.BackBoard:TouchEvents] ignoring digitizer event for display <main> from unsupported service:
  <BKIOHIDService ... eventSource: mouse; primaryUsagePage: 0xD; primaryUsage: 0x4;
   name: Pen and multitouch sensor; transport: USB> ... BuiltIn: 0
```

BackBoard 只接受**内置**（`BuiltIn = 1`）、与主显示器绑定的触摸屏。外接 USB 触摸屏的 `Built-In` 属性由 IOKit 驱动在匹配时设定，用户态改不了。

### 已尝试的方法

| 方法 | 是否需要降低安全性 | 结果 |
|---|---|---|
| 显示器覆盖文件 `DisplaySupportsTouch = true`（`TouchUI/enable_touch_ui.sh`） | 否（需要 sudo） | CoreDisplay 认为显示器支持触摸，但触摸仍被丢弃 |
| `hidutil property --set '{"Built-In":true}'` | 否 | 命令返回成功，读回为空，被驱动忽略 |
| 创建虚拟内置触摸屏 `IOHIDUserDeviceCreateWithProperties`（`TouchUI/vtouch.swift`） | 否 | 即使 root 也失败，需要 Apple 签发的 `com.apple.developer.hid.virtual.device` 授权 |
| 伪造直接触摸 CGEvent（类型 59 + IOHIDEvent，`TouchUI/inject_probe.swift`） | 否 | App 收不到 |
| 无代码 kext，用 `IOHIDProviderPropertyMerger` 合并 `Built-In = true`（`TouchUI/M14tBuiltIn.kext`） | **是**：恢复模式里降低启动安全性并允许第三方扩展 | 未测试 |
| DriverKit 驱动 | 需要 Apple 批准的授权，或关闭 SIP | 未尝试 |

结论：不降低安全性无法激活原生触屏界面。即使用 kext 把 `Built-In` 设为 1，日志里还有 `eventSource: mouse` 和显示器绑定（`<main>`）两个条件，可能仍不满足，例如需要 M14t 作为主显示器（合盖模式）。

因此本项目选择在驱动里**模拟**部分效果：放大的红黄绿按钮、点按吸附。

## iPhone 镜像 iPhone Mirroring

原生触屏 Mac 上，iPhone 镜像可以直接触控（跟手滑动、多指）。外接触摸屏能做到多少：

### 事件测试

在 iPhone 镜像窗口上发送不同事件，截图对比：

| 事件 | iPhone 是否滚动 |
|---|---|
| 连续滚动（像素、带 phase，触控板式） | 否 |
| 连续滚动 + 合成的手势事件（类型 29，字段照抄真实触控板） | 否 |
| 按住鼠标拖动（带 delta） | 否 |
| **滚轮式滚动（非连续）** | **是** |
| **原样回放录制的真实触控板事件**（`CGEvent(withData:)`） | 页面跟着动，但停在半途 |

回放真实触控板事件时，iPhone 能收到"手指在移动"，但收不到"手指离开"，页面停在半途，直到下一个手势开始才弹回。"松手"信号不在 CGEvent 事件流里（事件监听器录不到），第三方程序无法发送。

### 结论

- 驱动在 iPhone 镜像里用滚轮式滚动：能滚、能翻页，但不如触控板跟手，不支持捏合。
- 原生触屏 Mac 很可能通过 iPhone 镜像与 iPhone 之间的私有加密连接直接发送多点触控，外部程序进不去，除非向苹果签名的进程注入代码（需要关闭 SIP）。
- 另一条路是 WebDriverAgent（XCTest）在 iPhone 上合成真实多点触控：免费 Apple ID 即可，但只能在手势完成后整段重放，不跟手。

## M14t 硬件 Hardware

| 项目 | 值 |
|---|---|
| 显示器 | Vendor `0x30AE`，Product `0x62A3`，1920×1080 |
| 触控器 | Wacom "Pen and multitouch sensor"，USB VID `0x2D1F` PID `0x524C`，接在 Realtek USB 2.1 Hub 后 |
| 模式开关 | Windows（本驱动使用）/ Android-Chrome |
| 触摸报告 | Report ID 12，40 字节，5 个触点，X 0–12372，Y 0–6960 |
| 识别类型 | macOS 把它当成 `eventSource: mouse` 的外接数位板，自身没有触控功能，只能当鼠标单击 |
