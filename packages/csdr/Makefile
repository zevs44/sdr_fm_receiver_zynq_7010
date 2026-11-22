#
# OpenWrt package Makefile for csdr
# https://github.com/ha7ilm/csdr
#
include $(TOPDIR)/rules.mk

PKG_NAME:=csdr
# Версия в форме ГГГГ.ММ.ДД: apk из OpenWrt 25.12 отвергает версии с несколькими
# дефисами («package version is invalid»). Исходная дата сохранена в PKG_SOURCE_DATE.
PKG_VERSION:=2019.02.27
PKG_RELEASE:=7

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/ha7ilm/csdr.git
PKG_SOURCE_DATE:=2019-02-27
# HEAD of master at the time this package was written; pin it so builds
# are reproducible (upstream has been unmaintained since 2019).
PKG_SOURCE_VERSION:=6ef2a74206887155290a54c7117636f66742f858
PKG_MIRROR_HASH:=skip
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

PKG_MAINTAINER:=Alexander <you@example.com>
# libcsdr.c/libcsdr.h/wrapper code: BSD-3-Clause.
# libcsdr_gpl.c (built in via -DLIBCSDR_GPL, needed for e.g. old_fractional_decimator_ff)
# and a few other routines: GPL-3.0-or-later. No single top-level LICENSE
# file is shipped upstream, so no PKG_LICENSE_FILES.
PKG_LICENSE:=BSD-3-Clause GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

# Shared-object version, matches upstream Makefile's SOVERSION.
CSDR_SOVERSION:=0.15

# Upstream's Makefile auto-detects SIMD flags by grepping the *build host's*
# /proc/cpuinfo (see PARAMS_SIMD/cpufeature in their Makefile) - that is
# meaningless (and actively wrong: it would feed x86 -msse* flags to the
# ARM cross compiler) when cross-compiling, so we replace it outright with
# the flags OpenWrt has already worked out for this target/profile.
#
# NEON detection: do NOT grep TARGET_CFLAGS for -mfpu=neon - since
# openwrt/openwrt@8dcc108 (Mar 2019) the FPU choice is baked into the
# cross-gcc itself via --with-fpu at toolchain-build time, so a NEON
# target's TARGET_CFLAGS no longer contains that token at all (verified
# against current openwrt/packages: multimedia/ffmpeg/Makefile uses
# "$(findstring neon,$(CONFIG_CPU_TYPE))" for exactly this reason, e.g.
# CONFIG_CPU_TYPE="cortex-a9+neon-vfpv4"). Mirror that here. When it
# matches, pass csdr's own NEON switches (-DNEON_OPTS enables the
# hand-written NEON code paths in libcsdr.c, e.g.
# shift_addfast_cc/fir_decimate_cc - these need the #define regardless
# of what the toolchain defaults to, since that's a csdr-side ifdef,
# not a codegen default).
CSDR_NEON_EXTRA:=$(if $(findstring neon,$(CONFIG_CPU_TYPE)),-mvectorize-with-neon-quad -funsafe-math-optimizations -DNEON_OPTS)

define Package/csdr
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=SDR
  TITLE:=csdr - simple DSP library/CLI for Software Defined Radio
  URL:=https://github.com/ha7ilm/csdr
  DEPENDS:=+fftw3f +libstdcpp
endef

define Package/csdr/description
  csdr is a simple DSP library and command-line tool for Software Defined
  Radio (by HA7ILM). Provides the libcsdr.so DSP primitives (filters, AGC,
  demodulators, FFT via FFTW, etc.), the "csdr" pipe-based CLI tool, and
  the "nmux" TCP stream multiplexer. Built here with NEON vectorization
  enabled automatically when the target's CPU type requests it.
endef

define Build/Compile
	# Upstream's recipes literally invoke "gcc"/"g++" (not $(CC)/$(CXX)),
	# so point those at the cross toolchain in place.
	$(SED) 's/^\tgcc /\t$(TARGET_CC) /' $(PKG_BUILD_DIR)/Makefile
	$(SED) 's/^\tg++ /\t$(TARGET_CXX) /' $(PKG_BUILD_DIR)/Makefile
	+$(MAKE) -C $(PKG_BUILD_DIR) \
		PARAMS_LOOPVECT="-O2 -ffast-math" \
		PARAMS_SIMD="$(TARGET_CFLAGS) $(CSDR_NEON_EXTRA)" \
		PARAMS_LIBS="-lm -lrt -lfftw3f -DUSE_FFTW -DLIBCSDR_GPL -DUSE_IMA_ADPCM" \
		PARAMS_MISC="-Wno-unused-result" \
		SOVERSION="$(CSDR_SOVERSION)" \
		PARSEVECT=no \
		PREFIX="/usr" \
		all
endef

define Package/csdr/install
	$(INSTALL_DIR) $(1)/usr/lib $(1)/usr/bin
	$(CP) $(PKG_BUILD_DIR)/libcsdr.so.$(CSDR_SOVERSION) $(1)/usr/lib/
	ln -sf libcsdr.so.$(CSDR_SOVERSION) $(1)/usr/lib/libcsdr.so
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/csdr $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/nmux $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/fm_stereo_decode $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/resample_upsample_f $(1)/usr/bin/
endef

$(eval $(call BuildPackage,csdr))
