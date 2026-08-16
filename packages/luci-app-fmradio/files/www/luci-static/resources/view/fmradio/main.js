'use strict';
'require view';
'require ui';
'require rpc';
'require form';
'require uci';

var callGetInfo    = rpc.declare({ object: 'fmradio', method: 'get_info' });
var callGetFreq    = rpc.declare({ object: 'fmradio', method: 'get_freq' });
var callSetFreq    = rpc.declare({ object: 'fmradio', method: 'set_freq',    params: ['freq'] });
var callSeek       = rpc.declare({ object: 'fmradio', method: 'seek',        params: ['up']   });
var callScan       = rpc.declare({ object: 'fmradio', method: 'scan' });
var callScanStatus = rpc.declare({ object: 'fmradio', method: 'scan_status' });
var callGetCtrl    = rpc.declare({ object: 'fmradio', method: 'get_ctrl' });
var callSetCtrl    = rpc.declare({ object: 'fmradio', method: 'set_ctrl',    params: ['name', 'value'] });
var callGetRds     = rpc.declare({ object: 'fmradio', method: 'get_rds' });

// Interval handle for polling current frequency (cleared on view destroy)
var _freqPollInterval = null;
// Interval handle for polling auto-scan progress (cleared on view destroy)
var _scanPollInterval = null;
// Interval handle for polling RDS data (cleared on view destroy)
var _rdsPollInterval = null;

// FM band limits
var FM_MIN = 76.0;
var FM_MAX = 108.0;

return view.extend({
    load: function() {
        return uci.load('fmradio');
    },

    render: function() {
        var m, s, o;

        m = new form.Map('fmradio',
            _('FM Radio'),
            _('FM radio receiver control via v4l2-ctl.'));

        // ── Control Panel ────────────────────────────────────────────────────
        s = m.section(form.NamedSection, 'main', 'settings', _('Control Panel'));
        s.addremove = false;

        o = s.option(form.DummyValue, '_controls');
        o.render = function() {
            // Build station dropdown from UCI
            var stations = uci.sections('fmradio', 'station') || [];
            var selectOptions = [E('option', { value: '' }, _('-- Choose station --'))];

            stations.forEach(function(st) {
                if (st.freq) {
                    var name    = st.name || ('Station ' + st.freq);
                    var fString = parseFloat(st.freq).toFixed(1);
                    selectOptions.push(E('option', { value: fString },
                        name + ' (' + fString + ' MHz)'));
                }
            });

            var selectEl = E('select', {
                id:     'station_select',
                class:  'cbi-input-select',
                style:  'min-width:180px; max-width:240px; flex-shrink:0;',
                click:  function(ev) { ev.stopPropagation(); },
                change: function(ev) { ev.stopPropagation(); }
            }, selectOptions);

            /**
             * Parse and validate a user-entered frequency.
             * Accepts a comma as decimal separator (common on RU keyboard
             * layouts) and clamps the result into the tuner's band.
             * Returns a "NNN.N" string, or null if the input isn't a number.
             */
            function normalizeFreqInput(raw) {
                var f = parseFloat(String(raw).trim().replace(',', '.'));
                if (isNaN(f)) return null;
                if (f < FM_MIN) f = FM_MIN;
                if (f > FM_MAX) f = FM_MAX;
                return f.toFixed(1);
            }

            // ── Tuning button factory ────────────────────────────────────────
            // delta: MHz step (+1 / -1 / +0.1 / -0.1)
            function tuneBtn(label, delta) {
                return E('button', {
                    class: 'cbi-button cbi-button-neutral',
                    style: 'min-width:52px; font-size:0.92em;',
                    title: (delta > 0 ? '+' : '') + delta + ' MHz',
                    click: function(ev) {
                        ev.preventDefault();
                        var inputEl = document.getElementById('freq_input');
                        var cur = parseFloat(inputEl ? inputEl.value : '') || FM_MIN;
                        // Round to avoid floating-point drift (e.g. 100.1+0.1≠100.2)
                        var next = Math.round((cur + delta) * 10) / 10;
                        if (next < FM_MIN) next = FM_MIN;
                        if (next > FM_MAX) next = FM_MAX;
                        var fStr = next.toFixed(1);

                        // Optimistic update: reflect the new value immediately so
                        // rapid consecutive clicks accumulate correctly instead of
                        // reading a stale value while the RPC round-trip is pending.
                        if (inputEl) inputEl.value = fStr;

                        return callSetFreq(fStr).then(function() {
                            saveLastFreq(fStr);
                            updateCurrentFreq();
                        });
                    }
                }, label);
            }

            var container = E('div', { class: 'cbi-value' }, [
                E('div', { class: 'cbi-value-field', style: 'display:flex; flex-direction:column; gap:10px;' }, [

                    // ── Frequency / station name display ──────────────────────
                    E('div', {
                        id:    'current_freq_display',
                        style: 'font-weight:bold; font-size:1.15em; color:#0066cc; margin-bottom:4px;'
                    }, _('Current frequency: Fetching...')),

                    // ── Row 0: freq input + Set + tuning + seek ───────────────
                    E('div', { style: 'display:flex; flex-wrap:wrap; gap:8px; align-items:center;' }, [
                        E('input', {
                            id:          'freq_input',
                            type:        'text',
                            placeholder: '102.4',
                            class:       'cbi-input-text',
                            style:       'width:80px; flex-shrink:0;'
                        }),
                        E('button', {
                            class: 'cbi-button cbi-button-apply',
                            style: 'flex-shrink:0;',
                            click: function(ev) {
                                ev.preventDefault();
                                var inputEl = document.getElementById('freq_input');
                                var raw = inputEl ? inputEl.value.trim() : '';
                                if (!raw) return;

                                // Unlike the +/- buttons, this path took the raw
                                // string straight to the tuner — an out-of-band
                                // or non-numeric entry was passed through as-is.
                                var fStr = normalizeFreqInput(raw);
                                if (fStr === null) {
                                    ui.addNotification(null,
                                        E('p', _('Invalid frequency: ') + raw), 'error');
                                    return;
                                }
                                inputEl.value = fStr;

                                return callSetFreq(fStr).then(function() {
                                    saveLastFreq(fStr);
                                    updateCurrentFreq();
                                });
                            }
                        }, _('Set')),

                        E('span', { style: 'opacity:0.5; flex-shrink:0;' }, '|'),

                        // Fine tuning
                        tuneBtn('\u2212 1',   -1.0),
                        tuneBtn('\u2212 0.1', -0.1),
                        tuneBtn('+ 0.1',     +0.1),
                        tuneBtn('+ 1',       +1.0),

                        E('span', { style: 'opacity:0.5; flex-shrink:0;' }, '|'),

                        // Seek
                        E('button', {
                            class: 'cbi-button cbi-button-action',
                            style: 'flex-shrink:0;',
                            click: function(ev) {
                                ev.preventDefault();
                                return callSeek(0).then(function() {
                                    updateCurrentFreq(true);
                                });
                            }
                        }, 'Seek \u23ea'),
                        E('button', {
                            class: 'cbi-button cbi-button-action',
                            style: 'flex-shrink:0;',
                            click: function(ev) {
                                ev.preventDefault();
                                return callSeek(1).then(function() {
                                    updateCurrentFreq(true);
                                });
                            }
                        }, 'Seek \u23e9')
                    ]),

                    // ── Row 1: station dropdown + actions ─────────────────────
                    E('div', { style: 'display:flex; flex-wrap:wrap; gap:8px; align-items:center;' }, [
                        selectEl,
                        E('button', {
                            class: 'cbi-button cbi-button-apply',
                            style: 'background-color:#4caf50; color:white; flex-shrink:0;',
                            click: function(ev) {
                                ev.preventDefault();
                                var val = document.getElementById('station_select').value;
                                if (!val) return;
                                return callSetFreq(val).then(function() {
                                    saveLastFreq(val);
                                    updateCurrentFreq();
                                });
                            }
                        }, 'Play \ud83d\udd0a'),

                        E('button', {
                            class: 'cbi-button cbi-button-add',
                            style: 'flex-shrink:0;',
                            click: function(ev) {
                                ev.preventDefault();
                                return callGetFreq().then(function(res) {
                                    var f = parseFreqResult(res);
                                    if (!isNaN(f) && f > 0) {
                                        var fString = f.toFixed(1);
                                        var sid = uci.add('fmradio', 'station');
                                        uci.set('fmradio', sid, 'name', 'Station ' + fString);
                                        uci.set('fmradio', sid, 'freq', fString);
                                        uci.save();
                                        return uci.apply().then(function() {
                                            window.location.reload();
                                        });
                                    } else {
                                        ui.addNotification(null,
                                            E('p', _('Error: Could not determine current frequency.')),
                                            'error');
                                    }
                                });
                            }
                        }, _('Save current')),

                        E('button', {
                            id:    'autoscan_btn',
                            class: 'cbi-button cbi-button-neutral',
                            style: 'background-color:#ff9800; color:white; flex-shrink:0;',
                            click: function(ev) {
                                ev.preventDefault();
                                var btn = ev.currentTarget;
                                btn.disabled = true;

                                return callScan().then(function() {
                                    ui.showIndicator('autoscan',
                                        _('Scanning FM range... Found: 0'));

                                    if (_scanPollInterval) clearInterval(_scanPollInterval);
                                    _scanPollInterval = setInterval(function() {
                                        callScanStatus().then(function(statusRes) {
                                            var status = (statusRes && statusRes.status) || 'idle';
                                            var count  = (statusRes && statusRes.count)  || 0;

                                            if (status === 'running') {
                                                var ind = document.getElementById('indicator-autoscan');
                                                if (ind) {
                                                    ind.innerText =
                                                        _('Scanning FM range... Found: ') + count;
                                                }
                                            } else {
                                                clearInterval(_scanPollInterval);
                                                _scanPollInterval = null;
                                                ui.hideIndicator('autoscan');
                                                ui.addNotification(null,
                                                    E('p', _('Scan complete! Total stations found: ') + count));
                                                setTimeout(function() {
                                                    window.location.reload();
                                                }, 1000);
                                            }
                                        }).catch(function() {
                                            clearInterval(_scanPollInterval);
                                            _scanPollInterval = null;
                                            ui.hideIndicator('autoscan');
                                            btn.disabled = false;
                                        });
                                    }, 2000);
                                }).catch(function() {
                                    btn.disabled = false;
                                });
                            }
                        }, 'Auto-Scan \ud83d\udd0d'),

                        E('button', {
                            class: 'cbi-button',
                            style: 'flex-shrink:0;',
                            click: function(ev) {
                                ev.preventDefault();
                                return callGetInfo().then(function(res) {
                                    ui.showModal(_('Tuner Information (v4l2-ctl)'), [
                                        E('h4', '--get-tuner'),
                                        E('pre', { style: 'background:#f4f4f4; padding:5px;' },
                                            (res && res.tuner) || 'No data'),
                                        E('h4', '--list-ctrls'),
                                        E('pre', { style: 'background:#f4f4f4; padding:5px;' },
                                            (res && res.ctrls) || 'No data'),
                                        E('h4', '--all'),
                                        E('pre', {
                                            style: 'background:#f4f4f4; padding:5px;' +
                                                   ' max-height:200px; overflow-y:auto;'
                                        }, (res && res.all) || 'No data'),
                                        E('div', { class: 'right' }, [
                                            E('button', {
                                                class: 'cbi-button',
                                                click: ui.hideModal
                                            }, _('Close'))
                                        ])
                                    ]);
                                });
                            }
                        }, _('Info / Settings'))
                    ]),

                    // ── RDS panel ───────────────────────────────────────────────
                E('div', { id: 'rds_panel', style: 'margin-top:12px;' }, [
                    E('div', { style: 'display:flex; align-items:center; gap:10px; flex-wrap:wrap;' }, [
                        E('strong', {}, '\ud83d\udce1 RDS'),
                        E('span', {
                            id:    'rds_status',
                            style: 'font-style:italic; opacity:0.7; font-size:0.9em;'
                        }, _('Waiting for RDS data...'))
                    ]),
                    E('div', {
                        id:    'rds_fields',
                        // NB: keep a single `display` declaration here. This
                        // previously listed `display:none` *and* `display:grid`
                        // in one style string; the later one won, so the empty
                        // placeholder grid was visible before any data arrived.
                        // Hidden by default — pollRds/fetchRds flip it to grid.
                        style: 'display:none; margin-top:10px;' +
                               ' grid-template-columns: repeat(auto-fill, minmax(260px,1fr));' +
                               ' gap:6px 18px;'
                    }, [
                        rdsField('rds_ps',      '\ud83c\udfb5', _('Station name (PS)')),
                        rdsField('rds_pi',      '\ud83d\udd22', _('PI code')),
                        rdsField('rds_pty',     '\ud83c\udfa7', _('Programme type (PTY)')),
                        rdsField('rds_area',    '\ud83d\uddfa', _('Area coverage')),
                        rdsField('rds_country', '\ud83c\udff3', _('Country (ECC)')),
                        rdsField('rds_ms',      '\ud83d\udd0a', _('MS flag')),
                        rdsField('rds_di',      '\ud83c\udf99', _('Decoder info (DI)')),
                        rdsField('rds_tpta',    '\ud83d\udcca', _('TP / TA')),
                        rdsField('rds_rt',      '\ud83d\udcdd', _('RadioText (RT)'), true)
                    ]),
                    E('div', {
                        id:    'rds_stats',
                        style: 'display:none; margin-top:8px; padding:6px 10px;' +
                               ' background:rgba(30,136,229,0.08); border-left:3px solid #1e88e5;' +
                               ' border-radius:2px; font-size:0.88em;'
                    })
                ])
                ]),  // closes cbi-value-field
            ]);

            // ── Helper functions ─────────────────────────────────────────────

            // The row carries its own id so a field that never decodes
            // (RadioText on a station that doesn't send it) can be hidden
            // entirely instead of showing a permanent em-dash.
            function rdsField(id, icon, label, wide) {
                return E('div', {
                    id:    'row_' + id,
                    style: 'display:flex; gap:5px; align-items:baseline;' +
                           (wide ? ' grid-column:1/-1;' : '')
                }, [
                    E('span', { style: 'font-size:1em;' }, icon),
                    E('span', { style: 'opacity:0.7; white-space:nowrap;' }, label + ':'),
                    E('span', { id: id, style: 'font-weight:600; overflow-wrap:anywhere;' }, '—')
                ]);
            }

            /**
             * Render one RDS value for display.
             * A field the tuner couldn't decode reaches us either as an empty
             * string or — from an older backend — as the literal placeholder
             * "unknown" / "-". All of those show as an em-dash rather than
             * being printed verbatim.
             */
            function formatRdsValue(value) {
                var s = (value === undefined || value === null)
                    ? '' : String(value).trim();
                if (s === '' || s === '-' || s.toLowerCase() === 'unknown') return '—';
                return s;
            }

            function setRdsField(id, value) {
                var el = document.getElementById(id);
                if (el) el.innerText = formatRdsValue(value);
            }

            // Tracks the backend's change counter so the panel can tell
            // "genuinely new data" from "the same snapshot polled again", and
            // only moves the timestamp when something actually changed.
            var _rdsSeq  = -1;
            var _rdsSeen = null;

            function fetchRds() {
                var status = document.getElementById('rds_status');
                var fields = document.getElementById('rds_fields');
                var stats  = document.getElementById('rds_stats');

                // No "reading…" placeholder any more: get_rds returns the
                // reader daemon's current cache immediately instead of
                // occupying the backend for ten seconds per call.
                return callGetRds().then(function(res) {
                    if (!res) throw new Error('empty response');

                    setRdsField('rds_ps',      res.ps);
                    setRdsField('rds_rt',      res.rt);
                    setRdsField('rds_pi',      res.pi);
                    setRdsField('rds_pty',     res.pty);
                    setRdsField('rds_area',    res.area);
                    setRdsField('rds_country', res.ecc);
                    setRdsField('rds_ms',      res.ms);
                    setRdsField('rds_di',      res.di);
                    setRdsField('rds_tpta',    res.tpta);

                    // Not every station sends RadioText, and not every build
                    // of rds-ctl prints it — hide the row rather than leaving
                    // a permanent dash.
                    var rtRow = document.getElementById('row_rds_rt');
                    if (rtRow) rtRow.style.display =
                        (formatRdsValue(res.rt) === '\u2014') ? 'none' : 'flex';

                    if (fields) fields.style.display = 'grid';

                    // Hide the stats strip entirely when there's nothing real
                    // to show. The old backend defaulted these to "-", which is
                    // truthy, so the block used to render even with no data.
                    var hasStats = formatRdsValue(res.stat_blocks) !== '—';
                    if (stats && hasStats) {
                        stats.style.display = 'block';
                        while (stats.firstChild) stats.removeChild(stats.firstChild);
                        // Block errors and group errors are two different
                        // counters and used to be printed as one raw "0 (0.00%)
                        // / 5" string under a single "Errors" label, which read
                        // as nonsense. Label them separately; fall back to the
                        // combined field if the backend predates the split.
                        var blkErr = formatRdsValue(res.stat_block_errors);
                        var grpErr = formatRdsValue(res.stat_group_errors);
                        var errParts;
                        if (blkErr !== '\u2014' || grpErr !== '\u2014') {
                            errParts = [
                                ' | ' + _('Block errors') + ': ',
                                E('b', {}, blkErr),
                                ' | ' + _('Group errors') + ': ',
                                E('b', {}, grpErr)
                            ];
                        } else {
                            errParts = [
                                ' | ' + _('Errors') + ': ',
                                E('b', {}, formatRdsValue(res.stat_errors))
                            ];
                        }

                        stats.appendChild(E('span', {}, [
                            E('b', {}, _('RDS Statistics') + ': '),
                            _('Blocks/Groups') + ': ',
                            E('b', {}, formatRdsValue(res.stat_blocks))
                        ].concat(errParts, [
                            ' | ' + _('Corrected') + ': ',
                            E('b', {}, formatRdsValue(res.stat_corrected))
                        ])));
                    } else if (stats) {
                        stats.style.display = 'none';
                    }

                    // The backend bumps seq only when a field really
                    // changed, so this timestamp reflects the last change on
                    // air, not the last poll.
                    var seq = Number(res.seq);
                    if (!isNaN(seq) && seq !== _rdsSeq) {
                        _rdsSeq  = seq;
                        _rdsSeen = new Date();
                    }

                    var anyData = ['ps', 'pi', 'pty', 'area', 'ecc', 'ms', 'di', 'tpta', 'rt']
                        .some(function(k) { return formatRdsValue(res[k]) !== '\u2014'; });

                    if (status) {
                        if (Number(res.live) !== 1) {
                            // The reader daemon isn't up, so the backend fell
                            // back to the old blocking read — worth saying out
                            // loud, since that is the slow path.
                            status.innerText = _('RDS reader not running — slow fallback mode ' +
                                                 '(check /etc/init.d/fmradio)');
                        } else if (!anyData) {
                            status.innerText = '\u25cf ' + _('live') + ' \u2014 ' +
                                _('waiting for RDS from this station\u2026');
                        } else {
                            status.innerText = '\u25cf ' + _('live') + ' \u2014 ' +
                                _('last change: ') +
                                (_rdsSeen ? _rdsSeen.toLocaleTimeString() : '\u2014');
                        }
                    }

                }).catch(function() {
                    if (status) status.innerText = _('RDS read failed (rds-ctl not available?)');
                });
            }

            // get_rds no longer blocks (it reads the reader daemon's cache),
            // but the guard stays: it costs nothing and still prevents a
            // backlog if rpcd itself is momentarily slow.
            var _rdsPollBusy = false;

            /** Checks whether RDS reception is currently enabled and, if so,
             *  fetches fresh RDS data. Hides the panel contents when disabled. */
            function pollRds() {
                if (_rdsPollBusy) return;
                _rdsPollBusy = true;

                // Prefer the UCI-saved RDS state over a live hardware query:
                // it always reflects the user's actual last choice, and it
                // saves an RPC round-trip on every tick.
                var settingsSections = uci.sections('fmradio', 'settings');
                var savedRds = (settingsSections && settingsSections.length)
                    ? settingsSections[0].rds_reception
                    : undefined;

                var rdsOnPromise;
                if (savedRds !== undefined && savedRds !== '') {
                    rdsOnPromise = Promise.resolve(Number(savedRds) === 1);
                } else {
                    // Nothing saved yet (fresh install) — fall back to hardware.
                    rdsOnPromise = callGetCtrl().then(function(res) {
                        return !!(res && Number(res.rds_reception) === 1);
                    }).catch(function() {
                        return false;
                    });
                }

                return rdsOnPromise.then(function(rdsOn) {
                    var status = document.getElementById('rds_status');
                    var fields = document.getElementById('rds_fields');
                    var stats  = document.getElementById('rds_stats');

                    if (!rdsOn) {
                        if (fields) fields.style.display = 'none';
                        if (stats)  stats.style.display  = 'none';
                        if (status) status.innerText = _('RDS reception is off (enable it in Audio Settings)');
                        return;
                    }
                    return fetchRds();
                }).then(function() {
                    _rdsPollBusy = false;
                }).catch(function() {
                    _rdsPollBusy = false;
                });
            }

            function parseFreqResult(res) {
                var raw = (res && res.freq) ? res.freq : '';
                if (!raw && typeof res === 'string') raw = res;
                return parseFloat(raw.toString().replace(/[^0-9.]/g, ''));
            }

            function updateCurrentFreq(saveAfterUpdate) {
                return callGetFreq().then(function(res) {
                    var f      = parseFreqResult(res);
                    var signal = (res && res.signal) ? res.signal : '0%';

                    var displayEl  = document.getElementById('current_freq_display');
                    var inputEl    = document.getElementById('freq_input');
                    var dropdownEl = document.getElementById('station_select');

                    if (!isNaN(f) && f > 0) {
                        var fString       = f.toFixed(1);
                        var savedStations = uci.sections('fmradio', 'station') || [];
                        var stationName   = '';

                        for (var i = 0; i < savedStations.length; i++) {
                            if (savedStations[i].freq &&
                                parseFloat(savedStations[i].freq).toFixed(1) === fString) {
                                stationName = savedStations[i].name || '';
                                break;
                            }
                        }

                        var displayText = _('Current frequency: ') + fString + ' MHz';
                        if (stationName) displayText += ' — ' + stationName;
                        displayText += ' | Signal: \ud83d\udce1 ' + signal;

                        if (displayEl)  displayEl.innerText = displayText;
                        // Do not overwrite while user is typing
                        if (inputEl && document.activeElement !== inputEl)
                            inputEl.value = fString;
                        // Likewise, don't reset a selection the user is
                        // currently making but hasn't pressed Play on yet.
                        if (dropdownEl && document.activeElement !== dropdownEl) {
                            dropdownEl.value = fString;
                            if (dropdownEl.selectedIndex === -1) dropdownEl.value = '';
                        }

                        if (saveAfterUpdate === true) saveLastFreq(fString);
                    } else {
                        if (displayEl) displayEl.innerText = _('Current frequency: Unknown');
                    }
                }).catch(function() {
                    var displayEl = document.getElementById('current_freq_display');
                    if (displayEl) displayEl.innerText = _('Current frequency: Error');
                });
            }

            function saveLastFreq(freq) {
                var sections = uci.sections('fmradio', 'settings');
                var sid;
                if (sections && sections.length > 0) {
                    sid = sections[0]['.name'];
                } else {
                    sid = uci.add('fmradio', 'settings');
                }
                uci.set('fmradio', sid, 'last_freq', freq);
                uci.save();
                uci.apply();
            }

            window.updateFmRadioDisplay = updateCurrentFreq;
            window.updateFmRadioRds     = pollRds;
            window.saveFmRadioLastFreq  = saveLastFreq;

            updateCurrentFreq();
            pollRds();

            if (_freqPollInterval) clearInterval(_freqPollInterval);
            _freqPollInterval = setInterval(updateCurrentFreq, 10000);

            // Listening is now continuous on the device side:
            // /usr/libexec/fmradio-rdsd keeps rds-ctl open and maintains a
            // cache, and get_rds just reads it. So this interval is the only
            // latency left, and 1 s is already below what RDS itself can
            // deliver — the stream carries ~11.4 groups/s, so a full PS takes
            // roughly 1-4 s of decent reception to assemble and RadioText
            // longer still. Polling faster than 1 s would only re-read the
            // same snapshot.
            if (_rdsPollInterval) clearInterval(_rdsPollInterval);
            _rdsPollInterval = setInterval(pollRds, 1000);

            return container;
        };

        // ── Audio Settings ───────────────────────────────────────────────────
        s = m.section(form.NamedSection, 'main', 'settings', _('Audio Settings'));
        s.addremove = false;

        o = s.option(form.DummyValue, '_audio');
        o.render = function() {

            function saveSettingToUci(key, val) {
                var sections = uci.sections('fmradio', 'settings');
                var sid;
                if (sections && sections.length > 0) {
                    sid = sections[0]['.name'];
                } else {
                    sid = uci.add('fmradio', 'settings');
                }
                uci.set('fmradio', sid, key, String(val));
                uci.save();
                uci.apply();
            }

            function loadSettingFromUci(key) {
                var sections = uci.sections('fmradio', 'settings');
                if (!sections || !sections.length) return null;
                var v = sections[0][key];
                return (v !== undefined && v !== '') ? v : null;
            }

            // onValue/offValue default to '1'/'0'. audmode is the exception:
            // the tuner's audio mode is named rather than numbered, so its
            // toggle sends 'mono'/'stereo' straight through to VIDIOC_S_TUNER.
            function makeToggle(id, ctrlName, labelOn, labelOff, colorOn,
                                onValue, offValue) {
                onValue  = (onValue  === undefined) ? '1' : onValue;
                offValue = (offValue === undefined) ? '0' : offValue;

                var btn = E('button', {
                    id:    'toggle_' + id,
                    class: 'cbi-button',
                    style: 'min-width:130px;',
                    click: function(ev) {
                        ev.preventDefault();
                        var next = (btn.dataset.value === '1') ? 0 : 1;
                        var sent = next ? onValue : offValue;
                        return callSetCtrl(ctrlName, sent).then(function() {
                            setToggleState(btn, next, labelOn, labelOff, colorOn);
                            saveSettingToUci(ctrlName, sent);
                            // Give the Control Panel's RDS timer an immediate nudge
                            // instead of waiting for the next scheduled tick.
                            if (ctrlName === 'rds_reception' &&
                                typeof window.updateFmRadioRds === 'function') {
                                window.updateFmRadioRds();
                            }
                        });
                    }
                }, '…');

                function setToggleState(el, val, lOn, lOff, cOn) {
                    el.dataset.value = String(val);
                    if (val) {
                        el.innerText = lOn;
                        el.style.backgroundColor = cOn;
                        el.style.color = '#fff';
                    } else {
                        el.innerText = lOff;
                        el.style.backgroundColor = '';
                        el.style.color = '';
                    }
                }

                // Takes a stored value, not a boolean: 'mono' is on for the
                // audmode toggle, '1' for every other one.
                btn._setState = function(val) {
                    var on = (String(val) === onValue);
                    setToggleState(btn, on ? 1 : 0, labelOn, labelOff, colorOn);
                };

                return btn;
            }

            var peSelect = E('select', {
                id:    'pe_select',
                class: 'cbi-input-select',
                style: 'min-width:200px;',
                change: function(ev) {
                    ev.stopPropagation();
                    var val = peSelect.value;
                    callSetCtrl('de_emphasis', val).then(function() {
                        saveSettingToUci('de_emphasis', val);
                        ui.addNotification(null, E('p',
                            _('De-emphasis set to: ') +
                            (val === '1' ? '75 µs (USA)' : '50 µs (Europe/RU)')));
                    }).catch(function() {
                        ui.addNotification(null,
                            E('p', _('Failed to set de-emphasis')), 'error');
                    });
                }
            }, [
                E('option', { value: '1' }, '75 µs — ' + _('USA')),
                E('option', { value: '2' }, '50 µs — ' + _('Europe / RU'))
            ]);

            var muteBtn = makeToggle('mute', 'mute',
                '\ud83d\udd07 Muted',   '\ud83d\udd0a Sound ON',  '#e53935');
            var rdsBtn  = makeToggle('rds',  'rds_reception',
                '\ud83d\udce1 RDS ON',  '\ud83d\udce1 RDS OFF',   '#1e88e5');
            var monoBtn = makeToggle('mono', 'audmode',
                '\ud83c\udfa7 Mono ON', '\ud83c\udfa7 Stereo',    '#546e7a',
                'mono', 'stereo');
            var bassBtn = makeToggle('bass', 'loudness',
                '\ud83c\udfb5 Bass ON', '\ud83c\udfb5 Bass OFF',  '#8e24aa');

            var volLabel = E('span', {
                id:    'vol_label',
                style: 'font-weight:bold; min-width:24px; display:inline-block;'
            }, '—');

            var volSlider = E('input', {
                id:    'vol_slider',
                type:  'range',
                min:   '0',
                max:   '15',
                step:  '1',
                style: 'width:160px; cursor:pointer;',
                input: function() {
                    volLabel.innerText = volSlider.value;
                },
                change: function() {
                    var val = volSlider.value;
                    volLabel.innerText = val;
                    callSetCtrl('volume', val).then(function() {
                        saveSettingToUci('volume', val);
                    }).catch(function() {
                        ui.addNotification(null,
                            E('p', _('Failed to set volume')), 'error');
                    });
                }
            });

            var panel = E('div', {
                class: 'cbi-value-field',
                style: 'display:flex; flex-wrap:wrap; gap:14px; align-items:center;'
            }, [
                E('div', { style: 'display:flex; align-items:center; gap:6px;' }, [
                    E('span', {}, '\ud83d\udd09 ' + _('Volume') + ':'),
                    volSlider,
                    volLabel,
                    E('span', { style: 'opacity:0.6; font-size:0.85em;' }, '/ 15')
                ]),
                muteBtn,
                bassBtn,
                rdsBtn,
                monoBtn,
                E('div', { style: 'display:flex; align-items:center; gap:6px;' }, [
                    E('span', { title: _('Audio filter: 75 µs (USA) or 50 µs (Europe/RU)') },
                        '\ud83c\udf0d ' + _('De-emphasis') + ':'),
                    peSelect
                ])
            ]);

            callGetCtrl().then(function(res) {
                var vol = (res && res.volume != null) ? res.volume
                        : (loadSettingFromUci('volume') || 0);
                volSlider.value    = vol;
                volLabel.innerText = vol;

                // Normalises UCI strings ("0"/"1") and JSON numbers to a
                // clean 0/1 int. Needed because the JS string "0" is
                // truthy — a naive `value || 0` fallback would silently
                // render a saved "off" as "on".
                // What UCI holds wins over the hardware read-back: it is the
                // user's real last action, and the tuner is only consulted
                // before anything has ever been saved. The last argument is
                // the driver's own default, used when neither source answers.
                function pick(key, hw, fallback) {
                    var saved = loadSettingFromUci(key);
                    if (saved !== null) return String(saved);
                    if (hw !== undefined && hw !== null) return String(hw);
                    return fallback;
                }

                muteBtn._setState(pick('mute',          res && res.mute,          '0'));
                bassBtn._setState(pick('loudness',      res && res.loudness,      '0'));
                rdsBtn._setState( pick('rds_reception', res && res.rds_reception, '1'));
                monoBtn._setState(pick('audmode',       res && res.audmode,       'stereo'));
                peSelect.value =  pick('de_emphasis',   res && res.de_emphasis,   '2');

            }).catch(function() {
                var vol = loadSettingFromUci('volume') || 0;
                volSlider.value    = vol;
                volLabel.innerText = vol;
                muteBtn._setState(loadSettingFromUci('mute')          || '0');
                bassBtn._setState(loadSettingFromUci('loudness')      || '0');
                rdsBtn._setState( loadSettingFromUci('rds_reception') || '1');
                monoBtn._setState(loadSettingFromUci('audmode')       || 'stereo');
                peSelect.value =  loadSettingFromUci('de_emphasis')   || '2';
            });

            return E('div', { class: 'cbi-value' }, [panel]);
        };

        // ── Favourite Stations ───────────────────────────────────────────────
        s = m.section(form.GridSection, 'station', _('Favorite Stations'));
        s.addremove = true;
        s.anonymous = true;
        s.sortable  = true;

        s.option(form.Value, 'name', _('Name'));
        s.option(form.Value, 'freq', _('Frequency (MHz)')).datatype = 'float';

        o = s.option(form.DummyValue, '_play', _('Play'));
        o.editable = true;
        o.renderWidget = function(section_id) {
            var freq = uci.get('fmradio', section_id, 'freq');
            var fNum = parseFloat(freq);
            if (!freq || isNaN(fNum)) return E('span', { style: 'opacity:0.5;' }, '—');

            var fStr = fNum.toFixed(1);

            return E('button', {
                class: 'cbi-button',
                style: 'padding:2px 10px; font-size:1.15em; line-height:1;' +
                       ' background:transparent; border:none; cursor:pointer; color:#4caf50;',
                title: _('Play') + ' ' + fStr + ' MHz',
                click: function(ev) {
                    ev.preventDefault();
                    ev.stopPropagation();

                    var btn = ev.currentTarget;
                    btn.style.opacity = '0.4';

                    callSetFreq(fStr).then(function() {
                        btn.style.opacity = '1';
                        // This call was missing — the table's Play button tuned
                        // the hardware but never persisted last_freq, so a
                        // reboot would restore whatever was last set via the
                        // Control Panel instead of the actually-last-played
                        // station from this table.
                        if (typeof window.saveFmRadioLastFreq === 'function') {
                            window.saveFmRadioLastFreq(fStr);
                        }
                        if (typeof window.updateFmRadioDisplay === 'function')
                            window.updateFmRadioDisplay();
                    }).catch(function() {
                        btn.style.opacity = '1';
                        ui.addNotification(null,
                            E('p', _('Failed to tune to ') + fStr + ' MHz'), 'error');
                    });
                }
            }, '\u25b6\ufe0f');
        };

        // ── Import / Export ─────────────────────────────────────────────────
        s = m.section(form.NamedSection, 'main', 'settings', _('Import / Export'));
        s.addremove = false;

        o = s.option(form.DummyValue, '_importexport');
        o.render = function() {

            // Bumped whenever the settings keys or their encodings change.
            // Written by the exporter and required by the importer, so an
            // older file is refused outright rather than half-applied.
            var BACKUP_VERSION = 2;

            // Whitelist + clamp a single settings key coming from an
            // imported file. Returns null for unknown/invalid keys so
            // garbage never reaches UCI.
            function sanitizeSettingValue(key, raw) {
                if (key === 'last_freq') {
                    var f = parseFloat(raw);
                    if (isNaN(f)) return null;
                    if (f < FM_MIN) f = FM_MIN;
                    if (f > FM_MAX) f = FM_MAX;
                    return f.toFixed(1);
                }
                var n = parseInt(raw, 10);
                if (isNaN(n)) return null;
                if (key === 'volume') {
                    if (n < 0) n = 0;
                    if (n > 15) n = 15;
                    return String(n);
                }
                if (key === 'mute' || key === 'loudness' ||
                    key === 'rds_reception' || key === 'autoplay') {
                    return (n >= 1) ? '1' : '0';
                }
                if (key === 'de_emphasis') {
                    // V4L2_CID_TUNE_DEEMPHASIS menu: only 50 us and 75 us are
                    // selectable, so anything else is refused rather than
                    // clamped into a value the tuner would reject.
                    return (n === 1 || n === 2) ? String(n) : null;
                }
                return null;
            }

            // audmode is the one named setting, so it does not go through the
            // integer path above.
            function sanitizeAudmode(raw) {
                return (raw === 'mono' || raw === 'stereo') ? raw : null;
            }


            function exportSettings() {
                var stations = uci.sections('fmradio', 'station') || [];
                var settingsSections = uci.sections('fmradio', 'settings') || [];
                var settings = settingsSections.length ? settingsSections[0] : {};

                var payload = {
                    app:      'fmradio',
                    version:  BACKUP_VERSION,
                    exported: new Date().toISOString(),
                    settings: {
                        last_freq:     settings.last_freq     || '',
                        volume:        settings.volume        || '',
                        mute:          settings.mute          || '',
                        loudness:      settings.loudness      || '',
                        rds_reception: settings.rds_reception || '',
                        de_emphasis:   settings.de_emphasis   || '',
                        audmode:       settings.audmode       || '',
                        autoplay:      settings.autoplay      || ''
                    },
                    stations: stations
                        .filter(function(st) { return st.freq; })
                        .map(function(st) {
                            return { name: st.name || '', freq: st.freq };
                        })
                };

                var json = JSON.stringify(payload, null, 2);
                var blob = new Blob([json], { type: 'application/json' });
                var url  = URL.createObjectURL(blob);
                var dateStr = new Date().toISOString().slice(0, 10);

                var a = E('a', {
                    href:     url,
                    download: 'fmradio-backup-' + dateStr + '.json'
                });
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
                URL.revokeObjectURL(url);

                ui.addNotification(null, E('p', _('Settings exported.')));
            }

            function importSettingsFile(file) {
                var reader = new FileReader();

                reader.onerror = function() {
                    ui.addNotification(null, E('p', _('Failed to read the file.')), 'error');
                };

                reader.onload = function() {
                    var data;
                    try {
                        data = JSON.parse(reader.result);
                    } catch (e) {
                        ui.addNotification(null,
                            E('p', _('Import failed: invalid JSON file.')), 'error');
                        return;
                    }

                    if (!data || data.app !== 'fmradio' || !Array.isArray(data.stations)) {
                        ui.addNotification(null,
                            E('p', _('Import failed: this does not look like an fmradio backup file.')),
                            'error');
                        return;
                    }

                    // Version 1 files name the settings differently and encode
                    // de-emphasis as a boolean, so their audio settings would
                    // be dropped one by one without a word. Say so instead.
                    if (Number(data.version) !== BACKUP_VERSION) {
                        ui.addNotification(null,
                            E('p', _('Import failed: unsupported backup version ') +
                                   (data.version === undefined ? '?' : data.version) +
                                   _(' (expected ') + BACKUP_VERSION + ').'),
                            'error');
                        return;
                    }

                    var currentCount = (uci.sections('fmradio', 'station') || []).length;
                    var confirmMsg =
                        _('This will replace all') + ' ' + currentCount + ' ' +
                        _('current station(s) with') + ' ' + data.stations.length + ' ' +
                        _('from the file, and restore audio settings.') + '\n' +
                        _('This cannot be undone. Continue?');

                    if (!window.confirm(confirmMsg)) return;

                    // Wipe existing stations
                    (uci.sections('fmradio', 'station') || []).forEach(function(st) {
                        uci.remove('fmradio', st['.name']);
                    });

                    // Re-add stations from the file, sanitising each entry
                    data.stations.forEach(function(st) {
                        if (!st) return;
                        var f = parseFloat(st.freq);
                        if (isNaN(f)) return;
                        if (f < FM_MIN) f = FM_MIN;
                        if (f > FM_MAX) f = FM_MAX;
                        var fStr = f.toFixed(1);
                        var name = (st.name || ('Station ' + fStr)).toString().slice(0, 64);

                        var sid = uci.add('fmradio', 'station');
                        uci.set('fmradio', sid, 'name', name);
                        uci.set('fmradio', sid, 'freq', fStr);
                    });

                    // Restore audio settings, whitelisted + clamped
                    if (data.settings && typeof data.settings === 'object') {
                        var sections = uci.sections('fmradio', 'settings');
                        var sid = (sections && sections.length)
                            ? sections[0]['.name']
                            : uci.add('fmradio', 'settings');

                        Object.keys(data.settings).forEach(function(key) {
                            var clean = (key === 'audmode')
                                ? sanitizeAudmode(data.settings[key])
                                : sanitizeSettingValue(key, data.settings[key]);
                            if (clean !== null) uci.set('fmradio', sid, key, clean);
                        });
                    }

                    uci.save();
                    return uci.apply().then(function() {
                        ui.addNotification(null, E('p', _('Settings imported. Reloading...')));
                        setTimeout(function() { window.location.reload(); }, 800);
                    });
                };

                reader.readAsText(file);
            }

            var fileInput = E('input', {
                type:   'file',
                accept: '.json,application/json',
                style:  'display:none;',
                change: function(ev) {
                    var file = ev.target.files && ev.target.files[0];
                    if (file) importSettingsFile(file);
                    ev.target.value = ''; // allow re-importing the same filename later
                }
            });

            var exportBtn = E('button', {
                class: 'cbi-button cbi-button-action',
                style: 'flex-shrink:0;',
                click: function(ev) {
                    ev.preventDefault();
                    exportSettings();
                }
            }, '\u2b07\ufe0f ' + _('Export'));

            var importBtn = E('button', {
                class: 'cbi-button cbi-button-action',
                style: 'flex-shrink:0;',
                click: function(ev) {
                    ev.preventDefault();
                    fileInput.click();
                }
            }, '\u2b06\ufe0f ' + _('Import'));

            // ── Auto-play on boot ─────────────────────────────────────────────
            // Pure UI/UCI preference — no matching v4l2 control, so this does
            // not go through callSetCtrl like the Audio Settings toggles.
            function loadAutoplaySetting() {
                var sections = uci.sections('fmradio', 'settings');
                if (!sections || !sections.length) return 1;
                var v = sections[0].autoplay;
                // Key absent on existing installs — preserve current
                // behaviour (auto-play always happened before this option
                // existed), so default to enabled.
                if (v === undefined || v === '') return 1;
                return (Number(v) === 1) ? 1 : 0;
            }

            function saveAutoplaySetting(val) {
                var sections = uci.sections('fmradio', 'settings');
                var sid = (sections && sections.length)
                    ? sections[0]['.name']
                    : uci.add('fmradio', 'settings');
                uci.set('fmradio', sid, 'autoplay', String(val));
                uci.save();
                return uci.apply();
            }

            var autoplayBtn = E('button', {
                id:    'toggle_autoplay',
                class: 'cbi-button',
                style: 'min-width:190px; flex-shrink:0;',
                click: function(ev) {
                    ev.preventDefault();
                    var cur  = (autoplayBtn.dataset.value === '1') ? 1 : 0;
                    var next = cur ? 0 : 1;
                    return saveAutoplaySetting(next).then(function() {
                        setAutoplayState(next);
                        ui.addNotification(null, E('p', next
                            ? _('Auto-play on boot enabled.')
                            : _('Auto-play on boot disabled.')));
                    });
                }
            }, '…');

            function setAutoplayState(val) {
                autoplayBtn.dataset.value = String(val);
                if (val) {
                    autoplayBtn.innerText = '\u23f8\ufe0f ' + _('Disable auto-play');
                    autoplayBtn.style.backgroundColor = '#4caf50';
                    autoplayBtn.style.color = '#fff';
                } else {
                    autoplayBtn.innerText = '\u25b6\ufe0f ' + _('Enable auto-play');
                    autoplayBtn.style.backgroundColor = '';
                    autoplayBtn.style.color = '';
                }
            }
            setAutoplayState(loadAutoplaySetting());

            return E('div', { class: 'cbi-value' }, [
                E('div', {
                    class: 'cbi-value-field',
                    style: 'display:flex; flex-direction:column; gap:10px;'
                }, [
                    E('div', {
                        style: 'display:flex; flex-wrap:wrap; gap:10px; align-items:center;'
                    }, [
                        exportBtn,
                        importBtn,
                        fileInput,
                        E('span', { style: 'opacity:0.7; font-size:0.85em;' },
                            _('Backs up your station list and audio settings to a JSON file.'))
                    ]),
                    E('div', {
                        style: 'display:flex; flex-wrap:wrap; gap:10px; align-items:center;'
                    }, [
                        autoplayBtn,
                        E('span', { style: 'opacity:0.7; font-size:0.85em;' },
                            _('When disabled, the radio stays untuned after reboot until a station is picked manually.'))
                    ])
                ])
            ]);
        };

        return m.render();
    },

    destroy: function() {
        if (_freqPollInterval) {
            clearInterval(_freqPollInterval);
            _freqPollInterval = null;
        }
        if (_scanPollInterval) {
            clearInterval(_scanPollInterval);
            _scanPollInterval = null;
        }
        if (_rdsPollInterval) {
            clearInterval(_rdsPollInterval);
            _rdsPollInterval = null;
        }
        delete window.updateFmRadioDisplay;
        delete window.updateFmRadioRds;
        delete window.saveFmRadioLastFreq;
    }
});
