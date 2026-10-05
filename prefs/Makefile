include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = BatteryUKRMPrefs
BatteryUKRMPrefs_FILES = BUKRootListController.m
BatteryUKRMPrefs_FRAMEWORKS = UIKit
BatteryUKRMPrefs_PRIVATE_FRAMEWORKS = Preferences
BatteryUKRMPrefs_INSTALL_PATH = /Library/PreferenceBundles
BatteryUKRMPrefs_CFLAGS = -fobjc-arc
BatteryUKRMPrefs_EXTRA_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "mkdir -p $(THEOS_PACKAGE_DIR)/Library/PreferenceLoader/Preferences"
	install.exec "cp entry.plist $(THEOS_PACKAGE_DIR)/Library/PreferenceLoader/Preferences/BatteryUKRM.plist"
