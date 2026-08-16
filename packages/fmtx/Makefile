include $(TOPDIR)/rules.mk

PKG_NAME:=fmtx
PKG_VERSION:=1.1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=OpenWrt User

include $(INCLUDE_DIR)/package.mk

define Package/fmtx
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Zynq FM Transmitter AXI Control
  # Anything still depending on the old package name keeps resolving.
  PROVIDES:=fm-ctrl
  DEPENDS:=
endef

define Package/fmtx/description
  Command line utility (fmtx) to control the custom AXI4-Lite FM transmitter
  IP (fm_transmitter_axi) on Zynq: frequency, TX/stereo/pre-emphasis, peak
  deviation, RDS PS/PI/PTY/ECC/RadioText and the raw-MPX export scaling.
  Registers are accessed directly through mmap of /dev/mem, no kernel driver.
  Formerly packaged as fm-ctrl with the binary named fm_ctrl.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS) -Wall -Wextra" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define Package/fmtx/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/fmtx $(1)/usr/bin/fmtx
endef

$(eval $(call BuildPackage,fmtx))
