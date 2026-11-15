-- W10–W16: ubus payloads (topology collapse, colors, device list, live, ACL, range limits).
local H = require 'helper'
local api = require 'netmonitor.api'
local topology = require 'netmonitor.topology'
local live = require 'netmonitor.live'
local collector = require 'netmonitor.collector'
local json = require 'netmonitor.json'

local function mac(i) return string.format('aa:bb:cc:00:01:%02x', i) end

-- n devices x m targets; device i -> target j bytes scale with (n-i+1)*(m-j+1).
local function grid_db(n, m, now, extra)
	local dir, file = H.new_db()
	local samples, devices, targets = {}, {}, {}
	for i = 1, n do
		devices[#devices + 1] = { mac = mac(i), ip = '192.168.1.' .. (100 + i), hostname = 'host' .. i,
			first_seen = now - 600, last_seen = now - 10 }
		for j = 1, m do
			samples[#samples + 1] = { mac(i), 'site' .. j .. '.com', now - 300, (n - i + 1) * (m - j + 1) * 1000, 0 }
		end
	end
	for j = 1, m do targets[#targets + 1] = { key = 'site' .. j .. '.com' } end
	for _, s in ipairs(extra or {}) do samples[#samples + 1] = s end
	H.seed(file, samples, devices, targets)
	return dir, file
end

local function env_for(dir, file, now, over)
	local e = { cfg = H.cfg({ db_path = dir }), now = now, rundir = dir, db_file = file,
		uci_get = function() return nil end }
	for k, v in pairs(over or {}) do e[k] = v end
	return e
end

local function find(list, pred)
	for _, x in ipairs(list) do if pred(x) then return x end end
end

H.case('W10', '10 devices / 10 targets, range=1h -> Top4 + 其他 on each side with collapse edges', function()
	local now = os.time()
	local dir, file = grid_db(10, 10, now)
	local t = api.call('topology', { range = '1h' }, env_for(dir, file, now))
	H.ok(not t.error, 'error: ' .. tostring(t.error) .. ' ' .. tostring(t.detail))
	H.eq(#t.nodes.devices, 5, 'device nodes')
	H.eq(#t.nodes.targets, 5, 'target nodes')
	for i = 1, 4 do H.eq(t.nodes.devices[i].mac, mac(i), 'top device ' .. i) end
	H.eq(t.nodes.devices[5].id, 'd:other', 'other devices node')
	H.eq(t.nodes.devices[5].label, '其他设备', 'other devices label')
	H.eq(t.nodes.devices[5].members, 6, 'six collapsed devices')
	H.eq(t.nodes.targets[5].id, 't:other', 'other targets node')
	H.eq(t.nodes.targets[5].label, '其他去向', 'other targets label')
	H.eq(#t.paths, 25, '5x5 logical paths after collapse')
	H.ok(find(t.paths, function(p) return p.id == 'd:other>t:other' end), 'other->other remainder path')
	H.ok(find(t.paths, function(p) return p.id == 'd:other>t:site1.com' end), 'collapsed devices -> top target')
	H.eq(#t.edges, 50, 'two legs per path')
	local sum = 0
	for _, p in ipairs(t.paths) do sum = sum + p.bytes_total end
	H.eq(sum, t.bytes_total, 'collapse preserves totals')
	print(string.format('    devices=%d targets=%d paths=%d edges=%d total=%d',
		t.device_count, t.target_count, #t.paths, #t.edges, t.bytes_total))
	H.rmrf(dir)
end)

H.case('W11', 'Top device -> non-Top destination edge ends at 其他去向', function()
	local now = os.time()
	local dir, file = grid_db(10, 10, now)
	local t = api.call('topology', { range = '1h' }, env_for(dir, file, now))
	local p = find(t.paths, function(x) return x.id == 'd:' .. mac(1) .. '>t:other' end)
	H.ok(p, 'path exists')
	local out = find(t.edges, function(e) return e.id == p.id .. '#out' end)
	H.eq(out.from, 'gw', 'right leg from gateway')
	H.eq(out.to, 't:other', 'right leg ends at 其他去向')
	H.ok(not find(t.edges, function(e) return e.to == 't:site7.com' end), 'no edge to collapsed target')
	-- site5..site10 from device 1: sum (11-j)*10*1000 for j=5..10 = 10000*(6+5+4+3+2+1)
	H.eq(p.bytes_total, 210000, 'collapsed bytes')
	H.rmrf(dir)
end)

H.case('W12', '12 devices -> devices lists all 12 sorted by traffic', function()
	local now = os.time()
	local dir, file = grid_db(12, 2, now)
	local r = api.call('devices', { range = '1h' }, env_for(dir, file, now))
	H.ok(not r.error, 'error: ' .. tostring(r.error))
	H.eq(#r.devices, 12, 'all devices')
	for i = 2, #r.devices do
		H.ok(r.devices[i - 1].bytes_total >= r.devices[i].bytes_total, 'sorted desc at ' .. i)
	end
	H.eq(r.devices[1].mac, mac(1), 'heaviest first')
	H.eq(r.devices[12].mac, mac(12), 'lightest last')
	H.eq(r.devices[1].top_target, 'site1.com', 'top target')
	H.rmrf(dir)
end)

H.case('W12b', 'overview returns topology+devices from one scan', function()
	local now = os.time()
	local dir, file = grid_db(10, 10, now)
	local ov = api.call('overview', { range = '1h' }, env_for(dir, file, now))
	H.ok(not ov.error, 'overview: ' .. tostring(ov.error))
	H.ok(ov.topology and ov.topology.paths, 'topology payload')
	H.eq(#ov.topology.nodes.devices, 5, 'topo devices')
	H.eq(#ov.devices, 10, 'device grid')
	H.eq(ov.devices[1].mac, mac(1), 'heaviest device')
	H.rmrf(dir)
end)

H.case('W13', 'one device, two targets -> two colors, each consistent on both legs', function()
	local rows = {
		{ device = 'm1', target = 'a.com', up = 100, down = 900 },
		{ device = 'm1', target = 'b.com', up = 50, down = 450 },
	}
	local t = topology.build(rows)
	H.eq(#t.paths, 2, 'two paths (fan-out)')
	H.ok(t.paths[1].color ~= t.paths[2].color, 'distinct colors')
	for _, p in ipairs(t.paths) do
		local legs = {}
		for _, e in ipairs(t.edges) do if e.path == p.id then legs[#legs + 1] = e end end
		H.eq(#legs, 2, 'two legs for ' .. p.id)
		H.eq(legs[1].color, p.color, 'in-leg color')
		H.eq(legs[2].color, p.color, 'out-leg color')
		print(string.format('    %s color=%s legs=%s,%s', p.id, p.color, legs[1].id, legs[2].id))
	end
	local again = topology.build(rows)
	H.eq(again.paths[1].color, t.paths[1].color, 'stable color across calls')
	local ids = {}
	for i = 1, 10 do ids[i] = 'd:x>t:' .. i end
	local colors, seen = topology.assign_colors(ids), {}
	for _, c in pairs(colors) do H.ok(not seen[c], 'unique color within palette') seen[c] = true end
end)

H.case('W14', 'recent deltas -> live rate>0; idle device -> not live', function()
	local st = live.new()
	local now = 1794560000
	live.record(st, now - 60, { { device = 'idle', target = 'x', up = 5000, down = 5000 } }, 120)
	live.record(st, now - 5, { { device = 'busy', target = 'y', up = 15000, down = 150000 } }, 120)
	live.record(st, now, { { device = 'busy', target = 'y', up = 15000, down = 150000 } }, 120)
	local snap = live.snapshot(st, now, 15, 11)
	H.eq(snap.devices.busy.live, true, 'busy live')
	H.ok(snap.devices.busy.rate_down > 0, 'busy rate')
	H.eq(snap.devices.busy.rate_down, 20000, 'rate = bytes/window')
	H.ok(not (snap.devices.idle and snap.devices.idle.live), 'idle not live')

	local dir, file = grid_db(2, 1, now)
	local ctx = collector.new(H.cfg({ db_path = dir, interval = 5 }), { db_file = file, rundir = dir })
	live.record(ctx.live, now, { { device = mac(2), target = 'site1.com', up = 1000, down = 9000 } }, 15)
	collector.write_state(dir, collector.status_payload(ctx, { degraded = false }, now))
	local r = api.call('devices', { range = '1h' }, env_for(dir, file, now))
	local d1 = find(r.devices, function(d) return d.mac == mac(1) end)
	local d2 = find(r.devices, function(d) return d.mac == mac(2) end)
	H.eq(d2.live, true, 'payload live')
	H.ok(d2.rate_down > 0, 'payload rate>0')
	H.eq(d1.live, false, 'payload idle')
	H.eq(d1.rate_down, 0, 'idle rate 0')
	print(string.format('    %s live=%s rate_down=%d B/s; %s live=%s', d2.mac, tostring(d2.live), d2.rate_down, d1.mac, tostring(d1.live)))
	local stale = api.call('devices', { range = '1h' }, env_for(dir, file, now + 120))
	local s2 = find(stale.devices, function(d) return d.mac == mac(2) end)
	H.eq(s2.live, false, 'collector down -> no live flags')
	H.rmrf(dir)
end)

H.case('W15', 'rpcd ACL: read/write split; check_path read-only (no FS mutate)', function()
	local acl = assert(json.decode(H.read('./luci-app-netmonitor/root/usr/share/rpcd/acl.d/luci-app-netmonitor.json')))
	local a = acl['luci-app-netmonitor']
	H.ok(a, 'acl group')
	local read, write = {}, {}
	for _, m in ipairs(a.read.ubus.netmonitor) do read[m] = true end
	for _, m in ipairs(a.write.ubus.netmonitor) do write[m] = true end
	for _, m in ipairs({ 'status', 'topology', 'devices', 'overview', 'device_detail',
		'device_months', 'device_month_summary', 'get_config', 'estimate', 'check_path' }) do
		H.ok(read[m], 'read has ' .. m)
		H.ok(not write[m], 'write lacks ' .. m)
	end

	for _, m in ipairs({ 'set_config', 'collector', 'prepare_path', 'update_asn', 'update_service' }) do
		H.ok(write[m], 'write has ' .. m)
		H.ok(not read[m], 'read lacks ' .. m)
	end
	for m in pairs(api.METHODS) do H.ok(read[m] or write[m], 'ACL covers ' .. m) end
	for m in pairs(read) do H.ok(api.METHODS[m], 'ACL method implemented: ' .. m) end
	for m in pairs(write) do H.ok(api.METHODS[m], 'ACL method implemented: ' .. m) end
	H.ok(a.write.uci and a.write.uci[1] == 'netmonitor', 'uci write')

	-- F1: check_path must not mkdir/probe; prepare_path may.
	local mutated = { mkdir = 0, probe = 0 }
	local fs = H.fsops(10 * H.GiB, 32 * H.GiB, true, {
		on_mkdir = function() mutated.mkdir = mutated.mkdir + 1 end,
		on_probe = function() mutated.probe = mutated.probe + 1 end,
	})
	local env = { cfg = H.cfg({}), now = os.time(), fsops = fs }
	local r = api.call('check_path', { path = '/mnt/usb' }, env)
	H.eq(mutated.mkdir, 0, 'check_path no mkdir')
	H.eq(mutated.probe, 0, 'check_path no probe')
	H.eq(r.ok, true, 'check_path ok on existing')
	local p = api.call('prepare_path', { path = '/mnt/usb/new' }, env)
	H.ok(mutated.mkdir > 0, 'prepare_path mkdir')
	H.ok(mutated.probe > 0, 'prepare_path probe')
	H.eq(p.ok, true, 'prepare_path ok')
	local miss = api.call('check_path', { path = '/mnt/missing' }, {
		cfg = H.cfg({}), now = os.time(),
		fsops = H.fsops(10 * H.GiB, 32 * H.GiB, true, { exists = false }),
	})
	H.eq(miss.ok, false, 'missing path')
	H.eq(miss.error, 'path_missing', 'path_missing without create')
end)

H.case('W16', 'calendar-month retention: 30d rejected; today allowed (UCI days ignored)', function()
	-- Fixed mid-month so 7d fits calendar month; UCI=7d must not be the authority.
	local now = os.time({ year = 2026, month = 11, day = 15, hour = 12 })
	local dir, file = grid_db(2, 2, now)
	local env = env_for(dir, file, now)
	env.cfg = H.cfg({ db_path = dir, retention_value = 7, retention_unit = 'day' })
	local t = api.call('topology', { range = '30d' }, env)
	H.eq(t.error, 'range_exceeds_retention', 'topology error')
	local d = api.call('devices', { range = '30d' }, env)
	H.eq(d.error, 'range_exceeds_retention', 'devices error')
	local ok_today = api.call('topology', { range = 'today' }, env)
	H.ok(not ok_today.error, 'today allowed under calendar month')
	local allowed = table.concat(t.allowed_ranges, ',')
	print('    allowed_ranges=' .. allowed)
	H.ok(not allowed:find('30d'), '30d not offered')
	H.ok(allowed:find('today') or allowed:find('1h'), 'short ranges offered')
	local bad = api.call('topology', { range = 'forever' }, env)
	H.eq(bad.error, 'bad_range', 'unknown range')
	H.rmrf(dir)
end)

H.case('W19', 'device_detail API: day chips + sessions via ubus shape (F10)', function()
	local db = require 'netmonitor.db'
	local now = os.time({ year = 2026, month = 11, day = 13, hour = 12 })
	local start = os.time({ year = 2026, month = 11, day = 12, hour = 23, min = 50 })
	local dir, file = H.new_db()
	H.seed(file, {
		{ mac(1), 'x.com', start, 100, 1000 },
		{ mac(1), 'x.com', now, 200, 2000 },
	}, {
		{ mac = mac(1), ip = '192.168.1.10', hostname = 'laptop', first_seen = start, last_seen = now },
	}, { { key = 'x.com', display = 'x.com' } })
	assert(db.exec(file, string.format([[
INSERT INTO sessions VALUES (%s,'x.com',%d,%d,300,3000,0);]],
		db.quote(mac(1)), start, now)))
	local r = api.call('device_detail', { mac = mac(1) }, env_for(dir, file, now))
	H.ok(not r.error, 'detail error: ' .. tostring(r.error))
	H.ok(#r.days >= 2, 'day list from api')
	H.ok(r.day, 'default day')
	H.ok(#r.sessions >= 1, 'sessions for day')
	H.eq(r.approximate, true, 'approximate flag')
	H.eq(r.has_more, false, 'small day not paged')
	local day12 = api.call('device_detail', { mac = mac(1), day = '2026-11-12' }, env_for(dir, file, now))
	H.eq(day12.day, '2026-11-12', 'day filter')
	for _, s in ipairs(day12.sessions) do
		H.eq(s.active, false, 'historical day not active')
	end
	-- edges ↔ paths contract used by UI (F11)
	local topo = api.call('topology', { range = '1h' }, env_for(dir, file, now))
	local by_path = {}
	for _, p in ipairs(topo.paths) do by_path[p.id] = p end
	for _, e in ipairs(topo.edges) do
		local p = by_path[e.path]
		H.ok(p, 'edge path exists')
		H.eq(e.color, p.color, 'edge color matches path')
	end
	H.rmrf(dir)
end)

H.case('W19b', 'device_detail pages busy days by full destination aggregates', function()
	local db = require 'netmonitor.db'
	local now = os.time({ year = 2026, month = 11, day = 15, hour = 12 })
	local day0 = os.time({ year = 2026, month = 11, day = 15, hour = 0, min = 1 })
	local dir, file = H.new_db()
	local targets = {}
	local sess_sql = {}
	for i = 1, 520 do
		local key = string.format('host-%d.example', i)
		targets[#targets + 1] = { key = key, display = key, source = 'dns' }
		sess_sql[#sess_sql + 1] = string.format('(%s,%s,%d,%d,%d,%d,1)',
			db.quote(mac(1)), db.quote(key), day0 + i, day0 + i + 10, i * 100, i * 1000)
	end
	-- One busy destination with 5 sessions — page aggregate must sum ALL 5.
	-- Bytes high enough to rank on the first traffic-sorted page.
	targets[#targets + 1] = { key = 'busy.example', display = 'busy.example', source = 'dns' }
	for j = 1, 5 do
		sess_sql[#sess_sql + 1] = string.format('(%s,%s,%d,%d,%d,%d,1)',
			db.quote(mac(1)), db.quote('busy.example'), day0 + 1000 + j, day0 + 1010 + j, 200000, 800000)
	end
	H.seed(file, {}, {
		{ mac = mac(1), ip = '192.168.1.3', hostname = 'tower', first_seen = day0, last_seen = now },
	}, targets)
	assert(db.exec(file, 'INSERT INTO sessions (device,target,started_at,last_seen_at,bytes_up,bytes_down,closed) VALUES '
		.. table.concat(sess_sql, ',') .. ';'))
	local page1 = api.call('device_detail', {
		mac = mac(1), day = '2026-11-15', sort = 'traffic', limit = 50, offset = 0,
	}, env_for(dir, file, now))
	H.ok(not page1.error, 'page1: ' .. tostring(page1.error))
	H.eq(page1.paged, true, 'paged')
	H.eq(page1.has_more, true, 'has more')
	H.eq(#page1.sessions, 50, 'page size = destinations')
	H.ok(page1.session_count >= 525, 'session_count')
	H.ok(page1.bytes_total > 0, 'day totals')
	local busy
	for _, s in ipairs(page1.sessions) do
		if s.display == 'busy.example' then busy = s end
	end
	H.ok(busy, 'busy destination on page')
	H.eq(busy.session_count, 5, 'full session count for destination')
	H.eq(busy.bytes_up, 1000000, 'full up sum')
	H.eq(busy.bytes_down, 4000000, 'full down sum')
	local kids = api.call('device_detail', {
		mac = mac(1), day = '2026-11-15', children_of = 'busy.example',
	}, env_for(dir, file, now))
	H.eq(#kids.sessions, 5, 'expand returns each timed session')
	H.rmrf(dir)
end)

H.case('W20', 'set_config enabled=0 stops collector (F8)', function()
	local ran, saved = {}, nil
	local env = {
		cfg = H.cfg({ db_path = '/mnt/usb', enabled = 1 }),
		now = os.time(),
		saver = function(c) saved = c end,
		runner = function(cmd) ran[#ran + 1] = cmd; return true end,
		cron_runner = false,
		fsops = H.fsops(10 * H.GiB, 32 * H.GiB, true),
	}
	local r = api.call('set_config', { enabled = 0 }, env)
	H.eq(r.ok, true, 'ok: ' .. tostring(r.error) .. ' ' .. tostring(r.detail))
	H.eq((saved or env.cfg).enabled, 0, 'saved enabled')
	H.eq(env.cfg.enabled, 0, 'env enabled')
	H.ok(tostring(ran[#ran]):find('stop'), 'stop invoked: ' .. tostring(ran[#ran]))
end)

H.case('W24', 'set_config ignores ubus_rpc_session', function()
	local saved = nil
	local env = {
		cfg = H.cfg({ db_path = '/mnt/usb', enabled = 1, interval = 5 }),
		now = os.time(),
		saver = function(c) saved = c end,
		runner = function() return true end,
		cron_runner = false,
		fsops = H.fsops(10 * H.GiB, 32 * H.GiB, true),
	}
	local r = api.call('set_config', {
		interval = 7,
		ubus_rpc_session = 'deadbeef',
		confirm = true,
	}, env)
	H.eq(r.ok, true, 'ok: ' .. tostring(r.error))
	H.eq((saved or {}).interval, 7, 'interval saved')
end)
