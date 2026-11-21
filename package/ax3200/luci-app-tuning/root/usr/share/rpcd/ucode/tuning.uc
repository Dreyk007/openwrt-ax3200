#!/usr/bin/env ucode
// Operating modes of the Xiaomi AX3200 / Redmi AX6S build: LuCI -> System -> Operating mode and the
// "tuning" command. A mode sets flow offloading, WED, bridger, packet steering, the CPU frequency
// governor and SQM together; the measurements behind them are in RESEARCH.md (sections 9, 11-13).

'use strict';

import { readfile, writefile, popen } from 'fs';
import { cursor } from 'uci';
import { init_enabled } from 'luci.sys';

const MODULES_CONF = '/etc/modules.conf';
const WED_PARAM = '/sys/module/mt7915e/parameters/wed_enable';
const CPUFREQ = '/sys/devices/system/cpu/cpufreq/policy0/';

const PROFILES = {
	balanced:   { offload: 'hardware', wed: true,  bridger: false, steering: '2', governor: 'schedutil',   sqm: false },
	throughput: { offload: 'hardware', wed: true,  bridger: true,  steering: '2', governor: 'performance', sqm: false },
	lowlatency: { offload: 'hardware', wed: false, bridger: false, steering: '2', governor: 'performance', sqm: false },
	sqm:        { offload: 'software', wed: false, bridger: false, steering: '1', governor: 'performance', sqm: true }
};
const ORDER = [ 'balanced', 'throughput', 'lowlatency', 'sqm' ];
const SETTINGS = [ 'offload', 'wed', 'bridger', 'steering', 'governor', 'sqm' ];

function sh(cmd) {
	return system(cmd + ' >/dev/null 2>&1');
}

function read_trim(path) {
	const value = readfile(path);
	return (value != null) ? trim(value) : null;
}

function first_section(c, config, type) {
	let name = null;
	c.foreach(config, type, (s) => {
		if (name == null)
			name = s['.name'];
	});
	return name;
}

// SQM shapes the configured WAN device, also with PPPoE. That is the device fw4 puts in the
// flowtable, and the software fast path takes a flow at its netfilter ingress hook, so the
// downloads of an offloaded PPPoE connection never reach the ingress of pppoe-wan and its
// shaper. tc ingress of the device itself runs before that hook.
function wan_device(c) {
	return c.get('network', 'wan', 'device') || 'wan';
}

// WED as configured for the next boot; the driver default is off
function wed_configured() {
	const m = match(readfile(MODULES_CONF) || '', /wed_enable=([YNyn01])/);
	return m ? (m[1] == 'Y' || m[1] == 'y' || m[1] == '1') : false;
}

function set_wed(on) {
	const value = 'wed_enable=' + (on ? 'Y' : 'N');
	const lines = split(readfile(MODULES_CONF) || '', '\n');
	let found = false;

	for (let i = 0; i < length(lines); i++) {
		if (index(lines[i], 'options mt7915e') != 0)
			continue;
		found = true;
		lines[i] = match(lines[i], /wed_enable=/)
			? replace(lines[i], /wed_enable=[^ \t]*/, value)
			: lines[i] + ' ' + value;
	}
	if (!found) {
		if (length(lines) && lines[length(lines) - 1] == '')
			pop(lines);
		push(lines, 'options mt7915e ' + value, '');
	}
	writefile(MODULES_CONF, join('\n', lines));
}

// the settings in effect (WED: as configured, see wed_running for the running driver)
function current(c) {
	const fw = first_section(c, 'firewall', 'defaults');
	const fo = fw && c.get('firewall', fw, 'flow_offloading') == '1';
	const hw = fw && c.get('firewall', fw, 'flow_offloading_hw') == '1';
	const q = first_section(c, 'sqm', 'queue');

	return {
		offload: fo ? (hw ? 'hardware' : 'software') : 'none',
		wed: wed_configured(),
		bridger: init_enabled('bridger') ? true : false,
		steering: c.get('network', 'globals', 'packet_steering') || '1',
		governor: c.get('cpufreq', 'settings', 'governor') || 'schedutil',
		sqm: (q && c.get('sqm', q, 'enabled') == '1') ? true : false
	};
}

function match_profile(cur) {
	for (let name in ORDER) {
		let same = true;
		for (let k in SETTINGS)
			if (PROFILES[name][k] != cur[k])
				same = false;
		if (same)
			return name;
	}
	return 'custom';
}

function warnings(s) {
	const w = [];
	if (s.sqm && s.offload == 'hardware')
		push(w, 'sqm_hw_offload');
	if (s.bridger && !s.wed)
		push(w, 'bridger_without_wed');
	return w;
}

function count(text, needle) {
	return (text != null) ? length(split(text, needle)) - 1 : 0;
}

function bridger_hw_flows() {
	const p = popen('tc filter show dev eth0 ingress 2>/dev/null');
	if (!p)
		return 0;
	const text = p.read('all');
	p.close();
	return count(text, 'in_hw');
}

function status() {
	const c = cursor();
	const cur = current(c);
	const q = first_section(c, 'sqm', 'queue');
	const wed_running = read_trim(WED_PARAM);

	return {
		profile: match_profile(cur),
		saved_profile: c.get('tuning', 'settings', 'profile'),
		settings: cur,
		warnings: warnings(cur),
		wed_running: wed_running == 'Y',
		reboot_required: wed_running != null && (wed_running == 'Y') != cur.wed,
		bridger_running: sh('pidof bridger') == 0,
		governor_running: read_trim(CPUFREQ + 'scaling_governor'),
		governors: filter(split(read_trim(CPUFREQ + 'scaling_available_governors') || '', ' '), (g) => g != '' && g != 'userspace'),
		freq_khz: +(read_trim(CPUFREQ + 'scaling_cur_freq') || 0),
		cpu_stat: split(readfile('/proc/stat') || '', '\n')[0],
		ppe_bound: count(readfile('/sys/kernel/debug/ppe0/bind'), ' BND '),
		bridger_hw_flows: bridger_hw_flows(),
		sqm: {
			available: readfile('/etc/config/sqm') != null,
			interface: q ? c.get('sqm', q, 'interface') : null,
			download: q ? +(c.get('sqm', q, 'download') || 0) : 0,
			upload: q ? +(c.get('sqm', q, 'upload') || 0) : 0,
			saved_download: +(c.get('tuning', 'settings', 'sqm_download') || 0),
			saved_upload: +(c.get('tuning', 'settings', 'sqm_upload') || 0),
			wan_device: wan_device(c)
		}
	};
}

function validate(s) {
	if (type(s) != 'object')
		return null;
	const out = {
		offload: s.offload,
		wed: s.wed ? true : false,
		bridger: s.bridger ? true : false,
		steering: '' + s.steering,
		governor: s.governor,
		sqm: s.sqm ? true : false
	};
	const governors = split(read_trim(CPUFREQ + 'scaling_available_governors') || '', ' ');
	if (!(out.offload in [ 'none', 'software', 'hardware' ]) || !(out.steering in [ '0', '1', '2' ]) ||
	    !(out.governor in governors) || out.governor == 'userspace')
		return null;
	return out;
}

function apply(args) {
	const name = args.profile;
	let want;

	if (name in PROFILES)
		want = PROFILES[name];
	else if (name == 'custom')
		want = validate(args.settings);
	if (!want)
		return { error: 'invalid profile or settings' };

	const c = cursor();
	const before = current(c);
	const dl = +(args.sqm_download || c.get('tuning', 'settings', 'sqm_download') || 0);
	const ul = +(args.sqm_upload || c.get('tuning', 'settings', 'sqm_upload') || 0);
	let q = first_section(c, 'sqm', 'queue');

	if (want.sqm && (readfile('/etc/config/sqm') == null || dl <= 0 || ul <= 0))
		return { error: 'SQM needs sqm-scripts and the download and upload rates' };

	const fw = first_section(c, 'firewall', 'defaults');
	if (fw) {
		c.set('firewall', fw, 'flow_offloading', (want.offload != 'none') ? '1' : '0');
		c.set('firewall', fw, 'flow_offloading_hw', (want.offload == 'hardware') ? '1' : '0');
		c.commit('firewall');
	}

	if (!c.get('network', 'globals'))
		c.set('network', 'globals', 'globals');
	c.set('network', 'globals', 'packet_steering', want.steering);
	c.commit('network');

	if (!c.get('cpufreq', 'settings'))
		c.set('cpufreq', 'settings', 'settings');
	c.set('cpufreq', 'settings', 'governor', want.governor);
	c.commit('cpufreq');

	if (want.sqm || q) {
		if (!q) {
			q = 'wan';
			c.set('sqm', q, 'queue');
		}
		c.set('sqm', q, 'enabled', want.sqm ? '1' : '0');
		if (want.sqm) {
			c.set('sqm', q, 'interface', wan_device(c));
			c.set('sqm', q, 'download', '' + dl);
			c.set('sqm', q, 'upload', '' + ul);
			c.set('sqm', q, 'qdisc', 'cake');
			c.set('sqm', q, 'script', 'piece_of_cake.qos');
		}
		c.commit('sqm');
	}

	if (!c.get('tuning', 'settings'))
		c.set('tuning', 'settings', 'settings');
	c.set('tuning', 'settings', 'profile', name);
	if (dl > 0 && ul > 0) {
		c.set('tuning', 'settings', 'sqm_download', '' + dl);
		c.set('tuning', 'settings', 'sqm_upload', '' + ul);
	}
	c.commit('tuning');

	// WED is a module parameter: it takes effect at the next boot
	if (want.wed != before.wed)
		set_wed(want.wed);

	if (want.bridger)
		sh('/etc/init.d/bridger enable; /etc/init.d/bridger start');
	else
		sh('/etc/init.d/bridger stop; /etc/init.d/bridger disable');

	sh('/etc/init.d/firewall reload');
	sh('/etc/init.d/packet_steering reload');
	sh('/etc/init.d/cpufreq restart');
	if (q) {
		if (want.sqm)
			sh('/etc/init.d/sqm enable');
		sh('/etc/init.d/sqm restart');
	}

	const wed_running = read_trim(WED_PARAM);
	return {
		result: 'ok',
		profile: name,
		reboot_required: wed_running != null && (wed_running == 'Y') != want.wed,
		warnings: warnings(want)
	};
}

const methods = {
	profiles: {
		call: function() {
			return { order: ORDER, profiles: PROFILES };
		}
	},
	status: {
		call: function() {
			return status();
		}
	},
	apply: {
		args: { profile: 'profile', settings: {}, sqm_download: 0, sqm_upload: 0 },
		call: function(request) {
			return apply(request.args);
		}
	}
};

return { 'luci.tuning': methods };
