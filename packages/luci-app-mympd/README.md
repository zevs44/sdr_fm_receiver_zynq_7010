# luci-app-mympd

OpenWRT LuCI plugin for managing **myMPD** and **MPD** (Music Player Daemon).
Requires OpenWRT **23.05** or later.

---

## Features

| Section | What it does |
|---|---|
| **Resource Usage** | Live CPU% (normalised per-core) and RAM for both processes, via `ubus service list` + `/proc` |
| **myMPD Network** | Edit myMPD's HTTP port / bind address (read from its state directory) |
| **Web Interface** | One-click button to open myMPD in a new browser tab (HTTP) |
| **myMPD / MPD Service** | Start / Stop / Restart · Enable / Disable autostart on boot |
| **Autoplay** | Toggle: start playback once at boot, waiting for MPD (and, for internet radio, DNS) to be ready first |
| **Now Playing** | Track title, volume slider, Prev/Play-Pause/Stop/Next (Play/Pause label and color reflect current state), Repeat/Random/Single/Consume, Crossfade |
| **Queue** | Clear / Shuffle the current MPD play queue |
| **Library** | Incremental update, full rescan, statistics (`mpc stats`) |
| **Audio Outputs** | Per-output enable/disable (`mpc outputs`) |
| **ALSA Audio Output** | Device picker (parsed from `aplay -l`); mixer type/device/control (latter two as comboboxes from `aplay -l` / `amixer scontrols`); forced output format + auto-resample toggle |
| **HTTP Audio Stream** | Enable/configure MPD's built-in `httpd` output (encoder, bitrate, port, format -- defaults to `48000:16:2`) |
| **MPD Directories & Paths** | Edit path-related directives in `/etc/mpd.conf`; saving creates any directory/file that doesn't exist yet, since MPD refuses to start with a configured path that's missing |
| **MPD General Settings** | Edit network/logging/behaviour/user/buffer-size directives in `/etc/mpd.conf`; all fields except Bind address and MPD port are comboboxes of known-good values (still freely editable) |
| **myMPD Backup & Restore** | Download a `.tar.gz` snapshot of myMPD's workdir (auto-detected, see below), or upload one to restore -> auto-restart |
| **MPD Backup & Restore** | Download a `.tar.gz` of `/etc/mpd.conf` + playlists/database/state/sticker files, or upload one to restore -> auto-restart |

Status, now-playing, outputs, and resource usage are all refreshed automatically in the background.

---

## Requirements

| Package | Purpose |
|---|---|
| `luci-base` | LuCI framework (always required) |
| `mpc` | CLI client used by playback/queue/library/output controls (auto-installed) |
| `alsa-utils` | Provides `aplay` (device list) and `amixer` (mixer control list) (auto-installed) |
| `mympd` | The myMPD service itself (install separately -- see note below) |
| `mpd` | MPD binary, now a hard `DEPENDS` (auto-installed) -- **read the conflict warning below first** |

```sh
opkg update
opkg install luci-app-mympd mympd
```

### `mpd` DEPENDS vs. the bundled init script -- read this before installing

`DEPENDS` now includes `+mpd`, so `opkg install luci-app-mympd` pulls in
your feed's `mpd` package automatically. **If that package also installs
its own `/etc/init.d/mpd`** (very likely, since that's the standard
location any real `mpd` package would use), opkg will report a file
conflict during install, because this package installs its **own**
`/etc/init.d/mpd` too (see below) and two packages cannot own the same
path. If you hit that:

- check whether your feed splits `mpd` into separate binary/init-script
  packages (some minimal/custom feeds do) and depend on just the binary
  one, or
- drop `+mpd` from `DEPENDS` in the Makefile and install the `mpd`
  *binary* by hand instead (e.g. copy it to `/usr/bin/mpd` yourself, or
  `opkg install --force-overwrite mpd` if you're sure only the init
  script collides).

### About the bundled `/etc/init.d/mpd`

This package installs its **own** procd init script for MPD at
`/etc/init.d/mpd`. On every start (and once at install time -- see below)
it:

- creates the unprivileged `mpd:mpd` system account (uid/gid `900`) if
  missing, by appending directly to `/etc/passwd`/`/etc/group` (the same
  approach other OpenWRT packages use, since minimal images don't reliably
  ship `adduser`/`addgroup`),
- creates the music/playlist/cache directories, the run/log dirs, and the
  database/state/sticker files if missing, owned by `mpd:mpd`,
- **backfills** every directive this plugin's LuCI pages expose (MPD
  Directories & Paths, MPD General Settings) that isn't already actively
  set to something, and adds the tuned `audio_output` block if none exists
  yet -- see "Every settings field gets a default" below,
- fixes `/dev/snd` permissions.

The defaults include binding MPD's control port to `127.0.0.1` only
(previously `0.0.0.0`) and forcing the ALSA output to `48000:32:2` with
`auto_resample "no"` and no mixer, tuned for this board's I2S DAC.

**Do not also install an upstream `mpd` opkg package's init script** if one
exists separately in your feeds -- both would write to `/etc/init.d/mpd`
and opkg will refuse (or one will silently clobber the other). Only the
`mpd` *binary* needs to be present at `/usr/bin/mpd`; this plugin's init
script handles the rest.

### Every settings field gets a default -- including on an existing/foreign `mpd.conf`

Earlier versions only ever wrote a default `mpd.conf` when the file was
completely missing, on the assumption that an *existing* file necessarily
meant this package (or the user) had already set it up. That assumption
turned out to be wrong: the `mpd` opkg package itself typically ships its
own `/etc/mpd.conf` **conffile** -- the ~400-line stock upstream example,
with every directive commented out -- and opkg installs that before this
script ever runs. So `/etc/mpd.conf` always "existed" from this script's
point of view, and this plugin's own chosen defaults (`bind_to_address`,
`user`, the tuned `audio_output` block, and anything
else the user hadn't manually typed into a LuCI field and saved) were
silently never written at all. Confirmed on a real router: its actual
`/etc/mpd.conf` was the stock commented-out example with only whichever
handful of fields the user had happened to fill in and save via LuCI
appended at the bottom -- `samplerate_converter` and
others simply didn't exist anywhere in the file.

Now, `generate_conf()` backfills instead of only generating once:

- it still writes the short file header only when `/etc/mpd.conf` is
  genuinely missing,
- for every one of the ~20 flat directives MPD Directories & Paths / MPD
  General Settings expose, it appends this plugin's default **only if
  that directive isn't already actively set to something** -- a
  commented-out example line (`#music_directory "~/music"`) doesn't
  count as "already set", so the real default gets appended regardless
  of whether it came from a stock `mpd` package conffile or a totally
  empty file,
- it adds the whole tuned `audio_output` block only if no *uncommented*
  one exists yet at all, so it never fights or duplicates a block you've
  already configured through the ALSA Audio Output section.

This makes the whole operation safe to run on every single start
(existing values are never touched, so it's a no-op once everything is
already set) and safe to run against any pre-existing file regardless of
where it came from.

### Directories and the config are also prepared at install time, not just first start

The directory/config-preparation logic (default `mpd.conf` backfill, the
`mpd` system user, every directory MPD Directories & Paths currently
points at, and the database/state/sticker files) lives in a shared
library, `/usr/libexec/mpd-setup.sh`, sourced by both `/etc/init.d/mpd`
and `postinst`. `postinst` sources it directly and calls its
`mpd_setup_all` function -- it does **not** run `/etc/init.d/mpd setup`.

That distinction matters and is not just style: an earlier version *did*
call `/etc/init.d/mpd setup` from postinst, and this is believed to be
what broke plain `mpd start` after upgrading. Any `USE_PROCD=1` script
sources `/lib/functions/procd.sh`, which takes a *blocking* `flock` on fd
1000 at **source time** -- simply invoking `/etc/init.d/mpd` with *any*
action, including a custom one that itself never touches procd, pulls
that in. Re-running the full rc.common action dispatch for "mpd" from
inside postinst -- itself already a delicate, order-sensitive context --
reintroduces the exact class of problem that previously made LuCI's
Restart button hang when something similar was tried for Autoplay (see
below). All postinst actually needs is a few plain shell functions, so it
sources the library directly instead, with zero dependency on
rc.common/procd.sh.

This database/directory preparation means the database file (or at
minimum its directory, ready for MPD to populate on first real start) and
every other configured directory already exist immediately after
`opkg install`, rather than only appearing after the router is next
rebooted or MPD is manually started for the first time.

---

## Building from source

### As part of the OpenWRT build system

```sh
# 1. Clone / update the OpenWRT buildroot
git clone https://git.openwrt.org/openwrt/openwrt.git
cd openwrt

# 2. Add this package as a custom feed (feeds.conf)
echo 'src-link mympd_feed /path/to/this/repo/parent' >> feeds.conf

# 3. Update & install feeds
./scripts/feeds update -a
./scripts/feeds install luci-app-mympd

# 4. Select the package
make menuconfig
# -> LuCI -> 3. Applications -> luci-app-mympd

# 5. Build
make package/luci-app-mympd/compile V=s
```

The resulting `.ipk` will be in `bin/packages/<arch>/mympd_feed/`.

**If building a full image** (not just the package), note that
`/etc/init.d/mpd` sources `/usr/libexec/mpd-setup.sh` with an
`${IPKG_INSTROOT}` prefix specifically because the build system runs this
script directly (e.g. to set up the boot-enable symlink) against the
*build host's* shell with `IPKG_INSTROOT` pointing at the target staging
directory -- there's no chroot into it. A bare absolute path there would
resolve against the build host's own `/`, which doesn't have this
package's files, and fail with `No such file or directory` (confirmed
from an actual failed build). If you fork this script and add more
sourcing of absolute paths, they need the same prefix.

### Manual installation on a running router

```sh
scp root/usr/share/rpcd/acl.d/luci-app-mympd.json \
    root@router:/usr/share/rpcd/acl.d/

scp root/usr/share/luci/menu.d/luci-app-mympd-menu.json \
    root@router:/usr/share/luci/menu.d/

scp htdocs/luci-static/resources/view/mympd/mympd.js \
    root@router:/www/luci-static/resources/view/mympd/

scp root/etc/init.d/mpd root@router:/etc/init.d/mpd

ssh root@router '
    chmod +x /etc/init.d/mpd
    rm -f /tmp/luci-indexcache.*
    rm -rf /tmp/luci-modulecache/
    /etc/init.d/rpcd reload
'
```

---

## Configuration

### myMPD web interface port / bind address

`MYMPD_DATA_DIR` in `mympd.js` was previously hardcoded to `/etc/mympd`,
which was never actually correct -- it broke Backup/Restore with `tar:
can't change directory to '/etc/mympd': No such file or directory` on any
standard myMPD install. Confirmed against the OFFICIAL OpenWrt packaging
recipe (`contrib/packaging/openwrt` in jcorporation/myMPD) and several
`journalctl` logs, myMPD's real default workdir is `/var/lib/mympd`, and
the two network-setting files live under `<workdir>/config/`, not
`<workdir>/state/`:

```
/var/lib/mympd/config/http_port
/var/lib/mympd/config/http_host
```

The workdir is no longer hardcoded at all: `_resolveMympdDir()` asks procd
for myMPD's actual running command line first (the OpenWrt package's init
script always launches it as `mympd -w <workdir> -a <cachedir>`, so this is
authoritative even if you've overridden `option workdir` in
`/etc/config/mympd`), and only falls back to probing `/var/lib/mympd` then
`/etc/mympd` if myMPD isn't running yet to ask. Backup, Restore, and the
**myMPD Network** section all go through this.

**myMPD Network additionally prefers UCI** (`uci get/set/commit mympd...`)
over the workdir files whenever `/etc/config/mympd` exists: the OpenWrt
init script *regenerates* `<workdir>/config/http_port` from UCI on every
single start, so writing straight to that file would silently be reverted
on the next restart. Only myMPD installs with no UCI config at all (built
by hand, Docker, etc.) fall back to writing the workdir file directly.

### MPD control port is now localhost-only by default

The generated default now sets `bind_to_address "127.0.0.1"` (previously
`0.0.0.0`). myMPD and `mpc` both keep working since they run on the router
itself, but a phone/desktop MPD client pointed directly at the router's LAN
IP on port `6600` will no longer connect. If you rely on that, either change
**Bind address** back to `0.0.0.0` (or a specific LAN IP) in **MPD General
Settings**, or keep it as-is and control MPD only through myMPD's web UI.

### `samplerate_converter` depends on how MPD itself was built

MPD's `samplerate_converter` directive only accepts names matching whatever
resampling library MPD was actually compiled against -- there's no single
correct list. This package previously shipped the `libsamplerate` names
("Fastest Sinc Interpolator" etc.), which are **invalid** on a `libsoxr`
build (confirmed on `mpd-full 0.23.13-1`: MPD refuses to start at all on an
unrecognized value, not a warning-and-fallback, so saving General Settings
even once with the wrong name breaks MPD outright). The combobox now
offers the `soxr` names instead (`soxr quick` / `low` / `medium` / `high` /
`very high`), confirmed working. If your MPD build uses `libsamplerate`
instead, the combobox is still freely editable -- but check `mpd --version`
first, since the wrong value here doesn't just get ignored, it stops MPD
from starting.

### Autoplay

The **Autoplay** toggle writes `yes`/`no` to `/etc/mpd_autoplay`, read by
`/etc/init.d/mpd-autoplay`, which runs once near the end of boot
(`START=99`) and does nothing further if the toggle is off.

When it's on:

1. Waits `SETTLE_DELAY` (default 15s) before checking anything at all.
2. Waits up to `MPD_WAIT` (default 30s) for `mpc status` to get an answer.
3. If the current queue contains an `http://`/`https://` stream, waits up
   to `DNS_WAIT` (default 30s) for DNS to resolve that stream's actual
   host -- **this was the original bug**: on a slow PPPoE/DHCP WAN link,
   `mpc play` could fire before DNS was up at all, so an internet-radio
   queue would silently fail to start. Local-file-only queues skip this
   step entirely. The specific stream's host is resolved rather than an
   unrelated well-known name, since some networks have DNS up but can't
   resolve every public name (split-horizon DNS, blocklists, captive
   portals) -- testing the host actually needed is the more accurate
   check. If DNS still isn't resolving once the wait is exhausted,
   playback is attempted anyway (logged) rather than giving up entirely.
4. Runs `mpc play`, waits `BUFFER_WAIT` (default 3s), then re-checks
   `mpc status` for `[playing]` to confirm it actually took.

All four constants are plain variables at the top of the script if the
defaults don't fit your network. Everything is logged:
`logread | grep mpd-autoplay`.

**This runs once at boot only**, not on every MPD restart. Earlier
versions tried to also cover LuCI-triggered restarts (first as a `&`
background job launched from `/etc/init.d/mpd`'s own `start_service()`,
then as a long-lived procd-supervised watcher polling MPD's PID for
changes) -- both turned out to be more trouble than they were worth: the
background job was unreliable and, in its nested-procd-service form, made
LuCI's **Restart** button hang indefinitely. The underlying issue is
structural, not a coding slip: `/lib/functions/procd.sh` takes a
*blocking* `flock` on fd 1000 at **source** time (`USE_PROCD=1` pulls it
in), so `/etc/init.d/mpd` holds that lock for its whole lifetime and any
child it spawns inherits both the fd and the lock -- spawning a second
procd init script from inside another one's `start_service()` fights the
framework. `/etc/init.d/mpd-autoplay` avoids all of it by **not** setting
`USE_PROCD` at all: it's a one-shot task, not a daemon, and rc.common's
plain `start()`/`stop()` need nothing from procd.sh in the first place.
If autoplay-on-restart (not just autoplay-on-boot) turns out to matter in
practice, it should be re-added deliberately with that history in mind --
not as a side effect of hooking a generic restart trigger again.

### Custom paths in MPD Directories & Paths

MPD refuses to start at all if a configured path doesn't exist -- entering
a new `music_directory`, `db_file` etc. and just saving used to leave MPD
broken until you created it yourself over ssh. Saving this section now
creates whatever's missing immediately (directories with `mkdir -p`; files
like `db_file`/`state_file`/`sticker_file` get their parent directory
created and are touched into existence; `log_file`/`pid_file` only get
their parent directory created, since MPD writes those itself) -- each
field's grey hint text says which. All of it is also re-checked by
`/etc/init.d/mpd`'s `setup_configured_paths()` on every subsequent
(re)start, regardless of whether it was saved through this page, arrived
via a restored backup, or was hand-edited over ssh.

If pre-creating one particular path fails right when saving (e.g. it
points at a USB mount that isn't attached at that moment), that's reported
as a separate warning rather than making the whole save look like it
failed -- `/etc/mpd.conf` is written either way, and the same
`setup_configured_paths()` retries the path automatically on the next
start.

### myMPD external scripts are enabled by default

myMPD ships with importing external (community, e.g. from
[mympd-scripts](https://github.com/jcorporation/mympd-scripts)) Lua
scripts disabled by default -- a `<workdir>/config/scripts_external` file
containing `false` (or missing). `postinst` writes `true` there (creating
`<workdir>/config/` first if needed), using the same UCI-first workdir
resolution as everything else in this README, but **only if that file
doesn't already exist** -- it never overwrites a value you (or myMPD
itself) already set. This only matters if your `mympd` build has Lua
support compiled in at all -- see below; it's harmless either way if it
doesn't.

**Whether Lua scripting exists at all in myMPD is a compile-time flag of
the separate `mympd` package, not something `luci-app-mympd` can turn on**
(this package is pure JS/JSON, it compiles nothing). In the OpenWRT
buildroot's official `mympd` packaging recipe, Lua support is
`CONFIG_MYMPD_LUA`, under `make menuconfig` -> the `mympd` package's own
sub-options, and **defaults to off**. If it's off, `/usr/bin/mympd-script`
won't exist and myMPD's web UI won't show a Scripts section at all,
regardless of `scripts_external`. Check with `ls -la /usr/bin/mympd-script`
on the router; if it's missing, `mympd` needs rebuilding with
`CONFIG_MYMPD_LUA=y` (or a differently-built `.ipk` obtained) before
scripting is usable.

### `sticker_database` and `cache_directory` were never real MPD directives -- fixed and self-migrating

Embarrassing ones: every version of this package up to and including
1.8.2 used two config keys that turned out not to exist in MPD at all:

- `sticker_database` -- the real MPD directive is `sticker_file`.
- `cache_directory` -- has no real equivalent; MPD 0.23 doesn't expose a
  configurable cache directory in `mpd.conf` at all (caching is internal
  / via `$XDG_CACHE_HOME`). This field is gone from MPD Directories &
  Paths entirely, not renamed to anything.

Both went unnoticed for a long time because neither was written into the
*active* part of `/etc/mpd.conf` until the install-time backfill (above)
started actually completing every field -- at which point MPD started
refusing to start at all, confirmed from two separate real failure logs:

```
exception: Error in /etc/mpd.conf line 443; unrecognized parameter: sticker_database
exception: Error in /etc/mpd.conf line 444; unrecognized parameter: cache_directory
```

MPD treats an unrecognized top-level parameter as fatal, not a
warning-and-ignore -- and stops at the *first* one it finds, which is why
these surfaced one at a time across two upgrades rather than both at
once.

After the second one, every single directive this package writes was
cross-checked against `src/config/Templates.cxx` in MPD 0.23.13's own
source (the exact version in the failure logs) -- the literal array of
accepted top-level parameter names the config parser is compiled from,
not a manual or web copy. All ~20 others matched exactly; audio_output
block sub-keys (`device`, `format`, `auto_resample`, `mixer_type`,
`mixer_device`, `mixer_control`, httpd's `port`/`encoder`/`bitrate`,
etc.) were separately checked against the relevant output/mixer/encoder
plugin source files and are correct too.

Fixed throughout (LuCI fields, the shell backfill, MPD Backup's list of
paths to archive). Critically, a code fix alone doesn't repair a router
that already has either bad line written to `/etc/mpd.conf` by an earlier
version -- so `generate_conf()` also actively **migrates** both: on the
next run (next MPD start, or the next `opkg install`/upgrade),
`sticker_database` is removed with its configured path (if any) carried
over to `sticker_file`, and `cache_directory` is simply removed outright
(no replacement key), rather than either being just avoided going
forward. Confirmed against real broken configs from the field, including
both at once: the invalid lines are removed, `sticker_file` gets the
carried-over path, and nothing else in the file is touched. Re-running
the migration on an already-clean file is a confirmed no-op.

### MPD General Settings now covers ~30 fields, all source-verified

Added after the `sticker_database`/`cache_directory` incident above, using
the same rigor that should have been applied from the start: every one of
the ~16 new fields was cross-checked against `src/config/Templates.cxx`
in MPD 0.23.13's own source (the exact array the config parser is
compiled from), not documentation or memory. Deprecated directives
(`config/Templates.hxx`'s third field) and block-only directives
(`audio_output`, `decoder`, `input`, `filter`, `database`, etc. -- these
need `{ }` block syntax, not a flat `key "value"` line, so a text field
can't represent them at all) were excluded on purpose.

New fields with a forced default -- backfilled by `generate_conf()` like
everything else, using MPD 0.23.13's own compiled-in default where one
exists (confirmed in source, not assumed): `group` (pairs with the
existing `user`), `state_file_interval` (120s), `auto_update`'s new
sibling checkbox is unaffected, `save_absolute_paths_in_playlists` (no),
`filesystem_charset` (UTF-8), `connection_timeout` (60s),
`max_connections` (100), `max_playlist_length` (16384),
`max_command_list_size` (2048 KB), `max_output_buffer_size` (8192 KB).

New fields left **without** a forced default (shown in LuCI, but nothing
written unless you explicitly set one): `auto_update_depth`,
`metadata_to_use` (a comma-separated tag list -- freeform by nature),
`replaygain_preamp` / `replaygain_missing_preamp` / `replaygain_limit`
(only meaningful once `replaygain` isn't `off`), `audio_output_format` and
the *global* `mixer_type` (both redundant with the settings this
package's own `audio_output` block already sets per-output -- see ALSA
Audio Output).

Deliberately **not** added: `password`, `default_permissions`,
`local_permissions`, `host_permissions` (a real but interdependent
authentication subsystem that doesn't fit cleanly as four independent
flat fields, and less critical now that the control port defaults to
`127.0.0.1` only anyway).

### Backup & restore

Both the **myMPD Backup & Restore** and **MPD Backup & Restore** sections
work the same way: "Download backup" creates a `.tar.gz` on the router and
streams it straight to your browser (no manual `ssh`/`tar` needed); "Upload
& restore" opens a file picker filtered to `.tar.gz`/`.tgz` (LuCI's own
generic upload dialog doesn't support filtering by extension, so this uses
a small custom upload flow instead -- same endpoint, same behaviour,
narrower file picker), then extracts it and restarts the corresponding
service. Keep the downloaded archives somewhere safe.

MPD's backup contains `/etc/mpd.conf` plus whichever of the currently
configured `playlist_directory` / `db_file` / `state_file` /
`sticker_file` paths already exist -- not `music_directory`, which is
the media library itself rather than configuration. This works correctly
for custom (non-default) paths too, e.g. a `db_file` pointed at a USB
mount: existence isn't checked with an ubus `fs.stat()` call, which is
gated by a per-path read ACL that can't realistically be pre-authorized
for an arbitrary user-entered path -- a custom path would silently and
incorrectly look "missing" and get dropped from the backup. Every
configured path is instead handed to `tar` unconditionally, which runs as
a spawned process outside that ACL entirely and just skips whatever
genuinely isn't there yet (e.g. `sticker.sql` before its first use).

---

## File layout (installed)

```
/usr/share/rpcd/acl.d/luci-app-mympd.json          <- rpcd ACL
/usr/share/luci/menu.d/luci-app-mympd-menu.json     <- LuCI menu entry
/www/luci-static/resources/view/mympd/mympd.js      <- JS view
/etc/init.d/mpd                                     <- procd init script for MPD
/usr/libexec/mpd-setup.sh                           <- shared config/directory setup (used by both mpd and postinst)
/etc/init.d/mpd-autoplay                            <- one-shot boot task: waits for MPD/DNS, then plays
```

---

## License

Apache-2.0 -- see [LICENSE](LICENSE).
