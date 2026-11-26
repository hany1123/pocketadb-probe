ARCHS = arm64
TARGET := iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PocketADBProbe

PocketADBProbe_FILES = $(wildcard src/*.m)
PocketADBProbe_FRAMEWORKS = UIKit Foundation
PocketADBProbe_CFLAGS = -fobjc-arc \
                        -Wno-deprecated-declarations -Wno-unused-variable \
                        -Wno-unused-function -Wno-unused-const-variable
# 需要 objc/runtime 符号，让 dyld 动态查找
PocketADBProbe_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
