-- Device detail: sessions grouped by calendar day. Sessions crossing local
-- midnight are split; split segments take their bytes from the samples that
-- fall inside them, so no traffic is invented.
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
				d.rows[#d.rows + 1] = {
					target = s.target, display = s.display or s.target,
					unresolved = tonumber(s.unresolved) == 1,
					started_at = seg.started_at, last_seen_at = seg.last_seen_at,
					duration = seg.last_seen_at - seg.started_at,
					bytes_up = up, bytes_down = down, bytes_total = up + down,
					split = #segs > 1,
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

return M
