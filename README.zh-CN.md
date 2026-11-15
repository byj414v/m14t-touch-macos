# M14t Touch for macOS

[English](README.md) | **简体中文**

把联想 ThinkVision M14t 便携触摸屏变成 Mac 上的 iPad 式触摸屏。免费，无需付费软件或开发者账号。在 M5 MacBook Pro、macOS 27 上测试。

## 功能 Features

- 单指滑动滚动（带惯性）、点按、双击、长按右键、按住拖动
- 双指滚动 / 捏合缩放（⌘+ / ⌘−）/ 双指轻点右键
- 三指左右切换桌面、上滑调度中心
- 标题栏拖动窗口，甩动窗口到左右半屏
- 顶边下滑：聚焦搜索；底边上滑：呼出 Dock
- 只在手指按着屏幕时隐藏鼠标光标
- **放大的红黄绿按钮**：按住或轻点窗口左上角，弹出带弹簧动画的大按钮
- **点按自动吸附**：没点准时自动吸附到附近按钮 / 菜单项
- **iPhone 镜像**：点按、滑动翻页、滚动列表（滑动不如触控板跟手，不支持捏合，原因见研究笔记）
- 菜单栏图标可开关以上每一项

## 安装 Install

需要 Xcode 命令行工具（`xcode-select --install`）。

```bash
cd M14tTouch
bash build.sh               # 编译、签名、安装到 ~/Applications 并启动
bash install_autostart.sh   # 可选：开机自启
```

首次运行需在"系统设置 → 隐私与安全性"中给 M14tTouch 打开：
- **输入监控**（读取触摸屏原始数据）
- **辅助功能**（发送鼠标 / 键盘事件、操作窗口按钮）

> 提示：用自签名的固定代码签名证书（在钥匙串助理里创建，名称 `M14tTouch Local Signing`），
> 重新编译后系统授权不会失效。没有证书时 build.sh 会用临时签名。

触摸屏背面开关请拨到 **Windows** 模式。

## 文档 Docs

- [使用说明 Usage](docs/zh-CN/USAGE.md)：全部手势、菜单选项、自启与卸载
- [实现原理 Architecture](docs/zh-CN/ARCHITECTURE.md)：HID 解析、手势状态机、事件输出、签名与权限
- [研究笔记 Research](docs/zh-CN/RESEARCH.md)：原生触屏界面与 iPhone 镜像的实验和结论
- [常见问题 Troubleshooting](docs/zh-CN/TROUBLESHOOTING.md)

## 硬件信息 Hardware notes

- 触控器：Wacom "Pen and multitouch sensor"，VID `0x2D1F`，PID `0x524C`
- 报告：Report ID 12，40 字节，最多 5 点；X 0–12372，Y 0–6960

## 目录 Layout

| 目录 | 内容 |
|---|---|
| `M14tTouch/` | 驱动本体（Swift 单文件）+ 编译 / 自启脚本 |
| `M14tTouchTest/` | 引导式触摸测试工具（全屏，记录原始报告） |
| `TouchUI/` | 尝试激活 macOS 原生触屏界面的实验（见下） |

## 关于 macOS 原生触屏界面 Native touch UI

macOS 27 为触屏 MacBook Pro 增加了触控界面（放大的红黄绿按钮、更大的菜单等）。实验结论：

- 系统会收到 M14t 的触摸，但 BackBoard 因为它不是**内置**设备（`BuiltIn: 0`）而丢弃：
  `ignoring digitizer event ... from unsupported service`
- 不降低安全性的方法都已试过，均无效：显示器覆盖 `DisplaySupportsTouch`、`hidutil` 改属性、
  创建虚拟内置触摸屏（需要 Apple 授权）、伪造直接触摸事件。
- 唯一可能的路线是无代码 kext（`TouchUI/M14tBuiltIn.kext`，未测试），需要在恢复模式降低启动安全性，**不推荐**。

因此本项目在驱动里模拟了部分效果（放大红黄绿按钮、点按吸附）。

## 免责声明 Disclaimer

非官方项目，与 Apple、Lenovo、Wacom 无关。使用了少量私有 API（后台隐藏光标），系统更新后可能失效，风险自负。
