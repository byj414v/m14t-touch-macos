#!/bin/bash
# 实验：把 Lenovo M14t 标记为"支持触控的显示器"，尝试让 macOS 27 启用触控界面。
# 用法: sudo bash enable_touch_ui.sh      还原: sudo bash disable_touch_ui.sh
# 只新增一个显示器覆盖文件，不改系统文件、不需要关闭 SIP。
set -e
if [ "$EUID" -ne 0 ]; then echo "请用 sudo 运行: sudo bash $0"; exit 1; fi

DIR="/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-30ae"
FILE="$DIR/DisplayProductID-62a3"
mkdir -p "$DIR"
if [ -f "$FILE" ]; then cp "$FILE" "$FILE.bak.$(date +%s)"; echo "已备份原有覆盖文件"; fi

cat > "$FILE" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>DisplayProductName</key><string>M14t</string>
    <key>DisplayVendorID</key><integer>12462</integer>
    <key>DisplayProductID</key><integer>25251</integer>
    <key>DisplaySupportsTouch</key><true/>
</dict>
</plist>
EOF
chmod 644 "$FILE"
plutil -lint "$FILE"
echo "已写入: $FILE"
echo "下一步：拔掉 M14t 的线，等 5 秒再插回（或注销重新登录），然后告诉 Claude 重新测试。"
