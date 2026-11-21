#!/bin/bash
# dylib 2.1.0 容器 deb 本地核验（一次性排障脚本，风格同 check-banner.sh）
set -u
DEB=/mnt/d/WorkBudy/iOS-Tweaks/release/com.local.volmanaudioqueue.dylib_2.1.4_iphoneos-arm64.deb
AR=/mnt/d/WorkBudy/iOS-Tweaks/VolumeManager/tools/dylib_archs.py
W=/tmp/vm-dylib-check

rm -rf "$W" && mkdir -p "$W"

echo "=== 1) control ==="
dpkg-deb -f "$DEB" Package Version Architecture Name

echo "=== 2) layout 结构 ==="
dpkg-deb -x "$DEB" "$W/x"
( cd "$W/x" && find . -print | sort )

echo "=== 3) 惰性过滤器内容 ==="
cat "$W/x/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManAudioQueue.plist"

echo "=== 4) 引擎架构（必须只有 arm64）==="
python3 "$AR" "$W/x/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManAudioQueue.dylib"

echo "=== 5) banner + dylib 字面量（UTF-16LE 针）==="
strings -e l "$W/x/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManAudioQueue.dylib" \
  | grep -E "=== v" || echo "!! 未找到 banner"
echo -n "v2.1.4-dylib 命中数: "
strings -e l "$W/x/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManAudioQueue.dylib" \
  | grep -c "v2.1.4-dylib" || true
echo -n "dylib 形态字面量（无闸门 reason）命中数: "
strings -e l "$W/x/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManAudioQueue.dylib" \
  | grep -c "dylib" || true

echo "=== 6) UIKit 链接（LC_LOAD_DYLIB 明文）==="
strings -a "$W/x/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManAudioQueue.dylib" \
  | grep -i "UIKit.framework" || echo "!! 未找到 UIKit 链接"

echo "=== 7) 脚本语法 / CRLF / 权限 ==="
dpkg-deb -e "$DEB" "$W/e"
sh -n "$W/e/postinst" && echo "postinst sh -n OK"
sh -n "$W/e/postrm" && echo "postrm sh -n OK"
printf 'postinst CR 行数: %s\n' "$(grep -c $'\r' "$W/e/postinst" || true)"
printf 'postrm CR 行数: %s\n' "$(grep -c $'\r' "$W/e/postrm" || true)"
stat -c '%a %n' "$W/e/postinst" "$W/e/postrm"

echo "=== 8) 确认无 lite/SBHUD/面板残留 ==="
if find "$W/x" -iname '*lite*' -o -iname '*SBHUD*' -o -iname '*PrefsPanel*' | grep -q .; then
  echo "!! 发现不应存在的组件"
  find "$W/x" -iname '*lite*' -o -iname '*SBHUD*' -o -iname '*PrefsPanel*'
else
  echo "OK：纯 dylib 容器"
fi

echo "=== 全部核验完成 ==="
