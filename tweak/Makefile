TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

TWEAK_NAME = LongmaoPlus
LongmaoPlus_FILES = LongmaoPlus.m
LongmaoPlus_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations
LongmaoPlus_FRAMEWORKS = UIKit Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
