include $(TOPDIR)/rules.mk

PKG_NAME:=nand-install
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/nand-install
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Install OpenWrt from the SD card into the board NAND
  DEPENDS:=+mtd +ubi-utils +nand-utils
endef

define Package/nand-install/description
  Writes the root filesystem (from the read-only squashfs), bootloader,
  FPGA bitstream and kernel from the SD card into the board NAND.
  Dry-run first, explicit confirmation, flock, log, read-back verification.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/nand-install/install
	$(INSTALL_DIR) $(1)/sbin
	$(INSTALL_BIN) ./files/nand_install $(1)/sbin/nand_install
endef

$(eval $(call BuildPackage,nand-install))
