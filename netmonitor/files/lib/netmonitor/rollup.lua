-- Calendar-month rollup: all complete months with leftover detail →
-- monthly_traffic Top100 + 其他, then purge only those months.
local timeutil = require 'netmonitor.timeutil'
local db = require 'netmonitor.db'

local M = {}

M.TOP_N = 100
M.OTHER_TARGET = '__other__'
M.OTHER_DISPLAY = '其他'

local function aggregate_rows(db_file, start_ts, end_ts)
	local qs, qe = db.quote(start_ts), db.quote(end_ts)
	local samples = db.query(db_file, string.format([[
SELECT s.device AS device, s.target AS target,
  SUM(s.bytes_up) AS bytes_up, SUM(s.bytes_down) AS bytes_down,
  COALESCE(MAX(t.display), s.target) AS display
FROM traffic_samples s
LEFT JOIN targets t ON t.key = s.target
WHERE s.ts >= %s AND s.ts < %s
GROUP BY s.device, s.target;]], qs, qe))
	if samples and #samples > 0 then return samples end
	-- Fallback: sessions that started in the month window.
	return db.query(db_file, string.format([[
SELECT s.device AS device, s.target AS target,
  SUM(s.bytes_up) AS bytes_up, SUM(s.bytes_down) AS bytes_down,
  COALESCE(MAX(t.display), s.target) AS display
FROM sessions s
LEFT JOIN targets t ON t.key = s.target
WHERE s.started_at >= %s AND s.started_at < %s
GROUP BY s.device, s.target;]], qs, qe)) or {}
end

-- Rank per device: total DESC, then target ASC (deterministic ties). Keep Top N; rest → 其他.
local function top_n_per_device(rows, n)
	local by_dev = {}
	for _, r in ipairs(rows) do
		local mac = r.device
		local list = by_dev[mac]
		if not list then
			list = {}
			by_dev[mac] = list
		end
		list[#list + 1] = {
			target = r.target,
			display = r.display or r.target,
			bytes_up = tonumber(r.bytes_up) or 0,
			bytes_down = tonumber(r.bytes_down) or 0,
		}
	end
	local out = {}
	for mac, list in pairs(by_dev) do
		table.sort(list, function(a, b)
			local ta, tb = a.bytes_up + a.bytes_down, b.bytes_up + b.bytes_down
			if ta ~= tb then return ta > tb end
			return tostring(a.target) < tostring(b.target)
		end)
		local other_up, other_down = 0, 0
		for i, row in ipairs(list) do
			if i <= n then
				out[#out + 1] = {
					device = mac,
					target = row.target,
					display = row.display,
					bytes_up = row.bytes_up,
					bytes_down = row.bytes_down,
				}
			else
				other_up = other_up + row.bytes_up
				other_down = other_down + row.bytes_down
			end
		end
		if other_up > 0 or other_down > 0 then
			out[#out + 1] = {
				device = mac,
				target = M.OTHER_TARGET,
				display = M.OTHER_DISPLAY,
				bytes_up = other_up,
				bytes_down = other_down,
			}
		end
	end
	return out
end

function M.month_already_rolled(db_file, month_key)
	local rows = db.query(db_file,
		'SELECT 1 AS x FROM monthly_traffic WHERE month = ' .. db.quote(month_key) .. ' LIMIT 1;')
	return rows and rows[1] ~= nil
end

-- Discover complete calendar months (< current) that still have detail rows.
-- Returns oldest-first list of { key, start_ts, end_ts }.
function M.discover_complete_months_with_detail(db_file, now)
	now = now or os.time()
	local cur_start = timeutil.month_start(now)
	local rows = db.query(db_file, string.format([[
SELECT MIN(ts) AS t0 FROM (
  SELECT ts FROM traffic_samples WHERE ts < %s
  UNION ALL
  SELECT started_at AS ts FROM sessions WHERE started_at < %s
  UNION ALL
  SELECT last_seen_at AS ts FROM sessions WHERE last_seen_at < %s
);]], db.quote(cur_start), db.quote(cur_start), db.quote(cur_start)))
	local t0 = rows and rows[1] and tonumber(rows[1].t0)
	if not t0 then return {} end
	local out = {}
	local start = timeutil.month_start(t0)
	while start < cur_start do
		local finish = timeutil.next_month_start(start)
		local qs, qe = db.quote(start), db.quote(finish)
		local hit = db.query(db_file, string.format([[
SELECT 1 AS x WHERE EXISTS (
  SELECT 1 FROM traffic_samples WHERE ts >= %s AND ts < %s
) OR EXISTS (
  SELECT 1 FROM sessions WHERE started_at >= %s AND started_at < %s
) OR EXISTS (
  SELECT 1 FROM sessions WHERE last_seen_at >= %s AND last_seen_at < %s
) LIMIT 1;]], qs, qe, qs, qe, qs, qe))
		if hit and hit[1] then
			out[#out + 1] = {
				key = timeutil.month_key(start),
				start_ts = start,
				end_ts = finish,
			}
		end
		start = finish
	end
	return out
end

local function purge_month_detail(db_file, start_ts, end_ts)
	local qs, qe = db.quote(start_ts), db.quote(end_ts)
	return db.exec(db_file, table.concat({
		'BEGIN;',
		'DELETE FROM traffic_samples WHERE ts >= ' .. qs .. ' AND ts < ' .. qe .. ';',
		'DELETE FROM sessions WHERE last_seen_at >= ' .. qs .. ' AND last_seen_at < ' .. qe .. ';',
		'DELETE FROM sessions WHERE started_at >= ' .. qs .. ' AND started_at < ' .. qe .. ';',
		'COMMIT;',
	}, '\n'))
end

-- Roll one complete month: insert Top100 if needed, then purge that month's detail.
-- Empty months (no aggregate rows) still purge leftover detail.
function M.rollup_month(db_file, month_key, start_ts, end_ts)
	if not M.month_already_rolled(db_file, month_key) then
		local agg = aggregate_rows(db_file, start_ts, end_ts)
		local ranked = top_n_per_device(agg, M.TOP_N)
		if #ranked > 0 then
			local sql = { 'BEGIN;' }
			local qm = db.quote(month_key)
			for _, r in ipairs(ranked) do
				sql[#sql + 1] = string.format(
					'INSERT OR IGNORE INTO monthly_traffic(month, device, target, display, bytes_up, bytes_down) VALUES (%s,%s,%s,%s,%s,%s);',
					qm, db.quote(r.device), db.quote(r.target), db.quote(r.display),
					db.quote(r.bytes_up), db.quote(r.bytes_down))
			end
			sql[#sql + 1] = 'COMMIT;'
			local ok, err = db.exec(db_file, table.concat(sql, '\n'))
			if not ok then return nil, err end
		end
	end
	local ok, err = purge_month_detail(db_file, start_ts, end_ts)
	if not ok then return nil, err end
	return true, nil, month_key
end

-- Roll every complete month that still has leftover detail (oldest-first).
-- Never deletes a month that failed to roll when it had data.
function M.rollup_complete_months(db_file, now)
	now = now or os.time()
	local months = M.discover_complete_months_with_detail(db_file, now)
	local rolled = {}
	for _, m in ipairs(months) do
		local ok, err = M.rollup_month(db_file, m.key, m.start_ts, m.end_ts)
		if not ok then
			return nil, err, rolled
		end
		rolled[#rolled + 1] = m.key
	end
	return true, nil, rolled
end

-- Back-compat wrapper: roll all leftover complete months (not only previous).
function M.rollup_previous_month(db_file, now)
	local ok, err, rolled = M.rollup_complete_months(db_file, now)
	if not ok then return nil, err end
	local key = rolled and rolled[#rolled]
	if not key then
		local start_ts = timeutil.prev_month_bounds(now or os.time())
		key = timeutil.month_key(start_ts)
	end
	return true, nil, key
end

return M
