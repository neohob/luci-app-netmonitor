'use strict';
'require view';
'require dom';
'require netmonitor.common as nm';
'require netmonitor.topo as topo';

function param(name) {
	var m = new RegExp('[?&]' + name + '=([^&]*)').exec(location.search);
	return m ? decodeURIComponent(m[1]) : null;
}

function num(v) {
	return Number(v) || 0;
}

function pad2(n) {
	return (n < 10 ? '0' : '') + n;
}

function todayKey() {
	var t = new Date();
	return t.getFullYear() + '-' + pad2(t.getMonth() + 1) + '-' + pad2(t.getDate());
}

function parseDayKey(key) {
	var m = String(key || '').match(/^(\d{4})-(\d{2})-(\d{2})$/);
	if (!m) return null;
	return { y: +m[1], m: +m[2], d: +m[3] };
}

return view.extend({
	sortKey: 'bytes_total',
	sortDir: 'desc',
	filter: '',
	expanded: null,
	calOpen: false,
	calYear: null,
	calMonth: null,

	load: function() {
		nm.cssLink();
		this.mac = param('mac');
		this.day = param('day') || todayKey();
		this.expanded = {};
		var t = parseDayKey(this.day) || parseDayKey(todayKey());
		this.calYear = t.y;
		this.calMonth = t.m;
		return Promise.all([
			nm.callStatus().catch(function() { return null; }),
			this.mac ? nm.callDetail(this.mac, this.day, 'time').catch(function() { return null; }) : Promise.resolve(null)
		]);
	},

	reload: function() {
		var self = this;
		return nm.callDetail(this.mac, this.day, 'time').catch(function() { return null; }).then(function(d) {
			self.data = d;
			self.update();
		});
	},

	closeCalendar: function() {
		if (!this.calOpen) return;
		this.calOpen = false;
		this.update();
	},

	renderDayPicker: function(d) {
		var self = this;
		var selected = d.day || self.day || todayKey();
		var has = {};
		(d.days || []).forEach(function(day) { has[day] = true; });

		var btn = E('button', {
			'class': 'nm-chip nm-day-btn' + (has[selected] ? ' has-data' : ''),
			'type': 'button',
			'click': function(ev) {
				ev.preventDefault();
				ev.stopPropagation();
				self.calOpen = !self.calOpen;
				var p = parseDayKey(selected);
				if (p) { self.calYear = p.y; self.calMonth = p.m; }
				self.update();
			}
		}, selected);

		if (!self.calOpen)
			return E('div', { 'class': 'nm-day-wrap' }, [ btn ]);

		var y = self.calYear, m = self.calMonth;
		var first = new Date(y, m - 1, 1);
		var startPad = first.getDay(); /* 0=Sun */
		var daysInMonth = new Date(y, m, 0).getDate();
		var today = todayKey();
		var weekdays = [ _('日'), _('一'), _('二'), _('三'), _('四'), _('五'), _('六') ];

		var head = E('div', { 'class': 'nm-cal-head' }, [
			E('button', {
				'class': 'nm-cal-nav', 'type': 'button', 'title': _('上个月'),
				'click': function(ev) {
					ev.preventDefault(); ev.stopPropagation();
					self.calMonth -= 1;
					if (self.calMonth < 1) { self.calMonth = 12; self.calYear -= 1; }
					self.update();
				}
			}, '‹'),
			E('span', { 'class': 'nm-cal-title' }, y + '-' + pad2(m)),
			E('button', {
				'class': 'nm-cal-nav', 'type': 'button', 'title': _('下个月'),
				'click': function(ev) {
					ev.preventDefault(); ev.stopPropagation();
					self.calMonth += 1;
					if (self.calMonth > 12) { self.calMonth = 1; self.calYear += 1; }
					self.update();
				}
			}, '›'),
			E('button', {
				'class': 'nm-cal-close', 'type': 'button', 'title': _('关闭'),
				'click': function(ev) {
					ev.preventDefault();
					ev.stopPropagation();
					self.closeCalendar();
				}
			}, '×')
		]);

		var grid = [ E('div', { 'class': 'nm-cal-weekdays' }, weekdays.map(function(w) {
			return E('span', {}, w);
		})) ];

		var cells = [];
		var i;
		for (i = 0; i < startPad; i++)
			cells.push(E('span', { 'class': 'nm-cal-cell empty' }, ''));

		for (i = 1; i <= daysInMonth; i++) {
			(function(dayNum) {
				var key = y + '-' + pad2(m) + '-' + pad2(dayNum);
				var ok = !!has[key];
				var cls = 'nm-cal-cell';
				if (ok) cls += ' has-data';
				else cls += ' no-data';
				if (key === selected) cls += ' selected';
				if (key === today) cls += ' today';
				var attrs = { 'class': cls };
				if (ok) {
					attrs.type = 'button';
					attrs.title = key;
					attrs.click = function(ev) {
						ev.preventDefault();
						ev.stopPropagation();
						self.day = key;
						self.calOpen = false;
						self.expanded = {};
						self.reload();
					};
					cells.push(E('button', attrs, String(dayNum)));
				}
				else {
					attrs.title = _('无数据');
					cells.push(E('span', attrs, String(dayNum)));
				}
			})(i);
		}

		grid.push(E('div', { 'class': 'nm-cal-days' }, cells));

		var panel = E('div', {
			'class': 'nm-cal-panel',
			'click': function(ev) { ev.stopPropagation(); }
		}, [ head ].concat(grid));

		/* Argon auto light/dark: CSS vars are unreliable on overlays — copy the
		   live page surface so the panel never falls back to white-on-light-text. */
		try {
			var el = document.querySelector('.main-right') ||
				document.querySelector('#maincontent') ||
				document.querySelector('.cbi-map') ||
				document.body;
			while (el) {
				var cs = window.getComputedStyle(el);
				var bg = cs.backgroundColor;
				if (bg && bg !== 'transparent' && bg !== 'rgba(0, 0, 0, 0)') {
					panel.style.backgroundColor = bg;
					if (cs.color) panel.style.color = cs.color;
					break;
				}
				el = el.parentElement;
			}
		} catch (e) {}

		var backdrop = E('div', {
			'class': 'nm-cal-backdrop',
			'click': function(ev) {
				ev.preventDefault();
				ev.stopPropagation();
				self.closeCalendar();
			}
		});

		return E('div', { 'class': 'nm-day-wrap' }, [ backdrop, btn, panel ]);
	},

	groupSessions: function(rows) {
		/* API may already merge by display (session_count) to keep ubus small. */
		if (rows.length && rows[0].session_count != null) {
			return rows.map(function(r) {
				return {
					key: String(r.display == null ? r.target : r.display),
					display: r.display == null ? r.target : r.display,
					source: r.source,
					asn_org: r.asn_org,
					children: r.children || [],
					session_count: num(r.session_count),
					bytes_up: num(r.bytes_up),
					bytes_down: num(r.bytes_down),
					bytes_total: num(r.bytes_total),
					duration: num(r.duration),
					started_at: num(r.started_at),
					unresolved: !!r.unresolved,
					active: !!r.active,
					split: !!r.split
				};
			});
		}
		var map = {}, keys = [];
		rows.forEach(function(r) {
			var key = String(r.display == null ? r.target : r.display);
			var g = map[key];
			if (!g) {
				g = {
					key: key,
					display: r.display == null ? r.target : r.display,
					source: r.source,
					asn_org: r.asn_org,
					children: [],
					bytes_up: 0,
					bytes_down: 0,
					bytes_total: 0,
					duration: 0,
					started_at: num(r.started_at),
					unresolved: true,
					active: false,
					split: false
				};
				map[key] = g;
				keys.push(key);
			}
			g.children.push(r);
			g.bytes_up += num(r.bytes_up);
			g.bytes_down += num(r.bytes_down);
			g.bytes_total += num(r.bytes_total);
			g.duration += num(r.duration);
			var st = num(r.started_at);
			if (st && (!g.started_at || st < g.started_at)) g.started_at = st;
			if (!r.unresolved) g.unresolved = false;
			if (r.active) g.active = true;
			if (r.split) g.split = true;
			if (!g.source && r.source) g.source = r.source;
			if (!g.asn_org && r.asn_org) g.asn_org = r.asn_org;
		});
		return keys.map(function(k) { return map[k]; });
	},

	sortGroups: function(groups) {
		var key = this.sortKey || 'bytes_total';
		var dir = this.sortDir === 'asc' ? 1 : -1;

		groups.sort(function(a, b) {
			var av, bv;
			if (key === 'display') {
				av = String(a.display || '');
				bv = String(b.display || '');
				if (av !== bv) return av < bv ? -dir : dir;
			}
			else {
				av = num(a[key]);
				bv = num(b[key]);
				if (av !== bv) return av < bv ? -dir : dir;
			}
			/* stable tie-break */
			av = String(a.display || '');
			bv = String(b.display || '');
			if (av !== bv) return av < bv ? -1 : 1;
			return num(b.started_at) - num(a.started_at);
		});

		groups.forEach(function(g) {
			g.children.sort(function(a, b) {
				return num(b.started_at) - num(a.started_at);
			});
		});

		return groups;
	},

	filteredRows: function(d) {
		var f = (this.filter || '').toLowerCase();
		return (d.sessions || []).filter(function(r) {
			if (!f) return true;
			return String(r.display).toLowerCase().indexOf(f) >= 0
				|| String(r.target || '').toLowerCase().indexOf(f) >= 0;
		});
	},

	setSort: function(key) {
		if (this.sortKey === key)
			this.sortDir = this.sortDir === 'asc' ? 'desc' : 'asc';
		else {
			this.sortKey = key;
			this.sortDir = (key === 'display') ? 'asc' : 'desc';
		}
		if (this.tableBox && this.data)
			dom.content(this.tableBox, this.renderTable(this.data));
	},

	th: function(label, key) {
		var self = this;
		var active = self.sortKey === key;
		var mark = active ? (self.sortDir === 'asc' ? ' ▲' : ' ▼') : '';
		return E('th', {
			'class': 'th nm-th-sort' + (active ? ' nm-th-active' : ''),
			'click': function() { self.setSort(key); },
			'title': _('点击排序')
		}, [ label, active ? E('span', { 'class': 'nm-sort-mark' }, mark) : '' ]);
	},

	tagsFor: function(r) {
		var out = [];
		var n = num(r.session_count);
		if (n > 1) out.push(E('span', { 'class': 'nm-tag', 'title': _('合并的会话数') }, n + ' ' + _('次')));
		if (r.source === 'service')
			out.push(E('span', { 'class': 'nm-tag nm-tag-service', 'title': _('来自云/CDN 网段库') }, _('云')));
		else if (r.source === 'asn')
			out.push(E('span', {
				'class': 'nm-tag nm-tag-asn',
				'title': _('来自 GeoLite2 ASN（主名仍为 IP）')
			}, r.asn_org ? String(r.asn_org).slice(0, 24) : 'ASN'));
		else if (r.unresolved)
			out.push(E('span', { 'class': 'nm-tag' }, _('未解析')));
		if (r.active) out.push(E('span', { 'class': 'nm-tag nm-tag-live' }, _('进行中')));
		/* Day picker already scopes the list; never show 「跨日」here. */
		return out;
	},

	rowCells: function(r, interval, opts) {
		opts = opts || {};
		var nameCell = [];
		if (opts.toggle) nameCell.push(opts.toggle);
		nameCell.push(E('span', { 'class': 'nm-detail-name' }, r.display));
		nameCell = nameCell.concat(this.tagsFor(r));
		return [
			E('td', { 'class': 'td' + (opts.child ? ' nm-detail-child-td' : '') }, nameCell),
			E('td', { 'class': 'td' }, topo.formatBytes(r.bytes_up)),
			E('td', { 'class': 'td' }, topo.formatBytes(r.bytes_down)),
			E('td', { 'class': 'td' }, topo.formatBytes(r.bytes_total)),
			E('td', { 'class': 'td' }, '约 ' + topo.formatClock(r.started_at)),
			E('td', { 'class': 'td' }, topo.formatDuration(r.duration, interval))
		];
	},

	renderTable: function(d) {
		var self = this;
		var interval = (this.status && this.status.interval) || 5;
		var rows = this.filteredRows(d);
		if (!rows.length) return E('div', { 'class': 'nm-topo-empty' }, _('当天没有会话记录'));

		var groups = this.sortGroups(this.groupSessions(rows));
		var body = [
			E('tr', { 'class': 'tr table-titles' }, [
				this.th(_('目标'), 'display'),
				this.th(_('上传'), 'bytes_up'),
				this.th(_('下载'), 'bytes_down'),
				this.th(_('合计'), 'bytes_total'),
				this.th(_('开始时间（约）'), 'started_at'),
				this.th(_('持续时长（约）'), 'duration')
			])
		];

		groups.forEach(function(g) {
			var multi = g.children.length > 1;
			var open = multi && !!self.expanded[g.key];
			var toggle = null;
			if (multi) {
				toggle = E('button', {
					'class': 'nm-detail-toggle',
					'type': 'button',
					'aria-expanded': open ? 'true' : 'false',
					'title': open ? _('收起') : _('展开'),
					'click': function(ev) {
						ev.preventDefault();
						ev.stopPropagation();
						if (self.expanded[g.key]) delete self.expanded[g.key];
						else self.expanded[g.key] = true;
						dom.content(self.tableBox, self.renderTable(d));
					}
				}, open ? '▾' : '▸');
			}

			var groupAttrs = {
				'class': 'tr' + (multi ? ' nm-detail-group' : '') + (open ? ' nm-detail-open' : '')
			};
			if (multi) {
				groupAttrs.click = function(ev) {
					var t = ev.target;
					while (t && t !== ev.currentTarget) {
						if (t.tagName === 'BUTTON') return;
						t = t.parentNode;
					}
					if (self.expanded[g.key]) delete self.expanded[g.key];
					else self.expanded[g.key] = true;
					dom.content(self.tableBox, self.renderTable(d));
				};
			}
			body.push(E('tr', groupAttrs, self.rowCells(g, interval, { toggle: toggle })));

			if (open) {
				g.children.forEach(function(c) {
					body.push(E('tr', { 'class': 'tr nm-detail-child' },
						self.rowCells(c, interval, { child: true })));
				});
			}
		});

		return E('table', { 'class': 'table nm-detail' }, body);
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
			var filterIn = E('input', {
				'class': 'cbi-input-text',
				'placeholder': _('筛选目标…'),
				'value': self.filter,
				'input': function(ev) {
					self.filter = ev.target.value;
					dom.content(self.tableBox, self.renderTable(d));
				}
			});
			this.tableBox = E('div', {}, this.renderTable(d));
			body = E('div', {}, [
				E('div', { 'class': 'nm-device-head' }, [
					E('strong', {}, dev.hostname || dev.ip || d.mac),
					E('span', {}, ' ' + (dev.ip || '') + ' · ' + d.mac)
				]),
				this.renderDayPicker(d),
				d.day ? E('div', { 'class': 'nm-capacity' }, _('%s 合计 %s（↑%s ↓%s）').format(d.day,
					topo.formatBytes(d.bytes_total || 0), topo.formatBytes(d.bytes_up || 0), topo.formatBytes(d.bytes_down || 0))) : '',
				E('div', { 'class': 'nm-toolbar' }, [ filterIn ]),
				this.tableBox,
				E('p', { 'class': 'nm-note' }, _('开始时间与时长根据采样推算（约），精度约为采样间隔 %d 秒；空闲超过 %d 秒视为新会话；本地 0 点会结清统计会话并重新计数（不断开真实连接）。同名目标已合并，可点击展开明细。')
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
