-- Device detail: sessions grouped by calendar day. Collector soft-rolls open
-- sessions at local midnight (stats only). Legacy rows that still span midnight
-- are split here; split segments take bytes from samples in-range.
local timeutil = require 'netmonitor.timeutil'

local M = {}

local function segments(s)
	local out = {}
	local start, last = tonumber(s.started_at), tonumber(s.last_seen_at)
	local cur = start
	while cur <= last do
		local next_day = timeutil.next_day_start(cur)
		local seg_end = math.min(last, next_day - 1)
		out[#out + 1] = { day = timeutil.day_key(cur), started_at = cur, last_seen_at = seg_end }
		cur = next_day
	end
	return out
end

-- sessions: rows {device,target,display,unresolved,started_at,last_seen_at,bytes_up,bytes_down,closed}
-- samples: rows {target, ts, bytes_up, bytes_down} for the same device
-- opts: { day = 'YYYY-MM-DD'?, sort = 'time'|'traffic'|'target' }
function M.build(sessions, samples, opts)
	opts = opts or {}
	local by_target = {}
	for _, x in ipairs(samples or {}) do
		local t = by_target[x.target] or {}
		t[#t + 1] = x
		by_target[x.target] = t
	end

	local days, order = {}, {}
	for _, s in ipairs(sessions) do
		local segs = segments(s)
		for _, seg in ipairs(segs) do
			if not opts.day or opts.day == seg.day then
				local up, down
				if #segs == 1 then
					up, down = tonumber(s.bytes_up) or 0, tonumber(s.bytes_down) or 0
				else
					up, down = 0, 0
					for _, x in ipairs(by_target[s.target] or {}) do
						local ts = tonumber(x.ts)
						if ts >= seg.started_at and ts <= seg.last_seen_at then
							up = up + (tonumber(x.bytes_up) or 0)
							down = down + (tonumber(x.bytes_down) or 0)
						end
					end
				end
				local d = days[seg.day]
				if not d then
					d = { day = seg.day, bytes_up = 0, bytes_down = 0, rows = {} }
					days[seg.day] = d
					order[#order + 1] = seg.day
				end
				d.bytes_up = d.bytes_up + up
				d.bytes_down = d.bytes_down + down
				-- Day-scoped views already clipped to one calendar day: never
				-- surface 「跨日」there (yesterday stays on yesterday's chip).
				d.rows[#d.rows + 1] = {
					target = s.target, display = s.display or s.target,
					unresolved = tonumber(s.unresolved) == 1,
					source = s.source,
					asn_org = s.asn_org,
					started_at = seg.started_at, last_seen_at = seg.last_seen_at,
					duration = seg.last_seen_at - seg.started_at,
					bytes_up = up, bytes_down = down, bytes_total = up + down,
					split = (not opts.day) and (#segs > 1),
					-- Only the final segment of an open session is 「进行中」(F5).
					active = tonumber(s.closed) == 0
						and seg.last_seen_at == tonumber(s.last_seen_at),
				}
			end
		end
	end

	table.sort(order, function(a, b) return a > b end)
	local cmp
	if opts.sort == 'traffic' then
		cmp = function(a, b)
			if a.bytes_total ~= b.bytes_total then return a.bytes_total > b.bytes_total end
			return a.started_at > b.started_at
		end
	elseif opts.sort == 'target' then
		cmp = function(a, b)
			if a.display ~= b.display then return a.display < b.display end
			return a.started_at > b.started_at
		end
	else
		cmp = function(a, b)
			if a.started_at ~= b.started_at then return a.started_at > b.started_at end
			return a.display < b.display
		end
	end
	local out = {}
	for _, k in ipairs(order) do
		local d = days[k]
		table.sort(d.rows, cmp)
		d.bytes_total = d.bytes_up + d.bytes_down
		out[#out + 1] = d
	end
	return out
end

-- Merge same-display rows for ubus-sized payloads. Busy devices can produce
-- thousands of sessions/day (~1MB+ JSON), which hangs/times out rpcd and logs
-- the LuCI user out. Keep children only when the flat list is small enough.
-- opts.max_flat default 400.
function M.merge_by_display(rows, opts)
	opts = opts or {}
	local max_flat = tonumber(opts.max_flat) or 400
	local map, order = {}, {}
	for _, r in ipairs(rows or {}) do
		local key = tostring(r.display or r.target or '')
		local g = map[key]
		if not g then
			g = {
				target = r.target,
				display = r.display or r.target,
				source = r.source,
				asn_org = r.asn_org,
				bytes_up = 0, bytes_down = 0, bytes_total = 0, duration = 0,
				started_at = tonumber(r.started_at) or 0,
				unresolved = true, active = false, split = false,
				session_count = 0, children = {},
			}
			map[key] = g
			order[#order + 1] = key
		end
		g.session_count = g.session_count + 1
		g.bytes_up = g.bytes_up + (tonumber(r.bytes_up) or 0)
		g.bytes_down = g.bytes_down + (tonumber(r.bytes_down) or 0)
		g.bytes_total = g.bytes_total + (tonumber(r.bytes_total) or 0)
		g.duration = g.duration + (tonumber(r.duration) or 0)
		local st = tonumber(r.started_at) or 0
		if st > 0 and (g.started_at == 0 or st < g.started_at) then g.started_at = st end
		if not r.unresolved then g.unresolved = false end
		if r.active then g.active = true end
		if r.split then g.split = true end
		g.children[#g.children + 1] = r
	end
	local keep_children = #(rows or {}) <= max_flat
	local out = {}
	for _, k in ipairs(order) do
		local g = map[k]
		if not keep_children then g.children = nil end
		out[#out + 1] = g
	end
	return out, not keep_children
end

return M
