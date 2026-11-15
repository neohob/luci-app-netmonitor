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
			retention_unit: this.inUnit.value,
			sni_enable: this.inSni && this.inSni.checked ? 1 : 0,
			asn_enable: this.inAsn && this.inAsn.checked ? 1 : 0,
			asn_auto_update: this.inAsnAuto && this.inAsnAuto.checked ? 1 : 0,
			asn_week_time: this.inAsnWeek ? this.inAsnWeek.value : '*',
			asn_day_time: this.inAsnHour ? parseInt(this.inAsnHour.value, 10) : 4,
			asn_path: this.inAsnPath ? this.inAsnPath.value.trim() : '',
			asn_url: this.inAsnUrl ? this.inAsnUrl.value.trim() : '',
			service_enable: this.inSvc && this.inSvc.checked ? 1 : 0,
			service_auto_update: this.inSvcAuto && this.inSvcAuto.checked ? 1 : 0,
			service_week_time: this.inSvcWeek ? this.inSvcWeek.value : '*',
			service_day_time: this.inSvcHour ? parseInt(this.inSvcHour.value, 10) : 5,
			service_path: this.inSvcPath ? this.inSvcPath.value.trim() : ''
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
			return nm.callSetConfig(v.db_path, v.interval, v.idle_gap, v.retention_value, v.retention_unit, enable,
					v.sni_enable, v.asn_enable, v.asn_auto_update, v.asn_week_time, v.asn_day_time,
					v.asn_path, v.asn_url,
					v.service_enable, v.service_auto_update, v.service_week_time, v.service_day_time,
					v.service_path, confirm ? true : null)
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
			nm.banner('info', _('域名优先来自路由器 DNS；对仍「未解析」的目标，可探测 TLS SNI / HTTP Host（需 tcpdump）。请尽量让设备使用路由器 DNS，并关闭 DoH/DoT。QUIC 与已卸载连接可能仍看不到名字。')),
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
					_('明细仅保留当前日历月：跨月后自动汇总为往月 Top100 +「其他」并清理明细。概览可选时间范围也不超出当月。下列数字不再决定明细清理（仅兼容旧配置）；往月历史请在设备明细的「往月汇总」查看。')),
				this.estBox,
				this.field(_('采样间隔（秒）'), this.inInterval, _('默认 5 秒。间隔越短，开始时间/时长越准确。')),
				this.field(_('会话空闲间隔（秒）'), this.inIdle, _('同一设备与目标超过该时间无流量，即视为新会话。默认 60 秒。'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('目标名字探测')),
				(function() {
					self.inSni = E('input', { 'type': 'checkbox' });
					self.inSni.checked = cfg.sni_enable == null ? true : Number(cfg.sni_enable) !== 0;
					var tip = _('由采集器内置：持续嗅探局域网 DNS 应答，并对仍未解析的 IP 抓取 TLS SNI / HTTP Host（需 tcpdump）。随 netmonitor 启停，无需系统定时任务。');
					if (st.sni) {
						tip += ' ' + _('当前：') + (st.sni.enabled ? _('已启用') : _('已关闭'));
						if (st.sni.available)
							tip += ' · tcpdump OK';
						else
							tip += ' · ' + _('未检测到 tcpdump');
						if (st.sni.dns_sniff)
							tip += ' · ' + _('DNS 嗅探运行中');
						if (st.sni.ok != null)
							tip += ' · SNI ' + _('命中 %d / 失败 %d').format(st.sni.ok || 0, st.sni.fail || 0);
					}
					return self.field(_('目标名字探测（DNS 嗅探 + SNI）'), E('label', {}, [
						self.inSni, ' ', _('启用')
					]), tip);
				})()
			]),
			this.renderServiceSection(cfg, st),
			this.renderAsnSection(cfg, st),
			controls
		]);
	},

	formatBytes: function(n) {
		n = Number(n) || 0;
		if (n < 1024) return n + ' B';
		if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
		if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MiB';
		return (n / 1073741824).toFixed(2) + ' GiB';
	},

	asnStatusText: function(st) {
		var a = (st && st.asn) || {};
		var parts = [];
		if (!a.binding)
			parts.push(_('未安装 lua-maxminddb（opkg install lua-maxminddb）'));
		else
			parts.push(_('lua-maxminddb 已安装'));
		if (a.size)
			parts.push(_('库文件 %s').format(this.formatBytes(a.size)) +
				(a.mtime ? _(' · 更新于 %s').format(new Date(a.mtime * 1000).toLocaleString()) : ''));
		else
			parts.push(_('尚未下载 ASN 数据库'));
		var u = a.update || {};
		if (u.state === 'running')
			parts.push(_('正在更新…'));
		else if (u.state === 'ok' && u.ts)
			parts.push(_('上次更新成功 · %s').format(new Date(u.ts * 1000).toLocaleString()));
		else if (u.state === 'error')
			parts.push(_('上次更新失败：%s').format(u.error || '?'));
		if (a.hits != null)
			parts.push(_('本进程命中 %d').format(a.hits || 0));
		return parts.join(' · ');
	},

	pollAsnUpdate: function(tries) {
		var self = this;
		tries = tries || 0;
		return nm.callStatus().then(function(st) {
			self.st = st || self.st;
			if (self.asnStatusBox)
				dom.content(self.asnStatusBox, self.asnStatusText(st));
			var u = st && st.asn && st.asn.update;
			if (u && u.state === 'running' && tries < 90) {
				return new Promise(function(resolve) {
					window.setTimeout(function() {
						resolve(self.pollAsnUpdate(tries + 1));
					}, 2000);
				});
			}
			if (u && u.state === 'ok')
				ui.addNotification(null, E('p', _('ASN 数据库更新成功')), 'info');
			else if (u && u.state === 'error')
				ui.addNotification(null, E('p', _('ASN 更新失败：') + (u.error || '')), 'danger');
			return st;
		});
	},

	updateAsnNow: function() {
		var self = this, v = this.values();
		/* Persist URL/path first so the updater reads current settings. */
		return nm.callSetConfig(v.db_path, v.interval, v.idle_gap, v.retention_value, v.retention_unit,
			this.cfg.enabled == null ? 1 : this.cfg.enabled,
			v.sni_enable, v.asn_enable, v.asn_auto_update, v.asn_week_time, v.asn_day_time,
			v.asn_path, v.asn_url,
			v.service_enable, v.service_auto_update, v.service_week_time, v.service_day_time,
			v.service_path, null).then(function(res) {
			if (!res || !res.ok) {
				ui.addNotification(null, E('p', nm.errorText(res && res.error)), 'danger');
				return;
			}
			return nm.callUpdateAsn().then(function(r) {
				if (!r || !r.ok) {
					ui.addNotification(null, E('p', nm.errorText(r && r.error)), 'danger');
					return;
				}
				if (r.busy)
					ui.addNotification(null, E('p', _('ASN 更新已在进行中')), 'warning');
				else
					ui.addNotification(null, E('p', _('已开始下载 ASN 数据库…')), 'info');
				return self.pollAsnUpdate(0);
			});
		});
	},

	svcStatusText: function(st) {
		var a = (st && st.service) || {};
		var parts = [];
		if (a.size)
			parts.push(_('库文件 %s').format(this.formatBytes(a.size)) +
				(a.ranges ? _(' · %d 段').format(a.ranges) : '') +
				(a.mtime ? _(' · 更新于 %s').format(new Date(a.mtime * 1000).toLocaleString()) : ''));
		else
			parts.push(_('尚未下载服务网段库'));
		var u = a.update || {};
		if (u.state === 'running')
			parts.push(_('正在更新…'));
		else if (u.state === 'ok' && u.ts)
			parts.push(_('上次更新成功 · %s').format(new Date(u.ts * 1000).toLocaleString()));
		else if (u.state === 'error')
			parts.push(_('上次更新失败：%s').format(u.error || '?'));
		if (a.hits != null)
			parts.push(_('本进程命中 %d').format(a.hits || 0));
		return parts.join(' · ');
	},

	pollSvcUpdate: function(tries) {
		var self = this;
		tries = tries || 0;
		return nm.callStatus().then(function(st) {
			self.st = st || self.st;
			if (self.svcStatusBox)
				dom.content(self.svcStatusBox, self.svcStatusText(st));
			var u = st && st.service && st.service.update;
			if (u && u.state === 'running' && tries < 120) {
				return new Promise(function(resolve) {
					window.setTimeout(function() {
						resolve(self.pollSvcUpdate(tries + 1));
					}, 2000);
				});
			}
			if (u && u.state === 'ok')
				ui.addNotification(null, E('p', _('服务网段库更新成功')), 'info');
			else if (u && u.state === 'error')
				ui.addNotification(null, E('p', _('服务网段更新失败：') + (u.error || '')), 'danger');
			return st;
		});
	},

	updateSvcNow: function() {
		var self = this, v = this.values();
		return nm.callSetConfig(v.db_path, v.interval, v.idle_gap, v.retention_value, v.retention_unit,
			this.cfg.enabled == null ? 1 : this.cfg.enabled,
			v.sni_enable, v.asn_enable, v.asn_auto_update, v.asn_week_time, v.asn_day_time,
			v.asn_path, v.asn_url,
			v.service_enable, v.service_auto_update, v.service_week_time, v.service_day_time,
			v.service_path, null).then(function(res) {
			if (!res || !res.ok) {
				ui.addNotification(null, E('p', nm.errorText(res && res.error)), 'danger');
				return;
			}
			return nm.callUpdateService().then(function(r) {
				if (!r || !r.ok) {
					ui.addNotification(null, E('p', nm.errorText(r && r.error)), 'danger');
					return;
				}
				if (r.busy)
					ui.addNotification(null, E('p', _('服务网段更新已在进行中')), 'warning');
				else
					ui.addNotification(null, E('p', _('已开始下载服务网段…')), 'info');
				return self.pollSvcUpdate(0);
			});
		});
	},

	renderServiceSection: function(cfg, st) {
		this.inSvc = E('input', { 'type': 'checkbox' });
		this.inSvc.checked = cfg.service_enable == null ? true : Number(cfg.service_enable) !== 0;
		this.inSvcAuto = E('input', { 'type': 'checkbox' });
		this.inSvcAuto.checked = cfg.service_auto_update == null ? true : Number(cfg.service_auto_update) !== 0;
		this.inSvcPath = E('input', { 'class': 'cbi-input-text', 'type': 'text',
			'value': cfg.service_path || '/overlay/netmonitor/services.map',
			'style': 'width:100%;max-width:36em' });
		var week = String(cfg.service_week_time == null ? '*' : cfg.service_week_time);
		var weekOpts = [
			['*', _('每天')], ['0', _('周日')], ['1', _('周一')], ['2', _('周二')],
			['3', _('周三')], ['4', _('周四')], ['5', _('周五')], ['6', _('周六')]
		];
		this.inSvcWeek = E('select', { 'class': 'cbi-input-select' }, weekOpts.map(function(o) {
			return E('option', { 'value': o[0], 'selected': o[0] === week ? '' : null }, o[1]);
		}));
		var hour = Number(cfg.service_day_time != null ? cfg.service_day_time : 5);
		this.inSvcHour = E('select', { 'class': 'cbi-input-select' }, Array.apply(null, Array(24)).map(function(_unused, i) {
			return E('option', { 'value': String(i), 'selected': i === hour ? '' : null },
				_('%d 点').format(i));
		}));
		this.svcStatusBox = E('div', { 'class': 'cbi-value-description' }, this.svcStatusText(st));

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('服务网段库')),
			E('p', { 'class': 'cbi-value-description' },
				_('在 DNS/SNI 之后，用云厂商与 CDN 网段把目标标成「字节跳动」「Cloudflare」「AWS」等。默认约 340 KiB（metowolf + disposable）。家宽 P2P 对端无法标成 App 名。')),
			this.field(_('启用服务网段回填'), E('label', {}, [ this.inSvc, ' ', _('启用') ])),
			this.field(_('数据库路径'), this.inSvcPath, _('默认 /overlay/netmonitor/services.map')),
			this.field(_('自动更新'), E('div', {}, [
				E('label', {}, [ this.inSvcAuto, ' ', _('启用定时更新') ]),
				E('div', { 'style': 'margin-top:.5em' }, [
					this.inSvcWeek, ' ', this.inSvcHour
				])
			]), _('写入 crontab（# netmonitor-service-update）；关闭则移除该行。')),
			this.field(_('手动更新'), E('div', {}, [
				E('button', {
					'class': 'cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, 'updateSvcNow')
				}, _('立即更新服务网段')),
				this.svcStatusBox
			]), _('需能访问 GitHub / metowolf CDN；下载合并约半分钟。'))
		]);
	},

	renderAsnSection: function(cfg, st) {
		var self = this;
		var a = (st && st.asn) || {};
		this.inAsn = E('input', { 'type': 'checkbox' });
		this.inAsn.checked = cfg.asn_enable == null ? true : Number(cfg.asn_enable) !== 0;
		this.inAsnAuto = E('input', { 'type': 'checkbox' });
		this.inAsnAuto.checked = cfg.asn_auto_update == null ? true : Number(cfg.asn_auto_update) !== 0;
		this.inAsnPath = E('input', { 'class': 'cbi-input-text', 'type': 'text',
			'value': cfg.asn_path || '/overlay/netmonitor/GeoLite2-ASN.mmdb',
			'style': 'width:100%;max-width:36em' });
		var urls = [
			'https://cdn.jsdelivr.net/npm/geolite2-asn/GeoLite2-ASN.mmdb.gz',
			'https://cdn.jsdelivr.net/npm/@geo-mmd/geolite2-asn/GeoLite2-ASN.mmdb',
			'https://cdn.jsdelivr.net/gh/P3TERX/GeoLite.mmdb@download/GeoLite2-ASN.mmdb'
		];
		var curUrl = cfg.asn_url || urls[0];
		this.inAsnUrl = E('select', { 'class': 'cbi-input-select', 'style': 'max-width:36em' },
			urls.map(function(u) {
				return E('option', { 'value': u, 'selected': u === curUrl ? '' : null }, u.replace(/^https:\/\//, ''));
			}).concat([
				urls.indexOf(curUrl) < 0 ? E('option', { 'value': curUrl, 'selected': '' }, curUrl) : ''
			]));
		var week = String(cfg.asn_week_time == null ? '*' : cfg.asn_week_time);
		var weekOpts = [
			['*', _('每天')], ['0', _('周日')], ['1', _('周一')], ['2', _('周二')],
			['3', _('周三')], ['4', _('周四')], ['5', _('周五')], ['6', _('周六')]
		];
		this.inAsnWeek = E('select', { 'class': 'cbi-input-select' }, weekOpts.map(function(o) {
			return E('option', { 'value': o[0], 'selected': o[0] === week ? '' : null }, o[1]);
		}));
		var hour = Number(cfg.asn_day_time != null ? cfg.asn_day_time : 4);
		this.inAsnHour = E('select', { 'class': 'cbi-input-select' }, Array.apply(null, Array(24)).map(function(_unused, i) {
			return E('option', { 'value': String(i), 'selected': i === hour ? '' : null },
				_('%d 点').format(i));
		}));
		this.asnStatusBox = E('div', { 'class': 'cbi-value-description' }, this.asnStatusText(st));

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('ASN 归属库')),
			E('p', { 'class': 'cbi-value-description' },
				_('服务网段仍无法命名时，用 GeoLite2-ASN 在标签中显示运营商/组织（如 Chinanet）；主名保持为 IP，避免合并成一条。')),
			this.field(_('启用 ASN 回填'), E('label', {}, [ this.inAsn, ' ', _('启用') ]),
				_('需安装：opkg install libmaxminddb lua-maxminddb')),
			this.field(_('数据库路径'), this.inAsnPath, _('默认放在 /overlay/netmonitor/，约 8–12 MiB。')),
			this.field(_('更新 URL'), this.inAsnUrl, _('可选用 jsDelivr 镜像；保存设置后生效。')),
			this.field(_('自动更新'), E('div', {}, [
				E('label', {}, [ this.inAsnAuto, ' ', _('启用定时更新') ]),
				E('div', { 'style': 'margin-top:.5em' }, [
					this.inAsnWeek, ' ', this.inAsnHour
				])
			]), _('写入系统 crontab（带 # netmonitor-asn-update 标记）；关闭自动更新会移除该行。')),
			this.field(_('手动更新'), E('div', {}, [
				E('button', {
					'class': 'cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, 'updateAsnNow')
				}, _('立即更新 ASN 数据库')),
				this.asnStatusBox
			]), _('先保存当前 URL/路径再下载；进度会显示在下方。'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
