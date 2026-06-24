# ===========================================================================
# KiouEngineBridge — IPA-Patch tweak Makefile.
#
# Targets:
#   make            — JB rootless .deb (MSHookFunction via libsubstrate)
#   make package    — same, packaged
#   make jailed     — Dobby-static .dylib for Sideloadly injection (iOS 15+)
#   make chinlan    — Dobby-static .dylib for the statically-patched IPA path
#                     (iOS 18 sideload; the only mode that survives CSM).
#   make ipa        — patched IPA assembled from $(DECRYPTED_IPA)
# ===========================================================================

# ---------------------------------------------------------------------------
# PROJECT VARIABLES
# ---------------------------------------------------------------------------
TWEAK_NAME               := KiouEngineBridge
TWEAK_SOURCES_DIR        := Sources/$(TWEAK_NAME)

TARGET_PROCESS           := KIOU
TARGET_BUNDLE_ID         := com.neconome.shogi

# Target app version — selects the input IPA and the recipe version table.
# Override on the command line: make ipa TARGET_VERSION=1.0.2
TARGET_VERSION           ?= 1.0.1
DECRYPTED_IPA            ?= $(CURDIR)/assets/$(TARGET_VERSION)/Kiou-$(TARGET_VERSION).ipa
IPA_RECIPE               := recipes
IPA_FRAMEWORK            := UnityFramework

BUILD_COMMIT_DEFINE      := BUILD_COMMIT

# ---------------------------------------------------------------------------
# Theos boilerplate.
# ---------------------------------------------------------------------------
TARGET                   := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES := $(TARGET_PROCESS)
ARCHS                    := arm64
THEOS_PACKAGE_SCHEME     := rootless
-include .env
THEOS_DEVICE_IP          ?= 192.168.0.1

include $(THEOS)/makefiles/common.mk

$(TWEAK_NAME)_FILES      := $(shell find $(TWEAK_SOURCES_DIR) \
    \( -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp' \))
$(TWEAK_NAME)_FILES      += Sources/Chinlan/logging.m
$(TWEAK_NAME)_FILES      += Sources/Chinlan/logserver.m

BUILD_COMMIT             ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

_CONTROL_VERSION         := $(shell grep '^Version:' control | awk '{print $$2}')
# Theos sets DEBUG=1 by default; FINALPACKAGE=1 clears it for release builds.
ifneq ($(FINALPACKAGE),1)
PACKAGE_VERSION          ?= $(_CONTROL_VERSION)-dbg
else
PACKAGE_VERSION          ?= $(_CONTROL_VERSION)
endif

$(TWEAK_NAME)_CFLAGS     := -fobjc-arc -Wno-unused-function \
                            -D$(BUILD_COMMIT_DEFINE)=\"$(BUILD_COMMIT)\" \
                            -DBUILD_VERSION=\"$(PACKAGE_VERSION)\" \
                            -I$(TWEAK_SOURCES_DIR) \
                            -ISources/Chinlan
ifdef FINAL_RELEASE
$(TWEAK_NAME)_CFLAGS     += -DFINAL_RELEASE=1
endif

# Chinlan shared utilities are always compiled in. FINAL_RELEASE only turns
# debug-only helpers (like the localhost log stream) into empty stubs.
$(TWEAK_NAME)_FILES      +=
$(TWEAK_NAME)_FRAMEWORKS := Foundation UIKit

# ---------------------------------------------------------------------------
# Hook engine selection.
#
#   default (JB / rootless): MobileSubstrate (MSHookFunction via libsubstrate)
#   JAILED=1                : Dobby statically linked from vendor/dobby. No
#                             libsubstrate dependency — safe for Sideloadly /
#                             TrollStore injection on iOS 15–26.
#   CHINLAN=1               : static binary patch + __DATA,__bss SLOT
#                             dispatcher. No runtime __TEXT writes, survives
#                             iOS 18 CSM. Implies JAILED=1.
#
# Sources/Chinlan/hookengine.h picks the API at compile time via IPA_JAILED.
# ---------------------------------------------------------------------------
ifeq ($(CHINLAN),1)
    JAILED                   := 1
    $(TWEAK_NAME)_CFLAGS     += -DKIOU_CHINLAN=1 -DIPA_LOG_TO_DOCUMENTS=1
endif

ifeq ($(JAILED),1)
    $(TWEAK_NAME)_CFLAGS     += -DIPA_JAILED=1 -Ivendor/dobby/include
    $(TWEAK_NAME)_LDFLAGS    := -Lvendor/dobby/lib -ldobby -lc++ -lc++abi
ifeq ($(CHINLAN),1)
    $(TWEAK_NAME)_LDFLAGS    += -Wl,-undefined,error
endif
else
    $(TWEAK_NAME)_LDFLAGS    := -lsubstrate
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/$(TWEAK_NAME).dylib"
	install.exec "sleep 1; (open $(TARGET_BUNDLE_ID) 2>/dev/null || uiopen $(TARGET_BUNDLE_ID):// 2>/dev/null || echo 'no launcher tool; start $(TARGET_PROCESS) manually')"

jailed::
	$(MAKE) JAILED=1 clean
	$(MAKE) JAILED=1 all
	$(ECHO_NOTHING)mkdir -p packages/jailed$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib packages/jailed/$(TWEAK_NAME).dylib$(ECHO_END)
	@echo "jailed dylib -> packages/jailed/$(TWEAK_NAME).dylib"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/jailed/$(TWEAK_NAME).dylib 2>/dev/null \
	  || otool -L packages/jailed/$(TWEAK_NAME).dylib 2>/dev/null \
	  || echo "(otool unavailable)"

chinlan::
	$(MAKE) CHINLAN=1 clean
	$(MAKE) CHINLAN=1 all
	$(ECHO_NOTHING)mkdir -p packages/chinlan$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib packages/chinlan/$(TWEAK_NAME).dylib$(ECHO_END)
	@echo "chinlan dylib -> packages/chinlan/$(TWEAK_NAME).dylib"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/chinlan/$(TWEAK_NAME).dylib 2>/dev/null \
	  || otool -L packages/chinlan/$(TWEAK_NAME).dylib 2>/dev/null \
	  || echo "(otool unavailable)"

IPA_DYLIB                := $(CURDIR)/packages/chinlan/$(TWEAK_NAME).dylib

ipa:: chinlan
	@echo "==> assembling patched IPA from $(DECRYPTED_IPA) (v$(TARGET_VERSION))"
	@if [ ! -f "$(DECRYPTED_IPA)" ]; then \
	  echo "error: decrypted IPA missing at $(DECRYPTED_IPA)"; \
	  echo "       override with: make ipa TARGET_VERSION=<ver>"; \
	  exit 1; \
	fi
	@TARGET_VERSION="$(TARGET_VERSION)" ./shared/tools/build_patched_ipa.sh \
	  --recipe    "$(IPA_RECIPE)" \
	  --framework "$(IPA_FRAMEWORK)" \
	  --dylib     "$(IPA_DYLIB)" \
	  --input     "$(DECRYPTED_IPA)"

.PHONY: hooks
hooks::
	git config core.hooksPath scripts
	@echo "git hooks now resolve under scripts/"
