ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BatteryUKRM
BatteryUKRM_FILES = Tweak.xm
BatteryUKRM_CFLAGS = -fobjc-arc
BatteryUKRM_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
