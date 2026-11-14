'use strict';
'require view';
'require dom';
'require netmonitor.common as nm';
'require netmonitor.topo as topo';

function param(name) {
	var m = new RegExp('[?&]' + name + '=([^&]*)').exec(location.search);
	return m ? decodeURIComponent(m[1]) : null;
}

return view.extend({
	sort: 'time',
	filter: '',

	load: function() {
		nm.cssLink();
		this.mac = param('mac');
		this.day = param('day');
		return Promise.all([
			nm.callStatus().catch(function() { return null; }),
			this.mac ? nm.callDetail(this.mac, this.day, this.sort).catch(function() { return null; }) : Promise.resolve(null)
		]);
	},

	reload: function() {
		var self = this;
		return nm.callDetail(this.mac, this.day, this.sort).catch(function() { return null; }).then(function(d) {
			self.data = d;
			self.update();
		});
	},

	renderDays: function(d) {
		var self = this;
		return E('div', { 'class': 'nm-chips' }, (d.days || []).map(function(day) {
			return E('button', {
				'class': 'nm-chip' + (day === d.day ? ' active' : ''),
				'click': function() { self.day = day; self.reload(); }
			}, day);
		}));
	},

	renderTable: function(d) {
		var self = this;
		var interval = (this.status && this.status.interval) || 5;
		var f = this.filter.toLowerCase();
		var rows = (d.sessions || []).filter(function(r) {
			return !f || String(r.display).toLowerCase().indexOf(f) >= 0;
		});
		if (!rows.length) return E('div', { 'class': 'nm-topo-empty' }, _('当天没有会话记录'));
		return E('table', { 'class': 'table nm-detail' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('目标')),
				E('th', { 'class': 'th' }, _('上传')),
				E('th', { 'class': 'th' }, _('下载')),
				E('th', { 'class': 'th' }, _('合计')),
				E('th', { 'class': 'th' }, _('开始时间（约）')),
				E('th', { 'class': 'th' }, _('持续时长（约）'))
			])
		].concat(rows.map(function(r) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [
					r.display,
					r.unresolved ? E('span', { 'class': 'nm-tag' }, _('未解析')) : '',
					r.active ? E('span', { 'class': 'nm-tag nm-tag-live' }, _('进行中')) : '',
					r.split ? E('span', { 'class': 'nm-tag', 'title': _('该会话跨越午夜，已按自然日拆分') }, _('跨日')) : ''
				]),
				E('td', { 'class': 'td' }, topo.formatBytes(r.bytes_up)),
				E('td', { 'class': 'td' }, topo.formatBytes(r.bytes_down)),
				E('td', { 'class': 'td' }, topo.formatBytes(r.bytes_total)),
				E('td', { 'class': 'td' }, '约 ' + topo.formatClock(r.started_at)),
				E('td', { 'class': 'td' }, topo.formatDuration(r.duration, interval))
			]);
		})));
	},

	update: function() {
		var self = this, d = this.data;
		var body;
		if (!this.mac) {
			body = E('div', { 'class': 'nm-topo-empty' }, _('未指定设备'));
		}
		else if (!d || d.error) {
			body = E('div', { 'class': 'nm-topo-empty' }, d && d.error ? nm.errorText(d.error) : _('无法加载设备明细'));
		}
		else {
			var dev = d.device || {};
			var sortSel = E('select', { 'class': 'cbi-input-select', 'change': function(ev) {
				self.sort = ev.target.value; self.reload();
			} }, [
				E('option', { 'value': 'time', 'selected': self.sort === 'time' ? '' : null }, _('按开始时间')),
				E('option', { 'value': 'traffic', 'selected': self.sort === 'traffic' ? '' : null }, _('按流量')),
				E('option', { 'value': 'target', 'selected': self.sort === 'target' ? '' : null }, _('按目标'))
			]);
			var filterIn = E('input', { 'class': 'cbi-input-text', 'placeholder': _('筛选目标…'), 'value': self.filter,
				'input': function(ev) {
					self.filter = ev.target.value;
					dom.content(self.tableBox, self.renderTable(d));
				} });
			this.tableBox = E('div', {}, this.renderTable(d));
			body = E('div', {}, [
				E('div', { 'class': 'nm-device-head' }, [
					E('strong', {}, dev.hostname || dev.ip || d.mac),
					E('span', {}, ' ' + (dev.ip || '') + ' · ' + d.mac)
				]),
				d.days && d.days.length ? this.renderDays(d) : E('div', { 'class': 'nm-topo-empty' }, _('暂无会话记录')),
				d.day ? E('div', { 'class': 'nm-capacity' }, _('%s 合计 %s（↑%s ↓%s）').format(d.day,
					topo.formatBytes(d.bytes_total), topo.formatBytes(d.bytes_up), topo.formatBytes(d.bytes_down))) : '',
				E('div', { 'class': 'nm-toolbar' }, [ sortSel, filterIn ]),
				this.tableBox,
				E('p', { 'class': 'nm-note' }, _('开始时间与时长根据采样推算（约），精度约为采样间隔 %d 秒；空闲超过 %d 秒视为新会话。')
					.format((this.status && this.status.interval) || 5, (this.status && this.status.idle_gap) || 60))
			]);
		}
		dom.content(this.root, [
			E('div', { 'class': 'nm-banners' }, nm.statusBanners(this.status)),
			body
		]);
	},

	render: function(res) {
		this.status = res[0];
		this.data = res[1];
		this.root = E('div', { 'class': 'nm-root' });
		this.update();
		return E('div', {}, [
			E('h2', {}, [
				E('a', { 'href': L.url('admin/control/netmonitor/overview'), 'class': 'nm-back' }, '← ' + _('返回总览')),
				' ', _('设备明细')
			]),
			this.root
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
