TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = KIOU
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
THEOS_DEVICE_IP = 192.168.0.49

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KiouEngineBridge

KiouEngineBridge_FILES = $(shell find Sources/KiouEngineBridge -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
# Shared logging implementation lives in ../_shared/. il2cpp / hook-engine
# headers are inline-only so they don't need to be listed here.
KiouEngineBridge_FILES += ../_shared/kiou_logging.m

# Build-time git short HEAD (7 chars). No -dirty suffix for now.
KIOU_ENGINE_BRIDGE_COMMIT ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

KiouEngineBridge_CFLAGS = -fobjc-arc -Wno-unused-function -DKIOU_ENGINE_BRIDGE_COMMIT=\"$(KIOU_ENGINE_BRIDGE_COMMIT)\" -I../_shared
KiouEngineBridge_FRAMEWORKS = Foundation

# ---------------------------------------------------------------------------
# Hook engine selection — mirrors KiouEditor/Makefile.
#
#   default (JB / rootless): MobileSubstrate (MSHookFunction in libsubstrate)
#   JAILED=1                : Dobby, statically linked from the KiouEditor
#                             vendor tree so we don't duplicate the .a.
#
# The vendor/ symlink points at ../KiouEditor/vendor/dobby/ so the two tweaks
# share a single Dobby checkout. _shared/kiou_hookengine.h picks the API.
# ---------------------------------------------------------------------------
ifeq ($(JAILED),1)
    KiouEngineBridge_CFLAGS  += -DKIOU_JAILED=1 -Ivendor/dobby/include
    KiouEngineBridge_LDFLAGS  = -Lvendor/dobby/lib -ldobby -lc++ -lc++abi
else
    KiouEngineBridge_LDFLAGS  = -lsubstrate
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/KiouEngineBridge.dylib"
	install.exec "sleep 1; (open com.neconome.shogi 2>/dev/null || uiopen com.neconome.shogi:// 2>/dev/null || echo 'no launcher tool (uiopen/open); start KIOU manually')"

# jailed distribution: rebuild with Dobby statically linked, copy into
# packages/jailed/ for Sideloadly injection.
jailed::
	$(MAKE) JAILED=1 clean
	$(MAKE) JAILED=1 all
	$(ECHO_NOTHING)mkdir -p packages/jailed$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/KiouEngineBridge.dylib packages/jailed/KiouEngineBridge.dylib$(ECHO_END)
	@echo "jailed dylib -> packages/jailed/KiouEngineBridge.dylib"
	@echo "--- otool -L (must NOT list libsubstrate or libdobby) ---"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/jailed/KiouEngineBridge.dylib 2>/dev/null \
	  || otool -L packages/jailed/KiouEngineBridge.dylib 2>/dev/null \
	  || echo "(otool unavailable on host; inspect the dylib on a Mac/iOS device)"
