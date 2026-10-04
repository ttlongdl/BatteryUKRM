ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BatteryUKRMProbe
BatteryUKRMProbe_FILES = Probe.xm
BatteryUKRMProbe_CFLAGS = -fobjc-arc
BatteryUKRMProbe_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
