include $(TOPDIR)/rules.mk

PKG_NAME:=mpx-dump
PKG_VERSION:=1.0
PKG_RELEASE:=1

# mpx_dump.c does not declare a license or maintainer -- these two are
# placeholders, set them to whatever's correct before you publish or
# share this package outside your own tree.
PKG_MAINTAINER:=Alex <alex@example.invalid>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/mpx-dump
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=SDR
  TITLE:=MPX composite stream capture tool for axi_sdr_fm
endef

define Package/mpx-dump/description
  Captures N seconds of the raw MPX composite stream out of axi_sdr_fm.v's
  MPX export FIFO (registers 0x2C/0x30/0x34) via /dev/mem and writes it to
  a file of raw signed 16-bit little-endian samples at 250 kHz. Must be
  run as root (chrt -f 99 recommended) for /dev/mem access and SCHED_FIFO
  polling; run with no arguments to see usage.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/mpx_dump.c $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -O2 -Wall $(TARGET_CPPFLAGS) -o $(PKG_BUILD_DIR)/mpx_dump $(PKG_BUILD_DIR)/mpx_dump.c $(TARGET_LDFLAGS) -lrt
endef

define Package/mpx-dump/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mpx_dump $(1)/usr/bin/mpx_dump
endef

$(eval $(call BuildPackage,mpx-dump))
