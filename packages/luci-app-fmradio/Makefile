include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fmradio
PKG_VERSION:=2.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=OpenWrt User
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-fmradio
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI FM Radio receiver control
  DEPENDS:=+rpcd +v4l-utils-new +coreutils +coreutils-timeout +gawk +luci-base
  PKGARCH:=all
endef

define Package/luci-app-fmradio/description
  LuCI web interface and backend for FM radio receiver control.
  Features: station list, signal strength, continuously-updated RDS, audio
  settings, auto-scan. RDS is read by a supervised background daemon
  (/usr/libexec/fmradio-rdsd) that keeps rds-ctl open, so the web UI shows
  PS/PI/PTY/RadioText as they arrive instead of once per blocking 10 s read.
  Uses the tuner's own standard V4L2 control names throughout (loudness,
  rds_reception, de_emphasis, plus the tuner audio mode), so UCI options, ubus
  arguments and v4l2-ctl all speak the same vocabulary. Requires a
  zynq_fm_radio driver that exposes the standard controls.
endef

define Package/luci-app-fmradio/conffiles
/etc/config/fmradio
endef

define Build/Compile
endef

define Package/luci-app-fmradio/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/fmradio $(1)/etc/config/fmradio

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/fmradio $(1)/etc/init.d/fmradio

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/fmradio $(1)/usr/libexec/rpcd/fmradio

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/fmradio-rdsd $(1)/usr/libexec/fmradio-rdsd

	$(INSTALL_DIR) $(1)/usr/share/fmradio
	$(INSTALL_DATA) ./files/usr/share/fmradio/v4l2.sh $(1)/usr/share/fmradio/v4l2.sh

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-fmradio.json $(1)/usr/share/rpcd/acl.d/luci-app-fmradio.json

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-fmradio.json $(1)/usr/share/luci/menu.d/luci-app-fmradio.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/fmradio
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/fmradio/main.js $(1)/www/luci-static/resources/view/fmradio/main.js
endef

define Package/luci-app-fmradio/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	# Shipped by 1.1.0 and earlier: a second ACL file whose read/write members
	# were arrays instead of the objects rpcd expects, so it granted nothing.
	# luci-app-fmradio.json covers the same methods in the correct format.
	rm -f /usr/share/rpcd/acl.d/fmradio.json
	/etc/init.d/fmradio enable
	/etc/init.d/fmradio restart
	/etc/init.d/rpcd restart
fi
exit 0
endef

$(eval $(call BuildPackage,luci-app-fmradio))
