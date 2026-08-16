#
# Lua 5.4 for OpenWrt, installed under versioned paths so it coexists
# with the stock "lua" package (5.1.5, used by LuCI). Built for packages
# such as myMPD that require Lua >=5.3/5.4.
#
# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=lua5.4
PKG_VERSION:=5.4.8
PKG_RELEASE:=1

PKG_SOURCE:=lua-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://www.lua.org/ftp/
PKG_HASH:=4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae

PKG_BUILD_DIR:=$(BUILD_DIR)/lua-$(PKG_VERSION)
HOST_BUILD_DIR:=$(BUILD_DIR_HOST)/lua-$(PKG_VERSION)
PKG_BUILD_PARALLEL:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Alexander

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/host-build.mk

# Object files that make up liblua (everything vanilla Lua links into
# liblua.a, i.e. all of it except the lua/luac standalone-executable
# mains). Verified locally against the real lua-5.4.6 source: this is
# the exact list `ar t liblua.a` reports after `make linux`.
LUA54_LIB_OBJS := \
	lapi.o lcode.o lctype.o ldebug.o ldo.o ldump.o lfunc.o lgc.o \
	llex.o lmem.o lobject.o lopcodes.o lparser.o lstate.o lstring.o \
	ltable.o ltm.o lundump.o lvm.o lzio.o lauxlib.o lbaselib.o \
	lcorolib.o ldblib.o liolib.o lmathlib.o loadlib.o loslib.o \
	lstrlib.o ltablib.o lutf8lib.o linit.o

define Package/liblua5.4
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=Lua 5.4 (library)
  URL:=https://www.lua.org/
endef

define Package/liblua5.4/description
  Lua 5.4.x shared library, installed as /usr/lib/liblua5.4.so.* and
  /usr/include/lua5.4/*.h so it does not conflict with OpenWrt's stock
  lua package (5.1.5, used by LuCI). CMake's FindLua.cmake module
  auto-discovers this layout (same convention Debian/Ubuntu use for
  liblua5.4-dev).
endef

# Vanilla Lua's own Makefile only ever produces liblua.a (confirmed by
# building the real lua-5.4.6 tarball locally: `make linux` leaves no
# .so anywhere). We build the objects as position-independent (FPIC)
# and link the shared object ourselves; verified locally that the
# result is a valid ELF shared object and that CMake's find_package(Lua)
# picks it up correctly once installed under lib/liblua5.4.so +
# include/lua5.4/lua.h.
define Build/Compile
	$(MAKE) $(PKG_JOBS) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CROSS)gcc" \
		AR="$(TARGET_CROSS)ar rcu" \
		RANLIB="$(TARGET_CROSS)ranlib" \
		MYCFLAGS="$(TARGET_CPPFLAGS) $(TARGET_CFLAGS) $(FPIC) -std=gnu99" \
		MYLDFLAGS="$(TARGET_LDFLAGS)" \
		linux
	$(TARGET_CROSS)gcc -shared $(FPIC) \
		-Wl,-soname,liblua5.4.so.0 \
		-o $(PKG_BUILD_DIR)/src/liblua5.4.so.$(PKG_VERSION) \
		$(patsubst %,$(PKG_BUILD_DIR)/src/%,$(LUA54_LIB_OBJS)) \
		$(TARGET_LDFLAGS) -lm
	ln -sf liblua5.4.so.$(PKG_VERSION) $(PKG_BUILD_DIR)/src/liblua5.4.so.0
	ln -sf liblua5.4.so.0 $(PKG_BUILD_DIR)/src/liblua5.4.so
endef

# Staged for OTHER packages' cross-compile (e.g. mympd's
# PKG_BUILD_DEPENDS:=lua5.4). This is what CMake's find_package(Lua)
# actually searches when it runs inside staging_dir.
define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include/lua5.4
	$(CP) $(PKG_BUILD_DIR)/src/lua.h $(PKG_BUILD_DIR)/src/luaconf.h \
		$(PKG_BUILD_DIR)/src/lualib.h $(PKG_BUILD_DIR)/src/lauxlib.h \
		$(PKG_BUILD_DIR)/src/lua.hpp \
		$(1)/usr/include/lua5.4/
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_BUILD_DIR)/src/liblua5.4.so* $(1)/usr/lib/
endef

# Runtime ipk: only the soname'd .so, no unversioned dev symlink and
# no headers (those stay staging-side, same split the stock liblua
# package uses).
define Package/liblua5.4/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/liblua5.4.so.$(PKG_VERSION) $(1)/usr/lib/
	$(LN) liblua5.4.so.$(PKG_VERSION) $(1)/usr/lib/liblua5.4.so.0
endef

# Host-side luac5.4: myMPD's build.sh precompiles its bundled
# "mympd"/"json" Lua support libraries to bytecode at build time via
# `command -v luac5.4 || command -v luac`. Without this, that lookup
# falls through to the stock lua package's own host luac (5.1, staged
# by its Host/Install as $(STAGING_DIR_HOSTPKG)/bin/luac), which
# produces 5.1-format bytecode that a 5.4 runtime then refuses to
# load ("bad binary format (version mismatch)") -- confirmed against
# myMPD's real build.sh source (lualibs() function). Installing only
# the versioned "luac5.4" name (not a bare "luac") means build.sh's
# own version-preferring lookup picks it up without disturbing the
# stock package's luac symlink, which other packages may still need
# at 5.1.
define Host/Compile
	$(MAKE) -C $(HOST_BUILD_DIR) \
		CC="$(HOSTCC) -std=gnu99" \
		linux
endef

define Host/Install
	$(INSTALL_DIR) $(STAGING_DIR_HOSTPKG)/bin
	$(INSTALL_BIN) $(HOST_BUILD_DIR)/src/luac $(STAGING_DIR_HOSTPKG)/bin/luac5.4
endef

$(eval $(call BuildPackage,liblua5.4))
$(eval $(call HostBuild))
