-- Sampling-derived sessions (ADR-003): a device<->target pair stays in one
-- session while byte deltas keep arriving within idle_gap seconds.
local M = {}

function M.new()
	return { open = {} }
end

local function pair_key(device, target)
	return device .. '\t' .. target
end
M.pair_key = pair_key

-- Restore open sessions (closed = 0) loaded from the DB after a restart.
function M.restore(state, rows)
	for _, r in ipairs(rows or {}) do
		state.open[pair_key(r.device, r.target)] = {
			device = r.device, target = r.target,
			started_at = tonumber(r.started_at), last_seen_at = tonumber(r.last_seen_at),
			bytes_up = tonumber(r.bytes_up) or 0, bytes_down = tonumber(r.bytes_down) or 0,
			closed = 0,
		}
	end
end

-- Apply one poll's deltas: { {device=, target=, up=, down=}, ... }.
-- Returns the list of session rows that changed (to upsert).
function M.stitch(state, ts, deltas, idle_gap)
	local changed, seen = {}, {}
	for _, d in ipairs(deltas) do
		local k = pair_key(d.device, d.target)
		local s = state.open[k]
		if s and ts - s.last_seen_at > idle_gap then
			s.closed = 1
			changed[#changed + 1] = s
			s = nil
		end
		if not s then
			s = { device = d.device, target = d.target, started_at = ts,
				last_seen_at = ts, bytes_up = 0, bytes_down = 0, closed = 0 }
			state.open[k] = s
		end
		s.last_seen_at = ts
		s.bytes_up = s.bytes_up + (d.up or 0)
		s.bytes_down = s.bytes_down + (d.down or 0)
		if not seen[s] then
			seen[s] = true
			changed[#changed + 1] = s
		end
	end
	for k, s in pairs(state.open) do
		if s.closed == 0 and ts - s.last_seen_at > idle_gap then
			s.closed = 1
			changed[#changed + 1] = s
			state.open[k] = nil
		elseif s.closed == 1 then
			state.open[k] = nil
		end
	end
	return changed
end

function M.duration(s)
	return (s.last_seen_at or 0) - (s.started_at or 0)
end

return M
