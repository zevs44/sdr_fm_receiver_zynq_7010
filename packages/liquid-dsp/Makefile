#
# Copyright (C) 2026 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=liquid-dsp
PKG_VERSION:=1.7.0
PKG_RELEASE:=2

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/jgaeddert/liquid-dsp/tar.gz/refs/tags/v$(PKG_VERSION)?
PKG_HASH:=33c42ebc2e6088570421e282c6332e899705d42b4f73ebd1212e6a11da714dd4

PKG_MAINTAINER:=Your Name <you@example.com>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/liquid-dsp
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=DSP library for software-defined radio
  URL:=https://liquidsdr.org/
endef

define Package/liquid-dsp/description
  liquid-dsp is a free and open-source digital signal processing (DSP)
  library aimed at software-defined radio on embedded platforms: filters,
  framing, modems, forward error correction, resamplers, NCOs and more,
  with no dependencies beyond libc/libm. Packaged here as the DSP back
  end required by the redsea RDS decoder.
endef

# Upstream's CMake build (since v1.7.0) probes for SSE4/AVX/AVX2/AVX512/
# NEON/AltiVec support by compiling AND RUNNING a small test program
# (cmake/FindSIMD.cmake, via check_c/cxx_source_runs -> try_run). That
# can't work when cross-compiling, since the test binary is built for the
# target architecture and can't be executed on the build host - see
# patches/001-cmake-skip-simd-detection-when-cross-compiling.patch, which
# skips that probe entirely under CMAKE_CROSSCOMPILING and falls back to
# liquid's portable, non-SIMD dotprod implementation. ENABLE_SIMD is left
# at its upstream default (ON): with the probe disabled it has nothing to
# act on unless something below hands CMake a result directly.
CMAKE_OPTIONS += \
	-DBUILD_EXAMPLES=OFF \
	-DBUILD_AUTOTESTS=OFF \
	-DBUILD_BENCHMARKS=OFF \
	-DBUILD_SANDBOX=OFF \
	-DBUILD_DOC=OFF

# On ARM targets where OpenWrt's own toolchain config already guarantees
# NEON (CPU_SUBTYPE:=neon - e.g. the "zynq" target, Cortex-A9), we don't
# need upstream's probe to tell us NEON is safe to use; we already know.
# So skip the probe (as above) but hand CMake the answer it would have
# produced: pre-seed the exact cache variable FindSIMD.cmake's CHECK_SIMD
# macro sets on success (C_NEON_FOUND; C_NEON_FLAGS empty, since - like
# upstream's own first flag attempt - no extra per-file flag is needed
# beyond what CPU_SUBTYPE:=neon already puts in TARGET_CFLAGS). Only the
# C (not C++) variable matters: the actual dotprod source-file selection
# in CMakeLists.txt checks "C_NEON_FOUND", not "CXX_NEON_FOUND".
#
# Verified by hand: cross-building this package with a real arm-linux-
# gnueabihf toolchain (-mfpu=neon -mfloat-abi=hard) and these two
# variables pre-seeded selects dotprod_cccf.neon.c / dotprod_crcf.neon.c
# / dotprod_rrrf.neon.c, and objdump on the result shows genuine 128-bit
# NEON opcodes (vld1.32 {dN-dN+1}, vmul.f32 qN, ...), not just scalar
# VFP - i.e. this isn't merely "configures without error", it measurably
# generates vectorized code.
ifneq ($(findstring arm,$(CONFIG_ARCH)),)
ifneq ($(findstring neon,$(CONFIG_CPU_TYPE)),)
	CMAKE_OPTIONS += -DC_NEON_FOUND=TRUE -DC_NEON_FLAGS=
endif
endif

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include/liquid
	$(CP) $(PKG_INSTALL_DIR)/usr/include/liquid/liquid.h $(1)/usr/include/liquid/
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libliquid.so* $(1)/usr/lib/
endef

define Package/liquid-dsp/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libliquid.so.* $(1)/usr/lib/
endef

$(eval $(call BuildPackage,liquid-dsp))
