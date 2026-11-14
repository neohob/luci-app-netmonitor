'use strict';
'require view';
'require poll';
'require dom';
'require netmonitor.common as nm';
'require netmonitor.topo as topo';

var SVGNS = 'http://www.w3.org/2000/svg';
var SLOT_SPACING = 7;
/* Soft-cap for dense grid (A5): beyond Top4 always listed; very long lists
 * get 「显示全部」 rather than hiding topology「其他」members silently. */
var GRID_SOFT_CAP = 60;

function deviceUrl(mac) {
	return L.url('admin/control/netmonitor/device') + '?mac=' + encodeURIComponent(mac);
}

function setText(el, text) {
	if (!el) return;
	var t = text == null ? '' : String(text);
	if (el.textContent !== t) el.textContent = t;
}

return view.extend({
	range: '1h',
	showAll: false,

	load: function() {
		nm.cssLink();
		return nm.callStatus().catch(function() { return null; });
	},

	fetchData: function() {
		var self = this;
		return Promise.all([
			nm.callStatus().catch(function() { return null; }),
			nm.callTopology(self.range).catch(function() { return null; }),
			nm.callDevices(self.range).catch(function() { return null; })
		]);
	},

	pickRange: function(st) {
		var allowed = (st && st.allowed_ranges) || [ '1h' ];
		if (allowed.indexOf(this.range) < 0)
			this.range = allowed.indexOf('1h') >= 0 ? '1h' : allowed[allowed.length - 1];
	},

	renderChips: function(st) {
		var self = this;
		var allowed = (st && st.allowed_ranges) || [];
		return E('div', { 'class': 'nm-chips' }, allowed.map(function(key) {
			return E('button', {
				'class': 'nm-chip' + (key === self.range ? ' active' : ''),
				'click': function() { self.range = key; self.refresh(); }
			}, [ _(topo.rangeLabel(key)) ]);
		}));
	},

	renderCapacity: function(st, t) {
		var parts = [];
		if (t && t.storage) {
			parts.push(_('本范围约 %s 条记录，约占 %s').format(t.storage.range_rows, topo.formatBytes(t.storage.range_bytes)));
		}
		if (st && st.db_bytes != null) parts.push(_('数据库 %s').format(topo.formatBytes(st.db_bytes)));
		if (st && st.disk && st.disk.free != null) parts.push(_('剩余空间 %s').format(topo.formatBytes(st.disk.free)));
		if (st && st.retention_value) {
			var ul = (nm.UNIT_LABELS && nm.UNIT_LABELS[st.retention_unit]) || st.retention_unit;
			parts.push(_('保留 %s %s').format(st.retention_value, _(ul)));
		}
		return E('div', { 'class': 'nm-capacity' }, parts.join(' · '));
	},

	nodeCard: function(n, side, slotCount) {
		var cls = 'nm-node nm-node-' + side + (n.live ? ' live' : '') +
			(n.kind && n.kind.indexOf('other') === 0 ? ' other' : '');
		var label = n.label;
		var sub = '';
		var tags = [];
		if (n.kind === 'other_devices' || n.kind === 'other_targets')
			sub = _('%d 个').format(n.members);
		else if (n.kind === 'device')
			sub = n.ip || n.mac || '';
		else if (n.kind === 'target' && n.unresolved)
			sub = _('未解析');
		else if (n.kind === 'target' && n.source === 'sni')
			tags.push(E('span', { 'class': 'nm-tag nm-tag-sni', 'title': _('来自 TLS ClientHello SNI') }, 'SNI'));
		else if (n.kind === 'target' && n.source === 'http_host')
			tags.push(E('span', { 'class': 'nm-tag nm-tag-sni', 'title': _('来自 HTTP Host') }, 'Host'));
		else if (n.kind === 'target' && n.source === 'asn')
			tags.push(E('span', { 'class': 'nm-tag nm-tag-asn', 'title': _('来自 GeoLite2 ASN 组织名') }, 'ASN'));

		var ports = [];
		var offs = topo.slotOffsets(slotCount, SLOT_SPACING);
		for (var i = 0; i < slotCount; i++) {
			ports.push(E('span', {
				'class': 'nm-port nm-port-' + (side === 'left' ? 'out' : 'in'),
				'data-slot': i,
				'style': 'top:calc(50% + ' + offs[i] + 'px)'
			}));
		}

		var attrs = { 'class': cls, 'data-node': n.id, 'style': 'min-height:' + Math.max(48, slotCount * SLOT_SPACING + 16) + 'px' };
		if (n.kind === 'device') {
			attrs.click = function() { location.href = deviceUrl(n.mac); };
			attrs.title = _('查看设备明细');
		}
		var bytesTxt = (n.bytes_up != null || n.bytes_down != null)
			? topo.formatUpDown(n.bytes_up, n.bytes_down)
			: topo.formatBytes(n.bytes_total);
		return E('div', attrs, [
			E('div', { 'class': 'nm-node-label' }, [
				E('span', { 'class': 'nm-live-dot ' + (n.live ? 'nm-pulse' : 'nm-idle') }),
				E('span', { 'class': 'nm-label-text' }, label)
			].concat(tags)),
			E('div', { 'class': 'nm-node-sub' }, sub),
			E('div', { 'class': 'nm-node-bytes' }, bytesTxt)
		].concat(ports));
	},

	buildTopologyDom: function(t) {
		var layout = topo.assignSlots(t);
		var self = this;
		var left = E('div', { 'class': 'nm-col nm-col-left' }, t.nodes.devices.map(function(n) {
			return self.nodeCard(n, 'left', (layout.perDev[n.id] || []).length);
		}));
		var right = E('div', { 'class': 'nm-col nm-col-right' }, t.nodes.targets.map(function(n) {
			return self.nodeCard(n, 'right', (layout.perTgt[n.id] || []).length);
		}));
		var gwPorts = [], offs = topo.slotOffsets(layout.order.length, SLOT_SPACING);
		layout.order.forEach(function(pid, i) {
			gwPorts.push(E('span', { 'class': 'nm-port nm-port-in', 'data-slot': i, 'style': 'top:calc(50% + ' + offs[i] + 'px)' }));
			gwPorts.push(E('span', { 'class': 'nm-port nm-port-out', 'data-slot': i, 'style': 'top:calc(50% + ' + offs[i] + 'px)' }));
		});
		var gw = E('div', { 'class': 'nm-col nm-col-center' }, [
			E('div', { 'class': 'nm-node nm-gateway', 'data-node': 'gw',
				'style': 'min-height:' + Math.max(64, layout.order.length * SLOT_SPACING + 24) + 'px' }, [
				E('div', { 'class': 'nm-node-label' }, t.gateway.label),
				E('div', { 'class': 'nm-node-bytes' }, topo.formatBytes(t.bytes_total))
			].concat(gwPorts))
		]);
		var svg = document.createElementNS(SVGNS, 'svg');
		svg.setAttribute('class', 'nm-edges');
		var box = E('div', { 'class': 'nm-topo' }, [ svg, left, gw, right ]);
		this.topoState = { box: box, svg: svg, data: t, layout: layout, edgeKey: null };
		return box;
	},

	/* Patch live/bytes on an existing topology without remounting SVG (F14). */
	patchTopology: function(t) {
		var s = this.topoState;
		if (!s || !s.box || !s.box.isConnected) return false;
		s.data = t;
		s.layout = topo.assignSlots(t);
		var byId = {};
		(t.nodes.devices || []).forEach(function(n) { byId[n.id] = n; });
		(t.nodes.targets || []).forEach(function(n) { byId[n.id] = n; });
		s.box.querySelectorAll('[data-node]').forEach(function(el) {
			var id = el.getAttribute('data-node');
			if (id === 'gw') {
				setText(el.querySelector('.nm-node-bytes'), topo.formatBytes(t.bytes_total));
				return;
			}
			var n = byId[id];
			if (!n) return;
			el.classList.toggle('live', !!n.live);
			var dot = el.querySelector('.nm-live-dot');
			if (dot) {
				dot.classList.toggle('nm-pulse', !!n.live);
				dot.classList.toggle('nm-idle', !n.live);
			}
			setText(el.querySelector('.nm-label-text'), n.label);
			setText(el.querySelector('.nm-node-bytes'),
				(n.bytes_up != null || n.bytes_down != null)
					? topo.formatUpDown(n.bytes_up, n.bytes_down)
					: topo.formatBytes(n.bytes_total));
			if (n.kind === 'other_devices' || n.kind === 'other_targets')
				setText(el.querySelector('.nm-node-sub'), _('%d 个').format(n.members));
		});
		this.drawEdges(false);
		return true;
	},

	renderTopology: function(t) {
		if (!t || t.error) {
			this.topoState = null;
			this.lastTopoKey = null;
			return E('div', { 'class': 'nm-topo-empty' }, t && t.error ? nm.errorText(t.error) : _('暂无数据'));
		}
		if (!t.paths.length) {
			this.topoState = null;
			this.lastTopoKey = null;
			return E('div', { 'class': 'nm-topo-empty' }, _('所选时间范围内暂无流量记录'));
		}
		return this.buildTopologyDom(t);
	},

	/* Dock using server `edges`; reuse path nodes when edge set unchanged (F14). */
	drawEdges: function(forceRebuild) {
		var s = this.topoState;
		if (!s || !s.box.isConnected) return;
		var cr = s.box.getBoundingClientRect();
		var svg = s.svg;
		svg.setAttribute('width', cr.width);
		svg.setAttribute('height', cr.height);

		function port(nodeId, dir, slot) {
			var el = s.box.querySelector('[data-node="' + nodeId.replace(/"/g, '\\"') + '"] .nm-port-' + dir + '[data-slot="' + slot + '"]');
			return el ? topo.portCenter(el.getBoundingClientRect(), cr) : null;
		}

		var edges = s.data.edges || [];
		var edgeKey = edges.map(function(e) { return e.id; }).join(',');
		var canPatch = !forceRebuild && s.edgeKey === edgeKey && svg.childNodes.length === edges.length;

		if (!canPatch) {
			while (svg.firstChild) svg.removeChild(svg.firstChild);
			s.edgeKey = edgeKey;
		}

		edges.forEach(function(e) {
			var pid = e.path, a, b, leg;
			if (e.to === 'gw') {
				a = port(e.from, 'out', s.layout.slots.out[pid]);
				b = port('gw', 'in', s.layout.slots.gwIn[pid]);
				leg = 'in';
			}
			else {
				a = port('gw', 'out', s.layout.slots.gwOut[pid]);
				b = port(e.to, 'in', s.layout.slots['in'][pid]);
				leg = 'out';
			}
			if (!a || !b) return;
			var d = topo.edgePath(a, b);
			var path = canPatch
				? svg.querySelector('[data-path="' + pid.replace(/"/g, '\\"') + '"][data-leg="' + leg + '"]')
				: null;
			if (!path) {
				path = document.createElementNS(SVGNS, 'path');
				path.setAttribute('data-path', pid);
				path.setAttribute('data-leg', leg);
				var title = document.createElementNS(SVGNS, 'title');
				path.appendChild(title);
				svg.appendChild(path);
			}
			path.setAttribute('d', d);
			path.setAttribute('class', 'nm-edge' + (e.live ? ' live' : ''));
			path.setAttribute('stroke', e.color);
			path.setAttribute('stroke-width', topo.strokeWidth(e.weight));
			var dur = topo.flowDuration(e.weight) + 's';
			if (path.style.animationDuration !== dur)
				path.style.animationDuration = dur;
			var titleEl = path.querySelector('title');
			if (titleEl) titleEl.textContent = topo.formatEdgeTip(e);
		});
	},

	deviceCell: function(dev) {
		return E('div', {
			'class': 'nm-cell' + (dev.live ? ' live' : ''),
			'data-mac': dev.mac,
			'click': function() { location.href = deviceUrl(dev.mac); },
			'title': dev.mac
		}, [
			E('div', { 'class': 'nm-cell-head' }, [
				E('span', { 'class': 'nm-live-dot ' + (dev.live ? 'nm-pulse' : 'nm-idle') }),
				E('span', { 'class': 'nm-cell-name' }, dev.label)
			]),
			E('div', { 'class': 'nm-cell-ip' }, dev.ip || dev.mac),
			E('div', { 'class': 'nm-cell-bytes' }, topo.formatUpDown(dev.bytes_up, dev.bytes_down)),
			E('div', { 'class': 'nm-cell-total' }, topo.formatBytes(dev.bytes_total)),
			E('div', { 'class': 'nm-cell-sub' }, dev.live
				? '↑' + topo.formatRate(dev.rate_up) + ' ↓' + topo.formatRate(dev.rate_down)
				: ''),
			E('div', { 'class': 'nm-cell-top' }, dev.top_target || '')
		]);
	},

	patchGrid: function(d) {
		var root = this.gridRoot;
		if (!root || !root.isConnected) return false;
		var byMac = {};
		(d.devices || []).forEach(function(dev) { byMac[dev.mac] = dev; });
		root.querySelectorAll('.nm-cell[data-mac]').forEach(function(el) {
			var dev = byMac[el.getAttribute('data-mac')];
			if (!dev) return;
			el.classList.toggle('live', !!dev.live);
			var dot = el.querySelector('.nm-live-dot');
			if (dot) {
				dot.classList.toggle('nm-pulse', !!dev.live);
				dot.classList.toggle('nm-idle', !dev.live);
			}
			setText(el.querySelector('.nm-cell-name'), dev.label);
			setText(el.querySelector('.nm-cell-ip'), dev.ip || dev.mac);
			setText(el.querySelector('.nm-cell-bytes'), topo.formatUpDown(dev.bytes_up, dev.bytes_down));
			setText(el.querySelector('.nm-cell-total'), topo.formatBytes(dev.bytes_total));
			setText(el.querySelector('.nm-cell-sub'), dev.live
				? '↑' + topo.formatRate(dev.rate_up) + ' ↓' + topo.formatRate(dev.rate_down)
				: '');
			setText(el.querySelector('.nm-cell-top'), dev.top_target || '');
		});
		return true;
	},

	renderGrid: function(d) {
		var self = this;
		this.gridRoot = null;
		if (!d || d.error) return E('div', { 'class': 'nm-topo-empty' }, d && d.error ? nm.errorText(d.error) : '');
		var list = d.devices || [];
		if (!list.length) return E('div', { 'class': 'nm-topo-empty' }, _('暂无设备'));
		var shown = self.showAll ? list : list.slice(0, GRID_SOFT_CAP);
		var grid = E('div', { 'class': 'nm-grid' }, shown.map(function(dev) {
			return self.deviceCell(dev);
		}));
		this.gridRoot = grid;
		var out = [ grid ];
		if (list.length > shown.length) {
			out.push(E('button', { 'class': 'cbi-button nm-showall', 'click': function() {
				self.showAll = true; self.lastGridKey = null; self.refresh();
			} }, _('显示全部（共 %d 台）').format(list.length)));
		}
		return E('div', {}, out);
	},

	/* F14: sticky shell; remount topo/grid only when structure (ids) changes. */
	ensureShell: function() {
		if (this.shellReady) return;
		this.bannerBox = E('div', { 'class': 'nm-banners' });
		this.chipBox = E('div');
		this.capBox = E('div');
		this.toolbarBox = E('div', { 'class': 'nm-toolbar' }, [ this.chipBox, this.capBox ]);
		this.topoHost = E('div');
		this.gridHost = E('div');
		dom.content(this.root, [
			this.bannerBox,
			this.toolbarBox,
			E('h3', {}, _('流量拓扑')),
			this.topoHost,
			E('h3', {}, _('全部设备')),
			this.gridHost
		]);
		this.shellReady = true;
	},

	updateTopology: function(t) {
		var key = topo.topoStructureKey(t);
		if (key === this.lastTopoKey && this.topoState && this.topoState.box && this.topoState.box.isConnected) {
			this.patchTopology(t);
			return;
		}
		this.lastTopoKey = key;
		dom.content(this.topoHost, this.renderTopology(t));
		var self = this;
		window.requestAnimationFrame(function() { self.drawEdges(true); });
	},

	updateGrid: function(d) {
		var key = topo.deviceListKey(d, this.showAll, GRID_SOFT_CAP);
		if (key === this.lastGridKey && this.gridRoot && this.gridRoot.isConnected) {
			this.patchGrid(d);
			return;
		}
		this.lastGridKey = key;
		dom.content(this.gridHost, this.renderGrid(d));
	},

	update: function(res) {
		var st = res[0], t = res[1], d = res[2];
		this.pickRange(st);
		this.ensureShell();
		dom.content(this.bannerBox, nm.statusBanners(st));
		if (this.lastChipRange !== this.range || this.lastAllowed !== JSON.stringify((st && st.allowed_ranges) || [])) {
			dom.content(this.chipBox, this.renderChips(st));
			this.lastChipRange = this.range;
			this.lastAllowed = JSON.stringify((st && st.allowed_ranges) || []);
		}
		dom.content(this.capBox, this.renderCapacity(st, t));
		this.updateTopology(t);
		this.updateGrid(d);
	},

	refresh: function() {
		var self = this;
		return this.fetchData().then(function(res) { self.update(res); });
	},

	render: function(st) {
		var self = this;
		this.pickRange(st);
		this.root = E('div', { 'class': 'nm-root' }, E('p', { 'class': 'spinning' }, _('加载中…')));
		window.addEventListener('resize', function() { self.drawEdges(false); });
		this.refresh();
		poll.add(function() { return self.refresh(); }, Math.max(5, (st && st.interval) || 5));
		return E('div', {}, [
			E('h2', {}, _('流量监控')),
			this.root
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
