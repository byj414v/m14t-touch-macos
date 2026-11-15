# 实现原理 Architecture

驱动是一个单文件 Swift 程序（`M14tTouch/main.swift`），作为菜单栏 App 运行，不需要内核扩展。

```
M14t 触控器 ──USB HID──▶ IOHIDManager（输入报告回调）
                              │ 解析 5 点触摸
                              ▼
                        Gestures 状态机 ──▶ CGEvent（鼠标 / 滚动 / 键盘）──▶ macOS
                              │          └▶ AXUIElement（按窗口按钮、移动窗口）
                              ▼
                        Overlay 透明窗口（触摸点、波纹、红黄绿按钮）
```

## 1. 读取触摸 HID input

- `IOHIDManager` 按 `VID 0x2D1F / PID 0x524C` 匹配，注册 input report 回调。需要**输入监控**权限（`IOHIDRequestAccess`）。
- 报告格式（Report ID 12，40 字节）：

  | 偏移 | 内容 |
  |---|---|
  | 0 | Report ID = 12 |
  | 2 | 本帧触点数 |
  | 3 + 7·i | 第 i 个触点：`flags`（bit0 = 接触）、`id` u16、`X` u16（0–12372）、`Y` u16（0–6960） |
  | 38–39 | 扫描时间 |

- 坐标按 M14t 所在屏幕的 `CGDisplayBounds` 线性映射到全局坐标。屏幕通过名字含 "M14t" 的 `NSScreen` 找到，屏幕参数变化时重新查找。

## 2. 手势状态机 Gesture state machine

`Gestures.update()` 每帧收到当前所有触点，按"本次触摸出现过的最大手指数"分派：

| 模式 Mode | 含义 |
|---|---|
| `idle` | 没有手指 |
| `undecided` | 刚按下，还没超过移动阈值（10pt） |
| `armed` | 长按 0.5s 后，等待松开（右键）或拖动 |
| `drag` / `windowDrag` | 按住鼠标拖动 / 拖窗口 |
| `scroll` | 连续滚动 |
| `pinch` | 双指缩放 |
| `edge` | 从屏幕边缘开始的手势 |
| `lights` | 放大的红黄绿按钮 |
| `done` | 本次触摸已触发一次性动作，忽略剩余 |

注意：`begin()` 设定的特殊模式（`lights`、iPhone 镜像）在第一根手指计数时必须保留，否则会被重置为 `undecided`。

主要阈值都在文件开头（`TAP_MOVE`、`LONG_PRESS`、`EDGE`、`MOMENTUM_DECAY` 等）。

## 3. 输出事件 Event output

- 所有事件用 `CGEventSource(.hidSystemState)` 生成，发到 `.cghidEventTap`，并在 `eventSourceUserData` 打上标记 `0x4D313474`（"M14t"），以便区分自己发出的事件。
- **滚动**：像素单位、连续滚动（`isContinuous = 1`），带 `scrollPhase`（字段 99）和 `momentumPhase`（字段 123），App 会当作触控板滚动处理，支持橡皮筋回弹。
- **惯性**：松手后按 60Hz 发送 momentum 阶段事件，速度每帧乘 0.94。
- **呼出 Dock**：在屏幕底边连续发送 20 个向下的 `mouseMoved`（带 deltaY），模拟鼠标顶到底边。
- **隐藏光标**：后台 App 默认不能隐藏光标。用私有的 `CGSSetConnectionProperty(..., "SetsCursorInBackground", true)` 后调用 `CGDisplayHideCursor`；再用定时器检查 `CGCursorIsVisible`，因为被点击的 App 可能自己把光标显示回来。

## 4. 辅助功能 Accessibility

- `AXUIElementCopyElementAtPosition` 找到手指下的元素。
- **吸附**：在 12 / 22 / 32pt 三圈 × 8 个方向采样，找最近的按钮、复选框、菜单项、链接等可点元素，点它的中心。
- **红黄绿按钮**：读窗口的 `AXCloseButton` / `AXMinimizeButton` / `AXZoomButton`，用 `AXPress` 执行。
- **窗口分屏**：设置窗口的 `AXPosition` / `AXSize`。

## 5. 叠加层 Overlay

一个覆盖 M14t 整个屏幕、忽略鼠标、层级为 `screenSaver` 的透明窗口。画触摸点、点按波纹、吸附高亮和红黄绿按钮。按钮动画用阻尼弹簧 `1 − e^(−9t)·cos(15t)`，从真实小按钮的位置弹出；悬停的按钮平滑放大到 1.28 倍。

## 6. iPhone 镜像 iPhone Mirroring

- 用 `CGWindowListCopyWindowInfo` 找手指下的窗口，所属 App 的 bundle id 为 `com.apple.ScreenContinuity` 时进入镜像模式。
- iPhone 镜像不认触控板式的连续滚动，也不把鼠标拖动当成滑动，只认**滚轮式（非连续）滚动**。
- 手指位移先累积，再用 120Hz 定时器以整数像素匀速发出，否则零碎的小事件会被当成点按。
- 镜像模式下关闭驱动自己的惯性，否则 iOS 会以为手指一直没松开。

## 7. 签名与权限 Signing and TCC

macOS 的隐私授权（TCC）绑定代码签名。临时签名（ad-hoc）每次编译都会变，授权随之失效。`build.sh` 优先使用钥匙串里名为 `M14tTouch Local Signing` 的自签名代码签名证书，固定 identifier `local.m14t.touch`，重新编译后授权仍然有效。

创建证书：钥匙串访问 → 证书助理 → 创建证书 → 名称 `M14tTouch Local Signing`，类型"自签名根证书"，证书类型"代码签名"。
