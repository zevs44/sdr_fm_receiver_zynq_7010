#
# luci-app-mympd — OpenWRT LuCI plugin for myMPD & MPD
# Compatible with OpenWRT 23.05 and later.
#
# Place this package directory inside:
#   <buildroot>/package/feeds/luci/luci-app-mympd/
# or add the parent directory as a custom feed in feeds.conf.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mympd
PKG_VERSION:=1.9.2
PKG_RELEASE:=1

PKG_MAINTAINER:=Your Name <you@example.com>
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-mympd
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI App for myMPD
  URL:=https://github.com/jcorporation/mympd
  # NOTE: +mpd added per explicit request. This package ships its OWN
  # /etc/init.d/mpd (see the description below); if the "mpd" package in
  # your feed also installs /etc/init.d/mpd, opkg will report a file
  # conflict on install (two packages claiming the same path). If that
  # happens: check whether your feed splits mpd into separate
  # binary/init packages, or fall back to installing just the mpd
  # *binary* by hand and dropping +mpd from DEPENDS again.
  DEPENDS:=+luci-base +mpc +alsa-utils +mpd
  PKGARCH:=all
endef

define Package/luci-app-mympd/description
  LuCI application for managing myMPD and MPD (Music Player Daemon).

  Features:
    - Real-time service status with auto-polling (myMPD + MPD)
    - Start / Stop / Restart service controls
    - Enable / Disable service autostart on boot
    - Open myMPD web interface in a new browser tab (HTTP)
    - Live CPU / RAM usage for both processes
    - Now Playing: track, volume, play/pause/prev/next, repeat/random/
      single/consume, crossfade
    - Queue management: clear, shuffle
    - Library: incremental update, full rescan, statistics
    - Per-output enable/disable (mpc outputs)
    - ALSA output device picker (from aplay -l); mixer type/device/control
      as comboboxes (device list and control names from aplay -l / amixer)
    - Built-in HTTP audio stream output (encoder/bitrate/port)
    - Editable MPD paths and ~30 general settings (/etc/mpd.conf), every
      one cross-checked against MPD's own source for this exact version;
      most are comboboxes of known-good/source-confirmed-default values
    - myMPD network settings (HTTP port / bind address)
    - Backup (download) and restore (upload) of myMPD's config directory
    - Backup (download) and restore (upload) of MPD's config + state
      (mpd.conf, playlists, database, state, sticker file)
    - Autoplay toggle: start playback automatically once at boot, once
      MPD is confirmed ready and (if the queue has streams) DNS is too
    - Install-time setup: default/completed mpd.conf, the mpd user, and
      every MPD Directories & Paths directory (incl. the database file)
      are created by postinst, not only on first actual MPD start
    - Enables myMPD's external-scripts import (scripts_external) by
      default at install time, if not already set

  NOTE: this package ships its own /etc/init.d/mpd which auto-creates the
  unprivileged "mpd" system account, runtime directories, and a default
  mpd.conf (MPD drops root via its own "user" directive; control port
  defaults to 127.0.0.1 only). Do not also install the upstream "mpd"
  package's init script, as both write to the same path.
endef

# Nothing to download, configure, or compile — pure JS/JSON package
define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-mympd/install
	# ACL (rpcd permissions)
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-mympd.json \
	    $(1)/usr/share/rpcd/acl.d/

	# LuCI menu entry
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-mympd-menu.json \
	    $(1)/usr/share/luci/menu.d/

	# LuCI JS view(s)
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/mympd
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/mympd/mympd.js \
	    $(1)/www/luci-static/resources/view/mympd/

	# MPD init script (with auto directory setup)
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/mpd $(1)/etc/init.d/mpd

	# Shared setup library (sourced by /etc/init.d/mpd AND called directly
	# from postinst -- see mpd-setup.sh's own header for why postinst does
	# NOT just run `/etc/init.d/mpd setup` instead)
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./root/usr/libexec/mpd-setup.sh $(1)/usr/libexec/mpd-setup.sh

	# Autoplay: one-shot boot task, not USE_PROCD (see its own header)
	$(INSTALL_BIN) ./root/etc/init.d/mpd-autoplay $(1)/etc/init.d/mpd-autoplay
endef

# Invalidate LuCI's cached dispatch tree + rpcd ACL cache so the new
# menu entry (menu.d) and ACL group (rpcd/acl.d) are picked up immediately,
# without requiring a reboot or logout/login. This is the same logic
# feeds/luci/luci.mk injects by default for every luci-app-* package;
# since this Makefile defines its own postinst, it must be repeated here
# manually or it is silently lost.
define Package/luci-app-mympd/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
killall -HUP rpcd 2>/dev/null

# Enable MPD autostart on first install if not already enabled
/etc/init.d/mpd enabled 2>/dev/null || /etc/init.d/mpd enable

# Create the default/completed mpd.conf and every directory it currently
# points at (music, playlists, database, state, sticker file, log/pid
# parent dirs) right now, at install time -- not only once MPD is
# actually (re)started. Also backfills any directive this plugin exposes
# that the *mpd* package's own stock conffile (if present) left commented
# out; see the comment on mpd-setup.sh's generate_conf() for why that
# matters. Does not start MPD itself.
#
# Sources the shared library directly (mpd_setup_all) rather than calling
# `/etc/init.d/mpd setup`: the latter would re-invoke the full rc.common
# action dispatch for a USE_PROCD=1 script from inside postinst, which
# sources /lib/functions/procd.sh and takes a blocking flock on fd 1000 --
# the exact mechanism that previously made LuCI's Restart button hang when
# something similar was tried for autoplay (see README.md). Sourcing the
# plain library and calling one function avoids rc.common/procd.sh
# entirely.
[ -f /usr/libexec/mpd-setup.sh ] && {
	. /usr/libexec/mpd-setup.sh
	mpd_setup_all >/dev/null 2>&1
}

# The autoplay task is enabled like any other boot service. It's harmless
# when the toggle is off (it checks the flag and exits almost instantly),
# and nothing else starts it. `start` here (immediate, not waiting for the
# next boot) is safe even mid-install: it backgrounds itself and only
# does anything if autoplay was already turned on before an upgrade.
/etc/init.d/mpd-autoplay enabled 2>/dev/null || /etc/init.d/mpd-autoplay enable
/etc/init.d/mpd-autoplay start >/dev/null 2>&1

# myMPD disables external (user-imported, e.g. from the community
# mympd-scripts repo -- RadioBrowser and friends) Lua scripts by default.
# Enable it here so importing a script actually works without an extra
# manual ssh step. Same workdir resolution priority as the LuCI JS side
# (_resolveMympdDir()): prefer the OpenWRT "mympd" package's own UCI
# option if set, else its confirmed real default. Not ubus/command-line
# based here (unlike the JS): mympd very likely isn't running yet at
# install time for that to find anything anyway. Never overwrites a value
# that's already there, in case a user (or myMPD itself) already set this
# deliberately.
mympd_workdir="$(uci -q get mympd.main.workdir 2>/dev/null)"
[ -n "$mympd_workdir" ] || mympd_workdir=/var/lib/mympd
mkdir -p "$mympd_workdir/config" 2>/dev/null
if [ ! -e "$mympd_workdir/config/scripts_external" ]; then
	echo -n "true" > "$mympd_workdir/config/scripts_external" 2>/dev/null
	chown mympd:mympd "$mympd_workdir/config/scripts_external" 2>/dev/null
fi

exit 0
endef

$(eval $(call BuildPackage,luci-app-mympd))
