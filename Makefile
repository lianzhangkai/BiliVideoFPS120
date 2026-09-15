ARCHS = arm64 arm64e
TARGET = iphone:clang:13.7:13.0
INSTALL_TARGET_PROCESSES = BiliBili

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BiliVideoFPS120
BiliVideoFPS120_FILES = Tweak.xm
BiliVideoFPS120_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations
BiliVideoFPS120_FRAMEWORKS = UIKit Foundation QuartzCore AVFoundation CoreMedia

include $(THEOS_MAKE_PATH)/tweak.mk
