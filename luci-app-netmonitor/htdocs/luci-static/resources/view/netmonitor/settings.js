'use strict';
'require view';
'require dom';
'require ui';
'require netmonitor.common as nm';
'require netmonitor.topo as topo';

var UNIT_LABELS = nm.UNIT_LABELS || { hour: '小时', day: '天', week: '周', month: '个月', year: '年' };

return view.extend({
	load: function() {
		nm.cssLink();
		return Promise.all([
			nm.callStatus().catch(function() { return null; }),
			nm.callGetConfig().catch(function() { return null; })
		]);
	},

	field: function(label, input, help) {
		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, label),
			E('div', { 'class': 'cbi-value-field' }, [
				input,
				help ? E('div', { 'class': 'cbi-value-description' }, help) : ''
			])
		]);
	},

	values: function() {
		return {
			db_path: this.inPath.value.trim(),
			interval: parseInt(this.inInterval.value, 10),
			idle_gap: parseInt(this.inIdle.value, 10),
			retention_value: parseInt(this.inRetention.value, 10),
			retention_unit: this.inUnit.value
		};
	},

	renderPathCheck: function(r) {
		if (!r) return '';
		var out = [];
		if (!r.ok) {
			out.push(nm.banner('error', nm.errorText(r.error)));
			return E('div', {}, out);
		}
		out.push(E('div', { 'class': 'nm-capacity' }, _('可写 · 剩余 %s / 共 %s · 写入保护阈值 %s').format(
			topo.formatBytes(r.free), topo.formatBytes(r.total), topo.formatBytes(r.reserve))));
		if (r.estimate) {
			out.push(E('div', { 'class': 'nm-capacity' }, _('按当前保留期限，预计占用约 %s%s').format(
				topo.formatBytes(r.estimate.estimated_bytes),
				r.estimate.observed ? _('（根据实际记录估算）') : _('（初始估算，开始采集后会更准确）'))));
			if (r.estimate.fits === false)
				out.push(nm.banner('warn', _('预计占用超过可用空间，空间不足时会自动暂停写入。建议缩短保留期限或换更大的存储。')));
		}
		(r.warnings || []).forEach(function(w) {
			if (w === 'overlay')
				out.push(nm.banner('error', _('严重警告：该路径位于路由器内部闪存。长期写入会磨损闪存并可能占满系统空间，强烈建议使用 U 盘或硬盘。')));
			if (w === 'volatile')
				out.push(nm.banner('warn', _('该路径位于内存 (tmpfs)，重启后历史数据会丢失。')));
		});
		return E('div', {}, out);
	},

	/* Write ACL: create dir + probe. Read-only check_path never mutates FS (F1). */
	checkPath: function() {
		var self = this;
		var p = this.inPath.value.trim();
		return nm.callPreparePath(p).then(function(r) {
			self.pathResult = r;
			self.riskAck.checked = false;
			self.riskBox.style.display = (r && r.ok && (r.warnings || []).indexOf('overlay') >= 0) ? '' : 'none';
			dom.content(self.pathBox, self.renderPathCheck(r));
			return r;
		});
	},

	updateEstimate: function() {
		var self = this, v = this.values();
		return nm.callEstimate(v.retention_value, v.retention_unit, v.db_path || null).then(function(r) {
			if (!r || r.error) { dom.content(self.estBox, ''); return; }
			var txt = _('保留期内预计数据量约 %s').format(topo.formatBytes(r.estimated_bytes));
			if (r.free != null) txt += _('，当前剩余 %s').format(topo.formatBytes(r.free));
			dom.content(self.estBox, [
				E('div', { 'class': 'nm-capacity' }, txt),
				r.fits === false ? nm.banner('warn', _('预计占用超过可用空间，接近满时将暂停写入。')) : ''
			]);
		}).catch(function() {});
	},

	save: function(confirm) {
		var self = this, v = this.values();
		if (!v.db_path)
			return Promise.resolve(ui.addNotification(null, E('p', nm.errorText('need_path')), 'danger'));
		var pathChanged = v.db_path !== (this.cfg.db_path || '');
		var pre = pathChanged || !this.pathResult ? this.checkPath() : Promise.resolve(this.pathResult);
		return pre.then(function(r) {
			if (!r || !r.ok) return;
			if ((r.warnings || []).indexOf('overlay') >= 0 && !self.riskAck.checked) {
				ui.addNotification(null, E('p', _('请先勾选「我已了解风险」才能使用内部闪存路径。')), 'warning');
				return;
			}
			/* Wizard forces enable; otherwise keep current enabled (F8). */
			var enable = self.wizard ? 1 : (self.cfg.enabled == null ? 1 : self.cfg.enabled);
			return nm.callSetConfig(v.db_path, v.interval, v.idle_gap, v.retention_value, v.retention_unit, enable, confirm ? true : null)
				.then(function(res) {
					if (res && res.need_confirm) {
						ui.showModal(_('缩短保留期限'), [
							E('p', _('缩短后将删除约 %d 条超出新期限的历史记录，删除后无法恢复。').format(res.pending_delete_rows)),
							res.estimate ? E('p', _('新的预计占用约 %s。').format(topo.formatBytes(res.estimate.estimated_bytes))) : '',
							E('div', { 'class': 'right' }, [
								E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('取消')),
								' ',
								E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() {
									ui.hideModal();
									self.save(true);
								} }, _('确认删除并保存'))
							])
						]);
						return;
					}
					if (!res || !res.ok) {
						ui.addNotification(null, E('p', nm.errorText(res && res.error)), 'danger');
						return;
					}
					ui.addNotification(null, E('p', _('设置已保存，采集已启动。')), 'info');
					window.setTimeout(function() {
						location.href = L.url('admin/control/netmonitor/overview');
					}, 1500);
				});
		});
	},

	render: function(res) {
		var self = this;
		var st = res[0] || {}, cfg = res[1] || {};
		this.cfg = cfg;
		var wizard = st.state === 'need_wizard';
		this.wizard = wizard;

		this.inPath = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': cfg.db_path || '',
			'placeholder': '/mnt/sda1/netmonitor' });
		this.inInterval = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'min': 1, 'max': 60,
			'value': cfg.interval || 5 });
		this.inIdle = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'min': 2, 'max': 3600,
			'value': cfg.idle_gap || 60 });
		this.inRetention = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'min': 1,
			'value': cfg.retention_value || 30, 'change': function() { self.updateEstimate(); } });
		this.inUnit = E('select', { 'class': 'cbi-input-select', 'change': function() { self.updateEstimate(); } },
			(cfg.retention_units || [ 'hour', 'day', 'week', 'month', 'year' ]).map(function(u) {
				return E('option', { 'value': u, 'selected': u === (cfg.retention_unit || 'day') ? '' : null }, _(UNIT_LABELS[u] || u));
			}));
		this.pathBox = E('div');
		this.estBox = E('div');
		this.riskAck = E('input', { 'type': 'checkbox' });
		this.riskBox = E('label', { 'class': 'nm-risk', 'style': 'display:none' }, [
			this.riskAck, ' ', _('我已了解风险，仍要使用内部闪存保存数据')
		]);

		var running = st.state === 'running' || st.state === 'disk_pause';
		var controls = E('div', { 'class': 'nm-toolbar' }, [
			E('button', { 'class': 'cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, function() {
				return this.save(false);
			}) }, wizard ? _('保存并开始采集') : _('保存设置')),
			wizard ? '' : E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, function() {
				return nm.callCollector(running ? 'stop' : 'start').then(function(r) {
					if (r && r.ok) location.reload();
					else ui.addNotification(null, E('p', nm.errorText(r && r.error)), 'danger');
				});
			}) }, running ? _('停止采集') : _('启动采集'))
		]);

		this.updateEstimate();

		return E('div', { 'class': 'nm-root' }, [
			E('h2', {}, wizard ? _('流量监控 · 首次设置向导') : _('流量监控 · 设置')),
			E('div', { 'class': 'nm-banners' }, wizard ? [
				nm.banner('info', _('第 1 步：选择一个可写的数据存储目录（推荐 U 盘或硬盘），检查空间后保存即开始采集。未完成前不会采集任何数据。'))
			] : nm.statusBanners(st)),
			nm.banner('warn', _('域名识别只依赖路由器 DNS：请让设备使用路由器作为 DNS 服务器，并关闭浏览器/系统中的「安全 DNS」(DoH/DoT)。否则只能显示 IP，并标注「未解析」。')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('数据存储')),
				this.field(_('存储目录'), E('div', {}, [
					this.inPath, ' ',
					E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'checkPath') }, _('准备并检查'))
				]), _('数据库文件 netmonitor.db 会保存在此目录。按钮会创建目录并探测可写性（需写权限）。剩余空间低于 max(100 MiB, 卷容量 5%) 时自动暂停写入。')),
				this.pathBox,
				this.riskBox
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('保留与采样')),
				this.field(_('最长保留'), E('div', {}, [ this.inRetention, ' ', this.inUnit ]),
					_('按自然时间计算（依赖系统时间同步），超过期限的明细会被自动删除。')),
				this.estBox,
				this.field(_('采样间隔（秒）'), this.inInterval, _('默认 5 秒。间隔越短，开始时间/时长越准确。')),
				this.field(_('会话空闲间隔（秒）'), this.inIdle, _('同一设备与目标超过该时间无流量，即视为新会话。默认 60 秒。'))
			]),
			controls
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
