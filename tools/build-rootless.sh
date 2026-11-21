#!/bin/bash
# ============================================================================
# VolumeManager rootless 发布构建（v1.2.5 起）
#
#   用法: build-rootless.sh [full|patch|dylib|all]   （默认 all）
#   dylib（2.1.0 起）：纯注入母本容器——无 SpringBoard 组件/无面板/无闸门
#   （-DVMDYLIB=1：内嵌音量弹窗 + Documents 自包含配置），deb 仅作下载容器，
#   提取 dylib → TrollFools/JailFools 注入目标 App，全程不依赖 Sileo。
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
VARIANT="${1:-all}"

# 原版组件来源（SBHUD 等 SpringBoard 侧闭源组件；dylib 容器形态不需要）：
COMPONENT_SRC=""
if [ "$VARIANT" != "dylib" ]; then
  for cand in "$OUT/com.local.volmanaudioqueue.full_1.2.1_iphoneos-arm64.deb" \
              "$OUT/com.local.volmanaudioqueue.full_1.2.0_iphoneos-arm64.deb" ; do
    [ -f "$cand" ] && { COMPONENT_SRC="$cand"; break; }
  done
fi

[ -n "$COMPONENT_SRC" ] || [ "$VARIANT" = "dylib" ] || \
  { echo "!! 找不到任何组件来源（full_1.2.1 / full_1.2.0 均不存在）"; exit 1; }

build_one() {
  local kind="$1"
  local DST="$HOME/vm-rootless-$kind"
  rm -rf "$DST"
  mkdir -p "$DST/layout/DEBIAN" "$DST/layout/Library/MobileSubstrate/DynamicLibraries"

  cp "$REPO/packaging/Makefile.$kind"        "$DST/Makefile"
  cp "$REPO/packaging/control.$kind"         "$DST/control"
  cp "$REPO/src/VolManAudioQueue/Tweak.xm"   "$DST/"
  # dylib 容器的过滤器 = 永不匹配的惰性 plist（tweak.mk 强制要求 plist 存在；
  # Bundles 指向不存在的 bundle id → 永不注入 = 误装也完全惰性）。
  if [ "$kind" = "dylib" ]; then
    cp "$REPO/packaging/VolManAudioQueue.noop.plist" "$DST/VolManAudioQueue.plist"
  else
    cp "$REPO/src/VolManAudioQueue/VolManAudioQueue.plist" "$DST/"
  fi
  cp "$REPO/packaging/DEBIAN/postinst.$kind" "$DST/layout/DEBIAN/postinst"
  cp "$REPO/packaging/DEBIAN/postrm.$kind"   "$DST/layout/DEBIAN/postrm"
  chmod +x "$DST/layout/DEBIAN/postinst" "$DST/layout/DEBIAN/postrm"

  # Windows 侧可能带入 CR，全部清理
  find "$DST" -type f -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
  chmod 644 "$DST/Tweak.xm" "$DST/Makefile" "$DST/control" "$DST/VolManAudioQueue.plist" 2>/dev/null || true

  # dylib 变体：打包期改写引擎 banner（源文件不动）——实机验收=容器日志头可区分 dylib 形态
  if [ "$kind" = "dylib" ]; then
    sed -i -E 's/=== v[0-9][0-9.]* 注入/=== v2.1.4-dylib 注入/' "$DST/Tweak.xm"
  fi

  # 原版组件（dylib 容器不需要）
  if [ "$kind" != "dylib" ]; then
    rm -rf "$DST/orig" && mkdir -p "$DST/orig"
    dpkg-deb -x "$COMPONENT_SRC" "$DST/orig"
  fi
  local DL="$DST/layout/Library/MobileSubstrate/DynamicLibraries"
  if [ "$kind" = "full" ]; then
    cp -a "$DST/orig/var/jb/Library/." "$DST/layout/Library/"
    # 排除：旧引擎（由本次 make 重新编译）、原版有杂音的引擎
    rm -f "$DL/VolManAudioQueue.dylib" "$DL/VolManAudioQueue.plist" \
          "$DL/VolumeManagerAudioQueue.dylib" "$DL/VolumeManagerAudioQueue.plist"
    # v2.0.0：排除原版闭源栈中已被自研替代的组件（升级残留由 postinst 清退）
    #   旧面板 VolumeManagerPrefs.bundle + 旧 PreferenceLoader entry
    #     （自研 VolManPrefsPanel 替代；图标仍从 orig 旧面板 bundle 取用）
    #   原版主模块 VolumeManager.dylib（混音层已并入 VolManAudioQueue 引擎）
    #   净化模块 VolManPrefsClean（依附旧面板，面板退役即退役）
    rm -rf "$DST/layout/Library/PreferenceBundles/VolumeManagerPrefs.bundle"
    rm -f  "$DST/layout/Library/PreferenceLoader/Preferences/VolumeManagerPrefs.plist"
    rm -f  "$DL/VolumeManager.dylib" "$DL/VolumeManager.plist" \
           "$DL/VolManPrefsClean.dylib" "$DL/VolManPrefsClean.plist"
  elif [ "$kind" = "dylib" ]; then
    # dylib（2.1.0）：纯注入母本容器——layout 只含 tweak.mk 产物
    #（DL 引擎 dylib + 惰性 noop 过滤器），无 SBHUD/HUDPatch/面板/任何配置。
    # 用法=从 deb 提取 dylib 注入 App；误装也完全惰性（noop 过滤器永不匹配）。
    :
  else
    cp -a "$DST/orig/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManPrefsClean.dylib" \
          "$DST/orig/var/jb/Library/MobileSubstrate/DynamicLibraries/VolManPrefsClean.plist" "$DL/"
    # 净化模块权限（1.2.1 的教训：dylib 必须 755，否则静默不加载）
    chmod 755 "$DL/VolManPrefsClean.dylib"
    chmod 644 "$DL/VolManPrefsClean.plist"
  fi

  # HUD 透明补丁模块（v2.0 步骤②；CI FAT 产物，人工下载放 hudpatch-prebuilt）
  # 缺席不阻塞构建：full 照常出，透明补丁功能不进包（docs/05 §四.2）。
  if [ "$kind" = "full" ]; then
    HUDPRE="$REPO/tools/hudpatch-prebuilt"
    if [ -f "$HUDPRE/VolManHUDPatch.dylib" ] && [ -f "$HUDPRE/VolManHUDPatch.plist" ]; then
      cp -a "$HUDPRE/VolManHUDPatch.dylib" "$DL/VolManHUDPatch.dylib"
      cp -a "$HUDPRE/VolManHUDPatch.plist" "$DL/VolManHUDPatch.plist"
      chmod 755 "$DL/VolManHUDPatch.dylib"
      chmod 644 "$DL/VolManHUDPatch.plist"
      python3 "$REPO/tools/dylib_archs.py" "$DL/VolManHUDPatch.dylib"
    else
      echo "提示 — hudpatch-prebuilt 缺 VolManHUDPatch（跳过；HUD 透明补丁不进包）"
    fi
  fi

  # 自写设置面板（v2.0 步骤③；仅 full——lite 无开关/白名单 UI，不进包）
  if [ "$kind" = "full" ]; then
    PANELPRE="$REPO/tools/panel-prebuilt"
    if [ -f "$PANELPRE/VolManPrefsPanel.bundle/VolManPrefsPanel" ]; then
      PANEL_DST="$DST/layout/Library/PreferenceBundles/VolManPrefsPanel.bundle"
      mkdir -p "$PANEL_DST"
      cp -a "$PANELPRE/VolManPrefsPanel.bundle/." "$PANEL_DST/"
      # Info.plist（CI 产物不带；Preferences 加载 bundle 必需）
      cat > "$PANEL_DST/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>VolManPrefsPanel</string>
	<key>CFBundleIdentifier</key>
	<string>com.local.volmanprefspanel</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>VolManPrefsPanel</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleShortVersionString</key>
	<string>2.0.0</string>
	<key>CFBundleVersion</key>
	<string>2.0.0</string>
	<key>NSPrincipalClass</key>
	<string>VMPRootListController</string>
</dict>
</plist>
EOF
      # 图标沿用闭源面板的（三件套：@2x/@3x 缺失会导致入口图标被放大渲染）
      ICON_SRC="$DST/orig/var/jb/Library/PreferenceBundles/VolumeManagerPrefs.bundle"
      for ic in icon.png icon@2x.png icon@3x.png; do
        cp -f "$ICON_SRC/$ic" "$PANEL_DST/$ic" 2>/dev/null || true
      done
      # PreferenceLoader 入口（音量管理器）
      mkdir -p "$DST/layout/Library/PreferenceLoader/Preferences"
      cat > "$DST/layout/Library/PreferenceLoader/Preferences/VolManPrefsPanel.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>entry</key>
	<dict>
		<key>bundle</key>
		<string>VolManPrefsPanel</string>
		<key>cell</key>
		<string>PSLinkCell</string>
		<key>detail</key>
		<string>VMPRootListController</string>
		<key>icon</key>
		<string>icon.png</string>
		<key>isController</key>
		<true/>
		<key>label</key>
		<string>音量管理器</string>
	</dict>
</dict>
</plist>
EOF
      python3 "$REPO/tools/dylib_archs.py" "$PANEL_DST/VolManPrefsPanel"
      chmod -R 755 "$PANEL_DST" 2>/dev/null || true
    else
      echo "提示 — panel-prebuilt 缺 VolManPrefsPanel.bundle（跳过；自写面板不进包）"
    fi
  fi

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
  # 架构核验：引擎 dylib 必须只有 arm64；原版闭源组件（HUD 等 SpringBoard 侧）FAT 属正常。
  # lipo 在本构建机缺席（not found 被吞 → 检查空转），统一走 tools/dylib_archs.py 魔数判定。
  find "$DST/check" -name '*.dylib' -exec python3 "$REPO/tools/dylib_archs.py" {} +
  echo ""
}

case "$VARIANT" in
  full)  build_one full ;;
  patch) build_one patch ;;
  dylib) build_one dylib ;;
  all)   build_one full; build_one patch ;;
  *) echo "用法: $0 [full|patch|dylib|all]"; exit 1 ;;
esac
echo "全部完成 → $OUT"
