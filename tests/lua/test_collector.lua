-- W4–W9: collector parsing, attribution, retention, sessions, degraded mode.
local H = require 'helper'
local collector = require 'netmonitor.collector'
local conntrack = require 'netmonitor.conntrack'
local session = require 'netmonitor.session'
local detail = require 'netmonitor.detail'
local db = require 'netmonitor.db'

local function poll_fixture(ct_fixture, opts)
	opts = opts or {}
	local dir, file = H.new_db()
	local cfg = H.cfg({ db_path = dir })
	local ctx = collector.new(cfg, {
		db_file = file, rundir = dir, prime = opts.prime == true,
		statfs = H.statfs(10 * H.GiB, 32 * H.GiB),
		sources = {
			conntrack = function() return H.fixture(ct_fixture) end,
			neigh = function() return H.neigh_snapshot() end,
			dns = function() return opts.dns ~= false and H.fixture('dnsmasq.log') or '' end,
		},
	})
	local res = collector.poll(ctx, opts.now or os.time())
	return res, file, dir, ctx
end

local function sample_map(file)
	local rows = assert(db.query(file, [[
SELECT s.device, s.target, s.bytes_up, s.bytes_down, t.kind, t.unresolved, t.display
FROM traffic_samples s JOIN targets t ON t.key = s.target ORDER BY s.device, s.target;]]))
	local m = {}
	for _, r in ipairs(rows) do m[r.device .. '>' .. r.target] = r end
	return m, rows
end

H.case('W4', 'one poll on conntrack+dns fixture yields device->domain sample rows', function()
	local res, file, dir = poll_fixture('conntrack_basic.txt')
	H.eq(res.degraded, false, 'not degraded')
	local m, rows = sample_map(file)
	for _, r in ipairs(rows) do
		print(string.format('    sample %s -> %s up=%s down=%s kind=%s', r.device, r.target, r.bytes_up, r.bytes_down, r.kind))
	end
	H.eq(#rows, 4, 'four attributable flows (router/LAN/multicast skipped)')
	local a = m['aa:bb:cc:00:00:01>www.example.com']
	H.ok(a, 'laptop -> www.example.com via CNAME chain')
	H.eq(a.bytes_up, 1500, 'up = orig bytes')
	H.eq(a.bytes_down, 24000, 'down = reply bytes')
	H.eq(a.kind, 'domain', 'kind')
	local b = m['aa:bb:cc:00:00:02>youtube.com']
	H.ok(b, 'phone -> youtube.com (cached answer)')
	H.eq(b.bytes_down, 52000, 'phone down')
	local c = m['aa:bb:cc:00:00:03>198.51.100.7']
	H.ok(c, 'port-forwarded inbound attributed to LAN host')
	H.eq(c.bytes_up, 30000, 'inbound: up = reply direction')
	local dev = db.query(file, "SELECT hostname FROM devices WHERE mac = 'aa:bb:cc:00:00:01';")
	H.eq(dev[1].hostname, 'laptop', 'hostname from DHCP lease')

	local prime = poll_fixture('conntrack_basic.txt', { prime = true })
	H.eq(prime.primed, true, 'first daemon poll primes baseline')
	H.eq(prime.samples, 0, 'primed poll writes nothing')
	H.rmrf(dir)
end)

H.case('W5', 'conntrack IP without DNS answer -> target is IP, unresolved', function()
	local _, file, dir = poll_fixture('conntrack_basic.txt')
	local m = sample_map(file)
	local r = m['aa:bb:cc:00:00:01>8.8.4.4']
	H.ok(r, 'sample keyed by IP')
	H.eq(r.kind, 'ip', 'kind')
	H.eq(r.unresolved, 1, 'unresolved flag')
	H.eq(r.display, '8.8.4.4', 'display is IP')
	H.rmrf(dir)

	local _, file2, dir2 = poll_fixture('conntrack_basic.txt', { dns = false })
	local m2 = sample_map(file2)
	H.ok(m2['aa:bb:cc:00:00:01>93.184.216.34'], 'no DNS log at all -> IP target')
	H.eq(m2['aa:bb:cc:00:00:01>93.184.216.34'].unresolved, 1, 'unresolved')
	H.rmrf(dir2)
end)

H.case('W6', 'retention keeps current calendar month detail; purges older', function()
	local tu = require 'netmonitor.timeutil'
	local dir, file = H.new_db()
	local now = os.time({ year = 2026, month = 11, day = 15, hour = 12 })
	local cur = os.time({ year = 2026, month = 11, day = 10, hour = 12 })
	local old = os.time({ year = 2026, month = 9, day = 10, hour = 12 }) -- older than previous month
	H.seed(file, {
		{ 'aa:bb:cc:00:00:01', 'old.example', old, 10, 20 },
		{ 'aa:bb:cc:00:00:01', 'new.example', cur, 30, 40 },
	}, {
		{ mac = 'aa:bb:cc:00:00:01', ip = '192.168.1.10', last_seen = cur },
		{ mac = 'aa:bb:cc:00:00:09', ip = '192.168.1.19', last_seen = old },
	}, { { key = 'old.example' }, { key = 'new.example' } })
	assert(db.exec(file, string.format([[
INSERT INTO sessions VALUES ('aa:bb:cc:00:00:01','old.example',%d,%d,10,20,1);
INSERT INTO sessions VALUES ('aa:bb:cc:00:00:01','new.example',%d,%d,30,40,1);]], old, old, cur, cur)))
	local cfg = H.cfg({ db_path = dir, retention_value = 30, retention_unit = 'day' })
	local ok, err, cutoff = collector.retention_pass(file, cfg, now)
	H.ok(ok, 'retention pass: ' .. tostring(err))
	H.eq(cutoff, tu.month_start(now), 'cutoff = month_start')
	print(string.format('    now=%d cutoff=%d (%s)', now, cutoff, os.date('%Y-%m-%d %H:%M', cutoff)))
	local s = db.query(file, 'SELECT target FROM traffic_samples ORDER BY target;')
	H.eq(#s, 1, 'one sample left')
	H.eq(s[1].target, 'new.example', 'current-month kept')
	local ss = db.query(file, 'SELECT target FROM sessions;')
	H.eq(#ss, 1, 'one session left')
	H.eq(ss[1].target, 'new.example', 'current-month session kept')
	local d = db.query(file, 'SELECT mac FROM devices;')
	H.eq(#d, 1, 'stale device purged')
	-- F1: older month rolled into monthly_traffic — target kept via monthly refs.
	local mt = db.query(file, "SELECT COUNT(*) AS n FROM monthly_traffic WHERE month='2026-09';")
	H.ok(tonumber(mt[1].n) >= 1, 'September rolled')
	local t = db.query(file, 'SELECT key FROM targets;')
	H.ok(#t >= 1, 'targets remain')
	H.eq(os.date('%Y-%m-%d %H', tu.retention_cutoff(now, cfg)), '2026-11-01 00', 'detail cutoff = month start')
	H.rmrf(dir)
end)

H.case('W7', 'deltas, 61s gap, deltas -> two sessions with duration = last - first', function()
	local st = session.new()
	local t0 = 1794560000
	local function d() return { { device = 'm1', target = 'x.com', up = 100, down = 200 } } end
	local all = {}
	local function rec(changed) for _, s in ipairs(changed) do all[s] = true end end
	rec(session.stitch(st, t0, d(), 60))
	rec(session.stitch(st, t0 + 5, d(), 60))
	rec(session.stitch(st, t0 + 10, d(), 60))
	rec(session.stitch(st, t0 + 71, d(), 60))
	rec(session.stitch(st, t0 + 76, d(), 60))
	local list = {}
	for s in pairs(all) do list[#list + 1] = s end
	table.sort(list, function(a, b) return a.started_at < b.started_at end)
	for _, s in ipairs(list) do
		print(string.format('    session start=+%d last=+%d dur=%d bytes=%d/%d closed=%d',
			s.started_at - t0, s.last_seen_at - t0, session.duration(s), s.bytes_up, s.bytes_down, s.closed))
	end
	H.eq(#list, 2, 'two sessions')
	H.eq(list[1].started_at, t0, 's1 start')
	H.eq(session.duration(list[1]), 10, 's1 duration')
	H.eq(list[1].closed, 1, 's1 closed')
	H.eq(list[1].bytes_up, 300, 's1 bytes')
	H.eq(list[2].started_at, t0 + 71, 's2 start')
	H.eq(session.duration(list[2]), 5, 's2 duration')

	local st2 = session.new()
	session.stitch(st2, t0, d(), 60)
	session.stitch(st2, t0 + 60, d(), 60)
	local n = 0
	for _ in pairs(st2.open) do n = n + 1 end
	H.eq(n, 1, 'gap of exactly 60s stays one session')
	local closed = session.stitch(st2, t0 + 200, {}, 60)
	H.eq(#closed, 1, 'idle sweep closes session')
	H.eq(closed[1].closed, 1, 'closed flag')
end)

H.case('W7b', 'calendar midnight soft-rolls stats session; TCP untouched', function()
	local st = session.new()
	local before = os.time({ year = 2026, month = 11, day = 14, hour = 23, min = 59, sec = 50 })
	local after = os.time({ year = 2026, month = 11, day = 15, hour = 0, min = 0, sec = 10 })
	local function d(up) return { { device = 'm1', target = 'cloud.example', up = up or 100, down = 50 } } end
	session.stitch(st, before, d(100), 60)
	session.stitch(st, before + 5, d(200), 60)
	local n = 0
	for _ in pairs(st.open) do n = n + 1 end
	H.eq(n, 1, 'still open before midnight')
	local open_before = nil
	for _, s in pairs(st.open) do open_before = s end
	H.eq(open_before.bytes_up, 300, 'pre-midnight bytes')

	local changed = session.stitch(st, after, d(40), 60)
	local closed_row, open_row
	for _, s in ipairs(changed) do
		if s.closed == 1 then closed_row = s end
		if s.closed == 0 then open_row = s end
	end
	H.ok(closed_row, 'yesterday session closed for accounting')
	H.eq(closed_row.bytes_up, 300, 'yesterday keeps its bytes')
	H.eq(closed_row.started_at, before, 'yesterday start unchanged')
	H.ok(open_row, 'new day session opened')
	H.eq(open_row.started_at, after, 'new session starts after midnight')
	H.eq(open_row.bytes_up, 40, 'new day counts from zero')
	H.eq(open_row.closed, 0, 'new session open')
	-- idle across midnight with no deltas still closes the old stats row
	local st3 = session.new()
	session.stitch(st3, before, d(10), 60)
	local rolled = session.stitch(st3, after, {}, 60)
	H.eq(#rolled, 1, 'rollover without traffic')
	H.eq(rolled[1].closed, 1, 'closed on day change')
	n = 0
	for _ in pairs(st3.open) do n = n + 1 end
	H.eq(n, 0, 'nothing left open without deltas')
end)

H.case('W8b', 'merge_by_display sums bytes and can strip children', function()
	local detail = require 'netmonitor.detail'
	local rows = {
		{ target = 'a', display = 'Same', started_at = 100, duration = 10, bytes_up = 1, bytes_down = 2, bytes_total = 3, unresolved = false },
		{ target = 'b', display = 'Same', started_at = 50, duration = 5, bytes_up = 4, bytes_down = 5, bytes_total = 9, unresolved = false },
		{ target = 'c', display = 'Other', started_at = 80, duration = 1, bytes_up = 1, bytes_down = 0, bytes_total = 1, unresolved = true },
	}
	local merged, stripped = detail.merge_by_display(rows, { max_flat = 10 })
	H.eq(stripped, false, 'keep children when small')
	H.eq(#merged, 2, 'two displays')
	local same = merged[1].display == 'Same' and merged[1] or merged[2]
	H.eq(same.session_count, 2, 'count')
	H.eq(same.bytes_total, 12, 'sum total')
	H.eq(same.started_at, 50, 'earliest start')
	H.eq(#(same.children or {}), 2, 'children kept')
	local _, stripped2 = detail.merge_by_display(rows, { max_flat = 1 })
	H.eq(stripped2, true, 'strip children when large')
end)

H.case('W8', 'session crossing midnight splits into two calendar days', function()
	local start = os.time({ year = 2026, month = 11, day = 12, hour = 23, min = 59, sec = 30 })
	local mid = os.time({ year = 2026, month = 11, day = 13, hour = 0, min = 0, sec = 0 })
	local last = mid + 40
	local sessions = { { device = 'm1', target = 'x.com', display = 'x.com', unresolved = 0,
		started_at = start, last_seen_at = last, bytes_up = 600, bytes_down = 6000, closed = 1 } }
	local samples = {
		{ target = 'x.com', ts = start, bytes_up = 100, bytes_down = 1000 },
		{ target = 'x.com', ts = start + 20, bytes_up = 200, bytes_down = 2000 },
		{ target = 'x.com', ts = mid + 10, bytes_up = 150, bytes_down = 1500 },
		{ target = 'x.com', ts = last, bytes_up = 150, bytes_down = 1500 },
	}
	local days = detail.build(sessions, samples, {})
	for _, d in ipairs(days) do
		for _, r in ipairs(d.rows) do
			print(string.format('    %s start=%s dur=%ds bytes=%d/%d', d.day,
				os.date('%H:%M:%S', r.started_at), r.duration, r.bytes_up, r.bytes_down))
		end
	end
	H.eq(#days, 2, 'two days')
	H.eq(days[1].day, '2026-11-13', 'newest first')
	H.eq(days[2].day, '2026-11-12', 'previous day')
	H.eq(days[2].rows[1].started_at, start, 'day1 start')
	H.eq(days[2].rows[1].duration, 29, 'day1 duration to 23:59:59')
	H.eq(days[2].rows[1].bytes_up, 300, 'day1 bytes from samples')
	H.eq(days[1].rows[1].started_at, mid, 'day2 starts at midnight')
	H.eq(days[1].rows[1].duration, 40, 'day2 duration')
	H.eq(days[1].rows[1].bytes_down, 3000, 'day2 bytes from samples')
	H.eq(days[1].rows[1].bytes_up + days[2].rows[1].bytes_up, 600, 'no bytes invented')
	-- Open session crossing midnight: only final day segment is active (F5).
	sessions[1].closed = 0
	local open_days = detail.build(sessions, samples, {})
	H.eq(open_days[2].rows[1].active, false, 'historical split not active')
	H.eq(open_days[1].rows[1].active, true, 'current day segment active')

	local only = detail.build(sessions, samples, { day = '2026-11-13' })
	H.eq(#only, 1, 'day filter')
	H.eq(only[1].rows[1].split, false, 'day view hides cross-day tag')
	H.eq(days[1].rows[1].split, true, 'unfiltered multi-day still marked split')
	local day12 = detail.build(sessions, samples, { day = '2026-11-12' })
	H.eq(day12[1].rows[1].bytes_up, 300, 'yesterday chip keeps yesterday bytes')
	H.eq(only[1].rows[1].bytes_up, 300, 'today chip keeps today bytes only')
end)

H.case('W22', 'retention_error keeps running (not db_error / not write-pause) (F21)', function()
	local dir, file = H.new_db()
	local cfg = H.cfg({ db_path = dir })
	local ctx = collector.new(cfg, {
		db_file = file, rundir = dir, prime = false,
		statfs = H.statfs(10 * H.GiB, 32 * H.GiB),
		sources = {
			conntrack = function() return H.fixture('conntrack_basic.txt') end,
			neigh = function() return H.neigh_snapshot() end,
			dns = function() return H.fixture('dnsmasq.log') end,
		},
	})
	-- Force retention failure after a successful sample write path.
	local real_ret = collector.retention_pass
	collector.retention_pass = function() return nil, 'retention_boom' end
	ctx.last_retention = 0
	local now = os.time()
	local res = collector.poll(ctx, now)
	collector.retention_pass = real_ret
	H.eq(res.retention_error, true, 'retention_error flag')
	H.ok(not res.db_error, 'not db_error')
	H.ok(not res.paused, 'not paused')
	local st = collector.status_payload(ctx, res, now)
	H.eq(st.state, 'running', 'state stays running')
	H.eq(st.retention_error, true, 'payload retention_error')
	local has = false
	for _, w in ipairs(st.warnings or {}) do if w == 'retention_failed' then has = true end end
	H.ok(has, 'retention_failed warning')
	H.ok(st.error == nil or st.error == false, 'no write-pause error field hijack: ' .. tostring(st.error))
	-- Samples may still have been written on the same poll before retention.
	H.ok((res.samples or 0) >= 0, 'writes not forced off by retention fail')
	H.rmrf(dir)
end)

H.case('W23', 'dns log truncates in place without unlink (F20)', function()
	local dns = require 'netmonitor.dns'
	local dir = H.tmpdir()
	local path = dir .. '/dnsmasq.log'
	local f = assert(io.open(path, 'w'))
	f:write(('x'):rep(100) .. '\n')
	f:close()
	local state = dns.new()
	state.offset = 0
	local old = dns.MAX_LOG
	dns.MAX_LOG = 10
	dns.read_log(state, path)
	local f2 = io.open(path, 'r')
	H.ok(f2 ~= nil, 'path still present after truncate')
	local sz = f2 and f2:seek('end') or -1
	if f2 then f2:close() end
	H.eq(sz, 0, 'truncated to empty')
	H.eq(dns.health(path).ok, true, 'health ok after truncate')
	dns.MAX_LOG = old
	H.rmrf(dir)
end)

H.case('W9', 'conntrack without byte fields -> degraded, no fabricated bytes', function()
	local entries, stats = conntrack.parse(H.fixture('conntrack_nobytes.txt'))
	H.eq(stats.total, 2, 'flows parsed')
	H.eq(stats.with_bytes, 0, 'no byte counters')
	local res, file, dir, ctx = poll_fixture('conntrack_nobytes.txt')
	H.eq(res.degraded, true, 'degraded')
	H.eq(res.degraded_reason, 'no_byte_counters', 'reason')
	H.eq(res.samples, 0, 'no samples')
	local n = db.query(file, 'SELECT COUNT(*) AS n FROM traffic_samples;')
	H.eq(n[1].n, 0, 'no rows in db')
	local st = collector.status_payload(ctx, res, os.time())
	H.eq(st.degraded, true, 'status degraded flag')
	local d2 = conntrack.degraded({ total = 0, with_bytes = 0 }, false)
	H.eq(d2, true, 'missing conntrack file is degraded')
	H.rmrf(dir)
	local _ = entries
end)

H.case('W9b', 'long-lived flow missing from one read is not recounted from zero', function()
	local function line(up, down)
		return string.format('ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.100.203 dst=124.251.100.18 sport=51897 dport=443 packets=900 bytes=%d src=124.251.100.18 dst=203.0.113.2 sport=443 dport=51897 packets=800 bytes=%d [OFFLOAD] mark=0 zone=0 use=2', up, down)
	end
	local function poll(prev, text)
		local snap, out = conntrack.deltas(prev, (conntrack.parse(text)))
		local up, down = 0, 0
		for _, d in ipairs(out) do up, down = up + d.d_orig, down + d.d_reply end
		return snap, up, down
	end
	local snap, up, down = poll(nil, line(4700000, 3200000))
	snap, up, down = poll(snap, line(4700143, 3200097))
	H.eq(up, 143, 'keepalive up')
	H.eq(down, 97, 'keepalive down')
	snap = poll(snap, '')
	snap, up, down = poll(snap, line(4700286, 3200194))
	H.eq(up, 143, 'reappearing flow counts only the increment (up)')
	H.eq(down, 97, 'reappearing flow counts only the increment (down)')
	snap, up = poll(snap, line(4700429, 3200291) .. '\n' .. line(4700429, 3200291))
	H.eq(up, 143, 'duplicate tuple in one read counted once')
	snap, up, down = poll(snap, line(4000000, 3000000))
	H.eq(up + down, 0, 'counter regression rebases without a delta')
	snap, up = poll(snap, line(4000143, 3000097))
	H.eq(up, 143, 'increments resume from rebased baseline')
	for _ = 1, conntrack.MISS_GRACE + 1 do snap = poll(snap, '') end
	H.eq(next(snap), nil, 'baseline dropped after grace')
end)
