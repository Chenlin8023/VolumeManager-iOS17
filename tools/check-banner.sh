#!/bin/bash
# 判定字面量编码：UTF-8（-a）vs UTF-16LE（strings -e l）
OBJ=/home/dministrator/vm-rootless-full/.theos/obj/VolManAudioQueue.dylib
cd /mnt/d/WorkBudy/iOS-Tweaks/release || exit 1
rm -rf /tmp/v27 && mkdir -p /tmp/v27
dpkg-deb -x com.local.volmanaudioqueue.full_1.2.7_iphoneos-arm64.deb /tmp/v27
DEBDY=/tmp/v27/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManAudioQueue.dylib
for f in "$OBJ" "$DEBDY"; do
  echo "===== $f ====="
  echo "--- ASCII (strings -a) 里含 vmaq/v1.2 的行 ---"
  strings -a "$f" | grep -E "vmaq|v1\.2\." | head -5
  echo "--- UTF-16LE (strings -e l) 里含 vmaq/v1.2/注入 的行 ---"
  strings -e l -a "$f" | grep -E "vmaq|v1\.2\." | head -6
  echo "--- UTF-16LE banner 原文 ---"
  strings -e l -a "$f" | grep "bundle=%@" | head -2
done
