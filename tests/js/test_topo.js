'use strict';
/* W17: port center math + edgePath endpoints dock ±1px (host Node, no LuCI). */

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const SRC = path.join(ROOT, 'luci-app-netmonitor/htdocs/luci-static/resources/netmonitor/topo.js');

function loadTopo() {
	let src = fs.readFileSync(SRC, 'utf8');
	src = src.replace(/^'use strict';\s*/, '');
	src = src.replace(/^'require baseclass';\s*/, '');
	src = src.replace(/return baseclass\.extend\(\{([\s\S]*)\}\);\s*$/,
		'module.exports = {$1};');
	const mod = { exports: {} };
	const fn = new Function('module', 'exports', src);
	fn(mod, mod.exports);
	return mod.exports;
}

const topo = loadTopo();
let pass = 0, fail = 0;

function check(name, cond, detail) {
	if (cond) {
		console.log('PASS ' + name);
		pass++;
	} else {
		console.log('FAIL ' + name + (detail ? ' — ' + detail : ''));
		fail++;
	}
}

function almost(a, b, tol) {
	return Math.abs(a - b) <= (tol == null ? 1 : tol);
}

/* Synthetic measured rects: container at (100,50), port at (140,90) size 6x6. */
const containerRect = { left: 100, top: 50, width: 800, height: 400 };
const portRect = { left: 140, top: 90, width: 6, height: 6 };
const center = topo.portCenter(portRect, containerRect);
check('W17a portCenter x', almost(center.x, 43, 1), 'got ' + center.x + ' expected 43');
check('W17b portCenter y', almost(center.y, 43, 1), 'got ' + center.y + ' expected 43');

const a = { x: 10.3, y: 20.7 };
const b = { x: 210.1, y: 80.2 };
const d = topo.edgePath(a, b);
const ends = topo.pathEndpoints(d);
check('W17c edgePath start docks ±1px',
	almost(ends.start.x, a.x, 1) && almost(ends.start.y, a.y, 1),
	JSON.stringify(ends.start));
check('W17d edgePath end docks ±1px',
	almost(ends.end.x, b.x, 1) && almost(ends.end.y, b.y, 1),
	JSON.stringify(ends.end));

const slots = topo.slotOffsets(3, 8);
check('W17e slotOffsets centered', slots[0] === -8 && slots[1] === 0 && slots[2] === 8,
	JSON.stringify(slots));

const fakeTopo = {
	nodes: {
		devices: [{ id: 'd:m1' }, { id: 'd:m2' }],
		targets: [{ id: 't:a' }, { id: 't:b' }]
	},
	paths: [
		{ id: 'd:m1>t:a', from: 'd:m1', to: 't:a' },
		{ id: 'd:m1>t:b', from: 'd:m1', to: 't:b' },
		{ id: 'd:m2>t:a', from: 'd:m2', to: 't:a' }
	]
};
const layout = topo.assignSlots(fakeTopo);
check('W17f assignSlots fan-out slots',
	layout.slots.out['d:m1>t:a'] === 0 && layout.slots.out['d:m1>t:b'] === 1,
	JSON.stringify(layout.slots.out));

/* F14: structure key ignores byte/live churn; remount only on id set change. */
const t1 = {
	nodes: { devices: [{ id: 'd:m1' }], targets: [{ id: 't:a' }] },
	paths: [{ id: 'd:m1>t:a', bytes_total: 10, live: false }]
};
const t2 = {
	nodes: { devices: [{ id: 'd:m1' }], targets: [{ id: 't:a' }] },
	paths: [{ id: 'd:m1>t:a', bytes_total: 999, live: true }]
};
const t3 = {
	nodes: { devices: [{ id: 'd:m1' }, { id: 'd:m2' }], targets: [{ id: 't:a' }] },
	paths: [{ id: 'd:m1>t:a' }, { id: 'd:m2>t:a' }]
};
check('W17g topoStructureKey stable on live/bytes',
	topo.topoStructureKey(t1) === topo.topoStructureKey(t2),
	topo.topoStructureKey(t1) + ' vs ' + topo.topoStructureKey(t2));
check('W17h topoStructureKey changes on new node',
	topo.topoStructureKey(t1) !== topo.topoStructureKey(t3),
	topo.topoStructureKey(t3));
const dlist = { devices: [{ mac: 'aa:bb:cc:00:00:01' }, { mac: 'aa:bb:cc:00:00:02' }] };
check('W17i deviceListKey',
	topo.deviceListKey(dlist, false, 60) === 'aa:bb:cc:00:00:01,aa:bb:cc:00:00:02|0|2',
	topo.deviceListKey(dlist, false, 60));

console.log('W17 ' + (fail === 0 ? 'PASS' : 'FAIL') + ' — port center / edgePath dock ±1px + F14 keys');
console.log('js: ' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
