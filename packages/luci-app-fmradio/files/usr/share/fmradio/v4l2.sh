#!/bin/sh
# Shared tuner access for luci-app-fmradio.
#
# Sourced by /usr/libexec/rpcd/fmradio and /etc/init.d/fmradio, which both need
# to apply the same saved settings to the same device. One copy, because the
# two hand-maintained copies this replaced are how they ended up disagreeing
# about what a stored de-emphasis value meant.
#
# There is deliberately no name translation here. The control names below are
# the ones zynq_fm_radio exposes and the ones v4l2-ctl accepts, and they are
# used unchanged as UCI option names, ubus argument names and DOM ids:
#
#   volume         V4L2_CID_AUDIO_VOLUME      0..15
#   mute           V4L2_CID_AUDIO_MUTE        0 / 1
#   loudness       V4L2_CID_AUDIO_LOUDNESS    0 / 1   (the PL bass-boost bit)
#   rds_reception  V4L2_CID_RDS_RECEPTION     0 / 1
#   de_emphasis    V4L2_CID_TUNE_DEEMPHASIS   1 = 50 us, 2 = 75 us
#   audmode        tuner audio mode           mono / stereo
#
# audmode is not a control: mono/stereo is the tuner's audio mode, set with
# VIDIOC_S_TUNER and read from VIDIOC_G_TUNER, which is why it is the one entry
# that does not go through `v4l2-ctl -c`.
#
# de_emphasis carries the standard V4L2 menu numbers rather than a boolean of
# this package's own invention. 0 (V4L2_DEEMPHASIS_DISABLED) is masked out of
# the menu by the driver -- the PL has no de-emphasis bypass -- so it is
# rejected here too instead of being sent on for the tuner to refuse.

FM_RADIO_DEV="${FM_RADIO_DEV:-/dev/radio0}"

# Every setting this package restores, in the order it should be applied.
FM_SETTINGS="volume mute loudness rds_reception de_emphasis audmode"

# Value used when a control cannot be read back at all. These match the
# driver's own defaults, so a failed read looks like a freshly probed device
# rather than like "everything off".
fm_ctrl_default() {
	case "$1" in
	rds_reception) printf '1' ;;
	de_emphasis)   printf '2' ;;
	*)             printf '0' ;;
	esac
}

# fm_ctrl_sanitize <name> <value>
# Prints the cleaned value; returns non-zero (printing nothing) if the name is
# not one of ours or the value cannot be made sense of. This is the only input
# validation on the path from the web UI to the tuner, so it whitelists rather
# than filters: anything not explicitly recognised is refused.
fm_ctrl_sanitize() {
	local name="$1"
	local val="$2"

	case "$name" in
	volume)
		val=$(printf '%s' "$val" | tr -cd '0-9')
		[ -n "$val" ] || return 1
		# Strip leading zeros and cap the length before comparing, so a
		# pasted 30-digit number cannot overflow shell arithmetic.
		val=$(printf '%s' "$val" | sed 's/^0*//')
		[ -n "$val" ] || val=0
		[ ${#val} -gt 2 ] && val=15
		[ "$val" -gt 15 ] && val=15
		;;
	mute|loudness|rds_reception)
		val=$(printf '%s' "$val" | tr -cd '0-9')
		[ -n "$val" ] || return 1
		[ ${#val} -gt 2 ] && val=1
		[ "$val" -ge 1 ] && val=1 || val=0
		;;
	de_emphasis)
		case "$val" in 1|2) ;; *) return 1 ;; esac
		;;
	audmode)
		case "$val" in mono|stereo) ;; *) return 1 ;; esac
		;;
	*)
		return 1
		;;
	esac

	printf '%s' "$val"
}

# fm_ctrl_set <name> <value>
# Prints whatever v4l2-ctl said and returns its exit status.
fm_ctrl_set() {
	local name="$1"
	local val

	val=$(fm_ctrl_sanitize "$name" "$2") || {
		echo "error: bad control '$name' or value '$2'"
		return 1
	}

	if [ "$name" = "audmode" ]; then
		v4l2-ctl -d "$FM_RADIO_DEV" --set-tuner="$val" 2>&1
	else
		v4l2-ctl -d "$FM_RADIO_DEV" -c "${name}=${val}" 2>&1
	fi
}

# fm_ctrl_get_all
# Prints one "name=value" line per setting. Two v4l2-ctl calls, not six.
fm_ctrl_get_all() {
	local list tuner name val

	list=$(v4l2-ctl -d "$FM_RADIO_DEV" --list-ctrls 2>/dev/null)

	# v4l2-ctl prints "<name> 0x00a10901 (menu)   : min=.. default=.. value=N"
	# for every scalar type, so one pattern reads int, bool and menu alike.
	for name in volume mute loudness rds_reception de_emphasis; do
		val=$(printf '%s\n' "$list" \
			| grep -E "^[[:space:]]*$name[[:space:]]" \
			| grep -oE 'value=[0-9]+' \
			| head -1 \
			| cut -d= -f2)
		[ -n "$val" ] || val=$(fm_ctrl_default "$name")
		printf '%s=%s\n' "$name" "$val"
	done

	tuner=$(v4l2-ctl -d "$FM_RADIO_DEV" --get-tuner 2>/dev/null)
	# Match the "Current audio mode" line and only that one: the "Available
	# subchannels" line printed directly below it also contains the word
	# "mono", on every FM tuner, always.
	if printf '%s\n' "$tuner" | grep -i 'current audio mode' | grep -qw 'mono'; then
		printf 'audmode=mono\n'
	else
		printf 'audmode=stereo\n'
	fi
}

# Saved settings live in a single anonymous-or-named 'settings' section; look
# it up positionally first so both layouts work.
fm_uci_get() {
	local val
	val=$(uci -q get "fmradio.@settings[0].$1")
	[ -n "$val" ] || val=$(uci -q get "fmradio.main.$1")
	printf '%s' "$val"
}

# fm_apply_uci
# Restores every saved setting, then retunes unless auto-play was turned off.
# Prints "applied=..." and "errors=..." for the caller to report.
fm_apply_uci() {
	local applied="" errors="" name val freq autoplay

	for name in $FM_SETTINGS; do
		val=$(fm_uci_get "$name")
		[ -n "$val" ] || continue
		if fm_ctrl_set "$name" "$val" >/dev/null 2>&1; then
			applied="${applied} ${name}=${val}"
		else
			errors="${errors} ${name}"
		fi
	done

	# Frequency goes last so a control write can never land on the wrong
	# station. Empty/unset autoplay (installs from before the option
	# existed) counts as enabled.
	autoplay=$(fm_uci_get autoplay)
	freq=$(fm_uci_get last_freq | tr -cd '0-9.')
	if [ "$autoplay" != "0" ] && [ -n "$freq" ]; then
		if v4l2-ctl -d "$FM_RADIO_DEV" --set-freq="$freq" >/dev/null 2>&1; then
			applied="${applied} freq=${freq}"
		else
			errors="${errors} freq"
		fi
	fi

	printf 'applied=%s\n' "${applied# }"
	printf 'errors=%s\n' "${errors# }"
}
