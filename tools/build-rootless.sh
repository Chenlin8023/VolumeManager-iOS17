#!/bin/bash
# ============================================================================
# VolumeManager rootless 发布构建（v1.2.5 起）
#
#   用法: build-rootless.sh [full|patch|all]   （默认 all）
#
#   产出: release/com.local.volmanaudioqueue[_full]_<版本>_iphoneos-arm64.deb
#
#   原理（docs/02-构建与安装.md 的自动化版）：
#     · staging 目录放 Makefile.<variant> + control.<variant> + Tweak.xm +
#       注入过滤器 + layout/，`make package FINALPACKAGE=1` 在 rootless scheme
#       下编译引擎 dylib（arm64 单切片）并连同 layout 打包，自动补 /var/jb 前缀；
#     · 原版组件（面板 VolumeManagerPrefs[已净化] / HUD / 主模块 / 净化模块）
#       从最新稳定全量包提取复用，排除旧引擎与有杂音的原版 VolumeManagerAudioQueue；
#     · 交付 rootless 形态 deb —— roothide 设备安装时由转换器自动改写全部路径，
#       无需任何原生 arm64e 变体（v1.2.5 起废弃原生形态）。
# ============================================================================
set -euo pipefail
export THEOS="$HOME/theos"
export PATH="$THEOS/bin:$PATH"

REPO=/mnt/d/WorkBudy/iOS-Tweaks/VolumeManager
OUT=/mnt/d/WorkBudy/iOS-Tweaks/release
# 原版组件来源：最新稳定全量包（含净化模块执行位修复与已净化面板），按优先级回退
COMPONENT_SRC=""
for cand in "$OUT/com.local.volmanaudioqueue.full_1.2.1_iphoneos-arm64.deb" \
            "$OUT/com.local.volmanaudioqueue.full_1.2.0_iphoneos-arm64.deb" ; do
  [ -f "$cand" ] && { COMPONENT_SRC="$cand"; break; }
done
VARIANT="${1:-all}"

[ -n "$COMPONENT_SRC" ] || { echo "!! 找不到任何组件来源（full_1.2.1 / full_1.2.0 均不存在）"; exit 1; }

build_one() {
  local kind="$1"
  local DST="$HOME/vm-rootless-$kind"
  rm -rf "$DST"
  mkdir -p "$DST/layout/DEBIAN" "$DST/layout/Library/MobileSubstrate/DynamicLibraries"

  cp "$REPO/packaging/Makefile.$kind"        "$DST/Makefile"
  cp "$REPO/packaging/control.$kind"         "$DST/control"
  cp "$REPO/src/VolManAudioQueue/Tweak.xm"   "$DST/"
  cp "$REPO/src/VolManAudioQueue/VolManAudioQueue.plist" "$DST/"
  cp "$REPO/packaging/DEBIAN/postinst.$kind" "$DST/layout/DEBIAN/postinst"
  cp "$REPO/packaging/DEBIAN/postrm.$kind"   "$DST/layout/DEBIAN/postrm"
  chmod +x "$DST/layout/DEBIAN/postinst" "$DST/layout/DEBIAN/postrm"

  # Windows 侧可能带入 CR，全部清理
  find "$DST" -type f -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
  chmod 644 "$DST/Tweak.xm" "$DST/Makefile" "$DST/control" "$DST/VolManAudioQueue.plist" 2>/dev/null || true

  # 原版组件
  rm -rf "$DST/orig" && mkdir -p "$DST/orig"
  dpkg-deb -x "$COMPONENT_SRC" "$DST/orig"
  local DL="$DST/layout/Library/MobileSubstrate/DynamicLibraries"
  if [ "$kind" = "full" ]; then
    cp -a "$DST/orig/var/jb/Library/." "$DST/layout/Library/"
    # 排除：旧引擎（由本次 make 重新编译）、原版有杂音的引擎
    rm -f "$DL/VolManAudioQueue.dylib" "$DL/VolManAudioQueue.plist" \
          "$DL/VolumeManagerAudioQueue.dylib" "$DL/VolumeManagerAudioQueue.plist"
  else
    cp -a "$DST/orig/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManPrefsClean.dylib" \
          "$DST/orig/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManPrefsClean.plist" "$DL/"
  fi
  # 净化模块权限（1.2.1 的教训：dylib 必须 755，否则静默不加载）
  chmod 755 "$DL/VolManPrefsClean.dylib"
  chmod 644 "$DL/VolManPrefsClean.plist"

  cd "$DST"
  rm -f packages/*.deb 2>/dev/null || true
  make clean >/dev/null 2>&1 || true
  make package FINALPACKAGE=1 2>&1 | tail -12
  cp -f packages/*.deb "$OUT/"
  echo ""
  echo "=== [$kind] 产物 ==="
  local deb
  deb=$(ls -1t packages/*.deb | head -1)
  dpkg-deb -I "$deb" | grep -E "^(Package|Version|Architecture| Size)" || dpkg-deb -I "$deb" | head -8
  echo "--- 架构核验（必须只有 arm64）---"
  rm -rf "$DST/check" && mkdir -p "$DST/check"
  dpkg-deb -x "$deb" "$DST/check"
  find "$DST/check" -name '*.dylib' -exec sh -c 'echo "$(basename "$1"): $(lipo -archs "$1")"' _ {} \;
  echo ""
}

case "$VARIANT" in
  full)  build_one full ;;
  patch) build_one patch ;;
  all)   build_one full; build_one patch ;;
  *) echo "用法: $0 [full|patch|all]"; exit 1 ;;
esac
echo "全部完成 → $OUT"
