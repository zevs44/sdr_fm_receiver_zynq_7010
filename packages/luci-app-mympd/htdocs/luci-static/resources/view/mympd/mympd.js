'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require rpc';
'require request';

return view.extend({

	// -- mpd.conf field lists -------------------------------------------------
	// Defined as object properties, NOT top-level vars.
	// LuCI compileClass: new Function('"use strict"; ' + source)
	// so the file is a function body - top-level vars are fine, but ALL
	// block comments BEFORE `return view.extend` cause ASI on the `return`.

	// Placeholders mirror what this package's own /etc/init.d/mpd actually
	// generates (/lib/mpd/...), not upstream MPD's /var/lib/mpd/... defaults
	// -- otherwise the greyed-out hint text contradicts the config the very
	// same package writes.
	// `kind` drives what handleMpdConfSave creates on disk when this field
	// is saved, since a browser has no other way to make sure the path it
	// just told MPD to use actually exists -- MPD refuses to start
	// outright otherwise. 'dir': the path itself is a directory (mkdir
	// -p). 'file': a file MPD reads/writes as its own state (mkdir -p the
	// parent, then touch the file so it exists with correct ownership
	// from the start). 'parent': a file MPD creates itself on startup
	// (only the parent directory needs to pre-exist; pre-touching would
	// just be overwritten). /etc/init.d/mpd's own setup_configured_paths()
	// does the same thing on every (re)start regardless, so this is
	// really just for instant feedback rather than waiting for a restart.
	// NOTE: no "cache_directory" field here. It was one before, but never
	// actually existed as an MPD directive at all (confirmed against
	// src/config/Templates.cxx in MPD 0.23.13's own source -- caching is
	// handled internally / via $XDG_CACHE_HOME, not a mpd.conf key), and
	// caused the exact same fatal "unrecognized parameter" startup
	// failure sticker_database did. See generate_conf()'s migration step
	// in mpd-setup.sh, which removes it from any config that already has
	// it from an earlier version of this package.
	MPD_PATHS: [
		{ key: 'music_directory',    label: 'Music directory',       placeholder: '/lib/mpd/music',        kind: 'dir' },
		{ key: 'playlist_directory', label: 'Playlist directory',    placeholder: '/lib/mpd/playlists',    kind: 'dir' },
		{ key: 'db_file',            label: 'Database file',         placeholder: '/lib/mpd/database',     kind: 'file' },
		{ key: 'log_file',           label: 'Log file',              placeholder: '/var/log/mpd/mpd.log',  kind: 'parent' },
		{ key: 'pid_file',           label: 'PID file',              placeholder: '/var/run/mpd/pid',      kind: 'parent' },
		{ key: 'state_file',         label: 'State file',            placeholder: '/lib/mpd/state',        kind: 'file' },
		{ key: 'sticker_file',       label: 'Sticker file',           placeholder: '/lib/mpd/sticker.sql',  kind: 'file' }
	],

	// `choices` marks a field to be rendered as a ui.Combobox (dropdown of
	// known-good values, but still freely editable/typable, so an unusual
	// value already present in mpd.conf is never silently clobbered).
	// Every key here (not just samplerate_converter) is now verified
	// against src/config/Templates.cxx in MPD 0.23.13's own source -- the
	// literal compiled-in array of accepted top-level parameter names --
	// after two separate real "unrecognized parameter" startup failures
	// (sticker_database, cache_directory) that a plain doc/memory check
	// had missed. Deprecated directives (config/Templates.hxx's third
	// `deprecated` field) and block-only directives (audio_output,
	// decoder, input, filter, database, etc. -- these need `{ }` block
	// syntax, not a flat "key value" line, so they don't belong in this
	// list at all) are deliberately excluded.
	//
	// Fields without a placeholder default (no forced value if left
	// blank): mixer_type/audio_output_format (redundant with the
	// per-output settings ALSA Audio Output already manages),
	// replaygain_preamp/replaygain_missing_preamp/replaygain_limit
	// (only meaningful once replaygain isn't "off"), auto_update_depth
	// (MPD's own default, no explicit limit, is the sane default),
	// metadata_to_use (comma-separated tag list -- freeform by nature).
	MPD_SETTINGS: [
		{ key: 'bind_to_address',         label: 'Bind address',            placeholder: '127.0.0.1' },
		{ key: 'port',                    label: 'MPD port',                placeholder: '6600' },
		{ key: 'user',                    label: 'Run as user',             placeholder: 'mpd',
		  choices: { mpd: 'mpd' } },
		{ key: 'group',                   label: 'Run as group',            placeholder: 'mpd',
		  choices: { mpd: 'mpd' } },
		{ key: 'audio_buffer_size',       label: 'Audio buffer size (KB)',  placeholder: '32768',
		  choices: {
			'1024': '1024', '2048': '2048 (MPD default)', '4096': '4096',
			'8192': '8192', '16384': '16384', '32768': '32768 (this board)'
		  } },
		{ key: 'log_level',               label: 'Log level',               placeholder: 'notice',
		  choices: { error: 'error', warning: 'warning', notice: 'notice', info: 'info', verbose: 'verbose' } },
		{ key: 'restore_paused',          label: 'Restore paused',          placeholder: 'yes',
		  choices: { yes: 'yes', no: 'no' } },
		{ key: 'state_file_interval',     label: 'State save interval (s)', placeholder: '120',
		  choices: { '60': '60', '120': '120 (MPD default)', '300': '300', '600': '600' } },
		{ key: 'auto_update',             label: 'Auto-update library',     placeholder: 'yes',
		  choices: { yes: 'yes', no: 'no' } },
		{ key: 'auto_update_depth',       label: 'Auto-update depth',       placeholder: 'unlimited' },
		{ key: 'follow_outside_symlinks', label: 'Follow outside symlinks', placeholder: 'yes',
		  choices: { yes: 'yes', no: 'no' } },
		{ key: 'follow_inside_symlinks',  label: 'Follow inside symlinks',  placeholder: 'yes',
		  choices: { yes: 'yes', no: 'no' } },
		{ key: 'save_absolute_paths_in_playlists', label: 'Save absolute paths in playlists', placeholder: 'no',
		  choices: { yes: 'yes', no: 'no' } },
		{ key: 'metadata_to_use',         label: 'Metadata to use',         placeholder: 'artist,album,title,...' },
		{ key: 'filesystem_charset',      label: 'Filesystem charset',      placeholder: 'UTF-8',
		  choices: { 'UTF-8': 'UTF-8', 'ISO-8859-1': 'ISO-8859-1', 'ASCII': 'ASCII' } },
		{ key: 'zeroconf_enabled',        label: 'Zeroconf enabled',        placeholder: 'yes',
		  choices: { yes: 'yes', no: 'no' } },
		{ key: 'zeroconf_name',           label: 'Zeroconf name',           placeholder: 'Music Player',
		  choices: { 'Music Player': 'Music Player' } },
		{ key: 'replaygain',              label: 'ReplayGain mode',         placeholder: 'off',
		  choices: { off: 'off', track: 'track', album: 'album', auto: 'auto' } },
		{ key: 'replaygain_preamp',          label: 'ReplayGain preamp (dB)',         placeholder: '' },
		{ key: 'replaygain_missing_preamp',  label: 'ReplayGain preamp if untagged (dB)', placeholder: '' },
		{ key: 'replaygain_limit',        label: 'ReplayGain limiter',      placeholder: '',
		  choices: { yes: 'yes', no: 'no' } },
		{ key: 'volume_normalization',    label: 'Volume normalization',    placeholder: 'no',
		  choices: { yes: 'yes', no: 'no' } },
		{ key: 'samplerate_converter',    label: 'Samplerate converter',    placeholder: 'soxr quick',
		  choices: {
			'soxr quick':     'soxr quick (fastest, lowest quality)',
			'soxr low':       'soxr low',
			'soxr medium':    'soxr medium',
			'soxr high':      'soxr high',
			'soxr very high': 'soxr very high (best, Hi-Fi)'
		  } },
		{ key: 'audio_output_format',     label: 'Global audio output format', placeholder: '',
		  choices: { '48000:32:2': '48000:32:2', '44100:16:2': '44100:16:2', '48000:16:2': '48000:16:2' } },
		{ key: 'mixer_type',              label: 'Global mixer type',       placeholder: '',
		  choices: { none: 'none', software: 'software', hardware: 'hardware', 'null': 'null' } },
		{ key: 'connection_timeout',      label: 'Client connection timeout (s)', placeholder: '60',
		  choices: { '30': '30', '60': '60 (MPD default)', '120': '120', '300': '300' } },
		{ key: 'max_connections',         label: 'Max simultaneous connections', placeholder: '100',
		  choices: { '10': '10', '50': '50', '100': '100 (MPD default)', '200': '200' } },
		{ key: 'max_playlist_length',     label: 'Max playlist length (songs)', placeholder: '16384',
		  choices: { '4096': '4096', '8192': '8192', '16384': '16384 (MPD default)', '32768': '32768' } },
		{ key: 'max_command_list_size',   label: 'Max command list size (KB)', placeholder: '2048',
		  choices: { '1024': '1024', '2048': '2048 (MPD default)', '4096': '4096', '8192': '8192' } },
		{ key: 'max_output_buffer_size',  label: 'Max output buffer size (KB)', placeholder: '8192',
		  choices: { '4096': '4096', '8192': '8192 (MPD default)', '16384': '16384', '32768': '32768' } }
	],

	// -- myMPD's own working directory (matches the Backup/Restore feature) --
	// myMPD has no UCI schema of its own and no single ini file; it
	// persists settings as individual plain-text files under its workdir.
	// myMPD's real default workdir (confirmed against the OFFICIAL OpenWrt
	// packaging recipe -- jcorporation/myMPD contrib/packaging/openwrt --
	// and multiple independent journalctl logs: "Work dir: /var/lib/mympd",
	// "Config dir: /var/lib/mympd/config"). NOT /etc/mympd -- that was an
	// unverified guess in an earlier version of this file and is why
	// backup/restore failed with "tar: can't change directory to
	// '/etc/mympd'". Used only as the last-resort static fallback; see
	// _resolveMympdDir(), which asks procd for myMPD's actual `-w <path>`
	// command-line argument first, since the OpenWrt package's init script
	// always passes it explicitly (and it can be overridden via
	// `/etc/config/mympd`'s `workdir` option, which a hardcoded constant
	// could never account for).
	MYMPD_DATA_DIR:    '/var/lib/mympd',
	MYMPD_BACKUP_PATH: '/tmp/mympd-backup.tar.gz',
	MYMPD_UPLOAD_PATH: '/tmp/mympd-upload.tar.gz',
	MPD_BACKUP_PATH:   '/tmp/mpd-backup.tar.gz',
	MPD_UPLOAD_PATH:   '/tmp/mpd-upload.tar.gz',
	// Read by /etc/init.d/mpd's autoplay_trigger() on every (re)start.
	MPD_AUTOPLAY_FLAG: '/etc/mpd_autoplay',

	// -- Lazily-initialised caches ---------------------------------------------
	_cpuSnap:    null,
	_cpuCores:   null,
	_outputsSig: null,
	_volBusy:    false,
	_mympdDirPromise: null,

	// -- ubus service RPC (used for reliable PID discovery, and for
	//    myMPD workdir auto-detection via its actual command line) --------------
	_callServiceList: rpc.declare({
		object: 'service',
		method: 'list',
		params: ['name', 'verbose'],
		expect: { '': {} }
	}),

	// -- Low-level helpers ------------------------------------------------------

	_initd: function(svc, action) {
		return fs.exec('/etc/init.d/' + svc, [action]);
	},

	_mpc: function(args) {
		return fs.exec('/usr/bin/mpc', args);
	},

	_serviceStatus: function(svc) {
		return this._initd(svc, 'status').then(function(res) {
			if (res.code === 0) return 'running';
			return /running/i.test((res.stdout || '') + (res.stderr || '')) ? 'running' : 'stopped';
		}).catch(function() { return 'unknown'; });
	},

	_serviceEnabled: function(svc) {
		return this._initd(svc, 'enabled')
			.then(function(r) { return r.code === 0; })
			.catch(function() { return null; });
	},

	// -- Badge ------------------------------------------------------------------

	_applyBadge: function(id, status) {
		var el = document.getElementById(id);
		if (!el) return;
		var map = {
			running: ['label-success', _('Running')],
			stopped: ['label-danger',  _('Stopped')],
			unknown: ['label-warning', _('Unknown')]
		};
		var e = map[status] || map.unknown;
		el.className   = 'label ' + e[0];
		el.textContent = e[1];
	},

	// -- Service control ----------------------------------------------------------

	handleServiceAction: function(svc, action, ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		var verbs = { start: _('Starting'), stop: _('Stopping'), restart: _('Restarting') };
		ui.showModal((verbs[action] || action) + ' ' + svc.toUpperCase() + '...',
			[E('p', { 'class': 'spinning' }, _('Please wait...'))]);
		return self._initd(svc, action).then(function(res) {
			ui.hideModal();
			btn.disabled = false;
			var out = (res.stdout || '') + (res.stderr || '');
			ui.showModal(res.code === 0 ? _('Done') : _('Error'), [
				E('p', res.code === 0
					? svc.toUpperCase() + ' ' + _('action completed successfully.')
					: _('Failed: ') + svc + ' ' + action),
				out ? E('pre', {
					'style': 'max-height:180px;overflow-y:auto;background:#111;' +
					         'color:#7fff7f;padding:8px;border-radius:4px;font-size:.83em'
				}, [out]) : '',
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [_('Close')])
				])
			]);
			self._refreshStatus();
		}).catch(function(e) {
			ui.hideModal();
			btn.disabled = false;
			ui.addNotification(null, E('p', e.message));
		});
	},

	handleEnableToggle: function(svc, enable, ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		return self._initd(svc, enable ? 'enable' : 'disable').then(function() {
			btn.disabled = false;
			ui.addNotification(null, E('p',
				enable ? _('Autostart enabled.') : _('Autostart disabled.')), 'info');
			self._refreshEnableButtons(svc);
		}).catch(function(e) {
			btn.disabled = false;
			ui.addNotification(null, E('p', e.message));
		});
	},

	// -- Autoplay (start playback once mpd + myMPD are both up) --------------------------
	// The actual wait-then-`mpc play` logic runs on the router in
	// /etc/init.d/mpd's autoplay_trigger(), on every service (re)start --
	// this just flips the flag file it reads.

	handleAutoplayToggle: function(enable, ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		return fs.write(self.MPD_AUTOPLAY_FLAG, enable ? 'yes' : 'no').then(function() {
			btn.disabled = false;
			ui.addNotification(null, E('p',
				enable ? _('Autoplay enabled.') : _('Autoplay disabled.')), 'info');
			self._refreshAutoplayButtons();
		}).catch(function(e) {
			btn.disabled = false;
			ui.addNotification(null, E('p', e.message));
		});
	},

	_refreshAutoplayButtons: function() {
		return fs.read(this.MPD_AUTOPLAY_FLAG).then(function(txt) {
			return (txt || '').trim() === 'yes';
		}).catch(function() {
			return false; // missing flag file == disabled, matching the init script's default
		}).then(function(enabled) {
			var a     = document.getElementById('autoplay-enable-btn');
			var b     = document.getElementById('autoplay-disable-btn');
			var badge = document.getElementById('autoplay-badge');
			if (a) a.disabled = enabled;
			if (b) b.disabled = !enabled;
			if (badge) {
				badge.className   = 'label ' + (enabled ? 'label-success' : 'label-warning');
				badge.textContent = enabled ? _('Enabled') : _('Disabled');
			}
		});
	},

	// -- Playback controls --------------------------------------------------------

	_mpcNotify: function(args, okMsg, errMsg) {
		return this._mpc(args).then(function(res) {
			ui.addNotification(null,
				E('p', res.code === 0 ? okMsg : errMsg + (res.stderr || '')),
				res.code === 0 ? 'info' : 'danger');
		}).catch(function(e) { ui.addNotification(null, E('p', e.message)); });
	},

	handleMpdPrev:    function() { return this._mpcNotify(['prev'],    _('Previous track.'),         _('Error: ')); },
	handleMpdStop:    function() { return this._mpcNotify(['stop'],    _('Playback stopped.'),        _('Error: ')); },
	handleMpdNext:    function() { return this._mpcNotify(['next'],    _('Next track.'),              _('Error: ')); },
	handleMpdClear:   function() { return this._mpcNotify(['clear'],   _('Queue cleared.'),           _('Error: ')); },
	handleMpdShuffle: function() { return this._mpcNotify(['shuffle'], _('Queue shuffled.'),          _('Error: ')); },
	handleMpdUpdate:  function() { return this._mpcNotify(['update'],  _('Database update started.'), _('Error: ')); },
	handleMpdRescan:  function() { return this._mpcNotify(['rescan'],  _('Full rescan started.'),     _('Error: ')); },

	// No success notification here (unlike the other playback controls
	// above): the toggle button's own label/color already show the
	// result -- "Playback toggled." on every single click was just noise
	// on top of that. Still surfaces a notification on actual failure,
	// and refreshes Now Playing immediately (matching handleModeToggle's
	// pattern) so the button flips to Play/Pause right away instead of
	// waiting for the next 4s poll tick.
	handleMpdToggle: function(ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		return this._mpc(['toggle']).then(function(res) {
			btn.disabled = false;
			if (res.code !== 0)
				ui.addNotification(null, E('p', _('Error: ') + (res.stderr || '')), 'danger');
			self._refreshNowPlaying();
		}).catch(function(e) {
			btn.disabled = false;
			ui.addNotification(null, E('p', e.message));
		});
	},

	// -- Volume ---------------------------------------------------------------------

	handleVolumeSet: function(ev) {
		this._volBusy = false;
		return this._mpc(['volume', String(ev.currentTarget.value)])
			.catch(function(e) { ui.addNotification(null, E('p', e.message)); });
	},

	// 'input' fires continuously while dragging; 'change' only on release.
	// Marking the slider busy on the first 'input' suppresses the poll's
	// write-back until the drag finishes, and updates the % label live.
	handleVolumeInput: function(ev) {
		this._volBusy = true;
		var volLbl = document.getElementById('mpd-vol-label');
		if (volLbl) volLbl.textContent = ev.currentTarget.value + '%';
	},

	handleVolumeStep: function(delta) {
		var arg = delta > 0 ? '+' + delta : String(delta);
		return this._mpc(['volume', arg])
			.then(L.bind(this._refreshNowPlaying, this))
			.catch(function(e) { ui.addNotification(null, E('p', e.message)); });
	},

	// -- Mode toggles -----------------------------------------------------------------

	handleModeToggle: function(mode, ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		return this._mpc([mode]).then(L.bind(function(res) {
			btn.disabled = false;
			if (res.code !== 0)
				ui.addNotification(null, E('p', _('Error: ') + (res.stderr || '')), 'danger');
			self._refreshNowPlaying();
		}, this)).catch(function(e) {
			btn.disabled = false;
			ui.addNotification(null, E('p', e.message));
		});
	},

	handleCrossfadeSet: function(val) {
		if (!/^\d+$/.test(String(val).trim())) return;
		return this._mpc(['crossfade', String(val).trim()]).then(function(res) {
			ui.addNotification(null,
				E('p', res.code === 0
					? _('Crossfade set to ') + val + _(' seconds.')
					: _('Error setting crossfade.')),
				res.code === 0 ? 'info' : 'danger');
		}).catch(function(e) { ui.addNotification(null, E('p', e.message)); });
	},

	// -- MPD outputs --------------------------------------------------------------------

	_parseOutputs: function(text) {
		var outputs = [];
		(text || '').split('\n').forEach(function(line) {
			var m = line.match(/Output\s+(\d+)\s+\(([^)]+)\)\s+is\s+(enabled|disabled)/i);
			if (m) outputs.push({ id: m[1], name: m[2], enabled: m[3] === 'enabled' });
		});
		return outputs;
	},

	handleOutputToggle: function(id, enable, ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		return this._mpc([enable ? 'enable' : 'disable', String(id)]).then(L.bind(function(res) {
			btn.disabled = false;
			ui.addNotification(null,
				E('p', res.code === 0
					? _('Output ') + id + (enable ? _(' enabled.') : _(' disabled.'))
					: _('Error: ') + (res.stderr || '')),
				res.code === 0 ? 'info' : 'danger');
			self._refreshOutputs();
		}, this)).catch(function(e) {
			btn.disabled = false;
			ui.addNotification(null, E('p', e.message));
		});
	},

	// Rebuilds the outputs list only when the underlying data actually
	// changed (cheap JSON-signature comparison), avoiding needless DOM churn
	// -- and a visible flicker/click-under-cursor -- on every 10s poll tick.
	_refreshOutputs: function() {
		var self = this;
		var container = document.getElementById('mpd-outputs-list');
		if (!container) return;
		return self._mpc(['outputs']).then(function(res) {
			var outputs = self._parseOutputs(res.stdout || '');
			var sig = JSON.stringify(outputs);
			if (sig === self._outputsSig) return;
			self._outputsSig = sig;

			while (container.firstChild) container.removeChild(container.firstChild);
			if (!outputs.length) {
				container.appendChild(E('p', { 'style': 'color:#888' },
					_('No outputs found or mpc unavailable.')));
				return;
			}
			outputs.forEach(function(o) {
				container.appendChild(E('div', {
					'style': 'display:flex;align-items:center;gap:8px;margin-bottom:4px'
				}, [
					E('span', { 'style': 'min-width:200px' }, [
						'#' + o.id + ' ',
						E('strong', {}, [o.name]),
						' -- ',
						o.enabled
							? E('span', { 'style': 'color:#4c4' }, [_('enabled')])
							: E('span', { 'style': 'color:#c44' }, [_('disabled')])
					]),
					o.enabled
						? E('button', {
							'class': 'btn cbi-button-negative',
							'style': 'padding:2px 10px',
							'click': L.bind(self.handleOutputToggle, self, o.id, false)
						}, [_('Disable')])
						: E('button', {
							'class': 'btn cbi-button-positive',
							'style': 'padding:2px 10px',
							'click': L.bind(self.handleOutputToggle, self, o.id, true)
						}, [_('Enable')])
				]));
			});
		}).catch(function() {
			self._outputsSig = null;
			if (container) container.textContent = _('Could not query outputs.');
		});
	},

	// -- Now Playing --------------------------------------------------------------------
	// Bare `mpc` prints either:
	//   1 line  -- "volume: NN%  repeat: .. random: .. ..."          (stopped)
	//   3 lines -- title / "[playing] #n/n  t/t (p%)" / volume line  (playing or paused)
	// The volume line's POSITION therefore varies; search for it instead of
	// assuming a fixed index (previously hard-coded to lines[1], which is
	// only ever the *progress* line while something is playing, so the
	// volume slider never actually reflected the real volume in that case).

	_refreshNowPlaying: function() {
		var self   = this;
		var npEl   = document.getElementById('mpd-nowplaying');
		var volEl  = document.getElementById('mpd-vol-slider');
		var volLbl = document.getElementById('mpd-vol-label');
		return this._mpc([]).then(function(res) {
			if (!npEl) return;
			var lines = (res.stdout || '').split('\n').filter(Boolean);

			var volLine = null;
			for (var i = 0; i < lines.length; i++) {
				if (/volume:\s*\d+%/.test(lines[i])) { volLine = lines[i]; break; }
			}
			if (volLine) {
				var vm = volLine.match(/volume:\s*(\d+)%/);
				if (vm) {
					// Don't yank the knob out from under the user: this poll
					// runs every 4s, so writing volEl.value unconditionally
					// made the slider jump back mid-drag, and could also
					// re-send a stale volume on the next 'change' event.
					if (volEl && !self._volBusy) volEl.value = vm[1];
					if (volLbl) volLbl.textContent = vm[1] + '%';
				}
			}

			npEl.textContent = (lines.length > 1 && !/volume:\s*\d+%/.test(lines[0]))
				? lines[0]
				: _('Idle / stopped');

			// [playing]/[paused] only ever appears on the progress line,
			// which (per the comment above) is only present at all once
			// something is loaded -- a bare 1-line "volume: ..." reply
			// means stopped/idle, with no bracketed state to match.
			var state = 'stopped';
			for (var j = 0; j < lines.length; j++) {
				var sm = lines[j].match(/\[(playing|paused)\]/);
				if (sm) { state = sm[1]; break; }
			}
			var toggleBtn = document.getElementById('mpd-toggle-btn');
			if (toggleBtn) {
				if (state === 'playing') {
					toggleBtn.textContent = '|| ' + _('Pause');
					toggleBtn.className   = 'btn cbi-button-positive';
				} else {
					toggleBtn.textContent = '> ' + _('Play');
					toggleBtn.className   = 'btn cbi-button-action';
				}
			}
		}).catch(function() {
			if (npEl) npEl.textContent = _('mpc unavailable');
		});
	},

	// -- Library stats --------------------------------------------------------------------

	handleShowStats: function() {
		return this._mpc(['stats']).then(function(res) {
			ui.showModal(_('MPD Library Statistics'), [
				E('pre', {
					'style': 'background:#111;color:#7fff7f;padding:10px;' +
					         'border-radius:4px;font-size:.85em'
				}, [res.stdout || _('No data.')]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [_('Close')])
				])
			]);
		}).catch(function(e) { ui.addNotification(null, E('p', e.message)); });
	},

	// -- Resource monitor (CPU / RAM via /proc, PID via ubus/procd) -------------------------
	// PID discovery goes through `ubus call service list`, which procd
	// maintains natively for every USE_PROCD=1 service -- this is reliable
	// regardless of whether the daemon itself also writes a pidfile (MPD's
	// own pidfile is not guaranteed to be written/valid in --no-daemon mode,
	// and myMPD's pidfile path/name is not something this plugin should have
	// to guess).

	_findServicePid: function(name) {
		return this._callServiceList(name).then(function(res) {
			var svc = res && res[name];
			if (!svc || !svc.instances) return null;
			var keys = Object.keys(svc.instances);
			for (var i = 0; i < keys.length; i++) {
				var inst = svc.instances[keys[i]];
				if (inst && inst.running && inst.pid) return String(inst.pid);
			}
			return null;
		}).catch(function() { return null; });
	},

	// -- myMPD workdir discovery ---------------------------------------------------------
	// The OpenWrt "mympd" package's init script always launches myMPD as
	// `/usr/bin/mympd -w <workdir> -a <cachedir>`, with <workdir> read from
	// /etc/config/mympd (default /var/lib/mympd, but UCI-overridable) --
	// so a hardcoded constant can never be fully reliable. Ask procd for
	// the actual running command line first (authoritative, whatever the
	// workdir really is); only fall back to probing fixed candidate paths
	// if myMPD isn't running yet to ask.

	_readUciValue: function(key) {
		return fs.exec('/sbin/uci', ['-q', 'get', key]).then(function(res) {
			return res.code === 0 ? (res.stdout || '').trim() : null;
		}).catch(function() { return null; });
	},

	_resolveMympdDir: function() {
		var self = this;
		if (self._mympdDirPromise) return self._mympdDirPromise;

		self._mympdDirPromise = self._callServiceList('mympd', true).then(function(res) {
			var svc  = res && res.mympd;
			var keys = svc && svc.instances ? Object.keys(svc.instances) : [];
			for (var i = 0; i < keys.length; i++) {
				var cmd = svc.instances[keys[i]] && svc.instances[keys[i]].command;
				if (!Array.isArray(cmd)) continue;
				for (var j = 0; j < cmd.length; j++) {
					if ((cmd[j] === '-w' || cmd[j] === '--workdir') && cmd[j + 1])
						return cmd[j + 1];
					var m = /^--workdir=(.+)$/.exec(cmd[j]);
					if (m) return m[1];
				}
			}
			return null;
		}).catch(function() { return null; }).then(function(fromCmdline) {
			if (fromCmdline) return fromCmdline;
			// Not running (yet), or started without a visible -w flag --
			// probe known locations. /var/lib/mympd is the confirmed
			// upstream + OpenWrt-package default; /etc/mympd is kept as a
			// harmless second guess for any install that really does use
			// it, so this doesn't regress whatever worked before.
			var candidates = ['/var/lib/mympd', '/etc/mympd'];
			return candidates.reduce(function(chain, dir) {
				return chain.then(function(found) {
					if (found) return found;
					return fs.stat(dir).then(function() { return dir; }).catch(function() { return null; });
				});
			}, Promise.resolve(null));
		}).then(function(found) {
			return found || self.MYMPD_DATA_DIR;
		});

		return self._mympdDirPromise;
	},

	// Robust /proc/PID/stat parser: anchors on the LAST ')' (comm can in
	// theory contain spaces/parens) then indexes fields by position rather
	// than counting \S+ tokens in a regex (an earlier version miscounted
	// the skip-fields and silently read cmajflt+utime instead of
	// utime+stime, corrupting every CPU% figure).
	_readPidStat: function(pid) {
		return fs.read('/proc/' + pid + '/stat').then(function(txt) {
			if (!txt) return null;
			var closeIdx = txt.lastIndexOf(')');
			if (closeIdx < 0) return null;
			var rest = txt.slice(closeIdx + 1).trim().split(/\s+/);
			// rest[0]=state 1=ppid 2=pgrp 3=session 4=tty_nr 5=tpgid 6=flags
			// 7=minflt 8=cminflt 9=majflt 10=cmajflt 11=utime 12=stime
			var utime = parseInt(rest[11]);
			var stime = parseInt(rest[12]);
			if (isNaN(utime) || isNaN(stime)) return null;
			return { utime: utime, stime: stime };
		}).catch(function() { return null; });
	},

	_readTotalJiffies: function() {
		return fs.read('/proc/stat').then(function(txt) {
			var line = (txt || '').split('\n')[0];
			var total = 0;
			line.replace(/^cpu\s+/, '').split(/\s+/).forEach(function(n) {
				total += parseInt(n) || 0;
			});
			return total;
		}).catch(function() { return 0; });
	},

	// Counts cpuN lines in /proc/stat so CPU% can be normalised the same
	// way `top` does (100% == one fully-saturated core), rather than as a
	// share of total system-wide capacity, which understates usage by a
	// factor of N on an N-core board (e.g. the dual-core Zynq-7010).
	_readCpuCoreCount: function() {
		return fs.read('/proc/stat').then(function(txt) {
			var count = 0;
			(txt || '').split('\n').forEach(function(line) {
				if (/^cpu\d+\s/.test(line)) count++;
			});
			return count || 1;
		}).catch(function() { return 1; });
	},

	_readPidRam: function(pid) {
		return fs.read('/proc/' + pid + '/status').then(function(txt) {
			var m = (txt || '').match(/^VmRSS:\s+(\d+)/m);
			return m ? Math.round(parseInt(m[1]) / 1024) : null;
		}).catch(function() { return null; });
	},

	_refreshResourceStats: function() {
		var self = this;
		if (!self._cpuSnap) self._cpuSnap = {};

		var names = ['mpd', 'mympd'];
		var coreCountP = self._cpuCores !== null
			? Promise.resolve(self._cpuCores)
			: self._readCpuCoreCount().then(function(n) { self._cpuCores = n; return n; });

		return Promise.all([
			self._readTotalJiffies(),
			coreCountP,
			Promise.all(names.map(function(name) {
				return self._findServicePid(name).then(function(pid) {
					if (!pid) return { name: name, pid: null };
					return Promise.all([
						self._readPidStat(pid),
						self._readPidRam(pid)
					]).then(function(r) {
						return { name: name, pid: pid, stat: r[0], ram: r[1] };
					});
				});
			}))
		]).then(function(results) {
			var nowTotal  = results[0];
			var cores     = results[1];
			var processes = results[2];

			processes.forEach(function(p) {
				var el = document.getElementById('res-' + p.name + '-stats');
				if (!el) return;

				if (!p.pid) {
					el.textContent = _('Not running');
					el.style.color = '#c44';
					delete self._cpuSnap[p.name];
					return;
				}

				var cpuStr = '';
				if (p.stat) {
					var nowProc = p.stat.utime + p.stat.stime;
					var snap    = self._cpuSnap[p.name];
					if (snap && snap.pid === p.pid && nowTotal > snap.totalJiffies) {
						var dProc  = nowProc - snap.procJiffies;
						var dTotal = nowTotal - snap.totalJiffies;
						var pct    = (dProc / dTotal) * 100 * cores;
						cpuStr     = 'CPU ' + pct.toFixed(1) + '%';
					}
					self._cpuSnap[p.name] = {
						pid: p.pid, procJiffies: nowProc, totalJiffies: nowTotal
					};
				}

				var ramStr = p.ram !== null ? 'RAM ' + p.ram + ' MB' : '';
				el.textContent = [cpuStr, ramStr].filter(Boolean).join('  |  ') || _('Running');
				el.style.color = '';
			});
		}).catch(function() {
			names.forEach(function(name) {
				var el = document.getElementById('res-' + name + '-stats');
				if (el) { el.textContent = _('Error reading stats'); el.style.color = '#c44'; }
			});
		});
	},

	// -- mpd.conf key-value editor -------------------------------------------------------
	// Both read and write are brace-depth aware: a naive whole-file scan
	// would also match keys nested inside `audio_output { ... }` blocks.
	// This matters in practice: MPD's own top-level `port` (control port,
	// e.g. 6600) shares its name with the httpd audio_output's `port`
	// sub-key (stream port, e.g. 8000) -- once a user enables HTTP
	// streaming, a depth-unaware parser will show/overwrite whichever
	// `port` line happens to appear first/last in the file instead of the
	// real MPD control port.

	_readMpdConf: function() {
		return fs.read('/etc/mpd.conf').then(function(content) {
			var values = {};
			var depth  = 0;
			(content || '').split('\n').forEach(function(line) {
				var isComment = /^\s*#/.test(line);
				if (!isComment && depth === 0) {
					var m = line.match(/^\s*([a-zA-Z_]+)\s+"?([^"#\n]+)"?\s*(?:#.*)?$/);
					if (m) values[m[1].trim()] = m[2].trim();
				}
				if (!isComment) {
					var opens  = (line.match(/\{/g) || []).length;
					var closes = (line.match(/\}/g) || []).length;
					depth += opens - closes;
					if (depth < 0) depth = 0;
				}
			});
			return { raw: content || '', values: values };
		});
	},

	// Sanitise a value before it is embedded into a quoted mpd.conf string:
	// a literal `"` in user input would otherwise close the string early
	// and let the remainder of the value be interpreted as new directives.
	_sanitizeConfValue: function(value) {
		return String(value).replace(/["\r\n]/g, '');
	},

	_setMpdConfKey: function(raw, key, value) {
		var quoted = '"' + this._sanitizeConfValue(value) + '"';
		var lines  = raw.split('\n');
		var depth  = 0;
		var reKey  = new RegExp('^\\s*' + key + '(\\s|$)');
		var found  = false;

		for (var i = 0; i < lines.length; i++) {
			var line      = lines[i];
			var isComment = /^\s*#/.test(line);

			if (!isComment && depth === 0 && reKey.test(line)) {
				var indent = (line.match(/^(\s*)/) || ['', ''])[1];
				var trailingComment = (line.match(/(\s+#.*)$/) || ['', ''])[1];
				lines[i] = indent + key + '\t\t' + quoted + trailingComment;
				found = true;
				break;
			}

			if (!isComment) {
				var opens  = (line.match(/\{/g) || []).length;
				var closes = (line.match(/\}/g) || []).length;
				depth += opens - closes;
				if (depth < 0) depth = 0;
			}
		}

		if (found) return lines.join('\n');
		return raw.replace(/\s+$/, '') + '\n' + key + '\t\t' + quoted + '\n';
	},

	// Creates whatever handleMpdConfSave just pointed a Paths field at, so
	// a custom path actually works the moment it's saved rather than only
	// failing MPD's next start with no obvious explanation in the UI. See
	// the `kind` comment on MPD_PATHS above.
	//
	// fs.exec() resolves (does not reject) on a non-zero exit code -- like
	// every other fs.exec() call in this file, a failed mkdir/touch has to
	// be turned into a rejection explicitly by checking res.code, or a
	// permission error here would resolve silently instead of surfacing
	// to the caller's .catch().
	_ensurePathExists: function(kind, path) {
		if (!path || !kind) return Promise.resolve();
		var parent = path.replace(/\/[^\/]*\/?$/, '') || '/';
		var mkdirTarget = (kind === 'dir') ? path : parent;
		return fs.exec('/bin/mkdir', ['-p', '--', mkdirTarget]).then(function(res) {
			if (res.code !== 0)
				throw new Error((res.stderr || '').trim() || ('mkdir exited with code ' + res.code));
			if (kind !== 'file') return null;
			return fs.exec('/bin/touch', ['--', path]).then(function(res2) {
				if (res2.code !== 0)
					throw new Error((res2.stderr || '').trim() || ('touch exited with code ' + res2.code));
			});
		});
	},

	handleMpdConfSave: function(fields, widgets, rawHolder, ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		var raw     = rawHolder.raw;
		var written = {};
		fields.forEach(function(f) {
			var w   = widgets[f.key];
			var val = w ? String(w.getValue() == null ? '' : w.getValue()).trim() : '';
			if (val) {
				raw = self._setMpdConfKey(raw, f.key, val);
				written[f.key] = val;
			}
		});
		var isPaths = (fields === self.MPD_PATHS);
		return fs.write('/etc/mpd.conf', raw).then(function() {
			if (!isPaths) return null;
			return Promise.all(fields.map(function(f) {
				if (!written[f.key]) return null;
				// Non-fatal per path: mpd.conf is already saved regardless
				// of whether pre-creating this one path succeeds, and
				// /etc/init.d/mpd's setup_configured_paths() retries it on
				// the next MPD start anyway -- so a failure here (e.g. a
				// USB mount that isn't attached right now) shouldn't make
				// the whole save look like it failed.
				return self._ensurePathExists(f.kind, written[f.key]).catch(function(e) {
					ui.addNotification(null, E('p',
						_('Could not pre-create path for ') + f.label + ': ' + e.message), 'warning');
				});
			}));
		}).then(function() {
			btn.disabled  = false;
			rawHolder.raw = raw;
			// Keep `values` in step with `raw`. handleMpdBackup reads
			// rawHolder.values to decide which playlist/db/state/sticker
			// paths to archive; leaving it at its load-time snapshot meant
			// that editing a path here and then hitting "Download backup"
			// silently backed up the OLD path (and missed the new one).
			if (!rawHolder.values) rawHolder.values = {};
			Object.keys(written).forEach(function(k) { rawHolder.values[k] = written[k]; });
			ui.addNotification(null, E('p',
				isPaths
					? _('mpd.conf saved and paths created. Restart MPD to apply.')
					: _('mpd.conf saved. Restart MPD to apply.')), 'info');
		}).catch(function(e) {
			btn.disabled = false;
			ui.addNotification(null, E('p', _('Save failed: ') + e.message), 'danger');
		});
	},

	// -- audio_output block helpers -------------------------------------------------------

	_getAudioBlock: function(raw, type) {
		var lines = raw.split('\n');
		var inBlock = false, isCommented = false, params = {}, found = false;
		for (var i = 0; i < lines.length; i++) {
			var line     = lines[i];
			var stripped = line.replace(/^[#\s]+/, '').replace(/\s+$/, '');
			if (!inBlock && /^audio_output\s*\{/.test(stripped)) {
				inBlock = true; isCommented = /^\s*#/.test(line); params = {}; found = false;
				continue;
			}
			if (inBlock) {
				var tm = stripped.match(/^type\s+"([^"]+)"/);
				if (tm && tm[1] === type) found = true;
				var pm = stripped.match(/^([a-zA-Z_]+)\s+"([^"]*)"/);
				if (pm) params[pm[1]] = pm[2];
				if (/^\}/.test(stripped)) {
					if (found) return { params: params, enabled: !isCommented };
					inBlock = false;
				}
			}
		}
		return null;
	},

	_removeAudioBlock: function(raw, type) {
		var lines = raw.split('\n'), result = [], inBlock = false, hasType = false, buffer = [];
		for (var i = 0; i < lines.length; i++) {
			var line     = lines[i];
			var stripped = line.replace(/^[#\s]+/, '').replace(/\s+$/, '');
			if (!inBlock) {
				if (/^audio_output\s*\{/.test(stripped)) {
					inBlock = true; hasType = false; buffer = [line];
				} else {
					result.push(line);
				}
			} else {
				buffer.push(line);
				var tm = stripped.match(/^type\s+"([^"]+)"/);
				if (tm && tm[1] === type) hasType = true;
				if (/^\}/.test(stripped)) {
					inBlock = false;
					if (!hasType) result = result.concat(buffer);
					buffer = []; hasType = false;
				}
			}
		}
		if (buffer.length) result = result.concat(buffer);
		return result.join('\n');
	},

	_buildAudioBlock: function(params, enabled) {
		var self = this;
		var p = enabled ? '' : '#';
		var t = '\t';
		var lines = [p + 'audio_output {'];
		var order = ['type', 'name', 'device', 'port', 'encoder',
		             'bitrate', 'format', 'auto_resample', 'mixer_type', 'mixer_device', 'mixer_control'];
		var written = {};
		order.forEach(function(k) {
			if (params[k] !== undefined) {
				lines.push(p + t + k + '\t\t"' + self._sanitizeConfValue(params[k]) + '"');
				written[k] = true;
			}
		});
		Object.keys(params).forEach(function(k) {
			if (!written[k]) lines.push(p + t + k + '\t\t"' + self._sanitizeConfValue(params[k]) + '"');
		});
		lines.push(p + '}');
		return lines.join('\n');
	},

	_upsertAudioBlock: function(raw, type, params, enabled) {
		var cleaned = this._removeAudioBlock(raw, type);
		return cleaned.replace(/\s+$/, '') + '\n\n' +
		       this._buildAudioBlock(params, enabled) + '\n';
	},

	// -- ALSA output --------------------------------------------------------------------

	_parseAlsaDevices: function(text) {
		var devices = [];
		(text || '').split('\n').forEach(function(line) {
			// Regex handles device names with spaces before [...]:
			// card N: shortname [Long Name], device N: shortname [Long Name]
			var m = line.match(
				/^card\s+(\d+):\s+[^\[]+\[([^\]]+)\],\s+device\s+(\d+):\s+[^\[]+\[([^\]]+)\]/
			);
			if (!m) return;
			var hwId = 'hw:' + m[1] + ',' + m[3];
			devices.push({
				label: hwId + '  --  ' + m[2].trim() + ' / ' + m[4].trim(),
				value: hwId
			});
		});
		return devices;
	},

	// Parses `amixer scontrols` output, e.g. "Simple mixer control 'Master',0",
	// into a de-duplicated, ordered list of control names for the Mixer
	// control combobox. Queried against the default card (card 0) -- see
	// note at the call site for why this doesn't follow the selected
	// Audio device's card index.
	_parseMixerControls: function(text) {
		var names = [];
		(text || '').split('\n').forEach(function(line) {
			var m = line.match(/Simple mixer control '([^']+)'/);
			if (m && names.indexOf(m[1]) === -1) names.push(m[1]);
		});
		return names;
	},

	handleAlsaSave: function(rawHolder, mixDevWidget, mixCtrlWidget, formatWidget, autoResampleWidget, ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		var devSel        = document.getElementById('alsa-device-select');
		var mixType       = document.getElementById('alsa-mixer-type');
		var mixDevVal     = mixDevWidget        ? String(mixDevWidget.getValue()        == null ? '' : mixDevWidget.getValue()).trim()        : '';
		var mixCtrlVal    = mixCtrlWidget       ? String(mixCtrlWidget.getValue()       == null ? '' : mixCtrlWidget.getValue()).trim()       : '';
		var formatVal     = formatWidget        ? String(formatWidget.getValue()        == null ? '' : formatWidget.getValue()).trim()        : '';
		var autoResampleVal = autoResampleWidget ? String(autoResampleWidget.getValue() == null ? '' : autoResampleWidget.getValue()).trim() : '';
		var params  = { type: 'alsa', name: 'Zynq ADI I2S' };
		if (devSel  && devSel.value)  params.device        = devSel.value;
		if (mixType && mixType.value) params.mixer_type    = mixType.value;
		if (mixDevVal)                params.mixer_device  = mixDevVal;
		if (mixCtrlVal)               params.mixer_control = mixCtrlVal;
		if (formatVal)                params.format        = formatVal;
		if (autoResampleVal)          params.auto_resample = autoResampleVal;
		var raw = self._upsertAudioBlock(rawHolder.raw, 'alsa', params, true);
		return fs.write('/etc/mpd.conf', raw).then(function() {
			btn.disabled  = false;
			rawHolder.raw = raw;
			ui.addNotification(null, E('p', _('ALSA output saved. Restart MPD to apply.')), 'info');
		}).catch(function(e) {
			btn.disabled = false;
			ui.addNotification(null, E('p', _('Save failed: ') + e.message), 'danger');
		});
	},

	// -- HTTP stream --------------------------------------------------------------------

	handleHttpdSave: function(rawHolder, ev) {
		var self    = this;
		var btn     = ev.currentTarget;
		btn.disabled = true;
		var enabledChk = document.getElementById('httpd-enabled');
		var portInp    = document.getElementById('httpd-port');
		var encSel     = document.getElementById('httpd-encoder');
		var bitSel     = document.getElementById('httpd-bitrate');
		var fmtInp     = document.getElementById('httpd-format');
		var enabled = enabledChk && enabledChk.checked;
		var encoder = encSel ? encSel.value : 'lame';
		var params  = {
			type:    'httpd',
			name:    'HTTP Stream',
			port:    portInp && portInp.value.trim() ? portInp.value.trim() : '8000',
			encoder: encoder,
			format:  fmtInp && fmtInp.value.trim() ? fmtInp.value.trim() : '48000:16:2'
		};
		// FLAC is lossless (no bitrate concept); Opus's MPD plugin measures
		// bitrate in bits/sec while our shared dropdown offers kbps values
		// for lame/vorbis, so leaving it unset lets MPD apply its own
		// sensible Opus default rather than silently applying the wrong unit.
		if (encoder !== 'flac' && encoder !== 'opus')
			params.bitrate = bitSel ? bitSel.value : '128';
		var raw = self._upsertAudioBlock(rawHolder.raw, 'httpd', params, enabled);
		return fs.write('/etc/mpd.conf', raw).then(function() {
			btn.disabled  = false;
			rawHolder.raw = raw;
			ui.addNotification(null,
				E('p', enabled
					? _('HTTP stream enabled. Restart MPD to apply.')
					: _('HTTP stream disabled. Restart MPD to apply.')),
				'info');
		}).catch(function(e) {
			btn.disabled = false;
			ui.addNotification(null, E('p', _('Save failed: ') + e.message), 'danger');
		});
	},

	// -- myMPD network config --------------------------------------------------------------
	// Two possible sources of truth, tried in order:
	//  1. UCI (/etc/config/mympd) -- what the OFFICIAL OpenWrt "mympd"
	//     package's init script actually reads. Critically, that init
	//     script regenerates <workdir>/config/http_port from UCI on
	//     EVERY start, so writing straight to the workdir copy would
	//     silently be reverted on the next restart/reboot. This must be
	//     the primary path whenever UCI has a `mympd` config at all.
	//  2. <workdir>/config/http_port + http_host directly, for myMPD
	//     installs that don't use that OpenWrt package (manually built,
	//     Docker, etc.) and therefore have no UCI config to read at all.
	// `cfg.via` records which one was used, so handleMyMpdNetSave writes
	// back through the same mechanism it read from.

	_loadMyMpdConfig: function() {
		var self = this;
		return Promise.all([
			self._readUciValue('mympd.main.http_port'),
			self._readUciValue('mympd.main.http_host')
		]).then(function(uci) {
			if (uci[0] !== null || uci[1] !== null) {
				return {
					http_port: /^\d+$/.test(uci[0]) ? uci[0] : '8080',
					host:      uci[1] || '0.0.0.0',
					via:       'uci'
				};
			}
			return self._resolveMympdDir().then(function(base) {
				return Promise.all([
					fs.read(base + '/config/http_port').catch(function() { return null; }),
					fs.read(base + '/config/http_host').catch(function() { return null; })
				]).then(function(vals) {
					var port = vals[0] ? vals[0].trim() : '';
					var host = vals[1] ? vals[1].trim() : '';
					return {
						http_port: /^\d+$/.test(port) ? port : '8080',
						host:      host || '0.0.0.0',
						via:       'file'
					};
				});
			});
		});
	},

	handleMyMpdNetSave: function(portInp, hostSel, via, ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		var port = portInp.value.trim() || '8080';
		var host = hostSel.value;

		var save = (via === 'uci')
			? fs.exec('/sbin/uci', ['set', 'mympd.main.http_port=' + port])
				.then(function(r) { if (r.code !== 0) throw new Error('uci set http_port: ' + (r.stderr || r.code)); })
				.then(function() { return fs.exec('/sbin/uci', ['set', 'mympd.main.http_host=' + host]); })
				.then(function(r) { if (r.code !== 0) throw new Error('uci set http_host: ' + (r.stderr || r.code)); })
				.then(function() { return fs.exec('/sbin/uci', ['commit', 'mympd']); })
				.then(function(r) { if (r.code !== 0) throw new Error('uci commit: ' + (r.stderr || r.code)); })
			: self._resolveMympdDir().then(function(base) {
				return Promise.all([
					fs.write(base + '/config/http_port', port),
					fs.write(base + '/config/http_host', host)
				]);
			});

		return save.then(function() {
			btn.disabled = false;
			var linkEl = document.getElementById('mympd-web-link');
			if (linkEl) linkEl.href = 'http://' + window.location.hostname + ':' + port;
			ui.addNotification(null,
				E('p', _('myMPD network settings saved. Restart myMPD to apply.')), 'info');
		}).catch(function(e) {
			btn.disabled = false;
			ui.addNotification(null, E('p', _('Save failed: ') + e.message), 'danger');
		});
	},

	// -- Filtered file upload -------------------------------------------------------------
	// ui.uploadFile()'s own <input type=file> has no `accept` attribute and
	// its public signature gives no way to add one, so the browser's file
	// picker shows every file on the device rather than just .tar.gz/.tgz
	// archives. This is a trimmed reimplementation of the same upload flow
	// (same cgi-upload endpoint, same FormData shape, same progress bar)
	// with `accept` wired in. See ui.js's uploadFile() for the original.

	_uploadFileFiltered: function(path, accept) {
		return new Promise(function(resolveFn, rejectFn) {
			var input = E('input', {
				'type':   'file',
				'accept': accept,
				'style':  'display:none',
				'change': function(ev) {
					var file = ev.currentTarget.files[0];
					input.remove();
					if (!file) { rejectFn(new Error(_('No file selected'))); return; }

					var progress = E('div', { 'class': 'cbi-progressbar', 'title': '0%' },
						E('div', { 'style': 'width:0' }));
					ui.showModal(_('Uploading file…'), [progress]);

					var data = new FormData();
					data.append('sessionid', rpc.getSessionID());
					data.append('filename', path);
					data.append('filedata', file);

					request.post(L.env.cgi_base + '/cgi-upload', data, {
						timeout: 0,
						progress: function(pev) {
							var percent = (pev.loaded / pev.total) * 100;
							progress.setAttribute('title', percent.toFixed(2) + '%');
							progress.firstElementChild.style.width = percent.toFixed(2) + '%';
						}
					}).then(function(res) {
						var reply = res.json();
						ui.hideModal();
						if (L.isObject(reply) && reply.failure) {
							ui.addNotification(null,
								E('p', _('Upload request failed: ') + reply.message));
							rejectFn(new Error(reply.failure));
						} else {
							reply.name = file.name;
							resolveFn(reply);
						}
					}, function(err) {
						ui.hideModal();
						rejectFn(err);
					});
				}
			});
			document.body.appendChild(input);
			input.click();
		});
	},

	// -- Config backup & restore (myMPD + MPD) --------------------------------------------
	// Both services get a "Backup" (create + download a .tar.gz) and a
	// "Restore" (upload a .tar.gz, extract, restart) action. myMPD's
	// archive is a straight snapshot of its whole state directory
	// (/etc/mympd); MPD's is /etc/mpd.conf plus whichever of its data
	// paths currently exist, since MPD's state is scattered across
	// several independently-configurable paths rather than one directory
	// (see handleMpdBackup).

	_triggerBlobDownload: function(blob, filename) {
		var url = URL.createObjectURL(blob);
		var a   = E('a', { 'href': url, 'download': filename, 'style': 'display:none' });
		document.body.appendChild(a);
		a.click();
		a.remove();
		window.setTimeout(function() { URL.revokeObjectURL(url); }, 60000);
	},

	// Fetches the already-created archive via the cgi-download helper
	// (bypasses the ubus message-size limit) and removes the server-side
	// copy once the browser has it, whether or not the download itself
	// succeeded.
	_downloadAndCleanup: function(remotePath, filename) {
		var self = this;
		return fs.read_direct(remotePath, 'blob').then(function(blob) {
			self._triggerBlobDownload(blob, filename);
		}).finally(function() {
			fs.remove(remotePath).catch(function() {});
		});
	},

	handleMympdBackup: function(ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		var modal = ui.showModal(_('Creating backup...'),
			[E('p', { 'class': 'spinning' }, _('Locating myMPD workdir...'))]);
		return self._resolveMympdDir().then(function(base) {
			var p = modal.querySelector('p.spinning');
			if (p) p.textContent = _('Archiving ') + base + ' ...';
			return fs.exec('/bin/tar', ['-czf', self.MYMPD_BACKUP_PATH, '-C', base, '.']);
		}).then(function(res) {
			if (res.code !== 0)
				throw new Error((res.stderr || '').trim() || ('tar exited with code ' + res.code));
			return self._downloadAndCleanup(self.MYMPD_BACKUP_PATH, 'mympd-backup.tar.gz');
		}).then(function() {
			ui.hideModal();
			btn.disabled = false;
		}).catch(function(e) {
			ui.hideModal();
			btn.disabled = false;
			ui.addNotification(null, E('p', _('Backup failed: ') + e.message), 'danger');
		});
	},

	// Backs up /etc/mpd.conf plus whichever of the currently-configured
	// playlist/db/state/sticker paths actually exist right now.
	// music_directory is deliberately excluded -- it's the music library
	// itself, potentially huge and not "config" -- as are log_file and
	// pid_file (recreated on every start).
	//
	// Existence is NOT pre-checked with fs.stat(): that's an ubus call
	// gated by the per-path read ACL, which only covers the default
	// /lib/mpd/* tree -- a custom path saved via the Paths section (e.g.
	// db_file on a USB mount) would fail that stat for lack of ACL
	// grant, indistinguishable from genuinely not existing, and silently
	// get dropped from the backup. Instead every candidate path is
	// always handed to tar, which runs via fs.exec (a spawned process,
	// not gated by the file ACL at all) and simply skips members that
	// don't exist -- tar exits non-zero when it does, but still writes
	// everything it *could* find, so success is judged by whether the
	// one guaranteed-present file (mpd.conf) actually made it into the
	// resulting archive, not by tar's exit code alone.
	handleMpdBackup: function(rawHolder, ev) {
		var self = this;
		var btn  = ev.currentTarget;
		btn.disabled = true;
		ui.showModal(_('Creating backup...'),
			[E('p', { 'class': 'spinning' }, _('Collecting MPD config and state...'))]);

		var values     = rawHolder.values || {};
		var candidates = ['playlist_directory', 'db_file', 'state_file', 'sticker_file']
			.map(function(k) { return values[k]; })
			.filter(Boolean);
		var paths = ['/etc/mpd.conf'].concat(candidates);
		var rel   = paths.map(function(p) { return p.replace(/^\/+/, ''); });

		return fs.exec('/bin/tar', ['-czf', self.MPD_BACKUP_PATH, '-C', '/', '--'].concat(rel))
			.then(function(res) {
				if (res.code === 0) return; // clean exit: everything was archived, nothing further to check
				return fs.exec('/bin/tar', ['-tzf', self.MPD_BACKUP_PATH]).then(function(listRes) {
					var listing = listRes.stdout || '';
					if (listRes.code !== 0 || listing.indexOf('etc/mpd.conf') === -1) {
						throw new Error((res.stderr || '').trim() || _('Archive creation failed.'));
					}
					// Non-zero exit but mpd.conf (and whatever else exists)
					// still made it in -- e.g. sticker.sql not created yet.
					// Treat as a successful, if partial, backup.
				});
			})
			.then(function() {
				return self._downloadAndCleanup(self.MPD_BACKUP_PATH, 'mpd-backup.tar.gz');
			})
			.then(function() {
				ui.hideModal();
				btn.disabled = false;
			}).catch(function(e) {
				ui.hideModal();
				btn.disabled = false;
				ui.addNotification(null, E('p', _('Backup failed: ') + e.message), 'danger');
			});
	},

	// Shared upload -> confirm -> extract -> restart flow for both
	// services. `extractArgs` are appended after `-xzf <uploadPath>`, e.g.
	// ['-C', <resolved myMPD workdir>] for myMPD (see _resolveMympdDir) or
	// ['-C', '/'] for MPD (whose archive members are already relative to
	// '/', see handleMpdBackup).
	_confirmAndRestoreArchive: function(uploadPath, extractArgs, serviceName, title, res) {
		var self = this;
		ui.showModal(title, [
			E('p', _('Archive uploaded. Applying overwrites settings and restarts ') + serviceName + '.'),
			E('ul', {}, [
				res.size     ? E('li', {}, _('Size: ') + Math.round(res.size / 1024) + ' KB') : '',
				res.checksum ? E('li', {}, 'MD5: ' + res.checksum) : ''
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn',
					'click': function() {
						fs.remove(uploadPath).catch(function() {});
						ui.hideModal();
					}
				}, [_('Cancel')]), ' ',
				E('button', { 'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(self, function() {
						ui.showModal(_('Applying...'), [
							E('p', { 'class': 'spinning' }, _('Extracting archive...'))
						]);
						return fs.exec('/bin/tar', ['-xzf', uploadPath].concat(extractArgs))
							.then(function(res2) {
								var out = (res2.stdout || '') + (res2.stderr || '');
								if (res2.code === 0) {
									return self._initd(serviceName, 'restart').then(function() {
										ui.showModal(_('Done'), [
											E('p', _('Config restored and ') + serviceName + _(' restarted.')),
											E('div', { 'class': 'right' }, [
												E('button', { 'class': 'btn', 'click': ui.hideModal }, [_('Close')])
											])
										]);
										self._refreshStatus();
									});
								} else {
									ui.showModal(_('Error'), [
										E('p', _('Extraction failed:')),
										E('pre', {
											'style': 'background:#111;color:#f88;padding:8px;border-radius:4px'
										}, [out || _('No output.')]),
										E('div', { 'class': 'right' }, [
											E('button', { 'class': 'btn', 'click': ui.hideModal }, [_('Close')])
										])
									]);
								}
							}).finally(function() {
								fs.remove(uploadPath).catch(function() {});
							});
					})
				}, [_('Apply')])
			])
		]);
	},

	handleMympdRestore: function(ev) {
		var self = this;
		return Promise.all([
			self._uploadFileFiltered(self.MYMPD_UPLOAD_PATH, '.tar.gz,.tgz'),
			self._resolveMympdDir()
		]).then(function(r) {
			self._confirmAndRestoreArchive(
				self.MYMPD_UPLOAD_PATH, ['-C', r[1]],
				'mympd', _('Apply myMPD configuration?'), r[0]);
		}).catch(function(e) { if (e && e.message) ui.addNotification(null, E('p', e.message)); });
	},

	handleMpdRestore: function(ev) {
		var self = this;
		return self._uploadFileFiltered(self.MPD_UPLOAD_PATH, '.tar.gz,.tgz')
			.then(function(res) {
				self._confirmAndRestoreArchive(
					self.MPD_UPLOAD_PATH, ['-C', '/'],
					'mpd', _('Apply MPD configuration?'), res);
			})
			.catch(function(e) { if (e && e.message) ui.addNotification(null, E('p', e.message)); });
	},

	// -- Status polling -----------------------------------------------------------------

	_refreshStatus: function() {
		var self = this;
		return Promise.all([
			self._serviceStatus('mympd'),
			self._serviceStatus('mpd')
		]).then(function(r) {
			self._applyBadge('mympd-badge', r[0]);
			self._applyBadge('mpd-badge',   r[1]);
		});
	},

	_refreshEnableButtons: function(svc) {
		var self = this;
		self._serviceEnabled(svc).then(function(en) {
			var a = document.getElementById(svc + '-enable-btn');
			var b = document.getElementById(svc + '-disable-btn');
			if (a) a.disabled = (en === true);
			if (b) b.disabled = (en === false);
		});
	},

	// -- Service card builder -------------------------------------------------------------

	_serviceCard: function(svc, title, descr) {
		var self  = this;
		var badge = E('span', { 'id': svc + '-badge', 'class': 'label label-warning' }, ['...']);
		var mkBtn = function(label, cls, action) {
			return E('button', { 'class': 'btn ' + cls,
				'click': L.bind(self.handleServiceAction, self, svc, action)
			}, [label]);
		};
		var enBtn  = E('button', { 'id': svc + '-enable-btn',  'class': 'btn',
			'click': L.bind(self.handleEnableToggle, self, svc, true)  }, [_('Enable autostart')]);
		var disBtn = E('button', { 'id': svc + '-disable-btn', 'class': 'btn cbi-button-negative',
			'click': L.bind(self.handleEnableToggle, self, svc, false) }, [_('Disable autostart')]);
		self._serviceEnabled(svc).then(function(en) {
			if (en === true)  enBtn.disabled  = true;
			if (en === false) disBtn.disabled = true;
		});
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [title, ' ', badge]),
			E('p', { 'class': 'cbi-section-descr' }, [descr]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Service')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					mkBtn(_('Start'),   'cbi-button-positive', 'start'),   ' ',
					mkBtn(_('Stop'),    'cbi-button-negative', 'stop'),    ' ',
					mkBtn(_('Restart'), 'cbi-button-action',   'restart')
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Autostart')]),
				E('div',   { 'class': 'cbi-value-field' }, [enBtn, ' ', disBtn])
			])
		]);
	},

	// -- mpd.conf field section builder ----------------------------------------------------

	// Renders one ui.Textfield per field, unless `f.choices` is set, in which
	// case a ui.Combobox is rendered instead: a dropdown of known-good
	// values that remains freely editable, so a value already present in
	// mpd.conf but absent from `choices` is shown as-is rather than
	// silently coerced to the closest option. Widget instances (not raw
	// DOM values) are threaded through to handleMpdConfSave via `widgets`,
	// since ui.Combobox is a custom element, not a native <input>/<select>.
	_appendConfFields: function(container, fields, values, rawHolder, saveLabel) {
		var self    = this;
		var widgets = {};
		fields.forEach(function(f) {
			var id     = 'mpd-conf-' + f.key;
			var widget = f.choices
				? new ui.Combobox(values[f.key] || f.placeholder || '', f.choices, {
					id: id, placeholder: f.placeholder
				  })
				: new ui.Textfield(values[f.key] || '', {
					id: id, placeholder: f.placeholder
				  });
			widgets[f.key] = widget;
			// The `for` target must be 'widget.<id>', not '<id>':
			// ui.Textfield/ui.Dropdown put `options.id` on their wrapper
			// <div> and give the real <input> an id of 'widget.' + id.
			// Pointing the label at the wrapper div made clicking the
			// label a no-op, since <div> isn't a labelable element.
			var fieldChildren = [widget.render()];
			// `kind` (dir/file/parent, only set on MPD_PATHS entries) picks
			// the right reassurance that /etc/init.d/mpd's
			// setup_configured_paths() will create this on the next MPD
			// start -- so pointing a path at somewhere that doesn't exist
			// yet (a USB mount, say) is safe to save, not something that
			// needs a manual `mkdir`/`ssh` first.
			if (f.kind === 'dir') {
				fieldChildren.push(E('div', { 'style': 'color:#888;font-size:.85em;font-family:sans-serif' },
					[_('Created automatically (owned by the mpd user) on the next MPD start if missing.')]));
			} else if (f.kind === 'file') {
				fieldChildren.push(E('div', { 'style': 'color:#888;font-size:.85em;font-family:sans-serif' },
					[_('File and its parent directory are created automatically on the next MPD start if missing.')]));
			} else if (f.kind === 'parent') {
				fieldChildren.push(E('div', { 'style': 'color:#888;font-size:.85em;font-family:sans-serif' },
					[_('Parent directory is created automatically on the next MPD start; MPD writes this file itself.')]));
			}
			container.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': 'widget.' + id }, [_(f.label)]),
				E('div', { 'class': 'cbi-value-field', 'style': 'max-width:340px;font-family:monospace' },
					fieldChildren)
			]));
		});
		container.appendChild(E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }),
			E('div', { 'class': 'cbi-value-field' }, [
				E('button', { 'class': 'btn cbi-button-action important',
					'click': L.bind(self.handleMpdConfSave, self, fields, widgets, rawHolder)
				}, [_(saveLabel)])
			])
		]));
	},

	// -- Render -----------------------------------------------------------------------------

	render: function() {
		var self = this;

		// Resource monitor section
		var resourceSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('Resource Usage')]),
			E('p', { 'class': 'cbi-section-descr' },
				_('Live CPU and RAM of MPD and myMPD. Refreshed every 5 s.')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, ['MPD']),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('span', { 'id': 'res-mpd-stats', 'style': 'font-family:monospace;color:#888' },
						['...'])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, ['myMPD']),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('span', { 'id': 'res-mympd-stats', 'style': 'font-family:monospace;color:#888' },
						['...'])
				])
			])
		]);

		// myMPD network section (async filled after state files are read)
		var myMpdNetSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('myMPD Network')]),
			E('p', { 'class': 'cbi-section-descr' },
				_('HTTP port and bind address, read from myMPD\'s state directory.')),
			E('p', { 'id': 'mympd-net-loading', 'style': 'color:#888' }, [_('Reading configuration...')])
		]);

		// Web interface link (href updated after config read)
		var webSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('myMPD Web Interface')]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Open')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('a', {
						'id':     'mympd-web-link',
						'href':   'http://' + window.location.hostname + ':8080',
						'target': '_blank',
						'rel':    'noopener noreferrer',
						'class':  'btn cbi-button-action important'
					}, [_('Open myMPD ->')])
				])
			])
		]);

		// Service cards
		var myMpdCard = self._serviceCard('mympd', _('myMPD'),
			_('Feature-rich web client for MPD.'));
		var mpdCard   = self._serviceCard('mpd',   _('MPD (Music Player Daemon)'),
			_('The audio server managing playback and library.'));

		// Autoplay section
		var autoplaySection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [
				_('Autoplay'), ' ',
				E('span', { 'id': 'autoplay-badge', 'class': 'label label-warning' }, ['...'])
			]),
			E('p', { 'class': 'cbi-section-descr' },
				_('When enabled, playback starts automatically once MPD and myMPD are ' +
				  'both confirmed running -- on boot, and after any restart of either service.')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Autoplay on boot / restart')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'id': 'autoplay-enable-btn', 'class': 'btn cbi-button-positive',
						'click': L.bind(self.handleAutoplayToggle, self, true)
					}, [_('Enable')]),
					' ',
					E('button', { 'id': 'autoplay-disable-btn', 'class': 'btn cbi-button-negative',
						'click': L.bind(self.handleAutoplayToggle, self, false)
					}, [_('Disable')])
				])
			])
		]);
		self._refreshAutoplayButtons();

		// Now Playing section
		var nowPlayingSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('Now Playing')]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Track')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('span', { 'id': 'mpd-nowplaying', 'style': 'font-style:italic;color:#bbb' },
						[_('Loading...')])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Volume')]),
				E('div',   { 'class': 'cbi-value-field',
					         'style': 'display:flex;align-items:center;gap:8px' }, [
					E('button', { 'class': 'btn', 'style': 'padding:2px 10px',
						'click': L.bind(self.handleVolumeStep, self, -5) }, ['-5']),
					E('input',  { 'id': 'mpd-vol-slider', 'type': 'range',
						'min': '0', 'max': '100', 'value': '50', 'style': 'width:160px',
						'input':  L.bind(self.handleVolumeInput, self),
						'change': L.bind(self.handleVolumeSet, self) }),
					E('button', { 'class': 'btn', 'style': 'padding:2px 10px',
						'click': L.bind(self.handleVolumeStep, self, 5) }, ['+5']),
					E('span', { 'id': 'mpd-vol-label', 'style': 'min-width:40px' }, ['--'])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Playback')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn',
						'click': L.bind(self.handleMpdPrev,   self) }, ['|<< ' + _('Prev')]),  ' ',
					E('button', { 'id': 'mpd-toggle-btn', 'class': 'btn cbi-button-action',
						'click': L.bind(self.handleMpdToggle, self) }, ['>/|| ' + _('Play/Pause')]), ' ',
					E('button', { 'class': 'btn cbi-button-negative',
						'click': L.bind(self.handleMpdStop,   self) }, ['[] ' + _('Stop')]),    ' ',
					E('button', { 'class': 'btn',
						'click': L.bind(self.handleMpdNext,   self) }, ['>>| ' + _('Next')])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Modes')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn',
						'click': L.bind(self.handleModeToggle, self, 'repeat')  }, [_('Repeat')]),  ' ',
					E('button', { 'class': 'btn',
						'click': L.bind(self.handleModeToggle, self, 'random')  }, [_('Random')]),  ' ',
					E('button', { 'class': 'btn',
						'click': L.bind(self.handleModeToggle, self, 'single')  }, [_('Single')]),  ' ',
					E('button', { 'class': 'btn',
						'click': L.bind(self.handleModeToggle, self, 'consume') }, [_('Consume')])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Crossfade (sec)')]),
				E('div',   { 'class': 'cbi-value-field',
				             'style': 'display:flex;align-items:center;gap:8px' }, [
					E('input', { 'id': 'mpd-crossfade-input', 'type': 'number',
						'min': '0', 'max': '30', 'value': '0',
						'class': 'cbi-input-text', 'style': 'width:70px' }),
					E('button', { 'class': 'btn cbi-button-action',
						'click': function() {
							var v = document.getElementById('mpd-crossfade-input');
							if (v) self.handleCrossfadeSet(v.value);
						}
					}, [_('Set')])
				])
			])
		]);

		// Queue section
		var queueSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('Queue')]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Actions')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn cbi-button-negative',
						'click': L.bind(self.handleMpdClear,   self) }, [_('Clear queue')]),   ' ',
					E('button', { 'class': 'btn',
						'click': L.bind(self.handleMpdShuffle, self) }, [_('Shuffle queue')])
				])
			])
		]);

		// Library section
		var librarySection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('Library')]),
			E('p', { 'class': 'cbi-section-descr' }, [_('Requires mpc.')]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Database')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn cbi-button-action',
						'click': L.bind(self.handleMpdUpdate,  self) }, [_('Update (incremental)')]),  ' ',
					E('button', { 'class': 'btn',
						'click': L.bind(self.handleMpdRescan,  self) }, [_('Full rescan')]),            ' ',
					E('button', { 'class': 'btn',
						'click': L.bind(self.handleShowStats,  self) }, [_('Statistics')])
				])
			])
		]);

		// Audio outputs section
		var outputsSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('Audio Outputs')]),
			E('p', { 'class': 'cbi-section-descr' }, [_('Enable/disable MPD audio outputs.')]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Outputs')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('div', { 'id': 'mpd-outputs-list' }, [_('Loading...')])
				])
			])
		]);

		// ALSA section (async filled after aplay -l + mpd.conf)
		var alsaSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('ALSA Audio Output')]),
			E('p', { 'class': 'cbi-section-descr' },
				_('Configure the ALSA audio_output block in mpd.conf.')),
			E('p', { 'id': 'alsa-loading', 'style': 'color:#888' }, [_('Detecting ALSA devices...')])
		]);

		// HTTP stream section (async filled after mpd.conf)
		var httpdSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('HTTP Audio Stream')]),
			E('p', { 'class': 'cbi-section-descr' },
				_('Built-in HTTP streaming output. Tune in at http://<router>:<port>.')),
			E('p', { 'id': 'httpd-loading', 'style': 'color:#888' }, [_('Reading mpd.conf...')])
		]);

		// MPD paths section (async)
		var pathSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('MPD Directories & Paths')]),
			E('p', { 'class': 'cbi-section-descr' },
				_('File and directory paths in /etc/mpd.conf.')),
			E('p', { 'id': 'mpd-path-loading', 'style': 'color:#888' }, [_('Reading mpd.conf...')])
		]);

		// MPD general settings section (async)
		var settingsSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('MPD General Settings')]),
			E('p', { 'class': 'cbi-section-descr' },
				_('Network, logging and behaviour options in /etc/mpd.conf.')),
			E('p', { 'id': 'mpd-settings-loading', 'style': 'color:#888' },
				[_('Reading mpd.conf...')])
		]);

		// myMPD backup & restore section -- fully synchronous, since it has
		// no dependency on mpd.conf being read first.
		var mympdBackupSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('myMPD Backup & Restore')]),
			E('p', { 'class': 'cbi-section-descr' },
				_('Snapshot or restore the entire /etc/mympd state directory.')),
			E('p', { 'class': 'alert-message warning' },
				_('Restoring overwrites myMPD settings and restarts the service.')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Backup')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn cbi-button-action',
						'click': L.bind(self.handleMympdBackup, self)
					}, [_('Download backup (.tar.gz)')])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Restore')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn cbi-button-negative',
						'click': L.bind(self.handleMympdRestore, self)
					}, [_('Upload & restore archive...')])
				])
			])
		]);

		// MPD backup & restore section -- the Backup button needs the
		// parsed mpd.conf values (to know the current playlist/db/state/
		// sticker paths), so its controls are filled in async below,
		// alongside the Paths and Settings sections.
		var mpdBackupSection = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [_('MPD Backup & Restore')]),
			E('p', { 'class': 'cbi-section-descr' },
				_('Snapshot or restore /etc/mpd.conf plus the playlist, database, state and sticker files.')),
			E('p', { 'class': 'alert-message warning' },
				_('Restoring overwrites MPD settings and restarts the service.')),
			E('p', { 'id': 'mpd-backup-loading', 'style': 'color:#888' }, [_('Reading mpd.conf...')])
		]);

		var page = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [_('myMPD Manager')]),
			E('div', { 'class': 'cbi-map-descr' },
				_('Manage myMPD & MPD: services, playback, outputs, ALSA, HTTP stream, paths and backup.')),
			resourceSection,
			myMpdNetSection,
			webSection,
			myMpdCard,
			mpdCard,
			autoplaySection,
			nowPlayingSection,
			queueSection,
			librarySection,
			outputsSection,
			alsaSection,
			httpdSection,
			pathSection,
			settingsSection,
			mympdBackupSection,
			mpdBackupSection
		]);

		// Async: myMPD state-directory config
		self._loadMyMpdConfig().then(function(cfg) {
			var loadEl = document.getElementById('mympd-net-loading');
			if (loadEl) loadEl.remove();
			var linkEl = document.getElementById('mympd-web-link');
			if (linkEl) linkEl.href = 'http://' + window.location.hostname + ':' + cfg.http_port;
			var portInp = E('input', {
				'class': 'cbi-input-text', 'type': 'number',
				'min': '1', 'max': '65535', 'value': cfg.http_port, 'style': 'width:100px'
			});
			var hostSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:200px' }, [
				E('option', { 'value': '0.0.0.0',
					'selected': cfg.host === '0.0.0.0' ? '' : null },
					['0.0.0.0 (all interfaces)']),
				E('option', { 'value': '127.0.0.1',
					'selected': cfg.host === '127.0.0.1' ? '' : null },
					['127.0.0.1 (localhost only)'])
			]);
			[
				[_('HTTP Port'),      portInp],
				[_('Bind interface'), hostSel]
			].forEach(function(row) {
				myMpdNetSection.appendChild(E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [row[0]]),
					E('div',   { 'class': 'cbi-value-field' }, [row[1]])
				]));
			});
			myMpdNetSection.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn cbi-button-action important',
						'click': L.bind(self.handleMyMpdNetSave, self, portInp, hostSel, cfg.via)
					}, [_('Save network settings')]),
					' ',
					E('span', { 'style': 'color:#888;font-size:.85em' },
						[_('Restart myMPD after saving.')])
				])
			]));
		}).catch(function(e) {
			var el = document.getElementById('mympd-net-loading');
			if (el) el.textContent = _('Read failed: ') + e.message;
		});

		// Async: mpd.conf + aplay -l + amixer scontrols
		// amixer is queried against the default card (no `-c`, i.e. card 0)
		// in parallel with the other two calls, rather than after parsing
		// the currently-configured device: the configured device is only
		// known once `conf` is parsed below, which would force this call to
		// happen sequentially and delay the whole section for what is, on
		// this hardware (single on-board codec), always card 0 anyway. The
		// Mixer control combobox stays fully editable regardless, so a
		// different/second card's controls can still be typed by hand.
		Promise.all([
			self._readMpdConf(),
			fs.exec('/usr/bin/aplay',  ['-l']),
			fs.exec('/usr/bin/amixer', ['scontrols']).catch(function() {
				return { code: 1, stdout: '', stderr: '' };
			})
		]).then(function(results) {
			var conf      = results[0];
			var aplayRes  = results[1];
			var amixerRes = results[2];
			var rawHolder = { raw: conf.raw, values: conf.values };

			// -- ALSA section --
			var alsaLoad = document.getElementById('alsa-loading');
			if (alsaLoad) alsaLoad.remove();

			var devices   = self._parseAlsaDevices(
				aplayRes.code === 0 ? (aplayRes.stdout || '') : '');
			var existAlsa = self._getAudioBlock(conf.raw, 'alsa');
			var curDev    = existAlsa ? (existAlsa.params.device        || '') : '';
			var curMixT   = existAlsa ? (existAlsa.params.mixer_type    || 'none') : 'none';
			var curMixD   = existAlsa ? (existAlsa.params.mixer_device  || '') : '';
			var curMixC   = existAlsa ? (existAlsa.params.mixer_control || '') : '';
			var curFormat = existAlsa ? (existAlsa.params.format        || '') : '';
			var curAutoRs = existAlsa ? (existAlsa.params.auto_resample || '') : '';

			// Mixer device choices: "default" plus one "hw:N" entry per
			// card actually seen in `aplay -l` (deduped), so the list
			// reflects real hardware rather than a guessed range.
			var mixDevChoices = { 'default': 'default' };
			devices.forEach(function(d) {
				var card = d.value.split(',')[0]; // "hw:N,M" -> "hw:N"
				mixDevChoices[card] = card;
			});
			if (curMixD && !mixDevChoices[curMixD]) mixDevChoices[curMixD] = curMixD;

			// Mixer control choices: real simple-control names from
			// `amixer scontrols` (see note above the Promise.all for why
			// this is always card 0); falls back to the common ALSA names
			// if amixer produced nothing (e.g. not installed yet).
			var mixerNames = self._parseMixerControls(
				amixerRes.code === 0 ? (amixerRes.stdout || '') : '');
			if (!mixerNames.length)
				mixerNames = ['Master', 'PCM', 'Headphone', 'Speaker', 'Digital'];
			if (curMixC && mixerNames.indexOf(curMixC) === -1)
				mixerNames.unshift(curMixC);
			var mixCtrlChoices = {};
			mixerNames.forEach(function(n) { mixCtrlChoices[n] = n; });

			var devOptions = devices.map(function(d) {
				return E('option', { 'value': d.value,
					'selected': d.value === curDev ? '' : null }, [d.label]);
			});
			if (!devices.length) {
				devOptions = [E('option', { 'value': '' },
					[_('No ALSA devices found (aplay -l)')])];
			} else if (curDev && !devices.some(function(d) { return d.value === curDev; })) {
				devOptions.unshift(E('option', { 'value': curDev, 'selected': '' },
					[curDev + ' (current)']));
			}

			var devSel     = E('select', { 'id': 'alsa-device-select',
				'class': 'cbi-input-select', 'style': 'width:400px' }, devOptions);
			var mixTypeSel = E('select', { 'id': 'alsa-mixer-type',
				'class': 'cbi-input-select', 'style': 'width:160px' }, [
				E('option', { 'value': 'software',
					'selected': curMixT === 'software' ? '' : null }, ['software']),
				E('option', { 'value': 'hardware',
					'selected': curMixT === 'hardware' ? '' : null }, ['hardware']),
				E('option', { 'value': 'none',
					'selected': curMixT === 'none'     ? '' : null }, ['none'])
			]);
			var mixDevInp  = new ui.Combobox(curMixD || 'default', mixDevChoices, {
				id: 'alsa-mixer-device', placeholder: 'default'
			});
			var mixCtrlInp = new ui.Combobox(curMixC || '', mixCtrlChoices, {
				id: 'alsa-mixer-control', placeholder: 'Master'
			});

			// Forced output format + auto-resample: pre-filled with the
			// hardware-tuned defaults (48000:32:2 / no) whenever the
			// current audio_output block doesn't already set them --
			// notably true right after upgrading this package on a router
			// that already has an /etc/mpd.conf, since generate_conf()
			// only ever writes the template on a *missing* file and will
			// not retrofit these two keys into an existing config.
			var formatChoices = {
				'48000:32:2': '48000:32:2 (Zynq I2S native)',
				'44100:16:2': '44100:16:2',
				'48000:16:2': '48000:16:2',
				'*:*:*':      '*:*:* (unconstrained)'
			};
			if (curFormat && !formatChoices[curFormat]) formatChoices[curFormat] = curFormat;
			var formatInp = new ui.Combobox(curFormat || '48000:32:2', formatChoices, {
				id: 'alsa-format', placeholder: '48000:32:2'
			});
			var autoResampleInp = new ui.Combobox(curAutoRs || 'no', { yes: 'yes', no: 'no' }, {
				id: 'alsa-auto-resample', placeholder: 'no'
			});

			[
				[_('Audio device'),   devSel],
				[_('Mixer type'),     mixTypeSel],
				[_('Mixer device'),   mixDevInp.render()],
				[_('Mixer control'),  mixCtrlInp.render()],
				[_('Format'),         formatInp.render()],
				[_('Auto-resample'),  autoResampleInp.render()]
			].forEach(function(row) {
				alsaSection.appendChild(E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [row[0]]),
					E('div',   { 'class': 'cbi-value-field' }, [row[1]])
				]));
			});
			alsaSection.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn cbi-button-action important',
						'click': L.bind(self.handleAlsaSave, self, rawHolder,
							mixDevInp, mixCtrlInp, formatInp, autoResampleInp)
					}, [_('Save ALSA output')]),
					' ',
					E('span', { 'style': 'color:#888;font-size:.85em' },
						[_('Restart MPD after saving.')])
				])
			]));

			// -- HTTP stream section --
			var httpdLoad = document.getElementById('httpd-loading');
			if (httpdLoad) httpdLoad.remove();

			var existHttpd   = self._getAudioBlock(conf.raw, 'httpd');
			var httpdEnabled = existHttpd ? existHttpd.enabled              : false;
			var httpdPort    = existHttpd ? (existHttpd.params.port    || '8000') : '8000';
			var httpdEnc     = existHttpd ? (existHttpd.params.encoder || 'lame') : 'lame';
			var httpdBit     = existHttpd ? (existHttpd.params.bitrate || '128')  : '128';
			var httpdFmt     = existHttpd ? (existHttpd.params.format  || '48000:16:2') : '48000:16:2';

			var enabledChk = E('input', { 'id': 'httpd-enabled', 'type': 'checkbox',
				'checked': httpdEnabled ? '' : null });
			var streamPort = E('input', { 'id': 'httpd-port', 'class': 'cbi-input-text',
				'type': 'number', 'min': '1024', 'max': '65535',
				'value': httpdPort, 'style': 'width:100px' });
			var encSel     = E('select', { 'id': 'httpd-encoder',
				'class': 'cbi-input-select', 'style': 'width:130px' }, [
				E('option', { 'value': 'lame',   'selected': httpdEnc === 'lame'   ? '' : null },
					['MP3 (lame)']),
				E('option', { 'value': 'vorbis', 'selected': httpdEnc === 'vorbis' ? '' : null },
					['OGG Vorbis']),
				E('option', { 'value': 'flac',   'selected': httpdEnc === 'flac'   ? '' : null },
					['FLAC']),
				E('option', { 'value': 'opus',   'selected': httpdEnc === 'opus'   ? '' : null },
					['Opus'])
			]);
			var bitSel = E('select', { 'id': 'httpd-bitrate',
				'class': 'cbi-input-select', 'style': 'width:110px' },
				['128', '192', '256', '320'].map(function(b) {
					return E('option', { 'value': b, 'selected': httpdBit === b ? '' : null },
						[b + ' kbps']);
				}));
			var fmtInp = E('input', { 'id': 'httpd-format', 'class': 'cbi-input-text',
				'type': 'text', 'value': httpdFmt,
				'style': 'width:160px;font-family:monospace',
				'placeholder': '48000:16:2' });

			[
				[_('Enable streaming'), E('label', {}, [enabledChk, ' ', _('Active')])],
				[_('Stream port'),      streamPort],
				[_('Encoder'),          encSel],
				[_('Bitrate'),          bitSel],
				[_('Format'),           fmtInp]
			].forEach(function(row) {
				httpdSection.appendChild(E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [row[0]]),
					E('div',   { 'class': 'cbi-value-field' }, [row[1]])
				]));
			});
			httpdSection.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn cbi-button-action important',
						'click': L.bind(self.handleHttpdSave, self, rawHolder)
					}, [_('Save HTTP stream')]),
					' ',
					E('span', { 'style': 'color:#888;font-size:.85em' },
						[_('Restart MPD after saving.')])
				])
			]));

			// -- Paths section --
			var pLoad = document.getElementById('mpd-path-loading');
			if (pLoad) pLoad.remove();
			self._appendConfFields(pathSection, self.MPD_PATHS,
				conf.values, rawHolder, 'Save paths');

			// -- Settings section --
			var sLoad = document.getElementById('mpd-settings-loading');
			if (sLoad) sLoad.remove();
			self._appendConfFields(settingsSection, self.MPD_SETTINGS,
				conf.values, rawHolder, 'Save settings');

			// -- MPD backup & restore section --
			var bLoad = document.getElementById('mpd-backup-loading');
			if (bLoad) bLoad.remove();
			mpdBackupSection.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Backup')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn cbi-button-action',
						'click': L.bind(self.handleMpdBackup, self, rawHolder)
					}, [_('Download backup (.tar.gz)')])
				])
			]));
			mpdBackupSection.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [_('Restore')]),
				E('div',   { 'class': 'cbi-value-field' }, [
					E('button', { 'class': 'btn cbi-button-negative',
						'click': L.bind(self.handleMpdRestore, self)
					}, [_('Upload & restore archive...')])
				])
			]));

		}).catch(function(e) {
			['alsa-loading', 'httpd-loading', 'mpd-path-loading', 'mpd-settings-loading', 'mpd-backup-loading']
				.forEach(function(id) {
					var el = document.getElementById(id);
					if (el) el.textContent = _('Error reading config: ') + e.message;
				});
		});

		// Start polling
		poll.add(L.bind(self._refreshStatus,        self), 5);
		poll.add(L.bind(self._refreshNowPlaying,    self), 4);
		poll.add(L.bind(self._refreshOutputs,       self), 10);
		poll.add(L.bind(self._refreshResourceStats, self), 5);

		self._refreshStatus();
		self._refreshNowPlaying();
		self._refreshOutputs();
		self._refreshResourceStats();

		return page;
	},

	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null
});
