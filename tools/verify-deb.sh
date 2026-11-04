#!/bin/bash
# 核验 rootless 发布 deb：元信息 + dylib 架构切片（必须只有 arm64）
cd /mnt/d/WorkBudy/iOS-Tweaks/release || exit 1
for d in com.local.volmanaudioqueue.full_1.3.0_iphoneos-arm64.deb com.local.volmanaudioqueue_1.3.0_iphoneos-arm64.deb; do
  echo "### $d"
  dpkg-deb -f "$d" Package Version Architecture
  rm -rf /tmp/chk && mkdir -p /tmp/chk
  dpkg-deb -x "$d" /tmp/chk
  find /tmp/chk -name "*.dylib" | while read -r f; do
    echo "  $(basename "$f"): $(file -b "$f" | cut -c1-70)"
  done
  echo ""
done
