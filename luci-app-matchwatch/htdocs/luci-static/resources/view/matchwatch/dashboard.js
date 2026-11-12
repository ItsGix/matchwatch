'use strict';
'require view';
'require rpc';
'require fs';

/* Services > MatchWatch > Dashboard. Hosts the shared dashboard (resources/matchwatch/dashboard.js)
   and talks to the router through LuCI: data files by file.read, buttons by the luci.matchwatch
   rpcd object, both checked against the logged-in session's permissions. */

var DATA = '/tmp/matchwatch/www/';

var callRead = rpc.declare({ object: 'luci.matchwatch', method: 'read', params: [ 'action', 'arg' ], expect: {} });
var callWrite = rpc.declare({ object: 'luci.matchwatch', method: 'write', params: [ 'action', 'arg', 'days', 'region', 'name', 'data' ], expect: {} });

/* Buttons that only look, or only record a time. Everything else needs write permission. */
var READS = { hello: 1, mark: 1, devices: 1, doctor: 1, qos: 1, log: 1, linetest: 1, trace: 1, shareexport: 1, updatecheck: 1 };

/* The dashboard's two files are asked for by MatchWatch's version, so a browser that still holds
   an older version's copies fetches the new ones after an update instead of showing the old page. */
var stamp = '';

function loadDashboard() {
	if (window.MatchwatchDashboard)
		return Promise.resolve();

	return new Promise(function (resolve, reject) {
		var s = document.createElement('script');
		s.src = L.resource('matchwatch/dashboard.js') + stamp;
		s.onload = resolve;
		s.onerror = function () { reject(new Error('Could not load the MatchWatch dashboard script.')); };
		document.head.appendChild(s);
	});
}

/* Is the LuCI theme in use a dark one? Judged from the page's own background colour. */
function pageIsDark() {
	var els = [ document.getElementById('maincontent'), document.body, document.documentElement ], i, m;

	for (i = 0; i < els.length; i++) {
		if (!els[i])
			continue;

		m = /rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?/.exec(getComputedStyle(els[i]).backgroundColor);

		if (m && (m[4] == null || +m[4] > 0.5))
			return (0.2126 * m[1] + 0.7152 * m[2] + 0.0722 * m[3]) < 128;
	}

	return false;
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function () {
		return fs.read(DATA + 'info.json').then(function (text) {
			var v = String(JSON.parse(text).version || '');
			stamp = /^[0-9.]+$/.test(v) ? '?v=' + v : '';
		}).catch(function () {}).then(loadDashboard);
	},

	render: function () {
		var host = E('div', { 'class': 'matchwatch' });

		window.MatchwatchDashboard(host, {
			css: L.resource('matchwatch/dashboard.css') + stamp,
			settings: L.url('admin/services/matchwatch/settings'),
			dark: pageIsDark,
			get: function (file) {
				return fs.read(DATA + file).then(function (text) { return JSON.parse(text); });
			},
			act: function (p) {
				if (READS[p.action])
					return callRead(p.action, p.arg || '');

				return callWrite(p.action, p.arg || '', p.days || '', p.region || '', p.name || '', p.data || '');
			}
		});

		return host;
	}
});
