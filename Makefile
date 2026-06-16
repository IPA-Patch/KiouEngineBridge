TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = KIOU
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
THEOS_DEVICE_IP = 192.168.0.49

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KiouEngineBridge

KiouEngineBridge_FILES = $(shell find Sources/KiouEngineBridge -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
# Shared logging implementation lives in Sources/Common. il2cpp helpers are
# inline-only, so they don't need to be listed here.
KiouEngineBridge_FILES += Sources/Common/logging.m

# Build-time git short HEAD (7 chars). No -dirty suffix for now.
KIOU_ENGINE_BRIDGE_COMMIT ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

KiouEngineBridge_CFLAGS = -fobjc-arc -Wno-unused-function -DKIOU_ENGINE_BRIDGE_COMMIT=\"$(KIOU_ENGINE_BRIDGE_COMMIT)\" -ISources/Common
KiouEngineBridge_FRAMEWORKS = Foundation

# ---------------------------------------------------------------------------
# Hook engine selection.
#
#   default (JB / rootless): MobileSubstrate (MSHookFunction in libsubstrate)
#   JAILED=1                : Dobby statically linked from vendor/dobby. No
#                             libsubstrate dependency, so the resulting
#                             .dylib can be injected via Sideloadly into a
#                             non-jailbroken iOS 15-17 install.
#   BINPATCH=1              : static binary patch + __DATA,__bss SLOT
#                             dispatcher. No runtime __TEXT writes, so works
#                             on iOS 18 CSM (Sideloadly / TrollStore /
#                             AltStore / Apple Developer Program). The hook
#                             redirection lives in the patched UnityFramework
#                             cave; this dylib only publishes a function
#                             pointer into the reserved slot at constructor
#                             time. See docs/plans/kiou_engine_bridge_binpatch.md.
#                             Implies JAILED=1 so libsubstrate is dropped.
#
# Sources/Common/hookengine.h picks the API at compile time via IPA_JAILED.
# ---------------------------------------------------------------------------
ifeq ($(BINPATCH),1)
    JAILED                   := 1
    KiouEngineBridge_CFLAGS  += -DKIOU_BINPATCH=1 -DIPA_LOG_TO_DOCUMENTS=1
endif

ifeq ($(JAILED),1)
    KiouEngineBridge_CFLAGS  += -DIPA_JAILED=1 -Ivendor/dobby/include
    # Dobby is C++; pull in libc++ for __cxa_guard_*, __cxa_pure_virtual, etc.
    KiouEngineBridge_LDFLAGS := -Lvendor/dobby/lib -ldobby -lc++ -lc++abi
ifeq ($(BINPATCH),1)
    # binpatch path never actually invokes Dobby at runtime but keeps the
    # same link shape; refuse to silently fall back to a host hook engine.
    KiouEngineBridge_LDFLAGS += -Wl,-undefined,error
endif
else
    KiouEngineBridge_LDFLAGS  = -lsubstrate
endif

include $(THEOS_MAKE_PATH)/tweak.mk

.PHONY: jailed binpatch ipa hooks

after-install::
	install.exec "chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/KiouEngineBridge.dylib"
	install.exec "sleep 1; (open com.neconome.shogi 2>/dev/null || uiopen com.neconome.shogi:// 2>/dev/null || echo 'no launcher tool (uiopen/open); start KIOU manually')"

# jailed distribution: rebuild with Dobby statically linked, then copy the
# resulting .dylib into packages/jailed/ for Sideloadly injection. Verifies
# the final binary has no libsubstrate / libdobby external dep (libdobby.a
# is bundled as a static archive, so it must not appear in the load list).
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

# ---------------------------------------------------------------------------
# Full patched-IPA pipeline (Phase 1.5 distribution unit).
#
# Builds the binpatch dylib and runs shared/tools/build_patched_ipa.sh to
# produce a TrollStore / Sideloadly / AltStore / Apple Developer Program
# ready IPA. The user supplies a decrypted clean KIOU IPA via
# KIOU_CLEAN_IPA; the pipeline is driven by recipes/kiouenginebridge.py.
#
# This target NEVER redistributes a clean KIOU IPA — supply your own
# decrypted copy. Defaults to assets/Kiou-1.0.1.ipa (which is .gitignored)
# so a casual `make ipa` works in the dev container after the operator
# drops the IPA there.
# ---------------------------------------------------------------------------
KIOU_CLEAN_IPA     ?= $(PWD)/assets/Kiou-1.0.1.ipa
KIOU_IPA_RECIPE    := recipes.kiouenginebridge
KIOU_IPA_FRAMEWORK := UnityFramework
KIOU_IPA_DYLIB     := $(PWD)/packages/binpatch/KiouEngineBridge.dylib

ipa:: binpatch
	@echo "==> assembling patched IPA from $(KIOU_CLEAN_IPA)"
	@if [ ! -f "$(KIOU_CLEAN_IPA)" ]; then \
	  echo "error: clean KIOU IPA missing at $(KIOU_CLEAN_IPA)"; \
	  echo "       override with: make ipa KIOU_CLEAN_IPA=/path/to/clean.ipa"; \
	  exit 1; \
	fi
	@./shared/tools/build_patched_ipa.sh \
	  --recipe    "$(KIOU_IPA_RECIPE)" \
	  --framework "$(KIOU_IPA_FRAMEWORK)" \
	  --dylib     "$(KIOU_IPA_DYLIB)" \
	  --input     "$(KIOU_CLEAN_IPA)"

# ---------------------------------------------------------------------------
# Developer hooks. Point core.hooksPath at scripts/ so scripts/pre-commit
# fires before every commit. The hook runs the recipe<->dump cross-check
# (verify_sites) when a commit touches recipes/ or shared/tools/, and is
# a no-op otherwise -- including on workstations without the local dump
# index. See scripts/pre-commit for the full contract.
# ---------------------------------------------------------------------------
hooks::
	git config core.hooksPath scripts
	@echo "git hooks now resolve under scripts/ (pre-commit installed)"
