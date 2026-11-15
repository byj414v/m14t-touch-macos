# 常见问题 Troubleshooting

### 触摸完全没反应

1. 菜单栏图标显示 `☝︎!` 时，点开菜单看第一行，哪一项是 ✗：
   - **输入监控 ✗**：在"隐私与安全性 → 输入监控"里打开 M14tTouch，再点菜单里的「重新启动」。
   - **辅助功能 ✗**：在"隐私与安全性 → 辅助功能"里打开 M14tTouch。
   - **未找到 M14t 屏幕**：检查显示器是否点亮。
   - **未找到触控设备**：拔掉 M14t 再插上，等几秒（触控器比显示晚出现）；确认背面开关在 **Windows**。
2. 状态日志 `~/Library/Logs/M14tTouch.log` 每 2 秒写一行：
   `hid=0x0`（输入监控正常；`0xe00002e2` 表示缺权限）、`ax=1`（辅助功能正常）、`devices=` 触控设备数、`reports=` 收到的触摸报告数。触摸时 `reports` 不增长，说明数据没进来。

### 重新编译后权限失效

临时签名每次都变，系统会当成新 App。按 [ARCHITECTURE.md](ARCHITECTURE.md#7-签名与权限-signing-and-tcc) 创建固定的自签名证书。如果设置里已经有旧的条目但不起作用：

```bash
tccutil reset ListenEvent local.m14t.touch
tccutil reset Accessibility local.m14t.touch
```

然后重新运行 App 并授权。

### 编译时卡住不动

`codesign` 第一次使用证书时会弹出钥匙串对话框，输入登录密码并点"始终允许"。

### 点击后鼠标指针又出现

部分 App 被点击后会自己显示光标，驱动会在约 0.1 秒内重新隐藏。不想隐藏可在菜单里关闭"触摸时隐藏光标"。

### 从底边上滑不出 Dock

Dock 需要设置在屏幕底部，并且出现在 M14t 所在的屏幕上。macOS 只在鼠标顶住某个屏幕的底边时把 Dock 移过去，驱动会自动模拟这个动作。

### iPhone 镜像里滑动卡顿

这是目前的上限，原因见 [RESEARCH.md](RESEARCH.md#iphone-镜像-iphone-mirroring)。

### 想还原显示器覆盖文件

```bash
sudo bash TouchUI/disable_touch_ui.sh
```
