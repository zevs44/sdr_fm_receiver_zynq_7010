include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fmtx
PKG_VERSION:=0.2.0
PKG_RELEASE:=1
PKG_MAINTAINER:=OpenWrt User
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-fmtx
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI FM Transmitter control
  DEPENDS:=+rpcd +luci-base +fmtx
  PKGARCH:=all
endef

define Package/luci-app-fmtx/description
  LuCI web interface and backend for FM transmitter control: on/off,
  frequency, stereo/mono, pre-emphasis, peak deviation, RDS PS/PI/PTY/ECC
  and RadioText. Hardware access is via fmtx (package fmtx, formerly
  fm-ctrl / fm_ctrl), which mmaps /dev/mem to write the AXI4-Lite registers
  of the Zynq fm_transmitter_axi core.
endef

define Package/luci-app-fmtx/conffiles
/etc/config/fmtx
endef

define Build/Compile
endef

define Package/luci-app-fmtx/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/fmtx $(1)/etc/config/fmtx

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/fmtx $(1)/etc/init.d/fmtx

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/fmtx $(1)/usr/libexec/rpcd/fmtx

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-fmtx.json $(1)/usr/share/rpcd/acl.d/luci-app-fmtx.json

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-fmtx.json $(1)/usr/share/luci/menu.d/luci-app-fmtx.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/fmtx
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/fmtx/main.js $(1)/www/luci-static/resources/view/fmtx/main.js
endef

define Package/luci-app-fmtx/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	# Left behind by 0.1.0: a second ACL file in a format rpcd does not
	# accept (read/write as arrays instead of objects).
	rm -f /usr/share/rpcd/acl.d/fmtx.json
	/etc/init.d/fmtx enable
	/etc/init.d/rpcd restart
fi
exit 0
endef

$(eval $(call BuildPackage,luci-app-fmtx))
