#!/bin/bash
# 还原：删除 enable_touch_ui.sh 写入的 M14t 显示器覆盖文件。
if [ "$EUID" -ne 0 ]; then echo "请用 sudo 运行: sudo bash $0"; exit 1; fi
FILE="/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-30ae/DisplayProductID-62a3"
rm -f "$FILE" && echo "已删除: $FILE"
rmdir "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-30ae" 2>/dev/null
echo "请拔插 M14t 或注销重新登录使其生效。"
