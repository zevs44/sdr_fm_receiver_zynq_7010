include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-audiosrc
PKG_VERSION:=1.0
PKG_RELEASE:=10

PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Alex

LUCI_TITLE:=LuCI switch for the I2S audio source (Radio / myMPD / Bluetooth)
LUCI_DESCRIPTION:=Controls the i2s_axi_mux_top channel-select AXI register via the audiosrc tool, \
	persists the selection in UCI and re-applies it on boot.
LUCI_DEPENDS:=+luci-base +audiosrc
LUCI_PKGARCH:=all

define Package/luci-app-audiosrc/conffiles
/etc/config/audiosrc
endef

# cp -pR, которым luci.mk копирует ./root/* в пакет, сохраняет права как
# есть - если exec-бит на init.d/rpcd-скриптах потерян в дереве исходников
# (git/tar/scp это делают), сборка молча унаследует это. Для rpcd это
# фатально: plugin.c регистрирует объект только при наличии S_IXUSR
# (stat(path,&s) || !S_ISREG || !(s.st_mode & S_IXUSR) -> continue),
# иначе ubus-объекта просто нет -> RPCError "Object not found".
# Поэтому форсируем права при установке. Пути обязательно через
# $${IPKG_INSTROOT}: при сборке образа postinst выполняется на хосте, и
# без префикса chmod ушёл бы в корень СБОРОЧНОЙ МАШИНЫ.
define Package/luci-app-audiosrc/postinst
#!/bin/sh
chmod 0755 "$${IPKG_INSTROOT}/etc/init.d/audiosrc" \
           "$${IPKG_INSTROOT}/usr/libexec/rpcd/luci.audiosrc" 2>/dev/null

[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/audiosrc enable
	/etc/init.d/audiosrc start
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	# reload (SIGHUP) заставляет rpcd пересканировать /usr/libexec/rpcd и
	# подхватить свежий скрипт, но, в отличие от restart, не рвёт активные
	# сессии - иначе юзера выкидывало бы из LuCI сразу после установки.
	/etc/init.d/rpcd reload
	exit 0
}
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
