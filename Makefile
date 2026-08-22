TARGET := iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Follow

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DokaVip

DokaVip_FILES = Tweak.x
DokaVip_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
