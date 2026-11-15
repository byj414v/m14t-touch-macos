#!/bin/bash
# 设置开机自启：生成 LaunchAgent 并加载。卸载：bash install_autostart.sh --remove
set -e
PLIST=~/Library/LaunchAgents/local.m14t.touch.plist
AGENT=gui/$(id -u)/local.m14t.touch
if [ "$1" = "--remove" ]; then
    launchctl bootout $AGENT 2>/dev/null || true
    rm -f "$PLIST"; echo "已取消开机自启"; exit 0
fi
mkdir -p ~/Library/LaunchAgents
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.m14t.touch</string>
    <key>ProgramArguments</key>
    <array><string>$HOME/Applications/M14tTouch.app/Contents/MacOS/M14tTouch</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PL
pkill -f 'MacOS/M14tTouch' 2>/dev/null || true
launchctl bootout $AGENT 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "已设置开机自启"
