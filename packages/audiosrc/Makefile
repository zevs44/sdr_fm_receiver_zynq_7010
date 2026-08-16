include $(TOPDIR)/rules.mk

PKG_NAME:=audiosrc
PKG_VERSION:=1.0
PKG_RELEASE:=2

PKG_MAINTAINER:=Alex
PKG_LICENSE:=GPL-2.0-or-later

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/audiosrc
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Verified 32-bit MMIO read/write of the i2s_axi_mux_top channel-select register
endef

define Package/audiosrc/description
  Minimal replacement for devmem2, limited to aligned 32-bit accesses.
  Uses a volatile-qualified pointer for the actual MMIO access (devmem2
  itself omits this) and only reports a write as successful if reading
  the register back afterwards matches what was written (distinct exit
  code 3 otherwise). Prints exactly one line on success: "0x%08X".
  Used by luci-app-audiosrc to drive the i2s_axi_mux_top channel-select
  register. The address (0x43C80000) is fixed at compile time
  (AUDIOSRC_REG_ADDR in audiosrc.c), not an argument - this build no
  longer doubles as a general-purpose register poke tool for arbitrary
  AXI4-Lite addresses: audiosrc [value].
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/audiosrc.c $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-Wall -Wextra \
		-o $(PKG_BUILD_DIR)/audiosrc $(PKG_BUILD_DIR)/audiosrc.c
endef

define Package/audiosrc/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/audiosrc $(1)/usr/sbin/audiosrc
endef

$(eval $(call BuildPackage,audiosrc))
