#
# OpenWrt package: mpx-stream
#
# Userspace CLI that streams a raw sample FIFO -- MPX composite from
# axi_sdr_fm_mpx or axi_sdr_fm, or post-resampler stereo audio from
# axi_sdr_fm -- over /dev/mem AXI4-Lite register access (no kernel driver
# -- see src/mpx_stream.c for why) to stdout, a file, the network, or
# directly to ALSA. Packaged the same way as fm-ctrl: local C source,
# no upstream tarball.
#
# Drop this directory into your feeds/package tree (e.g.
# package/network/utils/mpx-stream/) alongside fm-ctrl, then:
#   make package/mpx-stream/compile V=s
#
# Needs alsa-lib (libasound) for the direct ALSA output backend (-o
# alsa:...); every other output (stdout/file/tcp/udp) doesn't touch it.
# Pulled in below as an ordinary DEPENDS, same as any other library.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=mpx-stream
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/mpx-stream
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=SDR
  TITLE:=Stream axi_sdr_fm/axi_sdr_fm_mpx raw MPX or audio samples
  DEPENDS:=+alsa-lib
endef

define Package/mpx-stream/description
  Reads the raw MPX composite or post-resampler stereo audio FIFO exposed
  by axi_sdr_fm_mpx / axi_sdr_fm over AXI4-Lite (direct /dev/mem access,
  no kernel driver) and streams it to stdout, a file, a TCP/UDP socket, or
  directly to ALSA. MPX output is s16le mono -- the format redsea's
  --input mpx expects. Audio output is stereo interleaved, 48 kHz nominal,
  with the FPGA's AUDIO_DATA_WIDTH significant bits right-justified in 4
  little-endian bytes -- for the default width of 24 that is ALSA's
  S24_LE (not S32_LE, and not the packed S24_3LE). Typical use:
    mpx_stream -b <axi_base_addr> | redsea --input mpx -r 250k
    mpx_stream --source audio -b <axi_base_addr> -o alsa:plughw:0,0
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) $(TARGET_LDFLAGS) \
		-Wall -Wextra -std=c11 \
		-o $(PKG_BUILD_DIR)/mpx_stream \
		$(PKG_BUILD_DIR)/mpx_stream.c \
		$(TARGET_LDFLAGS) -lasound
endef

define Package/mpx-stream/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mpx_stream $(1)/usr/bin/mpx_stream
endef

$(eval $(call BuildPackage,mpx-stream))
