ARCHS = arm64
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VolManPrefsClean

VolManPrefsClean_FILES = VolManPrefsClean.xm
VolManPrefsClean_FRAMEWORKS = Foundation UIKit
VolManPrefsClean_CFLAGS = -fobjc-arc -Wall -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk
