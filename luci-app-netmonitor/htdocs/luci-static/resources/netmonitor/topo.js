'use strict';
'require baseclass';

/* Pure layout and formatting helpers for the netmonitor views. No DOM
 * access beyond the rects passed in, so they can be unit-tested. */

var RANGE_LABELS = {
	'15m': '15分钟', '1h': '1小时', '6h': '6小时', 'today': '今天',
	'24h': '24小时', '7d': '7天', '30d': '30天', '90d': '90天', '1y': '1年'
};

function round1(v) {
	return Math.round(v * 10) / 10;
}

/* Center of a port element relative to the topology container. */
function portCenter(rect, containerRect) {
	return {
		x: round1(rect.left - containerRect.left + rect.width / 2),
		y: round1(rect.top - containerRect.top + rect.height / 2)
	};
}

/* Horizontal-tangent cubic curve from a to b (Magpie-style L-R edges). */
function edgePath(a, b) {
	var dx = Math.max(Math.abs(b.x - a.x) * 0.5, 24);
	return 'M' + a.x + ' ' + a.y +
		' C' + round1(a.x + dx) + ' ' + a.y +
		' ' + round1(b.x - dx) + ' ' + b.y +
		' ' + b.x + ' ' + b.y;
}

/* Parse the endpoints back out of an edgePath() string. */
function pathEndpoints(d) {
	var n = String(d).match(/-?\d+(\.\d+)?/g).map(Number);
	return { start: { x: n[0], y: n[1] }, end: { x: n[n.length - 2], y: n[n.length - 1] } };
}

/* Vertical offsets (px) for n port slots centred on a node edge. */
function slotOffsets(n, spacing) {
	var out = [], s = spacing || 8;
	for (var i = 0; i < n; i++)
		out.push((i - (n - 1) / 2) * s);
	return out;
}

/* Assign port slots: each node side gets one slot per incident path,
 * ordered to keep same-path legs aligned through the gateway. */
function assignSlots(topo) {
	var devIndex = {}, tgtIndex = {};
	(topo.nodes.devices || []).forEach(function(n, i) { devIndex[n.id] = i; });
	(topo.nodes.targets || []).forEach(function(n, i) { tgtIndex[n.id] = i; });

	var paths = (topo.paths || []).slice().sort(function(a, b) {
		return (devIndex[a.from] - devIndex[b.from]) || (tgtIndex[a.to] - tgtIndex[b.to]);
	});

	var slots = { gwIn: {}, gwOut: {}, out: {}, in: {} }, perDev = {}, perTgt = {};
	paths.forEach(function(p, i) {
		slots.gwIn[p.id] = i;
		slots.gwOut[p.id] = i;
		(perDev[p.from] = perDev[p.from] || []).push(p.id);
		(perTgt[p.to] = perTgt[p.to] || []).push(p.id);
	});
	Object.keys(perDev).forEach(function(id) {
		perDev[id].forEach(function(pid, i) { slots.out[pid] = i; });
	});
	Object.keys(perTgt).forEach(function(id) {
		perTgt[id].forEach(function(pid, i) { slots.in[pid] = i; });
	});
	return { order: paths.map(function(p) { return p.id; }), slots: slots, perDev: perDev, perTgt: perTgt };
}

function strokeWidth(weight) {
	return round1(1.5 + Math.max(0, Math.min(1, weight || 0)) * 4.5);
}

/* Heavier paths flow faster: 4s for the lightest down to 1s. */
function flowDuration(weight) {
	return round1(4 - Math.max(0, Math.min(1, weight || 0)) * 3);
}

function formatBytes(n) {
	n = Number(n) || 0;
	var units = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return (i === 0 ? n : n.toFixed(n >= 100 ? 0 : 1)) + ' ' + units[i];
}

function formatRate(bps) {
	return formatBytes(bps) + '/s';
}

function formatDuration(sec, interval) {
	sec = Math.max(0, Math.round(Number(sec) || 0));
	if (sec < (interval || 5)) return '约 <' + (interval || 5) + '秒';
	var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
	if (h) return '约 ' + h + '小时' + (m ? m + '分' : '');
	if (m) return '约 ' + m + '分' + (s ? s + '秒' : '');
	return '约 ' + s + '秒';
}

function formatClock(ts) {
	var d = new Date(ts * 1000);
	function p(v) { return (v < 10 ? '0' : '') + v; }
	return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function rangeLabel(key) {
	return RANGE_LABELS[key] || key;
}

/* Stable structure fingerprint for incremental overview updates (F14).
 * Node/path identity only — bytes/live changes do not remount the SVG shell. */
function topoStructureKey(t) {
	if (!t || t.error) return 'err:' + (t && t.error ? t.error : 'nil');
	if (!(t.paths && t.paths.length)) return 'empty';
	var d = (t.nodes && t.nodes.devices || []).map(function(n) { return n.id; });
	var g = (t.nodes && t.nodes.targets || []).map(function(n) { return n.id; });
	var p = t.paths.map(function(x) { return x.id; });
	return d.join(',') + '|' + g.join(',') + '|' + p.join(',');
}

function deviceListKey(d, showAll, softCap) {
	if (!d || d.error) return 'err:' + (d && d.error ? d.error : 'nil');
	var list = d.devices || [];
	var shown = showAll ? list : list.slice(0, softCap || 60);
	return shown.map(function(x) { return x.mac; }).join(',') + '|' + (showAll ? '1' : '0') + '|' + list.length;
}

return baseclass.extend({
	RANGE_LABELS: RANGE_LABELS,
	portCenter: portCenter,
	edgePath: edgePath,
	pathEndpoints: pathEndpoints,
	slotOffsets: slotOffsets,
	assignSlots: assignSlots,
	strokeWidth: strokeWidth,
	flowDuration: flowDuration,
	formatBytes: formatBytes,
	formatRate: formatRate,
	formatDuration: formatDuration,
	formatClock: formatClock,
	rangeLabel: rangeLabel,
	topoStructureKey: topoStructureKey,
	deviceListKey: deviceListKey
});
