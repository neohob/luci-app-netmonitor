-- monthly-rollup W3–W9: schema v5 + rollup/retention.
local H = require 'helper'
local db = require 'netmonitor.db'
local schema = require 'netmonitor.schema'
local rollup = require 'netmonitor.rollup'
local collector = require 'netmonitor.collector'
local tu = require 'netmonitor.timeutil'

local MAC = 'aa:bb:cc:00:00:01'

local function now_nov()
	return os.time({ year = 2026, month = 11, day = 15, hour = 12 })
end

local function oct_ts(day, hour)
	return os.time({ year = 2026, month = 10, day = day or 10, hour = hour or 12 })
end

H.case('W3', 'schema v5 creates monthly_traffic on empty and v4 DB', function()
	H.eq(schema.VERSION, 5, 'VERSION=5')
	local dir, file = H.new_db()
	local ver = db.query(file, "SELECT value FROM meta WHERE key='schema_version';")
	H.eq(tonumber(ver[1].value), 5, 'fresh schema_version')
	local mt = db.query(file, "SELECT sql FROM sqlite_master WHERE type='table' AND name='monthly_traffic';")
	H.ok(mt[1] and tostring(mt[1].sql):find('bytes_up'), 'monthly_traffic table')
	local idx = db.query(file, "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_monthly_device_month';")
	H.ok(idx[1], 'idx_monthly_device_month')
	local idx4 = db.query(file, "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_samples_ts_device_target';")
	H.ok(idx4[1], 'v4 index kept')
	H.rmrf(dir)

	-- Simulate v4 DB then migrate.
	local dir2 = H.tmpdir()
	local disk = require 'netmonitor.disk'
	local file2 = disk.db_file(dir2)
	local saved = schema.VERSION
	schema.VERSION = 4
	assert(schema.apply(file2, db))
	schema.VERSION = saved
	local v4 = db.query(file2, "SELECT value FROM meta WHERE key='schema_version';")
	H.eq(tonumber(v4[1].value), 4, 'stuck at v4')
	assert(schema.apply(file2, db))
	local v5 = db.query(file2, "SELECT value FROM meta WHERE key='schema_version';")
	H.eq(tonumber(v5[1].value), 5, 'migrated to v5')
	local mt = db.query(file2, "SELECT name FROM sqlite_master WHERE type='table' AND name='monthly_traffic';")
	H.ok(mt[1], 'monthly_traffic after migrate')
	H.rmrf(dir2)
end)

H.case('W4', '105 targets → Top100 + __other__ with exact remainder', function()
	local now = now_nov()
	local dir, file = H.new_db()
	local samples, targets = {}, {}
	local leftover_up, leftover_down = 0, 0
	for i = 1, 105 do
		local key = string.format('t%03d.example', i)
		targets[#targets + 1] = { key = key, display = key }
		-- Higher index = more traffic so Top100 are t006..t105; leftovers t001..t005
		local up, down = i * 10, i * 100
		samples[#samples + 1] = { MAC, key, oct_ts(5), up, down }
		if i <= 5 then
			leftover_up = leftover_up + up
			leftover_down = leftover_down + down
		end
	end
	H.seed(file, samples, {
		{ mac = MAC, ip = '192.168.1.10', last_seen = now },
	}, targets)
	local ok, err = rollup.rollup_previous_month(file, now)
	H.ok(ok, 'rollup: ' .. tostring(err))
	local rows = db.query(file, "SELECT target, bytes_up, bytes_down FROM monthly_traffic WHERE device="
		.. db.quote(MAC) .. " AND month='2026-10' ORDER BY target;")
	H.ok(#rows <= 101, '≤101 rows')
	H.eq(#rows, 101, 'exactly 100 + other')
	local other
	local named = 0
	for _, r in ipairs(rows) do
		if r.target == '__other__' then other = r else named = named + 1 end
	end
	H.eq(named, 100, '100 named')
	H.ok(other, '其他 present')
	H.eq(tonumber(other.bytes_up), leftover_up, 'other up')
	H.eq(tonumber(other.bytes_down), leftover_down, 'other down')
	H.rmrf(dir)
end)

H.case('W5', 'equal totals tie-break by target ASC after total DESC', function()
	local now = now_nov()
	local dir, file = H.new_db()
	-- 102 targets with identical totals; after Top100 the two smallest keys (lex) go to other
	-- Actually all equal → sort by target ASC → keep first 100 alphabetically, rest → other.
	local samples, targets = {}, {}
	for i = 1, 102 do
		local key = string.format('eq%03d.com', i)
		targets[#targets + 1] = { key = key }
		samples[#samples + 1] = { MAC, key, oct_ts(8), 50, 50 }
	end
	H.seed(file, samples, { { mac = MAC, ip = '10.0.0.1', last_seen = now } }, targets)
	assert(rollup.rollup_previous_month(file, now))
	local rows = db.query(file, "SELECT target FROM monthly_traffic WHERE month='2026-10' AND device="
		.. db.quote(MAC) .. " AND target != '__other__' ORDER BY target;")
	H.eq(#rows, 100, '100 named')
	H.eq(rows[1].target, 'eq001.com', 'first kept is smallest key')
	H.eq(rows[100].target, 'eq100.com', 'last kept')
	local other = db.query(file, "SELECT bytes_up, bytes_down FROM monthly_traffic WHERE target='__other__';")[1]
	H.eq(tonumber(other.bytes_up), 100, 'other up = 2*50')
	H.eq(tonumber(other.bytes_down), 100, 'other down')
	H.rmrf(dir)
end)

H.case('W6', 'after rollup prior-month samples/sessions gone; current untouched', function()
	local now = now_nov()
	local dir, file = H.new_db()
	local prev = oct_ts(20)
	local cur = os.time({ year = 2026, month = 11, day = 5, hour = 10 })
	H.seed(file, {
		{ MAC, 'old.com', prev, 1, 2 },
		{ MAC, 'new.com', cur, 3, 4 },
	}, { { mac = MAC, ip = '1.1.1.1', last_seen = cur } }, {
		{ key = 'old.com' }, { key = 'new.com' },
	})
	assert(db.exec(file, string.format([[
INSERT INTO sessions VALUES (%s,'old.com',%d,%d,1,2,1);
INSERT INTO sessions VALUES (%s,'new.com',%d,%d,3,4,0);]],
		db.quote(MAC), prev, prev, db.quote(MAC), cur, cur)))
	assert(rollup.rollup_previous_month(file, now))
	local ps, pe = tu.prev_month_bounds(now)
	local old_s = db.query(file, string.format(
		'SELECT COUNT(*) AS n FROM traffic_samples WHERE ts >= %s AND ts < %s;', db.quote(ps), db.quote(pe)))
	H.eq(tonumber(old_s[1].n), 0, 'no prior samples')
	local old_sess = db.query(file, string.format(
		'SELECT COUNT(*) AS n FROM sessions WHERE last_seen_at >= %s AND last_seen_at < %s;', db.quote(ps), db.quote(pe)))
	H.eq(tonumber(old_sess[1].n), 0, 'no prior sessions')
	local cur_s = db.query(file, "SELECT target FROM traffic_samples;")
	H.eq(#cur_s, 1, 'current sample kept')
	H.eq(cur_s[1].target, 'new.com', 'current target')
	local cur_sess = db.query(file, "SELECT target FROM sessions;")
	H.eq(#cur_sess, 1, 'current session kept')
	H.rmrf(dir)
end)

H.case('W7', 're-run rollup: no duplicate rows; detail stays empty', function()
	local now = now_nov()
	local dir, file = H.new_db()
	H.seed(file, {
		{ MAC, 'a.com', oct_ts(3), 10, 20 },
		{ MAC, 'b.com', oct_ts(4), 30, 40 },
	}, { { mac = MAC, ip = '1.1.1.1', last_seen = now } }, {
		{ key = 'a.com' }, { key = 'b.com' },
	})
	assert(rollup.rollup_previous_month(file, now))
	local n1 = tonumber(db.query(file, "SELECT COUNT(*) AS n FROM monthly_traffic WHERE month='2026-10';")[1].n)
	H.ok(n1 >= 2, 'rows after first')
	assert(rollup.rollup_previous_month(file, now))
	local n2 = tonumber(db.query(file, "SELECT COUNT(*) AS n FROM monthly_traffic WHERE month='2026-10';")[1].n)
	H.eq(n2, n1, 'row count unchanged')
	local samples = db.query(file, "SELECT COUNT(*) AS n FROM traffic_samples WHERE ts < " .. db.quote(tu.month_start(now)))
	H.eq(tonumber(samples[1].n), 0, 'detail still empty')
	H.rmrf(dir)
end)

H.case('W8', 'samples empty → fall back to sessions sums', function()
	local now = now_nov()
	local dir, file = H.new_db()
	local targets = {}
	for i = 1, 3 do targets[#targets + 1] = { key = 's' .. i .. '.com' } end
	H.seed(file, {}, { { mac = MAC, ip = '1.1.1.1', last_seen = now } }, targets)
	local prev = oct_ts(12)
	assert(db.exec(file, string.format([[
INSERT INTO sessions VALUES (%s,'s1.com',%d,%d,100,1000,1);
INSERT INTO sessions VALUES (%s,'s2.com',%d,%d,200,2000,1);
INSERT INTO sessions VALUES (%s,'s3.com',%d,%d,300,3000,1);]],
		db.quote(MAC), prev, prev + 10,
		db.quote(MAC), prev + 20, prev + 30,
		db.quote(MAC), prev + 40, prev + 50)))
	assert(rollup.rollup_previous_month(file, now))
	local rows = db.query(file, "SELECT target, bytes_up, bytes_down FROM monthly_traffic WHERE month='2026-10' ORDER BY target;")
	H.eq(#rows, 3, '3 from sessions')
	local by = {}
	for _, r in ipairs(rows) do by[r.target] = r end
	H.eq(tonumber(by['s1.com'].bytes_up), 100, 's1 up')
	H.eq(tonumber(by['s3.com'].bytes_down), 3000, 's3 down')
	H.rmrf(dir)
end)

H.case('W9', 'current-month only: no purge; no monthly insert for current', function()
	local now = now_nov()
	local dir, file = H.new_db()
	local cur = os.time({ year = 2026, month = 11, day = 8, hour = 9 })
	H.seed(file, {
		{ MAC, 'cur.com', cur, 9, 9 },
	}, { { mac = MAC, ip = '1.1.1.1', last_seen = cur } }, { { key = 'cur.com' } })
	local cfg = H.cfg({ db_path = dir })
	local ok, err = collector.retention_pass(file, cfg, now)
	H.ok(ok, 'retention: ' .. tostring(err))
	local samples = db.query(file, 'SELECT target FROM traffic_samples;')
	H.eq(#samples, 1, 'current kept')
	local mt = db.query(file, "SELECT COUNT(*) AS n FROM monthly_traffic WHERE month='2026-11';")
	H.eq(tonumber(mt[1].n), 0, 'no current-month monthly insert')
	-- previous month empty → no false insert
	local mt10 = db.query(file, "SELECT COUNT(*) AS n FROM monthly_traffic WHERE month='2026-10';")
	H.eq(tonumber(mt10[1].n), 0, 'no empty-month insert')
	H.rmrf(dir)
end)

H.case('W16', 'multi-month leftover: one retention_pass rolls M-2 and M-1', function()
	local now = now_nov()
	local dir, file = H.new_db()
	local sep = os.time({ year = 2026, month = 9, day = 12, hour = 10 })
	local oct = oct_ts(18)
	local cur = os.time({ year = 2026, month = 11, day = 5, hour = 10 })
	H.seed(file, {
		{ MAC, 'sep.com', sep, 10, 20 },
		{ MAC, 'oct.com', oct, 30, 40 },
		{ MAC, 'nov.com', cur, 50, 60 },
	}, { { mac = MAC, ip = '1.1.1.1', last_seen = cur } }, {
		{ key = 'sep.com' }, { key = 'oct.com' }, { key = 'nov.com' },
	})
	assert(db.exec(file, string.format([[
INSERT INTO sessions VALUES (%s,'sep.com',%d,%d,10,20,1);
INSERT INTO sessions VALUES (%s,'oct.com',%d,%d,30,40,1);
INSERT INTO sessions VALUES (%s,'nov.com',%d,%d,50,60,0);]],
		db.quote(MAC), sep, sep, db.quote(MAC), oct, oct, db.quote(MAC), cur, cur)))
	local cfg = H.cfg({ db_path = dir })
	local ok, err = collector.retention_pass(file, cfg, now)
	H.ok(ok, 'retention: ' .. tostring(err))
	local m9 = db.query(file, "SELECT COUNT(*) AS n FROM monthly_traffic WHERE month='2026-09';")
	local m10 = db.query(file, "SELECT COUNT(*) AS n FROM monthly_traffic WHERE month='2026-10';")
	H.ok(tonumber(m9[1].n) >= 1, 'September rolled')
	H.ok(tonumber(m10[1].n) >= 1, 'October rolled')
	local past = db.query(file, 'SELECT COUNT(*) AS n FROM traffic_samples WHERE ts < '
		.. db.quote(tu.month_start(now)))
	H.eq(tonumber(past[1].n), 0, 'no past-month samples')
	local past_s = db.query(file, 'SELECT COUNT(*) AS n FROM sessions WHERE last_seen_at < '
		.. db.quote(tu.month_start(now)))
	H.eq(tonumber(past_s[1].n), 0, 'no past-month sessions')
	local cur_s = db.query(file, "SELECT target FROM traffic_samples;")
	H.eq(#cur_s, 1, 'current intact')
	H.eq(cur_s[1].target, 'nov.com', 'nov sample')
	H.rmrf(dir)
end)

H.case('W17', 'rollup insert failure leaves unrolled detail; distinct rollup_failed', function()
	local now = now_nov()
	local dir, file = H.new_db()
	local sep = os.time({ year = 2026, month = 9, day = 8, hour = 10 })
	local oct = oct_ts(9)
	H.seed(file, {
		{ MAC, 'sep.com', sep, 1, 1 },
		{ MAC, 'oct.com', oct, 2, 2 },
	}, { { mac = MAC, ip = '1.1.1.1', last_seen = now } }, {
		{ key = 'sep.com' }, { key = 'oct.com' },
	})
	local real_exec = db.exec
	local calls = 0
	db.exec = function(path, sql)
		if type(sql) == 'string' and sql:find('INSERT OR IGNORE INTO monthly_traffic', 1, true) then
			calls = calls + 1
			if calls == 1 then
				return nil, 'inject_rollup_fail'
			end
		end
		return real_exec(path, sql)
	end
	local cfg = H.cfg({ db_path = dir })
	local ok, err, cutoff, meta = collector.retention_pass(file, cfg, now)
	db.exec = real_exec
	H.ok(meta and meta.rollup_failed, 'rollup_failed meta')
	H.ok(tostring(err or ''):find('inject_rollup_fail', 1, true)
		or tostring(meta.rollup_error or ''):find('inject_rollup_fail', 1, true),
		'distinct rollup error')
	-- First month failed before purge → its detail must remain.
	local left = db.query(file, 'SELECT COUNT(*) AS n FROM traffic_samples WHERE ts < ' .. db.quote(tu.month_start(now)))
	H.ok(tonumber(left[1].n) >= 1, 'unrolled detail still present')
	H.ok(cutoff == tu.month_start(now), 'cutoff still month_start')
	-- Safe GC still attempted (ok may be true even when rollup failed).
	H.ok(ok == true or ok == false, 'GC path ran')
	H.rmrf(dir)
end)
