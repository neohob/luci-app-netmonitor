'use strict';
'require baseclass';
'require rpc';
'require ui';

var callStatus = rpc.declare({ object: 'netmonitor', method: 'status' });
var callTopology = rpc.declare({ object: 'netmonitor', method: 'topology', params: [ 'range' ] });
var callDevices = rpc.declare({ object: 'netmonitor', method: 'devices', params: [ 'range' ] });
var callDetail = rpc.declare({ object: 'netmonitor', method: 'device_detail', params: [ 'mac', 'day', 'sort' ] });
var callGetConfig = rpc.declare({ object: 'netmonitor', method: 'get_config' });
var callSetConfig = rpc.declare({ object: 'netmonitor', method: 'set_config',
	params: [ 'db_path', 'interval', 'idle_gap', 'retention_value', 'retention_unit', 'enabled',
		'sni_enable', 'asn_enable', 'asn_auto_update', 'asn_week_time', 'asn_day_time',
		'asn_path', 'asn_url', 'confirm' ] });
var callEstimate = rpc.declare({ object: 'netmonitor', method: 'estimate',
	params: [ 'retention_value', 'retention_unit', 'db_path' ] });
var callCheckPath = rpc.declare({ object: 'netmonitor', method: 'check_path', params: [ 'path' ] });
var callPreparePath = rpc.declare({ object: 'netmonitor', method: 'prepare_path', params: [ 'path' ] });
var callCollector = rpc.declare({ object: 'netmonitor', method: 'collector', params: [ 'action' ] });
var callUpdateAsn = rpc.declare({ object: 'netmonitor', method: 'update_asn' });

var UNIT_LABELS = { hour: '小时', day: '天', week: '周', month: '个月', year: '年' };

var ERRORS = {
	need_path: '尚未选择数据存储路径',
	path_not_absolute: '路径必须以 / 开头',
	path_invalid: '路径无效',
	path_missing: '目录不存在（只读检查不会自动创建；请用「准备并检查」创建）',
	path_not_writable: '该路径不可写，请换一个位置（如 U 盘挂载点 /mnt/sda1）',
	insufficient_space: '可用空间不足，无法开始采集',
	statfs_failed: '无法读取该路径的磁盘空间（挂载可能已消失）',
	range_exceeds_retention: '所选时间范围超过保留期限',
	bad_range: '无效的时间范围',
	bad_day: '日期无效',
	bad_interval: '采样间隔需在 1–60 秒之间',
	bad_idle_gap: '会话空闲间隔需至少为采样间隔的 2 倍，且不超过 3600 秒',
	bad_retention: '保留期限必须是正整数',
	bad_retention_unit: '保留期限单位无效',
	bad_mac: '设备地址无效',
	db_error: '数据库读写失败，已暂停采集写入',
	db_init_failed: '数据库初始化失败',
	internal: '内部错误'
};

function errorText(code) {
	return _(ERRORS[code] || String(code));
}

function cssLink() {
	if (document.querySelector('link[data-netmonitor]')) return;
	document.head.appendChild(E('link', {
		'rel': 'stylesheet',
		'href': L.resource('netmonitor/netmonitor.css'),
		'data-netmonitor': '1'
	}));
}

function banner(level, text, actions) {
	return E('div', { 'class': 'nm-banner nm-banner-' + level }, [
		E('span', {}, [ text ]),
		actions ? E('span', { 'class': 'nm-banner-actions' }, actions) : ''
	]);
}

function restartButton() {
	return E('button', {
		'class': 'cbi-button cbi-button-apply',
		'click': ui.createHandlerFn(this, function() {
			return callCollector('restart').then(function(r) {
				if (r && r.ok) {
					ui.addNotification(null, E('p', _('采集已重新启动')), 'info');
					window.setTimeout(function() { location.reload(); }, 2000);
				}
				else {
					ui.addNotification(null, E('p', errorText(r && r.error)), 'danger');
				}
			});
		})
	}, [ _('重新启动采集') ]);
}

/* Status banners shared by overview and detail pages. */
function statusBanners(st) {
	var out = [];
	if (!st || typeof st !== 'object') {
		out.push(banner('error', _('无法连接 netmonitor 服务（请确认已安装 netmonitor 并重启 rpcd）')));
		return out;
	}
	if (st.state === 'need_wizard') {
		out.push(banner('warn', _('首次使用：请先完成设置向导，选择数据存储位置后才会开始采集。'), [
			E('a', { 'class': 'cbi-button cbi-button-action', 'href': L.url('admin/control/netmonitor/settings') }, [ _('打开设置向导') ])
		]));
	}
	else if (st.state === 'stopped') {
		out.push(banner('error', _('采集已停止'), [ restartButton() ]));
	}
	else if (st.state === 'path_error') {
		out.push(banner('error', _('存储路径不可用：') + errorText(st.error || 'statfs_failed'), [
			E('a', { 'class': 'cbi-button', 'href': L.url('admin/control/netmonitor/settings') }, [ _('更改存储路径') ])
		]));
	}
	else if (st.state === 'db_error') {
		out.push(banner('error', _('数据库写入失败，已暂停采集写入：') + errorText(st.error || 'db_error'), [ restartButton() ]));
	}
	else if (st.state === 'disk_pause') {
		out.push(banner('error', _('磁盘空间即将用尽，已暂停写入数据。请清理空间、缩短保留期限或更换存储路径。')));
	}
	else if (st.state === 'running' && st.error) {
		out.push(banner('error', _('采集异常：') + errorText(st.error)));
	}
	if (st.degraded) {
		out.push(banner('warn', _('降级模式：系统未提供连接字节计数（nf_conntrack_acct），无法统计流量。不会显示估算数字。')));
	}
	if (st.clock_unsynced) {
		out.push(banner('warn', _('系统时间尚未同步（NTP），时间范围与保留期限可能不准确。')));
	}
	(st.warnings || []).forEach(function(w) {
		if (w === 'overlay')
			out.push(banner('error', _('严重警告：数据存放在路由器内部闪存上，长期写入会磨损闪存并可能占满系统空间。强烈建议改用 U 盘或硬盘。')));
		else if (w === 'volatile')
			out.push(banner('warn', _('数据存放在内存 (tmpfs) 中，重启后历史记录会丢失。')));
		else if (w === 'flow_offloading')
			out.push(banner('warn', _('已启用防火墙流量卸载 (flow offloading)，被卸载的连接可能统计不全。')));
		else if (w === 'dns_log_missing')
			out.push(banner('warn', _('未找到 dnsmasq 查询日志，域名归因将大量显示为 IP「未解析」。请确认设备使用路由器 DNS，并检查设置中的 DNS 日志路径。')));
		else if (w === 'sni_unavailable')
			out.push(banner('warn', _('未安装 tcpdump：无法对「未解析」目标做 TLS/HTTP 名字探测，仅使用 DNS。可选安装 tcpdump 后重启采集。')));
		else if (w === 'asn_unavailable')
			out.push(banner('warn', _('ASN 归属库不可用：请安装 lua-maxminddb，并在设置中下载 GeoLite2-ASN 数据库。'), [
				E('a', { 'class': 'cbi-button', 'href': L.url('admin/control/netmonitor/settings') }, [ _('打开设置') ])
			]));
		else if (w === 'asn_update_failed')
			out.push(banner('warn', _('ASN 数据库上次更新失败，可在设置中手动重试。')));
		else if (w === 'retention_failed')
			out.push(banner('warn', _('历史清理（保留期限）失败，采集写入仍在继续。详情：') + errorText(st.retention_detail || st.error || 'db_error')));
	});
	return out;
}

return baseclass.extend({
	UNIT_LABELS: UNIT_LABELS,
	callStatus: callStatus,
	callTopology: callTopology,
	callDevices: callDevices,
	callDetail: callDetail,
	callGetConfig: callGetConfig,
	callSetConfig: callSetConfig,
	callEstimate: callEstimate,
	callCheckPath: callCheckPath,
	callPreparePath: callPreparePath,
	callCollector: callCollector,
	callUpdateAsn: callUpdateAsn,
	errorText: errorText,
	cssLink: cssLink,
	banner: banner,
	statusBanners: statusBanners
});
