#
# OpenWrt package Makefile for jketterl/csdr ("csdr2")
# https://github.com/jketterl/csdr
#
# This is a separate, actively-maintained C++ rewrite of csdr, used
# as the DSP backend of OpenWebRX. Packaged alongside (not instead
# of) utils/csdr, which builds the original ha7ilm/csdr - the two
# are NOT drop-in compatible: this version uses a different,
# getopt-style CLI (e.g. "csdr convert -i float -o s16" instead of
# "csdr convert_f_s16", "csdr fmdemod" instead of "csdr
# fmdemod_quadri_cf"), so an existing pipeline built against
# utils/csdr needs rewriting, not just re-pointing, to use this one.
#
# Known trade-off versus utils/csdr, checked directly against this
# commit's source (src/apps/csdr/commands.cpp): the `convert` command
# here only supports s16/float/char - no 24-bit format at all (the
# old csdr's convert_f_s24/convert_s24_f have no equivalent here).
# If you need 24-bit output, either let ALSA's plug/dmix layer
# convert from s16, or use utils/csdr's (now-fixed) convert_f_s24.
#
# Upside checked directly against this commit's source: `csdr
# fractionaldecimator <rate> --prefilter --transition=<bw>` accepts
# --prefilter and a custom --transition together (the old csdr's CLI
# only let you pick one or the other), and rate < 1 (upsampling)
# works correctly here - verified by running the exact two-stage
# 250000->31250->48000 chain used for utils/csdr and getting equally
# clean results (pilot/subcarrier/RDS all suppressed >75dB) without
# needing a separate resampling workaround.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=csdr2
PKG_VERSION:=0.19.0
PKG_RELEASE:=2

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/jketterl/csdr.git
PKG_SOURCE_DATE:=2024-07-11
# HEAD of the develop branch at the time this package was written; pin
# it so builds are reproducible.
PKG_SOURCE_VERSION:=1f15b8c5177cb348602da19e82bf0d62426ab8eb
PKG_MIRROR_HASH:=skip
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

PKG_MAINTAINER:=Alexander <you@example.com>
PKG_LICENSE:=BSD-3-Clause GPL-3.0-or-later

CMAKE_INSTALL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

# Same NEON-vs-cross-compilation problem as utils/csdr and
# libs/fftw3: detect from CONFIG_CPU_TYPE (the Kconfig-level ground
# truth), not from anything CFLAGS-derived - see patches/001 for why.
CMAKE_OPTIONS += \
	-DCSDR_HAS_NEON=$(if $(findstring neon,$(CONFIG_CPU_TYPE)),ON,OFF)

define Package/csdr2
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=SDR
  TITLE:=csdr2 - actively maintained C++ csdr (OpenWebRX's DSP backend)
  URL:=https://github.com/jketterl/csdr
  DEPENDS:=+fftw3f +libsamplerate +libstdcpp
endef

define Package/csdr2/description
  A from-scratch C++ rewrite of csdr (HA7ILM's original DSP
  library/CLI for Software Defined Radio), maintained by Jakob
  Ketterl as the DSP backend of OpenWebRX. Actively developed
  (unlike the original, unmaintained since 2019), cleaner getopt-
  style CLI, uses libsamplerate for rational resampling instead of
  a hand-rolled implementation. NOT a drop-in replacement for
  utils/csdr - different command syntax, and no 24-bit convert
  format. See the comments at the top of this Makefile.
endef

define Package/csdr2/install
	$(INSTALL_DIR) $(1)/usr/lib $(1)/usr/bin
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libcsdr.so* $(1)/usr/lib/
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/csdr $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/nmux $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/fm_stereo_decode $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/resample_upsample_f $(1)/usr/bin/
endef

$(eval $(call BuildPackage,csdr2))
