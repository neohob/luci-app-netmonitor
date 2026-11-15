'use strict';
'require view';
'require dom';
'require ui';
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

/* Browser-local fallback only; prefer router keys from status (F4). */
function todayKeyBrowser() {
	var t = new Date();
	return t.getFullYear() + '-' + pad2(t.getMonth() + 1) + '-' + pad2(t.getDate());
}

function currentMonthKeyBrowser() {
	var t = new Date();
	return t.getFullYear() + '-' + pad2(t.getMonth() + 1);
}

/* Clamp day to router's current calendar month. routerToday/routerMonth from status. */
function clampDayToRouterMonth(day, routerToday, routerMonth) {
	var today = routerToday || todayKeyBrowser();
	var curM = routerMonth || (today && String(today).slice(0, 7)) || currentMonthKeyBrowser();
	if (!day || String(day).slice(0, 7) !== curM) return today;
	return day;
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
	pageSize: 80,
	offset: 0,
	loadingMore: false,
	expanded: null,
	calOpen: false,
	calYear: null,
	calMonth: null,
	pastOpen: false,
	pastMonths: null,
	pastMonth: null,
	pastSummary: null,
	pastLoading: false,

	apiSort: function() {
		var k = this.sortKey;
		if (k === 'display') return 'target';
		if (k === 'started_at') return 'time';
		if (k === 'bytes_up') return 'up';
		if (k === 'bytes_down') return 'down';
		if (k === 'duration') return 'duration';
		return 'traffic';
	},

	fetchDetail: function(offset, childrenOf) {
		return nm.callDetail(this.mac, this.day, this.apiSort(), this.pageSize, offset || 0,
			this.filter || '', childrenOf || '');
	},

	load: function() {
		nm.cssLink();
		this.mac = param('mac');
		this.day = param('day') || null;
		this.expanded = {};
		this.offset = 0;
		this.pastOpen = false;
		this.pastMonths = null;
		this.pastMonth = null;
		this.pastSummary = null;
		var self = this;
		/* Fetch status first so calendar clamp uses router clock (F4). */
		return nm.callStatus().catch(function() { return null; }).then(function(st) {
			self.status = st;
			self.routerToday = (st && st.today) || todayKeyBrowser();
			self.routerMonth = (st && st.current_month) || String(self.routerToday).slice(0, 7);
			self.day = clampDayToRouterMonth(self.day, self.routerToday, self.routerMonth);
			var t = parseDayKey(self.day) || parseDayKey(self.routerToday);
			self.calYear = t.y;
			self.calMonth = t.m;
			if (!self.mac) return [ st, null ];
			return self.fetchDetail(0).catch(function() { return null; }).then(function(d) {
				return [ st, d ];
			});
		});
	},

	loadPastMonths: function() {
		var self = this;
		if (!self.mac) return Promise.resolve();
		self.pastLoading = true;
		self.update();
		return nm.callDeviceMonths(self.mac).catch(function() { return null; }).then(function(r) {
			self.pastLoading = false;
			self.pastMonths = (r && r.months) || [];
			if (!self.pastMonth && self.pastMonths.length)
				self.pastMonth = self.pastMonths[0];
			self.update();
			if (self.pastMonth)
				return self.loadPastSummary(self.pastMonth);
		});
	},

	loadPastSummary: function(month) {
		var self = this;
		if (!self.mac || !month) return Promise.resolve();
		self.pastMonth = month;
		self.pastLoading = true;
		self.update();
		return nm.callDeviceMonthSummary(self.mac, month).catch(function() { return null; }).then(function(r) {
			self.pastLoading = false;
			self.pastSummary = r;
			self.update();
		});
	},

	reload: function() {
		var self = this;
		this.offset = 0;
		this.expanded = {};
		return this.fetchDetail(0).catch(function() { return null; }).then(function(d) {
			self.data = d;
			self.update();
		});
	},

	loadMore: function() {
		var self = this;
		if (self.loadingMore || !self.data || !self.data.has_more) return Promise.resolve();
		self.loadingMore = true;
		self.update();
		var next = num(self.data.offset) + num(self.data.limit || self.pageSize);
		return self.fetchDetail(next).catch(function() { return null; }).then(function(d) {
			self.loadingMore = false;
			if (!d || d.error) {
				self.update();
				return;
			}
			var prev = self.data.sessions || [];
			var keepExpanded = self.expanded || {};
			self.data = d;
			self.data.sessions = prev.concat(d.sessions || []);
			self.data.has_more = !!d.has_more;
			self.expanded = keepExpanded;
			self.offset = next;
			self.update();
		});
	},

	/* Paged rows are full day aggregates per destination; expand loads each
	   timed session for that destination so start time matches bytes. */
	ensureChildren: function(display) {
		var self = this;
		var key = String(display || '');
		if (!key || !self.data || !self.data.paged) return Promise.resolve();
		var row = null;
		(self.data.sessions || []).forEach(function(r) {
			if (!row && String(r.display) === key) row = r;
		});
		if (!row || (row.children && row.children.length)) return Promise.resolve();
		if (row._loadingChildren) return row._loadingChildren;
		row._loadingChildren = self.fetchDetail(0, key).catch(function() { return null; }).then(function(d) {
			row._loadingChildren = null;
			if (!d || d.error) return;
			row.children = d.sessions || [];
			if (self.tableBox && self.data)
				dom.content(self.tableBox, self.renderTable(self.data));
		});
		return row._loadingChildren;
	},

	closeCalendar: function() {
		if (!this.calOpen) return;
		this.calOpen = false;
		this.update();
	},

	renderDayPicker: function(d) {
		var self = this;
		var routerToday = self.routerToday || (self.status && self.status.today) || todayKeyBrowser();
		var selected = d.day || self.day || routerToday;
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

		/* Lock picker to router current calendar month (detail retention, F4). */
		var cur = parseDayKey(routerToday);
		self.calYear = cur.y;
		self.calMonth = cur.m;
		var y = self.calYear, m = self.calMonth;
		var first = new Date(y, m - 1, 1);
		var startPad = first.getDay(); /* 0=Sun */
		var daysInMonth = new Date(y, m, 0).getDate();
		var today = routerToday;
		var weekdays = [ _('日'), _('一'), _('二'), _('三'), _('四'), _('五'), _('六') ];

		var head = E('div', { 'class': 'nm-cal-head' }, [
			E('span', { 'class': 'nm-cal-title' }, y + '-' + pad2(m) + '（' + _('当月明细') + '）'),
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

	renderPastMonths: function() {
		var self = this;
		var toggle = E('button', {
			'class': 'cbi-button',
			'type': 'button',
			'click': ui.createHandlerFn(self, function() {
				self.pastOpen = !self.pastOpen;
				if (self.pastOpen && !self.pastMonths)
					return self.loadPastMonths();
				self.update();
			})
		}, self.pastOpen ? _('收起往月汇总') : _('往月汇总'));

		if (!self.pastOpen)
			return E('div', { 'class': 'nm-toolbar', 'style': 'margin: 8px 0;' }, [ toggle ]);

		var body = [ toggle ];
		if (self.pastLoading)
			body.push(E('p', { 'class': 'nm-note' }, _('加载中…')));
		else if (!self.pastMonths || !self.pastMonths.length)
			body.push(E('p', { 'class': 'nm-note' }, _('暂无往月汇总（跨月后会自动生成 Top100）')));
		else {
			var opts = self.pastMonths.map(function(m) {
				return E('option', {
					'value': m,
					'selected': m === self.pastMonth ? '' : null
				}, m);
			});
			var sel = E('select', {
				'class': 'cbi-input-select',
				'change': function(ev) {
					self.loadPastSummary(ev.target.value);
				}
			}, opts);
			body.push(E('div', { 'class': 'nm-toolbar' }, [
				E('label', {}, _('选择月份') + ' '), sel
			]));
			var sum = self.pastSummary;
			if (sum && sum.error) {
				body.push(E('p', { 'class': 'nm-note' }, nm.errorText(sum.error)));
			}
			else if (sum && sum.rows) {
				body.push(E('div', { 'class': 'nm-capacity' },
					_('%s 合计 %s（↑%s ↓%s）；往月仅 Top100 +「其他」，无分时会话')
						.format(sum.month || self.pastMonth,
							topo.formatBytes(sum.bytes_total || 0),
							topo.formatBytes(sum.bytes_up || 0),
							topo.formatBytes(sum.bytes_down || 0))));
				var rows = [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('目标')),
						E('th', { 'class': 'th' }, _('上传')),
						E('th', { 'class': 'th' }, _('下载')),
						E('th', { 'class': 'th' }, _('合计'))
					])
				];
				(sum.rows || []).forEach(function(r) {
					rows.push(E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, r.display || r.target),
						E('td', { 'class': 'td' }, topo.formatBytes(r.bytes_up)),
						E('td', { 'class': 'td' }, topo.formatBytes(r.bytes_down)),
						E('td', { 'class': 'td' }, topo.formatBytes(r.bytes_total))
					]));
				});
				body.push(E('table', { 'class': 'table nm-detail' }, rows));
			}
		}
		return E('div', { 'class': 'nm-past-months', 'style': 'margin: 12px 0;' }, body);
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
		/* Server already applies q when paged; still filter client-side for small days. */
		if (d.paged) return d.sessions || [];
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
		if (this.data && this.data.paged)
			this.reload();
		else if (this.tableBox && this.data)
			dom.content(this.tableBox, this.renderTable(this.data));
	},

	onFilterInput: function(ev) {
		var self = this;
		self.filter = ev.target.value;
		if (self.filterTimer) window.clearTimeout(self.filterTimer);
		if (self.data && self.data.paged) {
			self.filterTimer = window.setTimeout(function() { self.reload(); }, 300);
			return;
		}
		if (self.tableBox && self.data)
			dom.content(self.tableBox, self.renderTable(self.data));
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
		if (!rows.length) {
			return E('div', {}, [
				E('div', { 'class': 'nm-topo-empty' }, _('当天没有会话记录'))
			]);
		}

		var groups = d.paged ? this.groupSessions(rows) : this.sortGroups(this.groupSessions(rows));
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
			var canExpand = num(g.session_count) > 1 || g.children.length > 1;
			var open = canExpand && !!self.expanded[g.key];
			var toggle = null;
			var toggleExpand = function() {
				if (self.expanded[g.key]) {
					delete self.expanded[g.key];
					dom.content(self.tableBox, self.renderTable(d));
					return;
				}
				self.expanded[g.key] = true;
				dom.content(self.tableBox, self.renderTable(d));
				if (d.paged && !(g.children && g.children.length))
					self.ensureChildren(g.display);
			};
			if (canExpand) {
				toggle = E('button', {
					'class': 'nm-detail-toggle',
					'type': 'button',
					'aria-expanded': open ? 'true' : 'false',
					'title': open ? _('收起') : _('展开分时会话'),
					'click': function(ev) {
						ev.preventDefault();
						ev.stopPropagation();
						toggleExpand();
					}
				}, open ? '▾' : '▸');
			}

			var groupAttrs = {
				'class': 'tr' + (canExpand ? ' nm-detail-group' : '') + (open ? ' nm-detail-open' : '')
			};
			if (canExpand) {
				groupAttrs.click = function(ev) {
					var t = ev.target;
					while (t && t !== ev.currentTarget) {
						if (t.tagName === 'BUTTON') return;
						t = t.parentNode;
					}
					toggleExpand();
				};
			}
			body.push(E('tr', groupAttrs, self.rowCells(g, interval, { toggle: toggle })));

			if (open) {
				if (g.children && g.children.length) {
					g.children.forEach(function(c) {
						body.push(E('tr', { 'class': 'tr nm-detail-child' },
							self.rowCells(c, interval, { child: true })));
					});
				}
				else {
					body.push(E('tr', { 'class': 'tr nm-detail-child' }, [
						E('td', { 'class': 'td', 'colspan': '6' }, _('正在加载该目的地的分时会话…'))
					]));
				}
			}
		});

		var wrap = [ E('table', { 'class': 'table nm-detail' }, body) ];
		if (d.paged) {
			wrap.push(E('p', { 'class': 'nm-note' },
				_('已显示 %d 个目的地（每个目的地为当天完整合计；会话共 %d 条）')
					.format(groups.length, num(d.session_count))));
		}
		return E('div', {}, wrap);
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
				'input': function(ev) { self.onFilterInput(ev); }
			});
			this.tableBox = E('div', {}, this.renderTable(d));
			var moreBar = '';
			if (d.has_more) {
				moreBar = E('div', { 'class': 'nm-toolbar', 'style': 'margin: 12px 0;' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'type': 'button',
						'disabled': self.loadingMore ? 'disabled' : null,
						'click': ui.createHandlerFn(self, self.loadMore)
					}, self.loadingMore
						? _('加载中…')
						: _('加载更多目的地（每页 %d 个，每个为当天完整合计）').format(num(d.limit) || self.pageSize))
				]);
			}
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
				moreBar,
				this.renderPastMonths(),
				E('p', { 'class': 'nm-note' }, _('明细仅保留当月日历天；往月见下方「往月汇总」（每设备 Top100 +「其他」）。开始时间与时长根据采样推算（约），精度约为采样间隔 %d 秒；空闲超过 %d 秒视为新会话；本地 0 点会结清统计会话并重新计数（不断开真实连接）。')
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
