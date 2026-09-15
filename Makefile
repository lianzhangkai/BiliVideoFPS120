ARCHS = arm64 arm64e
TARGET = iphone:clang:13.7:13.0
INSTALL_TARGET_PROCESSES = Bilibili

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BiliVideoFPS120
BiliVideoFPS120_FILES = Tweak.xm
BiliVideoFPS120_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations
BiliVideoFPS120_FRAMEWORKS = Foundation UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
