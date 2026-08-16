'use strict';
'require view';
'require rpc';
'require ui';

var callGet = rpc.declare({
	object: 'luci.audiosrc',
	method: 'get',
	expect: { source: 'radio' }
});

var callSet = rpc.declare({
	object: 'luci.audiosrc',
	method: 'set',
	params: [ 'source' ]
});

var SOURCES = [
	{ id: 'radio',     label: _('Radio') },
	{ id: 'mympd',     label: _('myMPD') },
	{ id: 'bluetooth', label: _('Bluetooth') }
];

return view.extend({
	load: function () {
		return callGet();
	},

	render: function (current) {
		var view = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Audio Source')),
			E('div', { 'class': 'cbi-section-descr' },
				_('Select which input is routed to the I2S output.')),
			E('div', { 'class': 'cbi-section' })
		]);

		var section = view.lastElementChild;
		var buttons = E('div', { 'class': 'cbi-value', 'style': 'padding-top:.5em' });

		SOURCES.forEach(function (src) {
			var active = (src.id === current);
			buttons.appendChild(E('button', {
				'class': 'btn cbi-button' + (active ? ' cbi-button-positive' : ' cbi-button-neutral'),
				'style': 'margin-right:.5em',
				'disabled': active ? '' : null,
				'click': ui.createHandlerFn(this, function (id, ev) {
					var btn = ev.target;
					btn.disabled = true;
					return callSet(id).then(function (res) {
						if (!res || res.success !== true) {
							ui.addNotification(null, E('p', _('Failed to switch source: ') +
								((res && res.message) || _('unknown error'))));
							btn.disabled = false;
							return;
						}
						window.location.reload();
					});
				}, src.id)
			}, [ active ? '\u2713 ' + src.label : src.label ]));
		});

		section.appendChild(buttons);
		return view;
	},

	/* Форма/CBI здесь не используется - переключение происходит сразу по
	   нажатию кнопки. Без этого базовый класс view отрисовал бы футер
	   "Save & Apply / Save / Reset", кнопки в котором ничего не делают. */
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
