#!/bin/sh
# Shared by /etc/init.d/mpd (sourced from there, functions called directly
# from start_service()/setup()) AND this package's postinst (sourced and
# called directly too) -- so that preparing the default/completed
# mpd.conf, the "mpd" system user, and every configured directory does
# NOT require postinst to re-invoke `/etc/init.d/mpd setup` as a fresh
# rc.common action dispatch.
#
# That re-invocation was tried in an earlier version and is believed to
# be what actually broke plain `mpd start` after upgrading: any
# USE_PROCD=1 script sources /lib/functions/procd.sh, which takes a
# *blocking* flock on fd 1000 at source time (see the flock/nested-init-
# script history already documented in the main init script and in
# README.md's Autoplay section, where the exact same class of problem
# previously made LuCI's Restart button hang). Re-running the full
# rc.common dispatch for "mpd" from inside postinst -- itself already a
# delicate, order-sensitive context -- reintroduces that exact risk for
# no real benefit, since all that's actually needed here is to call a few
# plain shell functions. Sourcing this file directly and calling
# `mpd_setup_all` does that with zero dependency on rc.common/procd.sh at
# all.

CONF=/etc/mpd.conf

MPD_MUSIC=/lib/mpd/music
MPD_PLAYLISTS=/lib/mpd/playlists
MPD_STATE_DIR=/lib/mpd
MPD_RUN_DIR=/var/run/mpd
MPD_LOG_DIR=/var/log/mpd

MPD_DATABASE=/lib/mpd/database
MPD_STATE=/lib/mpd/state
MPD_STICKER=/lib/mpd/sticker.sql

MPD_USER=mpd
MPD_GROUP=mpd
MPD_UID=900
MPD_GID=900

add_mpd_user() {
	# Create the unprivileged "mpd" system account if missing, so MPD can
	# drop root privileges via its own "user" config directive after
	# startup (see generate_conf() below). Uses the same check-before-
	# append pattern as other OpenWRT packages that create a system
	# account (e.g. the "tor" package's postinst), since busybox on a
	# minimal OpenWRT image does not reliably ship adduser/addgroup.
	grep -q "^mpd:" /etc/group  2>/dev/null || \
		echo "mpd:x:$MPD_GID:" >> /etc/group
	grep -q "^mpd:" /etc/passwd 2>/dev/null || \
		echo "mpd:x:$MPD_UID:$MPD_GID:mpd:$MPD_RUN_DIR:/bin/false" >> /etc/passwd
}

setup_dirs() {
	add_mpd_user

	# The state dir itself: `mkdir -p` below only touches the ownership of
	# the two subdirectories it creates, not this already-existing parent,
	# so without this explicit chown it stays root-owned. That silently
	# breaks anything MPD (running as $MPD_USER after its privilege drop)
	# needs to *create* directly inside it rather than merely open --
	# sticker_file in particular, which MPD only creates on first use
	# of the stickers feature rather than at startup.
	mkdir -p "$MPD_STATE_DIR"
	chown "$MPD_USER:$MPD_GROUP" "$MPD_STATE_DIR" 2>/dev/null
	chmod 755 "$MPD_STATE_DIR" 2>/dev/null

	# Music and playlist storage. Only the directories themselves get their
	# ownership/mode touched (non-recursively) -- an earlier version ran
	# `chown -R`/`chmod -R` over this whole tree on every single start, which
	# means every restart would walk the user's entire music library just to
	# reset permissions that (for a fixed MPD_USER/MPD_GROUP) never actually
	# change after the first run. On a library with many thousands of files
	# this can noticeably delay service start for no benefit.
	mkdir -p "$MPD_MUSIC" "$MPD_PLAYLISTS"
	chown "$MPD_USER:$MPD_GROUP" "$MPD_MUSIC" "$MPD_PLAYLISTS" 2>/dev/null
	chmod 755 "$MPD_MUSIC" "$MPD_PLAYLISTS" 2>/dev/null

	# Runtime and log dirs are always small, so recursive is fine and safest.
	mkdir -p "$MPD_RUN_DIR" "$MPD_LOG_DIR"
	chown -R "$MPD_USER:$MPD_GROUP" "$MPD_RUN_DIR" "$MPD_LOG_DIR"
	chmod -R 755 "$MPD_RUN_DIR" "$MPD_LOG_DIR"

	# Touch state files so MPD can open them, and fix just their own perms.
	# sticker.sql is included here too (belt-and-braces alongside the
	# MPD_STATE_DIR chown above): MPD only creates it lazily on first
	# sticker write, so pre-touching it means correct ownership is
	# guaranteed from boot rather than depending on that first write
	# succeeding under the dropped-privilege user.
	[ -f "$MPD_DATABASE" ] || touch "$MPD_DATABASE"
	[ -f "$MPD_STATE"    ] || touch "$MPD_STATE"
	[ -f "$MPD_STICKER"  ] || touch "$MPD_STICKER"
	chown "$MPD_USER:$MPD_GROUP" "$MPD_DATABASE" "$MPD_STATE" "$MPD_STICKER" 2>/dev/null

	# Fix /dev/snd permissions so MPD can open ALSA devices
	if [ -d /dev/snd ]; then
		chmod 777 /dev/snd/*  2>/dev/null || true
	fi
}

mpd_conf_get() {
	# $1 = top-level directive name. Extracts its value from $CONF, or
	# prints nothing if $CONF doesn't exist or the directive isn't
	# actively set. Anchored to column 0 (no leading whitespace allowed)
	# so this only ever matches a genuine TOP-LEVEL directive, never a
	# same-named key nested inside e.g. an audio_output block -- this
	# matters in practice: MPD's own top-level "port" (control port, e.g.
	# 6600) shares its name with the httpd audio_output's "port" sub-key
	# (stream port, e.g. 8000), which mympd.js's own _readMpdConf()/
	# _setMpdConfKey() already had to guard against with full brace-depth
	# tracking. This script never generates or expects an indented
	# top-level directive, so the simpler column-0 anchor is sufficient
	# here without needing the same brace counting.
	[ -f "$CONF" ] || return 0
	grep "^$1[[:space:]]" "$CONF" 2>/dev/null | head -n1 | \
		sed -e "s/^$1[[:space:]]*//" \
		    -e 's/#.*//' \
		    -e 's/^"//' \
		    -e 's/"[[:space:]]*$//' \
		    -e 's/[[:space:]]*$//'
}

mpd_conf_ensure() {
	# $1 = key, $2 = default value. Appends "key <default>" only if the
	# key isn't ALREADY actively set -- so this is a no-op re-run on every
	# start once everything is in place, and is also safe to run against a
	# foreign/stock mpd.conf: a commented-out example line (which is all
	# the "mpd" opkg package's own conffile ships -- see generate_conf()
	# below) does not count as "already set", so the real default still
	# gets appended.
	[ -n "$(mpd_conf_get "$1")" ] && return 0
	printf '%s\t\t"%s"\n' "$1" "$2" >> "$CONF"
}

setup_configured_paths() {
	# Whatever is ACTUALLY in /etc/mpd.conf right now needs to exist and
	# be owned by $MPD_USER, or MPD refuses to start outright -- this is
	# what makes a custom path entered in LuCI's "MPD Directories & Paths"
	# section actually work, since that page can only write the config
	# value; a browser has no way to create a directory on the router
	# itself. Also covers paths that arrive via a restored backup or a
	# manual ssh edit of mpd.conf. Must run AFTER generate_conf(), so
	# there is always a config to read on a fresh install too.
	local p

	for p in "$(mpd_conf_get music_directory)" \
	         "$(mpd_conf_get playlist_directory)"; do
		[ -n "$p" ] || continue
		mkdir -p "$p" 2>/dev/null
		chown "$MPD_USER:$MPD_GROUP" "$p" 2>/dev/null
	done

	for p in "$(mpd_conf_get db_file)" \
	         "$(mpd_conf_get state_file)" \
	         "$(mpd_conf_get sticker_file)"; do
		[ -n "$p" ] || continue
		mkdir -p "$(dirname "$p")" 2>/dev/null
		chown "$MPD_USER:$MPD_GROUP" "$(dirname "$p")" 2>/dev/null
		[ -e "$p" ] || touch "$p" 2>/dev/null
		chown "$MPD_USER:$MPD_GROUP" "$p" 2>/dev/null
	done

	# log_file/pid_file: only the parent directory is ensured -- MPD
	# creates these two files itself on start, and pre-touching pid_file
	# in particular is pointless (MPD overwrites it immediately anyway).
	for p in "$(mpd_conf_get log_file)" \
	         "$(mpd_conf_get pid_file)"; do
		[ -n "$p" ] || continue
		mkdir -p "$(dirname "$p")" 2>/dev/null
		chown "$MPD_USER:$MPD_GROUP" "$(dirname "$p")" 2>/dev/null
	done
}

generate_conf() {
	# Historically this only ever wrote a template when $CONF was
	# completely missing, on the assumption that any *existing* file was
	# necessarily one this package (or the user) had already set up. That
	# assumption breaks on a system where the "mpd" opkg package itself
	# ships its own /etc/mpd.conf conffile -- the ~400-line stock upstream
	# example, everything commented out -- since opkg installs that before
	# this script ever runs, so $CONF always "exists" and this plugin's
	# own chosen defaults (bind_to_address, user, the tuned audio_output
	# block, etc.) never got written at all. Confirmed in the wild: a
	# router's actual /etc/mpd.conf was the stock example with only
	# whatever fields the user had manually typed into the LuCI
	# Paths/Settings pages appended at the bottom -- everything else
	# (samplerate_converter and more) simply absent.
	#
	# Now: write the short header once on a genuinely missing file, then
	# unconditionally backfill every directive this plugin's LuCI pages
	# expose that isn't ALREADY actively set to something. This correctly
	# covers a truly fresh install, a stock/foreign conffile, and
	# (idempotently, safely) a file this function already completed on an
	# earlier start.
	if [ ! -f "$CONF" ]; then
		cat > "$CONF" << 'EOF'
# MPD configuration -- generated/completed by /etc/init.d/mpd
# Edit via LuCI: Services -> myMPD -> MPD Directories & Paths / General Settings
EOF
	fi

	# One-time migrations for directives an earlier version of this
	# package wrote that turned out not to be real MPD parameters at all
	# -- confirmed against src/config/Templates.cxx in MPD 0.23.13's own
	# source, cross-checked field by field after two separate real
	# failure logs:
	#   exception: Error in /etc/mpd.conf line 443; unrecognized parameter: sticker_database
	#   exception: Error in /etc/mpd.conf line 444; unrecognized parameter: cache_directory
	# MPD treats an unrecognized top-level parameter as fatal and refuses
	# to start at all, so a router that already got either line written
	# (by this same function's own earlier backfill) needs it actively
	# removed, not just avoided going forward -- a code fix alone does not
	# un-break an already-broken mpd.conf. $2 (if given) is where to carry
	# the old value over to, so a real, already-configured path isn't
	# silently lost -- e.g. a real sticker database someone had been
	# using. cache_directory has no replacement: it never corresponded to
	# anything MPD 0.23 actually reads (caching is internal / via
	# $XDG_CACHE_HOME), so it's simply deleted.
	mpd_conf_migrate() {
		local bad_key="$1" new_key="$2" old_value
		grep -q "^${bad_key}[[:space:]]" "$CONF" 2>/dev/null || return 0
		old_value="$(mpd_conf_get "$bad_key")"
		grep -v "^${bad_key}[[:space:]]" "$CONF" > "$CONF.tmp" 2>/dev/null && mv "$CONF.tmp" "$CONF"
		if [ -n "$new_key" ] && [ -n "$old_value" ] && [ -z "$(mpd_conf_get "$new_key")" ]; then
			printf '%s\t\t"%s"\n' "$new_key" "$old_value" >> "$CONF"
		fi
		if [ -n "$new_key" ]; then
			logger -t mpd "Migrated invalid '$bad_key' directive to '$new_key'" 2>/dev/null
		else
			logger -t mpd "Removed invalid '$bad_key' directive (not a real MPD parameter)" 2>/dev/null
		fi
	}
	mpd_conf_migrate sticker_database sticker_file
	mpd_conf_migrate cache_directory  ""

	# MPD Directories & Paths
	mpd_conf_ensure music_directory      "$MPD_MUSIC"
	mpd_conf_ensure playlist_directory   "$MPD_PLAYLISTS"
	mpd_conf_ensure db_file              "$MPD_DATABASE"
	mpd_conf_ensure log_file             "/var/log/mpd/mpd.log"
	mpd_conf_ensure pid_file             "$MPD_RUN_DIR/pid"
	mpd_conf_ensure state_file           "$MPD_STATE"
	mpd_conf_ensure sticker_file         "$MPD_STICKER"

	# MPD General Settings
	mpd_conf_ensure user                    "$MPD_USER"
	mpd_conf_ensure group                   "$MPD_GROUP"
	mpd_conf_ensure bind_to_address         "127.0.0.1"
	mpd_conf_ensure port                    "6600"
	mpd_conf_ensure audio_buffer_size       "32768"
	mpd_conf_ensure log_level               "notice"
	mpd_conf_ensure restore_paused          "yes"
	# state_file_interval/save_absolute_paths_in_playlists/
	# connection_timeout/max_connections/max_playlist_length/
	# max_command_list_size/max_output_buffer_size: values are MPD
	# 0.23.13's own compiled-in defaults (confirmed in source -- see
	# README), written explicitly so they show up as real, editable
	# values in LuCI rather than only being implied by leaving the key
	# out entirely.
	mpd_conf_ensure state_file_interval     "120"
	mpd_conf_ensure auto_update             "yes"
	mpd_conf_ensure follow_outside_symlinks "yes"
	mpd_conf_ensure follow_inside_symlinks  "yes"
	mpd_conf_ensure save_absolute_paths_in_playlists "no"
	mpd_conf_ensure filesystem_charset      "UTF-8"
	mpd_conf_ensure zeroconf_enabled        "yes"
	mpd_conf_ensure zeroconf_name           "Music Player"
	mpd_conf_ensure replaygain              "off"
	mpd_conf_ensure volume_normalization    "no"
	mpd_conf_ensure samplerate_converter    "soxr quick"
	mpd_conf_ensure connection_timeout      "60"
	mpd_conf_ensure max_connections         "100"
	mpd_conf_ensure max_playlist_length     "16384"
	mpd_conf_ensure max_command_list_size   "2048"
	mpd_conf_ensure max_output_buffer_size  "8192"
	# Deliberately NOT given a forced default (left for the user to set,
	# if at all, via LuCI -- see mympd.js's own comment on MPD_SETTINGS
	# for why each one): auto_update_depth, metadata_to_use,
	# replaygain_preamp, replaygain_missing_preamp, replaygain_limit,
	# audio_output_format, mixer_type (the global fallback -- this
	# package's own audio_output block already sets mixer_type "none"
	# per-output, so a global default here would be redundant).

	# ALSA audio_output block: only add the whole block if no *uncommented*
	# one exists yet at all -- the LuCI ALSA section owns editing an
	# existing block via its own read/modify/write logic; this must not
	# fight that or create a duplicate.
	if ! grep -qE '^[[:space:]]*audio_output[[:space:]]*\{' "$CONF" 2>/dev/null; then
		cat >> "$CONF" << 'EOF'

audio_output {
	type            "alsa"
	name            "Zynq ADI I2S"
	device          "hw:0,0"
	# Force 48 kHz / 32-bit / stereo -- matches the FPGA I2S transmitter's
	# native rate; must not be silently reformatted.
	format          "48000:32:2"
	# Do not let the ALSA plugin auto-adjust the rate -- fail loudly
	# instead of silently resampling.
	auto_resample   "no"
	mixer_type      "none"
}
EOF
	fi

	logger -t mpd "Ensured default mpd.conf directives" 2>/dev/null
}

# Prepares everything MPD needs (default/completed mpd.conf, the mpd
# system user, every directory and file MPD Directories & Paths currently
# points at) WITHOUT starting the daemon itself. Called both from
# /etc/init.d/mpd's start_service()/setup() and directly from postinst.
mpd_setup_all() {
	setup_dirs
	generate_conf
	setup_configured_paths
}
