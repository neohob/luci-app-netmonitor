-- Wall-clock (calendar) time helpers. All math uses os.time/os.date in the
-- router's local timezone, never uptime.
local M = {}

M.UNITS = { hour = true, day = true, week = true, month = true, year = true }

-- Subtract `value` calendar units from `now`; months/years follow the
-- calendar (os.time normalizes e.g. month 0 -> December of previous year).
function M.shift(now, value, unit)
	local t = os.date('*t', now)
	if unit == 'hour' then t.hour = t.hour - value
	elseif unit == 'day' then t.day = t.day - value
	elseif unit == 'week' then t.day = t.day - 7 * value
	elseif unit == 'month' then t.month = t.month - value
	elseif unit == 'year' then t.year = t.year - value
	else return nil, 'bad_unit' end
	t.isdst = nil
	return os.time(t)
end

function M.day_start(ts)
	local t = os.date('*t', ts)
	return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
end

function M.next_day_start(ts)
	local t = os.date('*t', ts)
	return os.time({ year = t.year, month = t.month, day = t.day + 1, hour = 0, min = 0, sec = 0 })
end

function M.day_key(ts)
	return os.date('%Y-%m-%d', ts)
end

function M.parse_day(key)
	local y, m, d = tostring(key or ''):match('^(%d%d%d%d)-(%d%d)-(%d%d)$')
	if not y then return nil end
	return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 })
end

-- Query ranges offered as UI chips.
M.RANGES = {
	{ key = '15m', value = 15, unit = 'min' },
	{ key = '1h', value = 1, unit = 'hour' },
	{ key = '6h', value = 6, unit = 'hour' },
	{ key = 'today', unit = 'today' },
	{ key = '24h', value = 24, unit = 'hour' },
	{ key = '7d', value = 7, unit = 'day' },
	{ key = '30d', value = 30, unit = 'day' },
	{ key = '90d', value = 90, unit = 'day' },
	{ key = '1y', value = 1, unit = 'year' },
}

function M.range_since(key, now)
	for _, r in ipairs(M.RANGES) do
		if r.key == key then
			if r.unit == 'min' then return now - 60 * r.value end
			if r.unit == 'today' then return M.day_start(now) end
			return M.shift(now, r.value, r.unit)
		end
	end
	return nil, 'bad_range'
end

function M.retention_cutoff(now, cfg)
	return M.shift(now, cfg.retention_value, cfg.retention_unit)
end

-- Resolve a range against the retention window. Ranges reaching further
-- back than retention are rejected rather than silently clamped.
function M.resolve_range(key, now, cfg)
	local since, err = M.range_since(key, now)
	if not since then return nil, err end
	local cutoff = M.retention_cutoff(now, cfg)
	if since < cutoff then
		return nil, 'range_exceeds_retention'
	end
	return since
end

function M.allowed_ranges(now, cfg)
	local out = {}
	local cutoff = M.retention_cutoff(now, cfg)
	for _, r in ipairs(M.RANGES) do
		local since = M.range_since(r.key, now)
		if since >= cutoff then out[#out + 1] = r.key end
	end
	return out
end

return M
