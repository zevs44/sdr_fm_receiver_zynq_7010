include $(TOPDIR)/rules.mk

PKG_NAME:=fftw3
PKG_VERSION:=3.3.8
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=COPYING

# PKG_HASH verified against fftw-3.3.8.tar.gz (confirmed independently via
# Homebrew's formula and Buildroot's checksum db - Buildroot's own comment
# mislabels this hash as belonging to "fftw-3.3.7.tar.gz", but the digest
# itself is the real 3.3.8 one). If www.fftw.org has since pruned this old
# release, OpenWrt's own PKG_HASH-addressed source mirror still serves it,
# so this stays fine to leave pinned.
PKG_SOURCE:=fftw-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=http://www.fftw.org
PKG_HASH:=6113262f6e92c5bd474f2875fa1b01054c4ad5040f6b0da7c03c98821d9ae303

PKG_BUILD_DIR=$(BUILD_DIR)/$(PKG_NAME)-$(BUILD_VARIANT)/fftw-$(PKG_VERSION)
PKG_FIXUP:=autoreconf

include $(INCLUDE_DIR)/package.mk

define Package/fftw3
  SECTION:=libs
  CATEGORY:=Libraries
  DEPENDS:=+libpthread
  VARIANT:=double
  TITLE:=Fast Fourier transform library
  URL:=http://www.fftw.org/
  MAINTAINER:=Vladimir Ulrich <admin@evl.su>
endef

define Package/fftw3f
  $(call Package/fftw3)
  VARIANT:=single
  TITLE+= (single precision)
endef

define Package/fftw3l
  $(call Package/fftw3)
  VARIANT:=long-double
  TITLE+= (long-double precision)
endef

define Package/fftw3/description
	FFTW is a collection of fast C routines for computing the
	Discrete Fourier Transform in one or more dimensions. It
	includes complex, real, and parallel transforms, and can
	handle arbitrary array sizes efficiently.
endef

define Package/fftw3f/description
  $(call Package/fftw3/description)

  This package contains the single precision library.
endef

define Package/fftw3l/description
  $(call Package/fftw3/description)

  This package contains the long-double precision library.
endef

TARGET_CFLAGS += $(FPIC)

CONFIGURE_ARGS += \
	--prefix=/usr \
	--without-libiconv-prefix \
	--without-libintl-prefix \
	--enable-shared \
	--enable-threads \
	--enable-type-prefix \
	--disable-debug \
	--disable-fortran \
	--disable-doc

ifeq ($(BUILD_VARIANT), single)
# NOTE: was $(findstring neon,$(CONFIG_TARGET_OPTIMIZATION)) - that variable
# only ever carried an explicit "-mfpu=neon..." token before OpenWrt moved
# FPU selection into the cross-gcc's own --with-fpu default at toolchain-
# build time (openwrt/openwrt@8dcc108, Mar 2019). Since then a NEON
# target's CONFIG_TARGET_OPTIMIZATION/TARGET_CFLAGS contain no "neon"
# substring at all, so --enable-neon was silently never passed on any
# OpenWrt release since - fftw3f has been building WITHOUT NEON this
# whole time even on genuine NEON targets. CONFIG_CPU_TYPE (e.g.
# "cortex-a9+neon-vfpv3") is the Kconfig-level value that survived that
# refactor untouched; it's what openwrt/packages' own ffmpeg Makefile
# keys off today for the identical decision.
CONFIGURE_ARGS += \
	$(if $(findstring neon,$(CONFIG_CPU_TYPE)),--enable-neon) \
	--enable-single
endif

ifeq ($(BUILD_VARIANT), long-double)
CONFIGURE_ARGS += \
	--enable-long-double
endif

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) DESTDIR="$(PKG_INSTALL_DIR)" install
endef

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include
	$(CP) $(PKG_INSTALL_DIR)/usr/include/fftw3.h $(1)/usr/include
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libfftw3*.a $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libfftw3*.so* $(1)/usr/lib
	$(INSTALL_DIR) $(1)/usr/lib/pkgconfig
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/pkgconfig/* $(1)/usr/lib/pkgconfig/
endef

define Package/fftw3/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libfftw3.so* $(1)/usr/lib/
endef

define Package/fftw3f/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libfftw3f.so* $(1)/usr/lib/
endef

define Package/fftw3l/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libfftw3l.so* $(1)/usr/lib/
endef

$(eval $(call BuildPackage,fftw3))
$(eval $(call BuildPackage,fftw3f))
$(eval $(call BuildPackage,fftw3l))
