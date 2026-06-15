TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = KIOU
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
THEOS_DEVICE_IP = 192.168.0.49

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KiouEngineBridge

KiouEngineBridge_FILES = $(shell find Sources/KiouEngineBridge -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
# Shared logging implementation lives in ./_shared/. il2cpp / hook-engine
# headers are inline-only so they don't need to be listed here.
KiouEngineBridge_FILES += _shared/kiou_logging.m

# Build-time git short HEAD (7 chars). No -dirty suffix for now.
KIOU_ENGINE_BRIDGE_COMMIT ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

KiouEngineBridge_CFLAGS = -fobjc-arc -Wno-unused-function -DKIOU_ENGINE_BRIDGE_COMMIT=\"$(KIOU_ENGINE_BRIDGE_COMMIT)\" -I_shared
KiouEngineBridge_FRAMEWORKS = Foundation

# ---------------------------------------------------------------------------
# Hook engine selection.
#
#   default (JB / rootless): MobileSubstrate (MSHookFunction in libsubstrate)
#   BINPATCH=1              : static binary patch + __DATA,__bss SLOT
#                             dispatcher. No runtime __TEXT writes, so works
#                             on iOS 18 CSM (Sideloadly / TrollStore /
#                             AltStore / Apple Developer Program). The hook
#                             redirection lives in the patched UnityFramework
#                             cave; this dylib only publishes a function
#                             pointer into the reserved slot at constructor
#                             time. See docs/plans/kiou_engine_bridge_binpatch.md.
#
# _shared/kiou_hookengine.h picks the API at compile time.
# ---------------------------------------------------------------------------
ifeq ($(BINPATCH),1)
    KiouEngineBridge_CFLAGS  += -DKIOU_BINPATCH=1
    KiouEngineBridge_LDFLAGS  = -Wl,-undefined,error
else
    KiouEngineBridge_LDFLAGS  = -lsubstrate
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/KiouEngineBridge.dylib"
	install.exec "sleep 1; (open com.neconome.shogi 2>/dev/null || uiopen com.neconome.shogi:// 2>/dev/null || echo 'no launcher tool (uiopen/open); start KIOU manually')"

# binpatch distribution: rebuild with KIOU_BINPATCH=1, drop libsubstrate, copy
# into packages/binpatch/ for the build_patched_ipa.sh pipeline.
binpatch::
	$(MAKE) BINPATCH=1 clean
	$(MAKE) BINPATCH=1 all
	$(ECHO_NOTHING)mkdir -p packages/binpatch$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/KiouEngineBridge.dylib packages/binpatch/KiouEngineBridge.dylib$(ECHO_END)
	@echo "binpatch dylib -> packages/binpatch/KiouEngineBridge.dylib"
	@echo "--- otool -L (must NOT list libsubstrate or libdobby) ---"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/binpatch/KiouEngineBridge.dylib 2>/dev/null \
	  || otool -L packages/binpatch/KiouEngineBridge.dylib 2>/dev/null \
	  || echo "(otool unavailable on host; inspect the dylib on a Mac/iOS device)"
