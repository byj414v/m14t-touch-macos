#!/bin/bash
# 编译 → 用固定的本机证书签名 → 安装到 ~/Applications → 启动
# 证书 "M14tTouch Local Signing" 在登录钥匙串里；签名身份不变，系统授权就不会失效。
set -e
cd "$(dirname "$0")"
IDENTITY="M14tTouch Local Signing"
APP=M14tTouch.app

mkdir -p $APP/Contents/MacOS
swiftc -O -target arm64-apple-macos14.0 main.swift -o $APP/Contents/MacOS/M14tTouch -framework AppKit -framework IOKit
# 有固定证书就用它（授权不会因重新编译失效），否则退回临时签名
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier local.m14t.touch $APP
else
    echo "未找到证书 \"$IDENTITY\"，使用临时签名（每次重新编译后需重新授权）"
    codesign --force --sign - --identifier local.m14t.touch $APP
fi

AGENT=gui/$(id -u)/local.m14t.touch
if launchctl print $AGENT >/dev/null 2>&1; then
    # 已设置开机自启：先停服务，替换后再由 launchd 重启
    launchctl bootout $AGENT 2>/dev/null || true
    sleep 1
    mkdir -p ~/Applications && rm -rf ~/Applications/$APP && cp -R $APP ~/Applications/
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.m14t.touch.plist
else
    pkill -f 'MacOS/M14tTouch' 2>/dev/null || true
    sleep 1
    mkdir -p ~/Applications && rm -rf ~/Applications/$APP && cp -R $APP ~/Applications/
    open ~/Applications/$APP
fi
echo "已安装并启动 ~/Applications/$APP"
