# VolManHUDPatch —— HUD 透明化运行时补丁（v2.0 步骤②，docs/05 §四.2）
#
# ⚠ 只能在 CI（Apple 工具链）构建，本地 WSL 禁止构建本模块：
#   SpringBoard 只加载 arm64e 切片，arm64 单切片被 dyld 静默拒载（硬规则 3，
#   2026-11-18 再度实锤：rootless 线引擎/PrefsClean 均从未进入任何系统进程）；
#   本地 clang19 的 arm64e 切片过不了 PAC 关（硬规则 8，Jikan 四轮实锤）。
# 构建入口 = .github/workflows/hudpatch.yml（FAT 双切片）；
# 产物人工下载放到 tools/hudpatch-prebuilt/，由 build-rootless.sh 打入 full 包。
ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VolManHUDPatch

VolManHUDPatch_FILES = VolManHUDPatch.xm
VolManHUDPatch_FRAMEWORKS = Foundation UIKit
VolManHUDPatch_CFLAGS = -fobjc-arc -Wall -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk
