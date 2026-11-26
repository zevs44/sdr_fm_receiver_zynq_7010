include $(TOPDIR)/rules.mk

PKG_NAME:=board-scripts
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/board-scripts
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=User script directory /myscripts and run-diag-* diagnostics
endef

define Package/board-scripts/description
  Creates /myscripts with mode 0777 for user automation and installs the
  board diagnostics script as /myscripts/run-diag-board. The same script runs
  on the board and inside QEMU during the build (--profile qemu).
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/board-scripts/install
	$(INSTALL_DIR) $(1)/myscripts
	chmod 0777 $(1)/myscripts
	$(INSTALL_BIN) ./files/run-diag-board $(1)/myscripts/run-diag-board
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/91-board-scripts \
		$(1)/etc/uci-defaults/91-board-scripts
endef

$(eval $(call BuildPackage,board-scripts))
