# VolManPrefsPanel —— 自写设置面板（v2.0 步骤③，docs/05 §五）
#
# ⚠ 只能在 CI（Apple 工具链）构建，本地 WSL 禁止构建本模块：
#   面板二进制由 Preferences（arm64e 系统进程）加载，arm64 单切片会被拒载
#   （2026-11-18 定案，见系统进程拒载记录）；含自有 ObjC 类（PSListController
#   子类）本地 clang19 过不了 PAC 关（硬规则 8）。
# 构建入口 = .github/workflows/panel.yml（FAT 双切片）；
# 产物人工下载放到 tools/panel-prebuilt/，由 build-rootless.sh 打入 full 包。
ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VolManPrefsPanel

VolManPrefsPanel_FILES = VMPShared.m VMPTableMediator.m VMPRootListController.m VMPWhitelistController.m VMPVolumeController.m
VolManPrefsPanel_FRAMEWORKS = Foundation UIKit
VolManPrefsPanel_PRIVATE_FRAMEWORKS = Preferences
VolManPrefsPanel_INSTALL_PATH = /Library/PreferenceBundles
VolManPrefsPanel_CFLAGS = -fobjc-arc -Wall -Wno-unused-function

include $(THEOS_MAKE_PATH)/bundle.mk
