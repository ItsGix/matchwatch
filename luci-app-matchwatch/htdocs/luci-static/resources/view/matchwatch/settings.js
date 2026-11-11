'use strict';
'require view';
'require form';
'require rpc';

/* Services > MatchWatch > Settings. Edits /etc/config/matchwatch; Save & Apply restarts the service. */

var callHostHints = rpc.declare({ object: 'luci-rpc', method: 'getHostHints', expect: { '': {} } });

return view.extend({
	load: function () {
		return callHostHints().catch(function () { return {}; });
	},

	render: function (hosts) {
		var m, s, o, seen = {}, list = [];

		m = new form.Map('matchwatch', _('MatchWatch'),
			_('Saving restarts MatchWatch, which ends the recording of a match in progress. Change settings between matches.'));

		s = m.section(form.NamedSection, 'main', 'matchwatch');
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('alerts', _('Alerts'));
		s.tab('blocking', _('Staying and blocking'));
		s.tab('advanced', _('Advanced'));

		/* ---- General */
		o = s.taboption('general', form.Value, 'device_ip', _('Device to watch'),
			_('Your gaming PC or console. Leave empty to watch every device. Give the device a fixed address under Network, DHCP and DNS, Static Leases, or MatchWatch loses track of it when the address changes.'));
		o.datatype = 'ip4addr("nomask")';
		o.placeholder = _('Every device');
		o.rmempty = true;

		Object.keys(hosts || {}).forEach(function (mac) {
			var h = hosts[mac] || {}, ips = h.ipaddrs || (h.ipv4 ? [ h.ipv4 ] : []);

			ips.forEach(function (ip) {
				if (!seen[ip]) {
					seen[ip] = true;
					list.push([ ip, h.name ? '%s (%s)'.format(h.name, ip) : ip ]);
				}
			});
		});

		list.sort(function (a, b) { return a[1].toLowerCase() < b[1].toLowerCase() ? -1 : 1; });
		list.forEach(function (e) { o.value(e[0], e[1]); });

		o = s.taboption('general', form.Flag, 'pc_score', _('Count your PC towards scores'),
			_('Off: pauses in what your PC sends are still shown in reports, but never lower the overall score or change the verdict.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'geo', _('Look up where servers are'),
			_('Asks ip-api.com for the city, country and hosting company of each game server. Only the server address is sent. Staying on places and the lobby alert need this on.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('general', form.Flag, 'web', _('Dashboard without login'),
			_('Also serves a view-only copy of the dashboard at /matchwatch/ to anyone on your network, with the "I felt that" button. Useful on a phone or second screen. Nothing can be blocked or changed from it.'));
		o.default = '0';
		o.rmempty = false;

		/* ---- Alerts */
		o = s.taboption('alerts', form.Value, 'ntfy_url', _('Phone alerts (ntfy)'),
			_('Install the ntfy app, subscribe to a hard-to-guess topic, and put its full address here. Leave empty for no phone alerts.'));
		o.placeholder = 'https://ntfy.sh/your-topic';
		o.rmempty = true;
		o.validate = function (section_id, value) {
			return (value === '' || /^https?:\/\/[^\s'"]+$/.test(value)) ? true : _('Enter a web address starting with http:// or https://');
		};

		o = s.taboption('alerts', form.Flag, 'notify_start', _('Alert when a match starts'),
			_('Tells your phone the moment the game itself begins, with where the server is and the ping. Handy when you have stepped away during a long queue.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('alerts', form.Flag, 'notify_newgame', _('Alert when a new game is seen'),
			_('Tells your phone the first time a match is played on a server port nobody has named. Until you name the game, staying on places, the lobby alert and automatic blocking leave it alone.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('alerts', form.Flag, 'notify_every_match', _('Alert after every match'),
			_('Off: only after bad matches and when you land on a server with a bad history.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('alerts', form.ListValue, 'lobby_alert', _('Lobby alert'),
			_('When the game starts connecting you to a server, MatchWatch works out where it is and how it has rated.'));
		o.value('0', _('Show on the dashboard only'));
		o.value('1', _('Also alert my phone when it is far or badly rated'));
		o.value('2', _('Always alert my phone'));
		o.default = '1';

		o = s.taboption('alerts', form.Value, 'lobby_margin_ms', _('"Far" means this much slower'),
			_('In milliseconds, compared with your best datacentre.'));
		o.datatype = 'range(0,500)';
		o.placeholder = '4';

		o = s.taboption('alerts', form.Value, 'warn_score', _('Warn below this rating'),
			_('Out of 100. Also the level at which a place is dropped from the places you stay on.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '55';

		/* ---- Staying and blocking */
		o = s.taboption('blocking', form.Value, 'block_days', _('Blocks last'),
			_('In days. Server addresses get reused, so blocks expire.'));
		o.datatype = 'range(1,365)';
		o.placeholder = '14';

		o = s.taboption('blocking', form.Flag, 'autoblock', _('Block bad servers automatically'),
			_('Blocks a server once enough counted matches on it average under the rating below.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('blocking', form.Value, 'autoblock_score', _('Automatic block below'));
		o.datatype = 'range(0,100)';
		o.placeholder = '45';
		o.depends('autoblock', '1');

		o = s.taboption('blocking', form.Value, 'autoblock_matches', _('After this many matches'));
		o.datatype = 'range(1,50)';
		o.placeholder = '2';
		o.depends('autoblock', '1');

		o = s.taboption('blocking', form.Flag, 'stay_strict', _('Turn servers away as the game tries them'),
			_('When you are staying on places. Off: servers elsewhere are only blocked after you have played a match on them.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('blocking', form.Value, 'stay_km', _('A city reaches this far'),
			_('In kilometres. How far from a chosen city a server may be and still count as being there.'));
		o.datatype = 'range(10,2000)';
		o.placeholder = '150';

		/* ---- Advanced */
		o = s.taboption('advanced', form.Value, 'lan_if', _('LAN interface'), _('Leave empty to detect it.'));
		o.datatype = 'network_device';
		o.placeholder = _('Detected');
		o.rmempty = true;

		o = s.taboption('advanced', form.Value, 'wan_if', _('WAN interface'), _('Leave empty to detect it.'));
		o.datatype = 'network_device';
		o.placeholder = _('Detected');
		o.rmempty = true;

		o = s.taboption('advanced', form.Value, 'ignore_ports', _('UDP ports that are never a game'),
			_('Separated by spaces.'));
		o.placeholder = '53 67 68 123 443 1900 5353';
		o.validate = function (section_id, value) {
			return /^[0-9 ]*$/.test(value) ? true : _('Port numbers separated by spaces');
		};

		o = s.taboption('advanced', form.Value, 'only_filter', _('Only look at this traffic'),
			_('A tcpdump expression, for example: port 3074 or portrange 30000-45000. Leave empty to consider all UDP.'));
		o.rmempty = true;
		o.validate = function (section_id, value) {
			return /^[A-Za-z0-9 .\/()-]*$/.test(value) ? true : _('Letters, numbers, spaces, dots, slashes, brackets and hyphens only');
		};

		o = s.taboption('advanced', form.Value, 'min_down_pps', _('A match needs this many packets a second down'));
		o.datatype = 'range(1,1000)';
		o.placeholder = '15';

		o = s.taboption('advanced', form.Value, 'min_up_pps', _('And this many up'));
		o.datatype = 'range(1,1000)';
		o.placeholder = '8';

		return m.render();
	}
});
