ARCHS = armv7
TARGET = iphone:clang:9.3:8.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AmbientMusic
AmbientMusic_FILES = Tweak.xm
AmbientMusic_FRAMEWORKS = UIKit QuartzCore CoreGraphics
AmbientMusic_CFLAGS = -fobjc-arc -fno-modules -Wno-deprecated-declarations -Wno-undeclared-selector

include $(THEOS_MAKE_PATH)/tweak.mk
