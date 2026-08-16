'use strict';
'require view';
'require ui';
'require rpc';
'require form';
'require uci';

var callSetCtrl            = rpc.declare({ object: 'fmtx', method: 'set_ctrl',            params: ['name', 'value'] });
var callSetRds             = rpc.declare({ object: 'fmtx', method: 'set_rds',             params: ['text', 'pi', 'pty', 'ecc'] });
var callStartRadiotext     = rpc.declare({ object: 'fmtx', method: 'start_radiotext',     params: ['text'] });
var callStopRadiotext      = rpc.declare({ object: 'fmtx', method: 'stop_radiotext' });
var callGetRadiotextStatus = rpc.declare({ object: 'fmtx', method: 'get_radiotext_status' });
var callGetInfo            = rpc.declare({ object: 'fmtx', method: 'get_info' });

// Transmit band limits — fmtx only warns outside this range (it computes an
// FTW from whatever -f is given), so this is a UI-side guard, not a confirmed
// hardware limit.
var TX_FREQ_MIN = 76.0;
var TX_FREQ_MAX = 108.0;

// Deviation is peak kHz for a full-scale composite (register 0x0C is a Q8.8
// gain, not a power-of-two shift; fmtx's -d does the conversion). fmtx
// hard-rejects <10 kHz (near-certainly a leftover shift value from before
// that change) and only warns above 80; 80 is used as the ceiling here
// instead, because that's where a 250 kHz receive chain stops being able to
// demodulate the composite at all.
var TX_DEVIATION_MIN = 10;
var TX_DEVIATION_MAX = 80;
var TX_DEVIATION_DEFAULT = 60;

// fmtx's fill_ps() copies at most 8 chars into a fixed buffer (space-padded)
// — anything longer is silently dropped by the tool itself, so the field is
// capped to match.
var TX_RDS_MAX_LEN = 8;

// RDS PTY (Programme Type): 0..31, matches fmtx -y.
var TX_PTY_MAX = 31;

// European RDS PTY table (EN 62106 / IEC 62106 Annex F). North America's
// RBDS uses different names from code 2 onward (e.g. 2 = "Information",
// not "Current affairs") — this is the European table.
var TX_PTY_NAMES = [
    'No programme type', 'News', 'Current affairs', 'Information', 'Sport',
    'Education', 'Drama', 'Culture', 'Science', 'Varied', 'Pop Music',
    'Rock Music', 'Easy Listening', 'Light Classical', 'Serious Classical',
    'Other Music', 'Weather', 'Finance', 'Children\u2019s Programmes',
    'Social Affairs', 'Religion', 'Phone-in', 'Travel', 'Leisure',
    'Jazz Music', 'Country Music', 'National Music', 'Oldies Music',
    'Folk Music', 'Documentary', 'Alarm Test', 'Alarm'
];

// RadioText (group 2A): fmtx's fill_rt() caps at 64 chars.
var TX_RT_MAX_LEN = 64;

return view.extend({
    // The rpcd backend is the only writer of /etc/config/fmtx and commits
    // every accepted value itself. Leaving the default handlers in place drew
    // a Save & Apply footer that could not do anything useful and invited a
    // second, competing writer of the same file.
    handleSave:      null,
    handleSaveApply: null,
    handleReset:     null,

    load: function() {
        return uci.load('fmtx');
    },

    render: function() {
        var m, s, o;

        m = new form.Map('fmtx',
            _('FM Transmitter'),
            _('FM transmitter control via fmtx (AXI register access on the Zynq FM transmitter core).'));

        // ── State + RPC helpers ─────────────────────────────────────────────
        // UCI is read once at page load to seed _txState; from then on
        // _txState is updated only after the backend confirms a change, and
        // the UI renders from it. This view never calls uci.set/uci.apply.
        var _txState = {};
        var _rtRunning = false;   // live process state, not a UCI value
        var _eccRotating = false; // ditto, for an ECC-only rotation specifically

        function loadCtrl(key) {
            var sections = uci.sections('fmtx', 'settings');
            if (!sections || !sections.length) return null;
            var v = sections[0][key];
            return (v !== undefined && v !== '') ? v : null;
        }

        function seedState() {
            ['enabled', 'freq', 'stereo', 'pre_emphasis', 'deviation', 'rds_text', 'pi', 'pty', 'ecc', 'radiotext']
                .forEach(function(k) { _txState[k] = loadCtrl(k); });
        }
        seedState();

        /**
         * Send one control change and update local state on success.
         * The RPC resolves even when fmtx itself failed — the tool's exit
         * status comes back in res.code, not as a rejected promise. Without
         * checking it, a device that never accepted the command (no /dev/mem
         * permission, AXI region absent, bitstream not loaded) would still
         * light the UI up green.
         */
        function applyCtrl(name, value) {
            return callSetCtrl(name, String(value)).then(function(res) {
                if (!res || Number(res.code) !== 0) {
                    throw new Error('fmtx failed for ' + name +
                                    ' (code ' + (res ? res.code : '?') + ')');
                }
                _txState[name] = String(value);
                return res;
            });
        }

        function applyRds(text, pi, pty, ecc) {
            return callSetRds(text, pi || '', pty || '', ecc || '').then(function(res) {
                if (!res || Number(res.code) !== 0) {
                    throw new Error('fmtx failed for RDS (code ' +
                                    (res ? res.code : '?') + ')');
                }
                // The backend sanitises and truncates; trust its echo of what
                // was actually sent rather than the raw input.
                _txState.rds_text = (res.result !== undefined) ? res.result : text;
                _txState.pi  = pi  || '';
                _txState.pty = pty || '';
                _txState.ecc = (res.ecc !== undefined) ? res.ecc : (ecc || '');
                // set_rds always stops whatever rotation was running first,
                // then starts a fresh ECC-only one if ecc is non-empty — ask
                // the backend what's actually running now rather than
                // inferring it, since "ecc is non-empty" alone doesn't mean
                // it's currently on air (e.g. right after a Stop click).
                return fetchRadiotextStatus().then(function() { return res; });
            });
        }

        /**
         * The rotation daemon's "is it running" is a background process, not
         * a hardware register — UCI can't tell you if fmtx crashed, so this
         * is checked live rather than trusted from storage. The backend
         * returns two signals: `running` is true only when RadioText content
         * specifically is part of the rotation, while `daemon_running` is the
         * raw liveness check — an ECC-only rotation leaves the daemon alive
         * with `running=0`, so ECC's own status is daemon_running combined
         * with whether ecc is currently set.
         */
        function fetchRadiotextStatus() {
            return callGetRadiotextStatus().then(function(res) {
                _rtRunning = !!(res && Number(res.running) === 1);
                var daemonRunning = !!(res && Number(res.daemon_running) === 1);
                _eccRotating = daemonRunning && !!_txState.ecc;
                return _rtRunning;
            }).catch(function() {
                return _rtRunning;
            });
        }

        // Both the RDS and the RadioText section want the live daemon state at
        // render time; they used to fire one RPC each for the same answer.
        var _statusSeed = null;
        function seedRadiotextStatus() {
            if (!_statusSeed) _statusSeed = fetchRadiotextStatus();
            return _statusSeed;
        }

        function toBoolState(val) {
            return (Number(val) === 1) ? 1 : 0;
        }

        // ── Control Panel ────────────────────────────────────────────────────
        s = m.section(form.NamedSection, 'main', 'settings', _('Control Panel'));
        s.addremove = false;

        o = s.option(form.DummyValue, '_controls');
        o.render = function() {

            // ── Status summary line ────────────────────────────────────────
            var statusLine = E('div', {
                id:    'tx_status_line',
                style: 'font-weight:bold; font-size:1.15em; color:#0066cc; margin-bottom:4px;'
            }, _('Loading...'));

            function refreshStatus() {
                var enabled = toBoolState(_txState.enabled);
                var freq    = _txState.freq;
                var stereo  = toBoolState(_txState.stereo);
                var pe      = _txState.pre_emphasis;

                var parts = [];
                parts.push(enabled ? '\ud83d\udd34 ' + _('ON') : '\u26aa ' + _('OFF'));
                if (freq) parts.push(freq + ' MHz');
                parts.push(stereo ? _('Stereo') : _('Mono'));
                if (pe === '1') parts.push('50\u00b5s');
                else if (pe === '2') parts.push('75\u00b5s');
                else if (pe === '0') parts.push(_('Pre-emphasis off'));

                statusLine.innerText = _('Transmitter: ') + parts.join(' \u2014 ');
            }
            window.updateFmtxStatus = refreshStatus;

            // ── Enable / Disable toggle ────────────────────────────────────
            var enableBtn = E('button', {
                id:    'tx_enable_btn',
                class: 'cbi-button',
                style: 'min-width:170px; font-size:1.05em; padding:8px 16px;',
                click: function(ev) {
                    ev.preventDefault();
                    var cur  = (enableBtn.dataset.value === '1') ? 1 : 0;
                    var next = cur ? 0 : 1;
                    enableBtn.disabled = true;
                    return applyCtrl('enabled', next).then(function() {
                        setEnableState(next);
                        refreshStatus();
                    }).catch(function() {
                        ui.addNotification(null,
                            E('p', _('Failed to change transmitter state — fmtx reported an error.')), 'error');
                    }).then(function() {
                        enableBtn.disabled = false;
                    });
                }
            }, '\u2026');

            function setEnableState(val) {
                enableBtn.dataset.value = String(val);
                if (val) {
                    enableBtn.innerText = '\ud83d\udd34 ' + _('Transmitter ON');
                    enableBtn.style.backgroundColor = '#4caf50';
                    enableBtn.style.color = '#fff';
                } else {
                    enableBtn.innerText = '\u26aa ' + _('Transmitter OFF');
                    enableBtn.style.backgroundColor = '#9e9e9e';
                    enableBtn.style.color = '#fff';
                }
            }

            // ── Frequency ───────────────────────────────────────────────────
            var freqInput = E('input', {
                id:          'tx_freq_input',
                type:        'text',
                placeholder: '87.5',
                class:       'cbi-input-text',
                style:       'width:90px; flex-shrink:0;'
            });

            // Two decimals, not one: several regions use a 0.05 MHz channel
            // grid, and rounding to 0.1 made half of those channels
            // unreachable from this form.
            function normalizeFreqInput(raw) {
                var f = parseFloat(String(raw).trim().replace(',', '.'));
                if (isNaN(f)) return null;
                if (f < TX_FREQ_MIN) f = TX_FREQ_MIN;
                if (f > TX_FREQ_MAX) f = TX_FREQ_MAX;
                return (Math.round(f * 100) / 100).toFixed(2);
            }

            var freqSetBtn = E('button', {
                class: 'cbi-button cbi-button-apply',
                style: 'flex-shrink:0;',
                click: function(ev) {
                    ev.preventDefault();
                    var raw = freqInput.value.trim();
                    if (!raw) return;
                    var fStr = normalizeFreqInput(raw);
                    if (fStr === null) {
                        ui.addNotification(null, E('p', _('Invalid frequency: ') + raw), 'error');
                        return;
                    }
                    freqInput.value = fStr;
                    return applyCtrl('freq', fStr)
                        .then(refreshStatus)
                        .catch(function() {
                            ui.addNotification(null,
                                E('p', _('Failed to set frequency — fmtx reported an error.')), 'error');
                        });
                }
            }, _('Set'));

            // ── Info modal (register dump from fmtx -i) ────────────────────
            var infoBtn = E('button', {
                class: 'cbi-button',
                style: 'flex-shrink:0;',
                click: function(ev) {
                    ev.preventDefault();
                    return callGetInfo().then(function(res) {
                        ui.showModal(_('Transmitter Info'), [
                            E('pre', { style: 'background:#f4f4f4; padding:5px; max-height:300px; overflow-y:auto;' },
                                (res && res.info) || _('No data')),
                            E('div', { class: 'right' }, [
                                E('button', { class: 'cbi-button', click: ui.hideModal }, _('Close'))
                            ])
                        ]);
                    }).catch(function() {
                        ui.addNotification(null,
                            E('p', _('Failed to read transmitter registers.')), 'error');
                    });
                }
            }, _('Info'));

            // Populate from UCI on load
            setEnableState(toBoolState(_txState.enabled));
            freqInput.value = _txState.freq || '';
            refreshStatus();

            return E('div', { class: 'cbi-value' }, [
                E('div', { class: 'cbi-value-field', style: 'display:flex; flex-direction:column; gap:10px;' }, [
                    statusLine,
                    E('div', { style: 'display:flex; flex-wrap:wrap; gap:10px; align-items:center;' }, [
                        enableBtn
                    ]),
                    E('div', { style: 'display:flex; flex-wrap:wrap; gap:8px; align-items:center;' }, [
                        E('span', {}, _('Frequency') + ':'),
                        freqInput,
                        E('span', { style: 'opacity:0.6;' }, 'MHz'),
                        freqSetBtn,
                        E('span', { style: 'opacity:0.5;' }, '|'),
                        infoBtn
                    ])
                ])
            ]);
        };

        // ── Transmitter Settings ─────────────────────────────────────────────
        s = m.section(form.NamedSection, 'main', 'settings', _('Transmitter Settings'));
        s.addremove = false;

        o = s.option(form.DummyValue, '_txsettings');
        o.render = function() {

            // ── Stereo / Mono toggle ───────────────────────────────────────
            var stereoBtn = E('button', {
                id:    'tx_stereo_btn',
                class: 'cbi-button',
                style: 'min-width:130px;',
                click: function(ev) {
                    ev.preventDefault();
                    var cur  = (stereoBtn.dataset.value === '1') ? 1 : 0;
                    var next = cur ? 0 : 1;
                    stereoBtn.disabled = true;
                    return applyCtrl('stereo', next).then(function() {
                        setStereoState(next);
                        if (typeof window.updateFmtxStatus === 'function') window.updateFmtxStatus();
                        // The stereo/mono announcement (RDS DI bit d0) lives
                        // inside the RDS frame, so the backend rebuilds that
                        // frame — which means restarting an active rotation.
                        return fetchRadiotextStatus().then(function() {
                            if (typeof window.updateFmtxRadiotext === 'function') window.updateFmtxRadiotext();
                            if (typeof window.updateFmtxEccStatus === 'function') window.updateFmtxEccStatus();
                        });
                    }).catch(function() {
                        ui.addNotification(null,
                            E('p', _('Failed to set stereo/mono — fmtx reported an error.')), 'error');
                    }).then(function() {
                        stereoBtn.disabled = false;
                    });
                }
            }, '\u2026');

            function setStereoState(val) {
                stereoBtn.dataset.value = String(val);
                if (val) {
                    stereoBtn.innerText = '\ud83c\udfa7 ' + _('Stereo');
                    stereoBtn.style.backgroundColor = '#1e88e5';
                    stereoBtn.style.color = '#fff';
                } else {
                    stereoBtn.innerText = '\ud83c\udfa7 ' + _('Mono');
                    stereoBtn.style.backgroundColor = '';
                    stereoBtn.style.color = '';
                }
            }

            // ── Pre-emphasis select (Off / 50µs / 75µs) ────────────────────
            // 0/1/2 = Off/50us/75us matches fmtx's -p flag exactly (it packs
            // this straight into CTRL bits 3:2), no remapping needed.
            var peSelect = E('select', {
                id:    'tx_pe_select',
                class: 'cbi-input-select',
                style: 'min-width:200px;',
                change: function(ev) {
                    ev.stopPropagation();
                    var val  = peSelect.value;
                    var prev = _txState.pre_emphasis;
                    peSelect.disabled = true;
                    return applyCtrl('pre_emphasis', val).then(function() {
                        if (typeof window.updateFmtxStatus === 'function') window.updateFmtxStatus();
                    }).catch(function() {
                        // A <select> keeps the user's pick regardless of what
                        // the device did — put it back so the control can't
                        // claim a setting the hardware never took.
                        peSelect.value = (prev !== null && prev !== undefined) ? String(prev) : '0';
                        ui.addNotification(null,
                            E('p', _('Failed to set pre-emphasis — fmtx reported an error.')), 'error');
                    }).then(function() {
                        peSelect.disabled = false;
                    });
                }
            }, [
                E('option', { value: '0' }, _('Off')),
                E('option', { value: '1' }, '50 \u00b5s \u2014 ' + _('Europe / RU')),
                E('option', { value: '2' }, '75 \u00b5s \u2014 ' + _('USA'))
            ]);

            // ── Peak deviation (kHz) ────────────────────────────────────────
            var devInput = E('input', {
                id:          'tx_deviation_input',
                type:        'number',
                min:         String(TX_DEVIATION_MIN),
                max:         String(TX_DEVIATION_MAX),
                step:        '0.1',
                placeholder: String(TX_DEVIATION_DEFAULT),
                class:       'cbi-input-text',
                style:       'width:80px; flex-shrink:0;'
            });

            function normalizeDeviationInput(raw) {
                var f = parseFloat(String(raw).trim().replace(',', '.'));
                if (isNaN(f)) return null;
                if (f < TX_DEVIATION_MIN) f = TX_DEVIATION_MIN;
                if (f > TX_DEVIATION_MAX) f = TX_DEVIATION_MAX;
                return f.toFixed(2);
            }

            var devSetBtn = E('button', {
                class: 'cbi-button cbi-button-apply',
                style: 'flex-shrink:0;',
                click: function(ev) {
                    ev.preventDefault();
                    var raw = devInput.value.trim();
                    if (raw === '') return;
                    var kHzStr = normalizeDeviationInput(raw);
                    if (kHzStr === null) {
                        ui.addNotification(null, E('p', _('Invalid deviation value')), 'error');
                        return;
                    }
                    devInput.value = kHzStr;
                    return applyCtrl('deviation', kHzStr).catch(function() {
                        ui.addNotification(null,
                            E('p', _('Failed to set deviation — fmtx reported an error.')), 'error');
                    });
                }
            }, _('Set'));

            // Populate from UCI on load
            setStereoState(toBoolState(_txState.stereo));
            peSelect.value = _txState.pre_emphasis || '0';
            devInput.value = _txState.deviation || TX_DEVIATION_DEFAULT;

            return E('div', { class: 'cbi-value' }, [
                E('div', { class: 'cbi-value-field', style: 'display:flex; flex-direction:column; gap:10px;' }, [
                    E('div', { style: 'display:flex; flex-wrap:wrap; gap:10px; align-items:center;' }, [
                        stereoBtn,
                        E('span', { style: 'opacity:0.5;' }, '|'),
                        E('span', {}, _('Pre-emphasis') + ':'),
                        peSelect
                    ]),
                    E('div', { style: 'display:flex; flex-wrap:wrap; gap:8px; align-items:center;' }, [
                        E('span', {}, _('Peak deviation') + ':'),
                        devInput,
                        E('span', { style: 'opacity:0.6;' }, 'kHz'),
                        devSetBtn,
                        E('span', { style: 'opacity:0.6; font-size:0.85em;' },
                            _('60 puts the pilot at the standard 6.75 kHz. Above 80 kHz a 250 kHz receiver can no longer demodulate the composite.'))
                    ])
                ])
            ]);
        };

        // ── RDS ──────────────────────────────────────────────────────────────
        s = m.section(form.NamedSection, 'main', 'settings', _('RDS'));
        s.addremove = false;

        o = s.option(form.DummyValue, '_rds');
        o.render = function() {

            var rdsInput = E('input', {
                id:          'tx_rds_input',
                type:        'text',
                maxlength:   String(TX_RDS_MAX_LEN),
                placeholder: _('Station name (8 chars)'),
                class:       'cbi-input-text',
                style:       'width:180px; flex-shrink:0;'
            });

            var charCounter = E('span', { style: 'opacity:0.6; font-size:0.85em;' }, '0 / ' + TX_RDS_MAX_LEN);

            rdsInput.addEventListener('input', function() {
                charCounter.innerText = rdsInput.value.length + ' / ' + TX_RDS_MAX_LEN;
            });

            // PI (0..0xFFFF, decimal or 0x-hex) and PTY (0..31) only take
            // effect together with the station name — fmtx rebuilds the whole
            // frame at once, so all three are sent from one Send click.
            var piInput = E('input', {
                id:          'tx_pi_input',
                type:        'text',
                maxlength:   '6',
                placeholder: '0x8000',
                class:       'cbi-input-text',
                style:       'width:90px; flex-shrink:0;'
            });

            var ptyInput = E('select', {
                id:    'tx_pty_input',
                class: 'cbi-input-select',
                style: 'min-width:190px; flex-shrink:0;'
            }, TX_PTY_NAMES.slice(0, TX_PTY_MAX + 1).map(function(name, code) {
                return E('option', { value: String(code) }, code + ' \u2014 ' + name);
            }));

            // ECC has nowhere to fit in a static frame once PS fills all 4
            // hardware slots, so a non-empty value here makes Send start an
            // ECC-only rotation instead of a plain one-shot write — see
            // applyRds/set_rds. No placeholder default: unlike PI/PTY, ECC
            // is an ITU/EBU-assigned per-country value with nothing sane to
            // suggest here.
            var eccInput = E('input', {
                id:          'tx_ecc_input',
                type:        'text',
                maxlength:   '4',
                placeholder: '0xE1',
                class:       'cbi-input-text',
                style:       'width:70px; flex-shrink:0;'
            });

            var eccStatus = E('span', { style: 'opacity:0.6; font-size:0.85em;' }, '');

            function refreshEccStatus() {
                eccStatus.innerText = _eccRotating
                    ? '\ud83d\udcf6 ' + _('on air (rotating)')
                    : (_txState.ecc ? _('set, not currently rotating') : '');
            }

            var rdsSendBtn = E('button', {
                class: 'cbi-button cbi-button-apply',
                style: 'flex-shrink:0;',
                click: function(ev) {
                    ev.preventDefault();
                    var text = rdsInput.value;
                    var pi   = piInput.value.trim();
                    var pty  = ptyInput.value.trim();
                    var ecc  = eccInput.value.trim();
                    if (!text.trim()) {
                        ui.addNotification(null,
                            E('p', _('Enter a station name (PS) first.')), 'error');
                        return;
                    }
                    rdsSendBtn.disabled = true;
                    return applyRds(text, pi, pty, ecc).then(function(res) {
                        // The backend sanitises and truncates; show what
                        // actually went out, not what was typed.
                        var sent = _txState.rds_text || '';
                        if (sent !== text) {
                            rdsInput.value = sent;
                            charCounter.innerText = sent.length + ' / ' + TX_RDS_MAX_LEN;
                        }
                        // Likewise for PI/ECC: the backend normalises both to
                        // 0xNN form and drops anything out of range, so the
                        // fields should show the accepted value, not the
                        // rejected one.
                        piInput.value  = _txState.pi  || '';
                        eccInput.value = _txState.ecc || '';
                        refreshEccStatus();

                        var msg = _('RDS identity sent: ') + '"' + sent + '"';
                        if (Number(res.radiotext_stopped) === 1) {
                            msg += ' \u2014 ' + _('RadioText rotation was stopped (identity changed).');
                        }
                        if (_eccRotating) {
                            msg += ' \u2014 ' + _('ECC is now on air via rotation.');
                        }
                        if (typeof window.updateFmtxRadiotext === 'function') window.updateFmtxRadiotext();
                        ui.addNotification(null, E('p', msg));
                    }).catch(function() {
                        ui.addNotification(null,
                            E('p', _('Failed to send RDS identity — fmtx reported an error.')), 'error');
                    }).then(function() {
                        rdsSendBtn.disabled = false;
                    });
                }
            }, '\ud83d\udce1 ' + _('Send'));

            // Populate from state seeded at page load
            var savedRds = _txState.rds_text || '';
            rdsInput.value = savedRds;
            charCounter.innerText = savedRds.length + ' / ' + TX_RDS_MAX_LEN;
            piInput.value  = _txState.pi  || '';
            ptyInput.value = _txState.pty || '0';
            eccInput.value = _txState.ecc || '';

            // Exposed so the RadioText section can nudge this status line
            // after starting/stopping its own rotation (which the ECC field
            // rides along on).
            window.updateFmtxEccStatus = refreshEccStatus;
            seedRadiotextStatus().then(refreshEccStatus);

            return E('div', { class: 'cbi-value' }, [
                E('div', {
                    class: 'cbi-value-field',
                    style: 'display:flex; flex-direction:column; gap:8px;'
                }, [
                    E('div', { style: 'display:flex; flex-wrap:wrap; gap:10px; align-items:center;' }, [
                        E('span', {}, _('PS') + ':'),
                        rdsInput,
                        charCounter,
                        E('span', { style: 'opacity:0.5;' }, '|'),
                        E('span', {}, 'PI:'),
                        piInput,
                        E('span', { style: 'opacity:0.5;' }, '|'),
                        E('span', {}, 'PTY:'),
                        ptyInput,
                        E('span', { style: 'opacity:0.5;' }, '|'),
                        E('span', {}, _('Country') + ' (ECC):'),
                        eccInput,
                        eccStatus,
                        rdsSendBtn
                    ]),
                    E('span', { style: 'opacity:0.6; font-size:0.85em;' },
                        _('PI is optional — leave blank to keep fmtx\u2019s default (0x8000). PTY defaults to \u201cNo programme type\u201d. ECC has no static slot left once PS fills the frame, so setting it starts a background rotation (same mechanism as RadioText below).'))
                ])
            ]);
        };

        // ── RadioText ────────────────────────────────────────────────────────
        s = m.section(form.NamedSection, 'main', 'settings', _('RadioText'));
        s.addremove = false;

        o = s.option(form.DummyValue, '_radiotext');
        o.render = function() {

            var rtStatusLine = E('div', {
                id:    'tx_rt_status_line',
                style: 'opacity:0.75; font-size:0.9em;'
            }, _('Checking status\u2026'));

            var rtInput = E('input', {
                id:          'tx_rt_input',
                type:        'text',
                maxlength:   String(TX_RT_MAX_LEN),
                placeholder: _('RadioText (up to 64 chars)'),
                class:       'cbi-input-text',
                style:       'width:320px; flex-shrink:0;'
            });

            var rtCounter = E('span', { style: 'opacity:0.6; font-size:0.85em;' }, '0 / ' + TX_RT_MAX_LEN);

            rtInput.addEventListener('input', function() {
                rtCounter.innerText = rtInput.value.length + ' / ' + TX_RT_MAX_LEN;
            });

            var rtToggleBtn = E('button', {
                id:    'tx_rt_toggle_btn',
                class: 'cbi-button',
                style: 'min-width:170px; flex-shrink:0;',
                click: function(ev) {
                    ev.preventDefault();

                    var action;
                    if (_rtRunning) {
                        rtToggleBtn.disabled = true;
                        action = callStopRadiotext().then(function() {
                            ui.addNotification(null, E('p', _('RadioText rotation stopped.')));
                        }).catch(function() {
                            ui.addNotification(null,
                                E('p', _('Failed to stop RadioText.')), 'error');
                        });
                    } else {
                        if (!_txState.rds_text) {
                            ui.addNotification(null,
                                E('p', _('Set a station name (PS) above first.')), 'error');
                            return;
                        }
                        // An empty text would start a process that exits
                        // immediately (there is nothing to rotate), so the
                        // backend rejects it — catch it here first for a
                        // clearer message.
                        if (!rtInput.value.trim()) {
                            ui.addNotification(null,
                                E('p', _('Enter some RadioText first.')), 'error');
                            return;
                        }
                        rtToggleBtn.disabled = true;
                        action = callStartRadiotext(rtInput.value).then(function(res) {
                            if (!res || Number(res.code) !== 0) {
                                throw new Error('start_radiotext failed');
                            }
                            _txState.radiotext = rtInput.value;
                            ui.addNotification(null, E('p', _('RadioText rotation started.')));
                        }).catch(function() {
                            ui.addNotification(null,
                                E('p', _('Failed to start RadioText — fmtx reported an error.')), 'error');
                        });
                    }

                    // Stopping or starting affects the whole daemon, not just
                    // RadioText — an ECC-only rotation dies with it too, and
                    // starting carries forward whatever ECC is currently
                    // saved (see start_radiotext), so re-check both live
                    // rather than assuming only _rtRunning changed.
                    return action.then(function() {
                        return fetchRadiotextStatus();
                    }).then(function() {
                        setRtToggleState(_rtRunning);
                        if (typeof window.updateFmtxEccStatus === 'function') window.updateFmtxEccStatus();
                    }).then(function() {
                        rtToggleBtn.disabled = false;
                    });
                }
            }, '\u2026');

            function setRtToggleState(running) {
                if (running) {
                    rtToggleBtn.innerText = '\u23f9\ufe0f ' + _('Stop rotation');
                    rtToggleBtn.style.backgroundColor = '#4caf50';
                    rtToggleBtn.style.color = '#fff';
                    rtStatusLine.innerText = '\ud83d\udcfb ' +
                        (_eccRotating
                            ? _('Rotating PS \u2194 RadioText + ECC')
                            : _('Rotating PS \u2194 RadioText'));
                } else {
                    rtToggleBtn.innerText = '\u25b6\ufe0f ' + _('Start rotation');
                    rtToggleBtn.style.backgroundColor = '';
                    rtToggleBtn.style.color = '';
                    // ECC-only rotation can be active even with RadioText
                    // off — "plain PS frame" would be wrong in that case.
                    rtStatusLine.innerText = _eccRotating
                        ? '\ud83d\udcfb ' + _('Rotating PS \u2194 ECC (RadioText not included)')
                        : _('Not running \u2014 station broadcasts a plain PS frame.');
                }
            }

            // Exposed so the RDS section can refresh this button immediately
            // when sending a new identity stops an active rotation.
            window.updateFmtxRadiotext = function() {
                setRtToggleState(_rtRunning);
            };

            // Populate from state seeded at page load, then confirm the
            // daemon's actual live status (see fetchRadiotextStatus above).
            rtInput.value = _txState.radiotext || '';
            rtCounter.innerText = rtInput.value.length + ' / ' + TX_RT_MAX_LEN;
            seedRadiotextStatus().then(function(running) {
                setRtToggleState(running);
            });

            return E('div', { class: 'cbi-value' }, [
                E('div', {
                    class: 'cbi-value-field',
                    style: 'display:flex; flex-direction:column; gap:8px;'
                }, [
                    rtStatusLine,
                    E('div', { style: 'display:flex; flex-wrap:wrap; gap:10px; align-items:center;' }, [
                        rtInput,
                        rtCounter,
                        rtToggleBtn
                    ]),
                    E('span', { style: 'opacity:0.6; font-size:0.85em;' },
                        _('The hardware buffer holds 4 RDS groups; a full RadioText needs 16 segments, so PS and RadioText frames rotate through it — only as many frames as the text actually needs. Stopping restores a plain PS frame.'))
                ])
            ]);
        };

        return m.render();
    }
});
