-- Live-rate cache from recent sampling windows.
local M = {}

function M.new()
	return { hist = {} }
end

-- Record one poll: deltas { {device=, target=, up=, down=}, ... }.
function M.record(state, ts, deltas, keep)
	local per_dev, per_pair = {}, {}
	for _, d in ipairs(deltas) do
		local e = per_dev[d.device] or { up = 0, down = 0 }
		e.up = e.up + (d.up or 0)
		e.down = e.down + (d.down or 0)
		per_dev[d.device] = e
		per_pair[d.device .. '|' .. d.target] = true
	end
	table.insert(state.hist, { ts = ts, dev = per_dev, pair = per_pair })
	while #state.hist > 0 and state.hist[1].ts <= ts - keep do
		table.remove(state.hist, 1)
	end
end

-- Devices with byte deltas within `recent` seconds are live; rate is the
-- byte sum over `window` seconds.
function M.snapshot(state, now, window, recent)
	local devices, pairs_live = {}, {}
	for _, h in ipairs(state.hist) do
		if h.ts > now - window then
			for mac, e in pairs(h.dev) do
				local d = devices[mac] or { up = 0, down = 0, last_ts = 0 }
				d.up = d.up + e.up
				d.down = d.down + e.down
				if h.ts > d.last_ts then d.last_ts = h.ts end
				devices[mac] = d
			end
			if h.ts > now - recent then
				for p in pairs(h.pair) do pairs_live[p] = true end
			end
		end
	end
	local out = {}
	for mac, d in pairs(devices) do
		local is_live = d.last_ts > now - recent
		out[mac] = {
			live = is_live,
			rate_up = is_live and math.floor(d.up / window) or 0,
			rate_down = is_live and math.floor(d.down / window) or 0,
			last_ts = d.last_ts,
		}
	end
	return { devices = out, pairs = pairs_live }
end

return M
