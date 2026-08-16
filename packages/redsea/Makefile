#
# Copyright (C) 2026 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=redsea
PKG_VERSION:=1.3.1
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/windytan/redsea/tar.gz/refs/tags/v$(PKG_VERSION)?
PKG_HASH:=2d1137dba23c1ae2d8af87bda45ab90ee962e55d3b93dc9295d1a53e15a8cfae

PKG_MAINTAINER:=Your Name <you@example.com>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

# nlohmann_json (headers + a .pc file) is a build-time-only dependency:
# the nlohmannjson package is BUILDONLY (produces no .ipk of its own), so
# it has to be pulled in with PKG_BUILD_DEPENDS rather than DEPENDS.
PKG_BUILD_DEPENDS:=nlohmannjson

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/meson.mk

define Package/redsea
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Command-line FM-RDS decoder with JSON output
  URL:=https://github.com/windytan/redsea
  DEPENDS:=+libsndfile +liquid-dsp +libstdcpp
endef

define Package/redsea/description
  redsea is a lightweight command-line FM-RDS (Radio Data System) decoder.
  Fed a demodulated 171 kHz MPX stream (e.g. piped straight from rtl_fm),
  a recorded WAV file, or a hex/.spy log, it decodes RDS groups - PS name,
  RadioText(+), TMC, clock time, alternative frequencies, ODA data and
  more - and prints them as newline-delimited JSON, one line per group:
    rtl_fm -M fm -l 0 -A std -s 171k -f 87.9M | redsea -r 171k
endef

define Package/redsea/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/redsea $(1)/usr/bin/
endef

$(eval $(call BuildPackage,redsea))
