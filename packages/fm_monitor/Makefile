include $(TOPDIR)/rules.mk

PKG_NAME:=fm_monitor
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/fm_monitor
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Real-time register monitor for axi_sdr_fm
  DEPENDS:=
endef

define Package/fm_monitor/description
  A real-time console utility to read and monitor all AXI4-Lite registers
  (tuning word, RDS Program Service name, status, volume, controls) of the
  axi_sdr_fm module.
endef

# Copy sources into the build directory
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

# Compile with target platform flags (cross-compilation)
define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

# Install the binary into the system image (/usr/bin)
define Package/fm_monitor/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/fm_monitor $(1)/usr/bin/
endef

$(eval $(call BuildPackage,fm_monitor))
