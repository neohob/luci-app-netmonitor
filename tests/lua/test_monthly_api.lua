-- monthly-rollup W10–W13: device_detail month clamp + month summary APIs + ACL.
local H = require 'helper'
local api = require 'netmonitor.api'
local db = require 'netmonitor.db'
local json = require 'netmonitor.json'

local MAC = 'aa:bb:cc:00:02:01'

local function env_for(dir, file, now)
	return { cfg = H.cfg({ db_path = dir }), now = now, rundir = dir, db_file = file,
		uci_get = function() return nil end }
end

H.case('W10', 'device_detail days only current month; day=prev → bad_day', function()
	local now = os.time({ year = 2026, month = 11, day = 15, hour = 12 })
	local prev = os.time({ year = 2026, month = 10, day = 20, hour = 12 })
	local cur = os.time({ year = 2026, month = 11, day = 10, hour = 12 })
	local dir, file = H.new_db()
	H.seed(file, {
		{ MAC, 'a.com', prev, 1, 1 },
		{ MAC, 'b.com', cur, 2, 2 },
	}, { { mac = MAC, ip = '192.168.1.50', hostname = 'phone', first_seen = prev, last_seen = cur } }, {
		{ key = 'a.com' }, { key = 'b.com' },
	})
	assert(db.exec(file, string.format([[
INSERT INTO sessions VALUES (%s,'a.com',%d,%d,1,1,1);
INSERT INTO sessions VALUES (%s,'b.com',%d,%d,2,2,1);]],
		db.quote(MAC), prev, prev, db.quote(MAC), cur, cur)))
	local r = api.call('device_detail', { mac = MAC }, env_for(dir, file, now))
	H.ok(not r.error, 'ok: ' .. tostring(r.error))
	for _, d in ipairs(r.days) do
		H.eq(tostring(d):sub(1, 7), '2026-11', 'day in current month: ' .. d)
	end
	H.ok(#r.days >= 1, 'has current-month day')
	local bad = api.call('device_detail', { mac = MAC, day = '2026-10-20' }, env_for(dir, file, now))
	H.eq(bad.error, 'bad_day', 'prev month day rejected')
	H.rmrf(dir)
end)

H.case('W11', 'device_months returns sorted month keys desc', function()
	local now = os.time({ year = 2026, month = 11, day = 15, hour = 12 })
	local dir, file = H.new_db()
	H.seed(file, {}, { { mac = MAC, ip = '1.1.1.1', last_seen = now } }, {})
	assert(db.exec(file, string.format([[
INSERT INTO monthly_traffic VALUES ('2026-09',%s,'x.com','x.com',1,1);
INSERT INTO monthly_traffic VALUES ('2026-10',%s,'y.com','y.com',2,2);
INSERT INTO monthly_traffic VALUES ('2026-10',%s,'z.com','z.com',3,3);]],
		db.quote(MAC), db.quote(MAC), db.quote(MAC))))
	local r = api.call('device_months', { mac = MAC }, env_for(dir, file, now))
	H.eq(#r.months, 2, 'two months')
	H.eq(r.months[1], '2026-10', 'newest first')
	H.eq(r.months[2], '2026-09', 'older second')
	H.rmrf(dir)
end)

H.case('W12', 'device_month_summary totals + 其他 + sort by total desc', function()
	local now = os.time({ year = 2026, month = 11, day = 15, hour = 12 })
	local dir, file = H.new_db()
	H.seed(file, {}, { { mac = MAC, ip = '1.1.1.1', last_seen = now } }, {})
	assert(db.exec(file, string.format([[
INSERT INTO monthly_traffic VALUES ('2026-10',%s,'big.com','big.com',100,900);
INSERT INTO monthly_traffic VALUES ('2026-10',%s,'mid.com','mid.com',50,50);
INSERT INTO monthly_traffic VALUES ('2026-10',%s,'__other__','其他',10,15);]],
		db.quote(MAC), db.quote(MAC), db.quote(MAC))))
	local r = api.call('device_month_summary', { mac = MAC, month = '2026-10' }, env_for(dir, file, now))
	H.eq(#r.rows, 3, '3 rows')
	H.eq(r.rows[1].target, 'big.com', 'highest first')
	H.eq(r.rows[2].target, 'mid.com', 'mid')
	H.eq(r.rows[3].target, '__other__', '其他 last')
	H.eq(r.rows[3].display, '其他', '其他 display')
	H.eq(r.bytes_total, 100 + 900 + 50 + 50 + 10 + 15, 'totals match')
	H.eq(r.rows[1].bytes_total, 1000, 'big total')
	H.rmrf(dir)
end)

H.case('W13', 'ACL read includes device_months and device_month_summary', function()
	local acl = assert(json.decode(H.read('./luci-app-netmonitor/root/usr/share/rpcd/acl.d/luci-app-netmonitor.json')))
	local read = {}
	for _, m in ipairs(acl['luci-app-netmonitor'].read.ubus.netmonitor) do read[m] = true end
	H.ok(read.device_months, 'device_months')
	H.ok(read.device_month_summary, 'device_month_summary')
	H.ok(api.METHODS.device_months, 'method registered')
	H.ok(api.METHODS.device_month_summary, 'summary registered')
end)

H.case('W18', 'calendar-month: early month UCI=7d does not drive cutoff/estimate/confirm', function()
	local tu = require 'netmonitor.timeutil'
	-- Early in month: calendar cutoff is month_start, not UCI 7 days.
	local now = os.time({ year = 2026, month = 11, day = 3, hour = 12 })
	local dir, file = H.new_db()
	local env = env_for(dir, file, now)
	env.cfg = H.cfg({ db_path = dir, retention_value = 7, retention_unit = 'day' })
	H.eq(tu.retention_cutoff(now, env.cfg), tu.month_start(now), 'cutoff = month_start not UCI')
	local allowed = tu.allowed_ranges(now, env.cfg)
	local joined = table.concat(allowed, ',')
	-- 7d reaches before Nov 1 → not offered; not because of UCI but calendar month.
	H.ok(not joined:find('7d'), '7d not offered early in month')
	H.ok(not joined:find('30d'), '30d not offered')
	H.ok(joined:find('today') or joined:find('1h'), 'in-month ranges offered')
	local est = api.call('estimate', { retention_value = 7, retention_unit = 'day' }, env)
	H.eq(est.detail_retention, 'calendar_month', 'estimate tagged calendar_month')
	local month_secs = tu.next_month_start(now) - tu.month_start(now)
	H.eq(est.retention_seconds, month_secs, 'estimate window = full calendar month')
	-- Changing UCI retention must not trigger need_confirm (cutoff unchanged).
	env.saver = function() end
	env.runner = function() return true end
	env.cron_runner = false
	env.fsops = H.fsops(10 * H.GiB, 32 * H.GiB, true)
	local r = api.call('set_config', { retention_value = 1, retention_unit = 'day' }, env)
	H.ok(r.ok, 'set_config ok')
	H.ok(not r.need_confirm, 'no false shorten-retention confirm')
	H.eq(r.detail_retention, 'calendar_month', 'set_config notes calendar_month')
	H.rmrf(dir)
end)

H.case('W19', 'devices/overview list last_seen-in-range with zero samples', function()
	local now = os.time({ year = 2026, month = 11, day = 15, hour = 12 })
	local dir, file = H.new_db()
	local quiet = 'aa:bb:cc:00:99:01'
	H.seed(file, {
		{ MAC, 'busy.com', now - 100, 10, 20 },
	}, {
		{ mac = MAC, ip = '192.168.1.50', hostname = 'busy', first_seen = now - 1000, last_seen = now - 50 },
		{ mac = quiet, ip = '192.168.1.99', hostname = 'quiet', first_seen = now - 1000, last_seen = now - 30 },
	}, { { key = 'busy.com' } })
	local env = env_for(dir, file, now)
	local d = api.call('devices', { range = '1h' }, env)
	H.ok(not d.error, 'devices: ' .. tostring(d.error))
	local found = false
	for _, row in ipairs(d.devices) do
		if row.mac == quiet then found = true end
	end
	H.ok(found, 'quiet last_seen device listed in devices')
	local ov = api.call('overview', { range = '1h' }, env)
	H.ok(not ov.error, 'overview ok')
	local found_ov = false
	for _, row in ipairs(ov.devices) do
		if row.mac == quiet then found_ov = true end
	end
	H.ok(found_ov, 'quiet last_seen device listed in overview')
	H.rmrf(dir)
end)

H.case('W22', 'pair_rows uses covering index idx_samples_ts_device_target', function()
	local src = H.read('./netmonitor/files/lib/netmonitor/api.lua')
	H.ok(src:find('INDEXED BY idx_samples_ts_device_target'), 'covering index in pair_rows')
	H.ok(not src:find('INDEXED BY idx_samples_ts[^_]'), 'old idx_samples_ts not forced')
end)
